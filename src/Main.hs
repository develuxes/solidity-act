{-# LANGUAGE DeriveGeneric  #-}
{-# Language DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleInstances  #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# Language TypeOperators #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE LambdaCase #-}
import Data.List
import Data.Aeson hiding (Bool, Number)
import GHC.Generics
import System.Environment ( getArgs )
import System.Exit ( exitFailure )
import Data.Text          (Text, pack, unpack)
import EVM.ABI
import EVM.Solidity
import qualified Data.Text as Text
import Data.Map.Strict    (Map)
import Data.Maybe
import qualified Data.Map.Strict      as Map -- abandon in favor of [(a,b)]?
import Data.Vector (fromList)

import qualified Data.ByteString.Lazy.Char8 as B

import Control.Monad
import Control.Monad.Except
import Data.Bitraversable
import Data.Bifunctor
import Data.Bifoldable
import Data.Functor.Identity

import Syntax
import Splitter
import ErrM
import Lex (lexer, AlexPosn(..))
import Parse
import Options.Generic
import RefinedAst

--command line options
data Command w
  = Parse             { file  :: w ::: String <?> "Path to file"}
  | Lex               { file  :: w ::: String <?> "Path to file"}
  | ParseAndTypeCheck { file  :: w ::: String <?> "Path to file"}

  | KaseSplit         { spec    :: w ::: String <?> "Path to spec"
                      , soljson :: w ::: String <?> "Path to .sol.json"
                      }

  | Type              { file  :: w ::: String <?> "Path to file"}

  | Compile           { spec    :: w ::: String       <?> "Path to spec"
                      , soljson :: w ::: String       <?> "Path to .sol.json"
                      , k       :: w ::: Bool         <?> "output k files"
                      , ir      :: w ::: Bool         <?> "output k files"
                      , coq     :: w ::: Bool         <?> "output coq files"
                      , out     :: w ::: Maybe String <?> "output path"
                      }
    deriving (Generic)

instance ParseRecord (Command Wrapped)
deriving instance Show (Command Unwrapped)

safeDrop :: Int -> [a] -> [a]
safeDrop 0 a = a
safeDrop _ [a] = [a]
safeDrop n (x:xs) = safeDrop (n-1) xs

prettyErr :: String -> (Pn, String) -> IO ()
prettyErr contents (AlexPn _ line col,msg) = do let cxt = safeDrop (line - 1) (lines contents)
                                                putStrLn $ show line <> " | " <> head cxt
                                                putStrLn $ unpack (Text.replicate (col + (length (show line <> " | ")) - 1) " " <> "^")
                                                putStrLn $ msg
                                                exitFailure

main :: IO ()
main = do
    cmd <- unwrapRecord "Act -- Smart contract specifier"
    case cmd of
      (Lex f) -> do contents <- readFile f
                    print $ lexer contents

      (Parse f) -> do contents <- readFile f
                      case parse $ lexer contents of
                        Bad e -> prettyErr contents e
                        Ok x -> print x
      (Type f) -> do contents <- readFile f
                     case parse $ lexer contents of
                                    Bad e -> prettyErr contents e
                                    Ok spec -> case typecheck spec of
                                                  (Ok a)  -> B.putStrLn $ encode a
                                                  (Bad e) -> prettyErr contents e

      -- (Compile spec soljson) -> do contents <- readFile f

      --                   case parse $ lexer contents of
      --                               Bad e -> prettyErr contents e
      --                               Ok spec -> case typecheck spec of
      --                                             (Ok a)  -> B.putStrLn $ encode a
      --                                             (Bad e) -> prettyErr contents e

--       (TypeCheck f) -> do contents <- readFile f
--                           let act = read contents :: [RawBehaviour]
--                           case typecheck act of
--                             (Ok a)  -> B.putStrLn $ encode a
--                             (Bad s) -> error s

--       (KaseSplit specFile implFile) -> do specText <- readFile specFile
--                                           let spec = read specText :: [RawBehaviour]
--                                           case typecheck spec of
--                                             (Ok a)  -> do implText <- readFile implFile
--                                                           print "ok"
--                                             (Bad s) -> error s

typecheck :: [RawBehaviour] -> Err [Behaviour]
typecheck behvs = let store = lookupVars behvs in
                  do bs <- mapM (splitBehaviour store) behvs
                     return $ join bs

--- Finds storage declarations from constructors
lookupVars :: [RawBehaviour] -> Map Id (Map Id Container)
lookupVars ((Transition _ _ _ _ _ _):bs) = lookupVars bs
lookupVars ((Constructor _ contract _ _ (Creates assigns) _ _ _):bs) =
  Map.singleton contract (Map.fromList $ map fromAssign assigns)
  <> lookupVars bs -- TODO: deal with variable overriding
  where fromAssign (AssignVal (StorageDecl typ var) _) = (var, typ)
        fromAssign (AssignMany (StorageDecl typ var) _) = (var, typ)
        fromAssign (AssignStruct _ _) = error "TODO: assignstruct"
lookupVars [] = mempty


-- typing of eth env variables
defaultStore :: [(EthEnv, MType)]
defaultStore =
  [(Callvalue, Integer),
   (Caller, Integer),
   (Blockhash, ByteStr),
   (Blocknumber, Integer),
   (Difficulty, Integer),
   (Timestamp, Integer),
   (Gaslimit, Integer),
   (Coinbase, Integer),
   (Chainid, Integer),
   (Address, Integer),
   (Origin, Integer),
   (Nonce, Integer)
   --others TODO
  ]

-- typing of vars: this contract storage, other contract scopes, calldata args
type Env = (Map Id Container, Map Id (Map Id Container), Map Id MType)

-- todo: make Exp T_Bool a monoid so that this is mconcat
joinand :: [Exp T_Bool] -> Exp T_Bool
joinand [x] = x
joinand (x:xs) = And x (joinand xs)
joinand [] = LitBool True

andRaw :: [Expr] -> Expr
andRaw [x] = x
andRaw (x:xs) = EAnd nowhere x (andRaw xs)
andRaw [] = BoolLit True


-- checks a transition given a typing of its storage variables
splitBehaviour :: Map Id (Map Id Container) -> RawBehaviour -> Err [Behaviour]
splitBehaviour store (Transition name contract iface@(Interface _ decls) iffs' cases maybePost) = do
  iff <- checkIffs env iffs'
  postcondition <- mapM (checkBool env) (fromMaybe [] maybePost)
  flatten iff postcondition [] cases

  where env = (fromMaybe mempty (Map.lookup contract store), store, abiVars)
        abiVars = Map.fromList $ map (\(Decl typ var) -> (var, metaType typ)) decls

        -- translate wildcards into negation of other cases
        normalize = snd . mapAccumL (\a b -> case b of
                                        Leaf pn Wild p -> (a, Leaf pn (ENot nowhere (andRaw a)) p)
                                        Branch pn Wild p -> (a, Branch pn (ENot nowhere (andRaw a)) p)
                                        e@(Leaf _ c _) -> (c:a, e)
                                        e@(Branch _ c _) -> (c:a, e)) []

        -- split case into pass and fail case
        splitCase ifs [] ret storage postc = [Behaviour name contract iface (joinand ifs) postc storage ret]
        splitCase ifs iffs ret storage postc = [ Behaviour name contract iface (joinand (ifs <> iffs)) postc storage ret
                                               , Behaviour name contract iface (And (joinand ifs) (Neg (joinand iffs))) postc mempty Nothing]

        -- flatten case tree
        flatten iff postc pathcond (Leaf _ cond post) = do c <- checkBool env cond
                                                           (p, maybeReturn) <- checkPost env contract post
                                                           return $ splitCase (c:pathcond) iff maybeReturn p (joinand postc)

        flatten iff postc pathcond (Branch _ cond cs) = do c <- checkBool env cond
                                                           leaves <- mapM (flatten iff postc (c:pathcond)) (normalize cs)
                                                           return $ join leaves

splitBehaviour store (Constructor name contract decls iffs cases post ensures invariants) = Ok [] --error "TODO: check constructor"

checkPost :: Env -> Id -> Post -> Err (Map Id [StorageUpdate], Maybe ReturnExp)
checkPost env@(ours, theirs, localVars) contract (Post maybeStorage extStorage maybeReturn) =
  do  returnexp <- mapM (inferExpr env) maybeReturn
      ourStorage <- case maybeStorage of
        Just entries -> checkEntries contract entries
        Nothing -> Ok []
      otherStorage <- checkStorages extStorage
      return $ ((Map.fromList $ (contract, ourStorage):otherStorage), returnexp)
  where checkEntries name entries = mapM (uncurry $ checkStorageExpr (fromMaybe mempty (Map.lookup name theirs), theirs, localVars)) entries
        checkStorages :: [ExtStorage] -> Err [(Id, [StorageUpdate])]
        checkStorages [] = Ok []
        checkStorages ((ExtStorage name entries):xs) = do p <- checkEntries name entries
                                                          ps <- checkStorages xs
                                                          Ok $ (name, p):ps
        checkStorages ((ExtCreates _ name entries):xs) = error "TODO: check other storages"

checkStorageExpr :: Env -> Entry -> Expr -> Err StorageUpdate
checkStorageExpr env@(ours, theirs, localVars) entry@(Entry p id ixs) expr =
    case Map.lookup id ours of
      Just container -> case final container of
          Integer -> liftM2 IntUpdate (checkIntEntry env entry container) (checkInt env expr)
          Boolean -> liftM2 BoolUpdate (checkBoolEntry env entry container) (checkBool env expr)
          ByteStr -> liftM2 BytesUpdate (checkBytesEntry env entry container) (checkBytes env expr)
      Nothing -> Bad $ (p, "Unknown storage variable: " <> show id)
  where final (Direct m) = metaType m
        final (Syntax.Mapping t c) = final c

checkIntEntry :: Env -> Entry -> Container -> Err (TContainer () T_Int)
checkIntEntry _ (Entry p id []) (Direct t ) = case metaType t of
                                              Integer -> Ok $ DirectInt id
                                              Boolean -> Bad $ (p, "Typing error")
                                              ByteStr -> Bad $ (p, "Typing error")
checkIntEntry _ (Entry p id []) _ = Bad $ (p, "Abstract container specifications not (yet) supported")
checkIntEntry env (Entry p id (e:es)) (Syntax.Mapping t c) =
  case metaType t of
    Integer -> do exp <- checkInt env e
                  rest <- checkIntEntry env (Entry p id es) c
                  return $ Lookup (IntIndexed rest) exp
    Boolean -> do exp <- checkBool env e
                  rest <- checkIntEntry env (Entry p id es) c
                  return $ Lookup (BoolIndexed rest) exp
    ByteStr -> do exp <- checkBytes env e
                  rest <- checkIntEntry env (Entry p id es) c
                  return $ Lookup (BytesIndexed rest) exp

checkBoolEntry :: Env -> Entry -> Container -> Err (TContainer () T_Bool)
checkBoolEntry env (Entry p id []) (Syntax.Direct t) = case metaType t of
                                            Integer -> Bad $ (p, "Typing error")
                                            Boolean -> Ok $ DirectBool id
                                            ByteStr -> Bad $ (p, "Typing error")
checkBoolEntry env (Entry p id (e:es)) (Syntax.Mapping t c) = case metaType t of
                                                  Integer -> do exp <- checkInt env e
                                                                rest <- checkBoolEntry env (Entry p id es) c
                                                                return $ Lookup (IntIndexed rest) exp
                                                  Boolean -> do exp <- checkBool env e
                                                                rest <- checkBoolEntry env (Entry p id es) c
                                                                return $ Lookup (BoolIndexed rest) exp
                                                  ByteStr -> do exp <- checkBytes env e
                                                                rest <- checkBoolEntry env (Entry p id es) c
                                                                return $ Lookup (BytesIndexed rest) exp
checkBoolEntry env (Entry p id _) _ = Bad $ (p, "Wrong arguments given to mapping: " <> show id)

checkBytesEntry :: Env -> Entry -> Container -> Err (TContainer () T_Bytes)
checkBytesEntry env (Entry p id []) (Syntax.Direct t) = case metaType t of
                                            Integer -> Bad $ (p, "Typing error")
                                            Boolean -> Bad $ (p, "Typing error")
                                            ByteStr -> Ok $ DirectBytes id
checkBytesEntry env (Entry p id (e:es)) (Syntax.Mapping t c) = case metaType t of
                                                  Integer -> do exp <- checkInt env e
                                                                rest <- checkBytesEntry env (Entry p id es) c
                                                                return $ Lookup (IntIndexed rest) exp
                                                  Boolean -> do exp <- checkBool env e
                                                                rest <- checkBytesEntry env (Entry p id es) c
                                                                return $ Lookup (BoolIndexed rest) exp
                                                  ByteStr -> do exp <- checkBytes env e
                                                                rest <- checkBytesEntry env (Entry p id es) c
                                                                return $ Lookup (BytesIndexed rest) exp
checkBytesEntry env (Entry p id _) _ = Bad $ (p, "Wrong arguments given to mapping: " <> show id)

checkIffs :: Env -> [IffH] -> Err [Exp T_Bool]
checkIffs env ((Iff pos exps):xs) = do
  head <- mapM (checkBool env) exps
  tail <- checkIffs env xs
  Ok $ head <> tail
checkIffs env ((IffIn pos typ exps):xs) = do
  head <- mapM (checkInt env) exps
  tail <- checkIffs env xs
  Ok $ map (bound typ) head <> tail
checkIffs _ [] = Ok []

bound :: AbiType -> (Exp T_Int) -> Exp T_Bool
bound typ exp = And (LEQ (lowerBound typ) exp) $ LEQ exp (upperBound typ)

lowerBound :: AbiType -> Exp T_Int
lowerBound (AbiIntType a) = LitInt $ 0 - 2 ^ (a - 1)
-- todo: other negatives?
lowerBound _ = LitInt 0

--todo, the rest
upperBound :: AbiType -> Exp T_Int
upperBound (AbiUIntType n) = LitInt $ 2 ^ n - 1
upperBound (AbiIntType n) = LitInt $ 2 ^ (n - 1) - 1
upperBound AbiAddressType  = LitInt $ 2 ^ 160 - 1

metaType :: AbiType -> MType
metaType (AbiUIntType _)     = Integer
metaType (AbiIntType  _)     = Integer
metaType AbiAddressType      = Integer
metaType AbiBoolType         = Boolean
metaType (AbiBytesType _)    = ByteStr
metaType AbiBytesDynamicType = ByteStr
metaType AbiStringType       = ByteStr
--metaType (AbiArrayDynamicType a) =
--metaType (AbiArrayType        Int AbiType
--metaType (AbiTupleType        (Vector AbiType)
metaType _ = error "TODO"

inferExpr :: Env -> Expr -> Err ReturnExp
inferExpr env exp = let intintint op v1 v2 = do w1 <- checkInt env v1
                                                w2 <- checkInt env v2
                                                Ok $ ExpInt $ op w1 w2
                        boolintint op v1 v2 = do w1 <- checkInt env v1
                                                 w2 <- checkInt env v2
                                                 Ok $ ExpBool $ op w1 w2
                        boolboolbool op v1 v2 = do w1 <- checkBool env v1
                                                   w2 <- checkBool env v2
                                                   Ok $ ExpBool $ op w1 w2
                    in case exp of
    EAnd _  v1 v2 -> boolboolbool And  v1 v2
    EOr _   v1 v2 -> boolboolbool Or   v1 v2
    EImpl _ v1 v2 -> boolboolbool Impl v1 v2
    EEq _   v1 v2 -> boolintint  Eq  v1 v2
    ENeq _  v1 v2 -> boolintint  NEq v1 v2
    ELT _   v1 v2 -> boolintint  LE   v1 v2
    ELEQ _  v1 v2 -> boolintint  LEQ  v1 v2
    EGT _   v1 v2 -> boolintint  GE   v1 v2
    ETrue _ ->  Ok  $ ExpBool $ LitBool True
    EFalse _ -> Ok $ ExpBool $ LitBool False
    -- EITE _ v1 v2 v3 -> do w1 <- checkBool env v1
    --                       w2 <- checkInt env v2
    --                       w3 <- checkInt env v3
    --                       Ok $ ITE w1 w2 w3
    EAdd _ v1 v2 -> intintint Add v1 v2
    ESub _ v1 v2 -> intintint Sub v1 v2
    EMul _ v1 v2 -> intintint Mul v1 v2
    EDiv _ v1 v2 -> intintint Div v1 v2
    EMod _ v1 v2 -> intintint Mod v1 v2
    EExp _ v1 v2 -> intintint Exp v1 v2
    Var p v1 -> Bad (p, "TODO: infer var type")
    IntLit n -> Ok $ ExpInt $ LitInt n
    _ -> error "TODO: infer other stuff type"
    -- Wild ->
    -- Zoom Var Exp
    -- Func Var [Expr]
    -- Look Expr Expr
    -- ECat Expr Expr
    -- ESlice Expr Expr Expr
    -- Newaddr Expr Expr
    -- Newaddr2 Expr Expr Expr
    -- BYHash Expr
    -- BYAbiE Expr
    -- StringLit String

checkBool :: Env -> Expr -> Err (Exp T_Bool)
checkBool env@(ours, theirs,thisContext) b =
  let checkInts op v1 v2 = do w1 <- checkInt env v1
                              w2 <- checkInt env v2
                              Ok $ op w1 w2
      checkBools op v1 v2 = do w1 <- checkBool env v1
                               w2 <- checkBool env v2
                               Ok $ op w1 w2
  in case b of
    ENot  _ v1    -> Neg <$> checkBool env v1
    EAnd  _ v1 v2 -> checkBools And  v1 v2
    EOr   _ v1 v2 -> checkBools Or   v1 v2
    EImpl _ v1 v2 -> checkBools Impl v1 v2
    EEq   _ v1 v2 -> checkInts  Eq  v1 v2
    ENeq  _ v1 v2 -> checkInts  NEq v1 v2
    ELT   _ v1 v2 -> checkInts  LE   v1 v2
    ELEQ  _ v1 v2 -> checkInts  LEQ  v1 v2
    EGT   _ v1 v2 -> checkInts  GE   v1 v2
    EGEQ  _ v1 v2 -> checkInts  GEQ  v1 v2
    ETrue _  -> Ok $ LitBool True
    EFalse _ -> Ok $ LitBool False
    BoolLit a -> Ok $ LitBool a
    --
    Var p v -> case Map.lookup v thisContext of
      Just Boolean -> Ok (BoolVar v)
      Just a -> Bad $ (p, "Type error; variable: " <> show v <> " has type " <> show a <> ", expected bool.")
      Nothing -> Bad $ (p, "Unknown variable: " <> show v <> " of type boolean.")
    -- Look v1 v2 -> case Map.lookup v1 thisContext of
    --   Just (MappingType t1 t2) -> error "TODO: lookups"
    --                               --do checkExpr store contract (abiTypeToMeta t1)
    --   Just (ArrayType typ len) -> error "TODO: arrays"
    --   _ -> Bad $ "Unexpected lookup in " <> pprint v1 <> ": not array or mapping."
    -- TODO: zoom, lookup and functions
    s -> error ("TODO: check bool, case:" <> show s )


checkInt :: Env -> Expr -> Err (Exp T_Int)
checkInt env@(ours, theirs,thisContext) e =
  let checkInts op v1 v2 = do w1 <- checkInt env v1
                              w2 <- checkInt env v2
                              Ok $ op w1 w2
  in case e of
  EAdd _ v1 v2 -> checkInts Add v1 v2
  ESub _ v1 v2 -> checkInts Sub v1 v2
  EMul _ v1 v2 -> checkInts Mul v1 v2
  EDiv _ v1 v2 -> checkInts Div v1 v2
  EMod _ v1 v2 -> checkInts Mod v1 v2
  EExp _ v1 v2 -> checkInts Exp v1 v2
  ENewaddr _ v1 v2 -> checkInts NewAddr v1 v2
  EnvExp p v1 -> case lookup v1 defaultStore of
    Just Integer -> Ok $ IntEnv v1
    Just typ     -> Bad (p, show v1 <> "has type: " <> show typ)
    _            -> Bad (p, "unknown environment variable: " <> show v1)
  -- Var p v -> case Map.lookup v thisContext of
  --   Just Integer -> Ok $ IntVar v
  --   _ -> Bad $ (p, "Unexpected variable: " <> show v <> " of type integer")
  IntLit n -> Ok $ LitInt n
  EntryExp e@(Entry p id x) -> case (Map.lookup id ours, Map.lookup id thisContext) of
      (Nothing, Nothing) -> Bad $ (p, "unknown environment variable: " <> show id)
      (Nothing, Just Integer) -> case x of
        [] -> Ok $ IntVar id
        _ -> Bad (p, "todo: array lookups; " <> show id)
      (Nothing, Just c) -> Bad (p, "type error at variable: " <> id <> ". Expected: Integer, got: " <> show c)

      (Just c, Nothing) -> do a <- checkIntEntry env e c
                              return $ TEntry a
      _ -> Bad (p, "ambiguous variable: " <> show id)
  v -> error ("TODO: check int, case:" <> show v )

checkBytes :: Env -> Expr -> Err (Exp T_Bytes)
checkBytes = error ""
