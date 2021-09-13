{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE LambdaCase #-}
{-# Language TypeApplications #-}
{-# Language ScopedTypeVariables #-}
{-# Language NamedFieldPuns #-}
{-# Language DataKinds #-}
{-# LANGUAGE ApplicativeDo, OverloadedLists, PatternSynonyms, ViewPatterns #-}

module Type (typecheck, bound, lookupVars, defaultStore, metaType, Err) where

import Data.List
import EVM.ABI
import EVM.Solidity (SlotType(..))
import Data.Map.Strict    (Map,keys,findWithDefault)
import Data.Maybe
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict    as Map -- abandon in favor of [(a,b)]?
import Data.Typeable hiding (typeRep)
import Type.Reflection (typeRep)

import Data.ByteString (ByteString)

import Control.Applicative
import Control.Monad (join,unless)
import Control.Monad.Writer
import Data.List.Extra (snoc,unsnoc)
import Data.Function (on)
import Data.Functor
import Data.Functor.Alt
import Data.Foldable
import Data.Traversable
import Data.Tuple.Extra (uncurry3)

import Data.Singletons

import Syntax
import Syntax.Timing
import Syntax.Untyped (Pn)
--import Syntax.Untyped hiding (Post,Constant,Rewrite)
import qualified Syntax.Untyped as U
import Syntax.Typed
import ErrorLogger
import Parse

type Err a = Error TypeErr a

type TypeErr = String

typecheck :: [U.RawBehaviour] -> Err [Claim]
typecheck behvs = (S store:) . concat <$> traverse (splitBehaviour store) behvs
                  <* noDuplicateContracts behvs
                  <* traverse noDuplicateVars [creates | U.Definition _ _ _ _ creates _ _ _ <- behvs]
  where
    store = lookupVars behvs

noDuplicateContracts :: [U.RawBehaviour] -> Err ()
noDuplicateContracts behvs = noDuplicates [(pn,contract) | U.Definition pn contract _ _ _ _ _ _ <- behvs]
                             $ \c -> "Multiple definitions of " <> c <> "."

noDuplicateVars :: U.Creates -> Err ()
noDuplicateVars (U.Creates assigns) = noDuplicates (fmap fst . fromAssign <$> assigns)
                                      $ \x -> "Multiple definitions of " <> x <> "."

noDuplicates :: [(Pn,Id)] -> (Id -> String) -> Err ()
noDuplicates xs errmsg = traverse_ (throw . fmap errmsg) . duplicatesBy ((==) `on` snd) $ xs


--- Finds storage declarations from constructors
lookupVars :: [U.RawBehaviour] -> Store
lookupVars = foldMap $ \case
  U.Transition {} -> mempty
  U.Definition _ contract _ _ (U.Creates assigns) _ _ _ ->
    Map.singleton contract . Map.fromList $ snd . fromAssign <$> assigns

fromAssign :: U.Assign -> (Pn, (Id, SlotType))
fromAssign (U.AssignVal (U.StorageVar pn typ var) _) = (pn, (var, typ))
fromAssign (U.AssignMany (U.StorageVar pn typ var) _) = (pn, (var, typ))
fromAssign (U.AssignStruct _ _) = error "TODO: assignstruct"

-- | filters out duplicate entries in list
duplicatesBy :: (a -> a -> Bool) -> [a] -> [a]
duplicatesBy f [] = []
duplicatesBy f (x:xs) =
  let e = [x | any (f x) xs]
  in e <> duplicatesBy f xs

-- | The type checking environment. 
data Env = Env
  { contract :: Id              -- ^ The name of the current contract.
  , store    :: Map Id SlotType -- ^ This contract's storage entry names and their types.
  , theirs   :: Store           -- ^ Mapping from contract names to a map of their entry names and their types.
  , calldata :: Map Id MType    -- ^ The calldata var names and their types.
  }

-- typing of eth env variables
defaultStore :: [(EthEnv, MType)]
defaultStore =
  [(Callvalue, Integer),
   (Caller, Integer),
   (Blockhash, Integer),
   (Blocknumber, Integer),
   (Difficulty, Integer),
   (Timestamp, Integer),
   (Gaslimit, Integer),
   (Coinbase, Integer),
   (Chainid, Integer),
   (This, Integer),
   (Origin, Integer),
   (Nonce, Integer),
   (Calldepth, Integer)
   --others TODO
  ]

mkEnv :: Id -> Store -> [Decl] -> Env
mkEnv contract store decls = Env
  { contract = contract
  , store    = fromMaybe mempty (Map.lookup contract store)
  , theirs   = store
  , calldata = abiVars
  }
 where
   abiVars = Map.fromList $ map (\(Decl typ var) -> (var, metaType typ)) decls

-- checks a transition given a typing of its storage variables
splitBehaviour :: Store -> U.RawBehaviour -> Err [Claim]
splitBehaviour store (U.Transition pn name contract iface@(Interface _ decls) iffs cases posts) =
  -- constrain integer calldata variables (TODO: other types)
  fmap concatMap (caseClaims
                    <$> checkIffs env iffs
                    <*> traverse (inferExpr env sing) posts)
    <*> traverse (checkCase env) normalizedCases
  <* noIllegalWilds
  where
    env :: Env
    env = mkEnv contract store decls

    noIllegalWilds :: Err ()
    noIllegalWilds = case cases of
      U.Direct   _  -> pure ()
      U.Branches bs -> for_ (init bs) $ \c@(U.Case p _ _) ->
                          when (isWild c) (throw (p, "Wildcard pattern must be last case"))  -- TODO test when wildcard isn't last

    -- translate wildcards into negation of other branches and translate a single case to a wildcard 
    normalizedCases :: [U.Case]
    normalizedCases = case cases of
      U.Direct   post -> [U.Case nowhere (U.WildExp nowhere) post]
      U.Branches bs ->
        let
          Just (rest, last@(U.Case pn _ post)) = unsnoc bs
          negation = U.ENot nowhere $
                        foldl (\acc (U.Case _ e _) -> U.EOr nowhere e acc) (U.BoolLit nowhere False) rest
        in rest `snoc` (if isWild last then U.Case pn negation post else last)

    -- | split case into pass and fail case
    caseClaims :: [Exp Bool Untimed] -> [Exp Bool Timed] -> ([Exp Bool Untimed], [Rewrite], Maybe (TypedExp Timed)) -> [Claim]
    caseClaims []   postcs (if',storage,ret) =
      [ B $ Behaviour name Pass contract iface if' postcs storage ret ]
    caseClaims iffs postcs (if',storage,ret) =
      [ B $ Behaviour name Pass contract iface (if' <> iffs) postcs storage ret,
        B $ Behaviour name Fail contract iface (if' <> [Neg (mconcat iffs)]) [] (Constant . locFromRewrite <$> storage) Nothing ]

splitBehaviour store (U.Definition pn contract iface@(Interface _ decls) iffs (U.Creates assigns) extStorage postcs invs) =
  if not . null $ extStorage then error "TODO: support extStorage in constructor"
  else let env = mkEnv contract store decls
  in do
    stateUpdates <- concat <$> traverse (checkAssign env) assigns
    iffs' <- checkIffs env iffs
    invariants <- traverse (inferExpr env sing) invs
    ensures <- traverse (inferExpr env sing) postcs

    pure $ invrClaims invariants <> ctorClaims stateUpdates iffs' ensures
  where
    invrClaims invariants = I . Invariant contract [] [] <$> invariants
    ctorClaims updates iffs' ensures
      | null iffs' = [ C $ Constructor contract Pass iface []                    ensures updates [] ]
      | otherwise  = [ C $ Constructor contract Pass iface iffs'                 ensures updates []
                     , C $ Constructor contract Fail iface [Neg (mconcat iffs')] ensures []      [] ]

checkCase :: Env -> U.Case -> Err ([Exp Bool Untimed], [Rewrite], Maybe (TypedExp Timed))
checkCase env c@(U.Case pn pre post)
  | isWild c  = checkCase env (U.Case pn (U.BoolLit (getPosn pre) True) post)
  | otherwise = do
      if' <- inferExpr env sing pre
      (storage,return) <- checkPost env post
      pure ([if'],storage,return)

-- | Ensures that none of the storage variables are read in the supplied `Expr`.
noStorageRead :: Map Id SlotType -> U.Expr -> Err ()
noStorageRead store expr = for_ (keys store) $ \name ->
  for_ (findWithDefault [] name (idFromRewrites expr)) $ \pn ->
    throw (pn,"Cannot read storage in creates block")

makeUpdate :: Env -> Sing a -> Id -> [TypedExp Untimed] -> Exp a Untimed -> StorageUpdate
makeUpdate env@Env{contract} typ name ixs newVal =
  case typ of
    SInteger -> IntUpdate   (IntItem   contract name ixs) newVal
    SBoolean -> BoolUpdate  (BoolItem  contract name ixs) newVal
    SByteStr -> BytesUpdate (BytesItem contract name ixs) newVal

-- ensures that key types match value types in an U.Assign
checkAssign :: Env -> U.Assign -> Err [StorageUpdate]
checkAssign env@Env{contract, store} (U.AssignVal (U.StorageVar pn (StorageValue typ) name) expr)
  = withSomeType (metaType typ) $ \stype ->
      sequenceA [makeUpdate env stype name [] <$> inferExpr env stype expr]
        <* noStorageRead store expr
checkAssign env@Env{store} (U.AssignMany (U.StorageVar pn (StorageMapping (keyType :| _) valType) name) defns)
  = for defns $ \def@(U.Defn e1 e2) -> checkDefn env keyType valType name def
                                     <* noStorageRead store e1
                                     <* noStorageRead store e2
checkAssign _ (U.AssignVal (U.StorageVar pn (StorageMapping _ _) _) expr)
  = throw (getPosn expr, "Cannot assign a single expression to a composite type")
checkAssign _ (U.AssignMany (U.StorageVar pn (StorageValue _) _) _)
  = throw (pn, "Cannot assign multiple values to an atomic type")
checkAssign _ _ = error "todo: support struct assignment in constructors"

-- ensures key and value types match when assigning a defn to a mapping
-- TODO: handle nested mappings
checkDefn :: Env -> AbiType -> AbiType -> Id -> U.Defn -> Err StorageUpdate
checkDefn env@Env{contract} keyType valType name (U.Defn k val) = withSomeType (metaType valType) $ \valType' ->
  makeUpdate env valType' name <$> checkIxs env (getPosn k) [k] [keyType] <*> inferExpr env valType' val

checkPost :: Env -> U.Post -> Err ([Rewrite], Maybe (TypedExp Timed))
checkPost env@Env{contract,calldata} (U.Post storage extStorage maybeReturn) = do
  returnexp <- traverse (typedExp scopedEnv) maybeReturn
  ourStorage <- checkEntries contract storage
  otherStorage <- checkStorages extStorage
  pure (ourStorage <> otherStorage, returnexp)
  where
    checkEntries :: Id -> [U.Storage] -> Err [Rewrite]
    checkEntries name entries = for entries $ \case
      U.Constant loc     -> Constant <$> checkPattern     (focus name scopedEnv) loc
      U.Rewrite  loc val -> Rewrite  <$> checkStorageExpr (focus name scopedEnv) loc val

    checkStorages :: [U.ExtStorage] -> Err [Rewrite]
    checkStorages [] = pure []
    checkStorages (U.ExtStorage name entries:xs) = mappend <$> checkEntries name entries <*> checkStorages xs
    checkStorages _ = error "TODO: check other storages"

    -- remove storage items from the env that are not mentioned on the LHS of a storage declaration
    scopedEnv :: Env
    scopedEnv = focus contract $ Env
      { contract = mempty
      , store    = mempty
      , theirs   = filtered
      , calldata = calldata
      }
      where
        filtered = flip Map.mapWithKey (theirs env) $ \name vars ->
          if name == contract
            then Map.filterWithKey (\slot _ -> slot `elem` localNames) vars
            else Map.filterWithKey
                  (\slot _ -> slot `elem` Map.findWithDefault [] name externalNames)
                  vars

    focus :: Id -> Env -> Env
    focus name unfocused@Env{theirs} = unfocused
      { contract = name
      , store    = Map.findWithDefault mempty name theirs
      }

    localNames :: [Id]
    localNames = nameFromStorage <$> storage

    externalNames :: Map Id [Id]
    externalNames = Map.fromList $ mapMaybe (\case
        U.ExtStorage name storages -> Just (name, nameFromStorage <$> storages)
        U.ExtCreates {} -> error "TODO: handle ExtCreate"
        U.WildStorage -> Nothing
      ) extStorage

checkStorageExpr :: Env -> U.Pattern -> U.Expr -> Err StorageUpdate
checkStorageExpr _ (U.PWild _) _ = error "TODO: add support for wild storage to checkStorageExpr"
checkStorageExpr env@Env{contract,store} (U.PEntry p name args) expr = case Map.lookup name store of
  Just (StorageValue typ) -> withSomeType (metaType typ) $ \typ' ->
    makeUpdate env typ' name [] <$> inferExpr env typ' expr
  Just (StorageMapping argtyps valType) -> withSomeType (metaType valType) $ \valType' ->
    makeUpdate env valType' name <$> checkIxs env p args (NonEmpty.toList argtyps) <*> inferExpr env valType' expr
  Nothing -> throw (p, "Unknown storage variable: " <> show name)

checkPattern :: Env -> U.Pattern -> Err StorageLocation
checkPattern _ (U.PWild _) = error "TODO: checkPattern for Wild storage"
checkPattern env@Env{contract,store} (U.PEntry p name args) =
  case Map.lookup name store of
    Just (StorageValue t) -> makeLocation t []
    Just (StorageMapping argtyps t) -> makeLocation t (NonEmpty.toList argtyps)
    Nothing -> throw (p, "Unknown storage variable: " <> show name)
  where
    makeLocation :: AbiType -> [AbiType] -> Err StorageLocation
    makeLocation locType argTypes = do
      indexExprs <- checkIxs env p args argTypes -- TODO possibly output errormsg with `name` in `checkIxs`?
      pure $ case metaType locType of
        Integer -> IntLoc   $ IntItem   contract name indexExprs
        Boolean -> BoolLoc  $ BoolItem  contract name indexExprs
        ByteStr -> BytesLoc $ BytesItem contract name indexExprs

checkIffs :: Env -> [U.IffH] -> Err [Exp Bool Untimed]
checkIffs env = foldr check (pure [])
  where
    check (U.Iff   _     exps) acc = mappend <$> traverse (inferExpr env sing) exps                    <*> acc
    check (U.IffIn _ typ exps) acc = mappend <$> traverse (fmap (bound typ) . inferExpr env sing) exps <*> acc
--checkIffs env (U.Iff _ exps:xs) = do
--  hd <- traverse (inferExpr env sing) exps
--  tl <- checkIffs env xs
--  pure $ hd <> tl
--checkIffs env (U.IffIn _ typ exps:xs) = do
--  hd <- traverse (inferExpr env sing) exps
--  tl <- checkIffs env xs
--  pure $ map (bound typ) hd <> tl
--checkIffs _ [] = pure []

bound :: AbiType -> Exp Integer t -> Exp Bool t
bound typ e = And (LEQ (lowerBound typ) e) $ LEQ e (upperBound typ)

lowerBound :: AbiType -> Exp Integer t
lowerBound (AbiIntType a) = IntMin a
-- todo: other negatives?
lowerBound _ = LitInt 0

-- todo, the rest
upperBound :: AbiType -> Exp Integer t
upperBound (AbiUIntType n) = UIntMax n
upperBound (AbiIntType n) = IntMax n
upperBound AbiAddressType = UIntMax 160
upperBound (AbiBytesType n) = UIntMax (8 * n)
upperBound typ  = error $ "upperBound not implemented for " ++ show typ

-- | Attempt to construct a `TypedExp` whose type matches the supplied `AbiType`.
-- The target timing parameter will be whatever is required by the caller.
checkExpr :: Typeable t => Env -> U.Expr -> AbiType -> Err (TypedExp t)
checkExpr env e typ = case metaType typ of
  Integer -> ExpInt <$> inferExpr env sing e
  Boolean -> ExpBool <$> inferExpr env sing e
  ByteStr -> ExpBytes <$> inferExpr env sing e

-- | Attempt to typecheck an untyped expression as any possible type.
typedExp :: Typeable t => Env -> U.Expr -> Err (TypedExp t)
typedExp env e = ExpInt   <$> inferExpr env sing e
             <!> ExpBool  <$> inferExpr env sing e
             <!> ExpBytes <$> inferExpr env sing e
             <!> throw (getPosn e, "TypedExp: no suitable type") -- TODO improve error handling once we've merged the unified stuff!

-- | Attempts to construct an expression with the type and timing required by
-- the caller. If this is impossible, an error is thrown instead.
inferExpr :: forall a t. (Typeable a, Typeable t) => Env -> Sing a -> U.Expr -> Err (Exp a t)
inferExpr env@Env{contract,store,calldata} typ expr = case expr of
  U.ENot    p v1    -> check p $ Neg  <$> inferExpr env sing v1
  U.EAnd    p v1 v2 -> check p $ And  <$> inferExpr env sing v1 <*> inferExpr env sing v2
  U.EOr     p v1 v2 -> check p $ Or   <$> inferExpr env sing v1 <*> inferExpr env sing v2
  U.EImpl   p v1 v2 -> check p $ Impl <$> inferExpr env sing v1 <*> inferExpr env sing v2
  U.EEq     p v1 v2 -> polycheck p Eq v1 v2
  U.ENeq    p v1 v2 -> polycheck p NEq v1 v2
  U.ELT     p v1 v2 -> check p $ LE   <$> inferExpr env sing v1 <*> inferExpr env sing v2
  U.ELEQ    p v1 v2 -> check p $ LEQ  <$> inferExpr env sing v1 <*> inferExpr env sing v2
  U.EGEQ    p v1 v2 -> check p $ GEQ  <$> inferExpr env sing v1 <*> inferExpr env sing v2
  U.EGT     p v1 v2 -> check p $ GE   <$> inferExpr env sing v1 <*> inferExpr env sing v2
  U.EAdd    p v1 v2 -> check p $ Add  <$> inferExpr env sing v1 <*> inferExpr env sing v2
  U.ESub    p v1 v2 -> check p $ Sub  <$> inferExpr env sing v1 <*> inferExpr env sing v2
  U.EMul    p v1 v2 -> check p $ Mul  <$> inferExpr env sing v1 <*> inferExpr env sing v2
  U.EDiv    p v1 v2 -> check p $ Div  <$> inferExpr env sing v1 <*> inferExpr env sing v2
  U.EMod    p v1 v2 -> check p $ Mod  <$> inferExpr env sing v1 <*> inferExpr env sing v2
  U.EExp    p v1 v2 -> check p $ Exp  <$> inferExpr env sing v1 <*> inferExpr env sing v2
  U.IntLit  p v1    -> check p . pure $ LitInt v1
  U.BoolLit p v1    -> check p . pure $ LitBool v1
  U.EITE    _ v1 v2 v3 -> ITE <$> inferExpr env sing v1 <*> inferExpr env typ v2 <*> inferExpr env typ v3
  U.EUTEntry   p name es -> checkTime p $ entry p Neither name es
  U.EPreEntry  p name es -> checkTime p $ entry p Pre     name es
  U.EPostEntry p name es -> checkTime p $ entry p Post    name es
  U.EnvExp p v1 -> case lookup v1 defaultStore of
    Just Integer -> check p . pure $ IntEnv v1
    Just ByteStr -> check p . pure $ ByEnv  v1
    _            -> throw (p, "unknown environment variable: " <> show v1)
  v -> error $ "internal error: infer type of:" <> show v
  -- Wild ->
  -- Zoom Var Exp
  -- Func Var [U.Expr]
  -- Look U.Expr U.Expr
  -- ECat U.Expr U.Expr
  -- ESlice U.Expr U.Expr U.Expr
  -- Newaddr U.Expr U.Expr
  -- Newaddr2 U.Expr U.Expr U.Expr
  -- BYHash U.Expr
  -- BYAbiE U.Expr
  -- StringLit String
  where
--    expected = sing @a
--
--    check' :: Typeable x => Sing x -> Pn -> Exp x t0 -> Err (Exp a t0)
--    check' actual pn = validate
--                        [(pn,"Type mismatch. Expected " <> show expected <> ", got " <> show actual <> ".")]
--                        castType

    -- Try to cast the type parameter of an expression to the goal of `inferExpr`,
    -- or throw an error.
    check :: forall x t0. Typeable x => Pn -> Err (Exp x t0) -> Err (Exp a t0)
    check pn = ensure
                [(pn,"Type mismatch. Expected " <> show (typeRep @a) <> ", got " <> show (typeRep @x) <> ".")]
                castType
              
    checkTime :: forall x t0. Typeable t0 => Pn -> Err (Exp x t0) -> Err (Exp x t)
    checkTime pn = ensure
                    [(pn, (tail . show $ typeRep @t) <> " variable needed here!")]
                    castTime

    -- Takes a polymorphic binary AST constructor and specializes it to each of
    -- our types. Those specializations are used in order to guide the
    -- typechecking of the two supplied expressions. Returns at first success.
    polycheck :: Typeable x => Pn -> (forall y. (Eq y, Typeable y) => Exp y t -> Exp y t -> Exp x t) -> U.Expr -> U.Expr -> Err (Exp a t)
    polycheck pn cons e1 e2 = check pn (cons @Integer    <$> inferExpr env sing e1 <*> inferExpr env sing e2)
                          <!> check pn (cons @Bool       <$> inferExpr env sing e1 <*> inferExpr env sing e2)
                          <!> check pn (cons @ByteString <$> inferExpr env sing e1 <*> inferExpr env sing e2)
                          <!> throw (pn, "Couldn't harmonize types!") -- TODO improve error handling once we've merged the unified stuff!

    -- Try to construct a reference to a calldata variable or an item in storage.
    entry :: forall t0. Typeable t0 => Pn -> Time t0 -> Id -> [U.Expr] -> Err (Exp a t0)
    entry pn timing name es = case (Map.lookup name store, Map.lookup name calldata) of
      (Nothing, Nothing) -> throw (pn, "Unknown variable: " <> name)
      (Just _, Just _)   -> throw (pn, "Ambiguous variable: " <> name)
      (Nothing, Just c) -> if isTimed timing then throw (pn, "Calldata var cannot be pre/post.") else case c of
        -- Create a calldata reference and typecheck it as with normal expressions.
        Integer -> check pn . pure $ IntVar  name
        Boolean -> check pn . pure $ BoolVar name
        ByteStr -> check pn . pure $ ByVar   name
      (Just (StorageValue a), Nothing)      -> checkEntry a []
      (Just (StorageMapping ts a), Nothing) -> checkEntry a $ NonEmpty.toList ts
      where
        checkEntry :: AbiType -> [AbiType] -> Err (Exp a t0)
        checkEntry a ts = case metaType a of
          Integer -> check pn $ using IntItem
          Boolean -> check pn $ using BoolItem
          ByteStr -> check pn $ using BytesItem
          where
            -- Using the supplied constructor, create a `TStorageItem` and then place it in a `TEntry`.
            using :: Typeable x => (Id -> Id -> [TypedExp t0] -> TStorageItem x t0) -> Err (Exp x t0)
            using cons = TEntry timing . cons contract name <$> checkIxs env pn es ts

checkIxs :: Typeable t => Env -> Pn -> [U.Expr] -> [AbiType] -> Err [TypedExp t]
checkIxs env pn exprs types = if length exprs /= length types
                              then throw (pn, "Index mismatch for entry!")
                              else traverse (uncurry $ checkExpr env) (exprs `zip` types)

-- checkIxs' :: Typeable t => Env -> Pn -> [U.Expr] -> [AbiType] -> Logger TypeErr [TypedExp t]
-- checkIxs' env pn exprs types = traverse (uncurry $ checkExpr env) (exprs `zip` types)
--                           <* when (length exprs /= length types) (log' (pn, "Index mismatch for entry!"))
