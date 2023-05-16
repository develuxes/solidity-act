{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MonadComprehensions #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DataKinds #-}
{-# Language RecordWildCards #-}

module SMT (
  Solver(..),
  SMTConfig(..),
  Query(..),
  SMTResult(..),
  spawnSolver,
  stopSolver,
  sendLines,
  runQuery,
  mkPostconditionQueries,
  mkPostconditionQueriesBehv,
  mkInvariantQueries,
  target,
  getQueryContract,
  isFail,
  isPass,
  ifExists,
  getBehvName,
  identifier,
  getSMT
) where

import Prelude hiding (GT, LT)

import Data.Containers.ListUtils (nubOrd)
import System.Process (createProcess, cleanupProcess, proc, ProcessHandle, std_in, std_out, std_err, StdStream(..))
import Text.Regex.TDFA hiding (empty)
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import Control.Applicative ((<|>))
import Control.Monad.Reader

import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe
import Data.List
import GHC.IO.Handle (Handle, hGetLine, hPutStr, hFlush)
import Data.ByteString.UTF8 (fromString)

import Syntax
import Syntax.Annotated

import Print
import Type (defaultStore)

--- ** Data ** ---


data Solver = Z3 | CVC4
  deriving Eq

instance Show Solver where
  show Z3 = "z3"
  show CVC4 = "cvc4"

data SMTConfig = SMTConfig
  { _solver :: Solver
  , _timeout :: Integer
  , _debug :: Bool
  }

type SMT2 = String

-- | The context is a `Reader` monad which allows us to read
-- the name of the current interface.
type Ctx = Reader Id

-- | Specify the name to use as the current interface when creating SMT-code.
withInterface :: Id -> Ctx SMT2 -> SMT2
withInterface = flip runReader

-- | An SMTExp is a structured representation of an SMT Expression
--   The _storage, _calldata, and _environment fields hold variable declarations
--   The _assertions field holds the various constraints that should be satisfied
data SMTExp = SMTExp
  { _storage :: [SMT2]
  , _calldata :: [SMT2]
  , _environment :: [SMT2]
  , _assertions :: [SMT2]
  }
  deriving (Show)

instance Pretty SMTExp where
  pretty e = vsep [storage, calldata, environment, assertions]
    where
      storage = text ";STORAGE:" <$$> (vsep . (fmap text) . nubOrd . _storage $ e) <> line
      calldata = text ";CALLDATA:" <$$> (vsep . (fmap text) . nubOrd . _calldata $ e) <> line
      environment = text ";ENVIRONMENT" <$$> (vsep . (fmap text) . nubOrd . _environment $ e) <> line
      assertions = text ";ASSERTIONS:" <$$> (vsep . (fmap text) . nubOrd . _assertions $ e) <> line

data Transition
  = Behv Behaviour
  | Ctor Constructor
  deriving (Show)

-- | A Query is a structured representation of an SMT query for an individual
--   expression, along with the metadata needed to extract a model from a satisfiable query
data Query
  = Postcondition Transition (Exp ABoolean) SMTExp
  | Inv Invariant (Constructor, SMTExp) [(Behaviour, SMTExp)]
  deriving (Show)

data SMTResult
  = Sat Model
  | Unsat
  | Unknown
  | Error Int String
  deriving (Show)

-- | An assignment of concrete values to symbolic variables structured in a way
--   to allow for easy pretty printing. The LHS of each pair is the symbolic
--   variable, and the RHS is the concrete value assigned to that variable in the
--   counterexample
data Model = Model
  { _mprestate :: [(StorageLocation, TypedExp)]
  , _mpoststate :: [(StorageLocation, TypedExp)]
  , _mcalldata :: (String, [(Decl, TypedExp)])
  , _menvironment :: [(EthEnv, TypedExp)]
  -- invariants always have access to the constructor context
  , _minitargs :: [(Decl, TypedExp)]
  }
  deriving (Show)

instance Pretty Model where
  pretty (Model prestate poststate (ifaceName, args) environment initargs) =
    (underline . text $ "counterexample:") <$$> line
      <> (indent 2
        (    calldata'
        <$$> ifExists environment (line <> environment' <> line)
        <$$> storage
        <$$> ifExists initargs (line <> initargs')
        ))
    where
      calldata' = text "calldata:" <$$> line <> (indent 2 $ formatSig ifaceName args)
      environment' = text "environment:" <$$> line <> (indent 2 . vsep $ fmap formatEnvironment environment)
      storage = text "storage:" <$$> (indent 2 . vsep $ [ifExists prestate (line <> prestate'), poststate'])
      initargs' = text "constructor arguments:" <$$> line <> (indent 2 $ formatSig "constructor" initargs)

      prestate' = text "prestate:" <$$> line <> (indent 2 . vsep $ fmap formatStorage prestate) <> line
      poststate' = text "poststate:" <$$> line <> (indent 2 . vsep $ fmap formatStorage poststate)

      formatSig iface cd = text iface <> (encloseSep lparen rparen (text ", ") $ fmap formatCalldata cd)
      formatCalldata (Decl _ name, val) = text $ name <> " = " <> prettyTypedExp val
      formatEnvironment (env, val) = text $ prettyEnv env <> " = " <> prettyTypedExp val
      formatStorage (loc, val) = text $ prettyLocation loc <> " = " <> prettyTypedExp val

data SolverInstance = SolverInstance
  { _type :: Solver
  , _stdin :: Handle
  , _stdout :: Handle
  , _stderr :: Handle
  , _process :: ProcessHandle
  }


--- ** Analysis Passes ** ---


-- | For each postcondition in the claim we construct a query that:
--    - Asserts that the preconditions hold
--    - Asserts that storage has been updated according to the rewrites in the behaviour
--    - Asserts that the postcondition cannot be reached
--   If this query is unsatisfiable, then there exists no case where the postcondition can be violated.
mkPostconditionQueries :: Act -> [Query]
mkPostconditionQueries (Act _ contr) = concatMap mkPostconditionQueriesContract contr
  where
    mkPostconditionQueriesContract (Contract constr behvs) =
      mkPostconditionQueriesConstr constr <> concatMap mkPostconditionQueriesBehv behvs

mkPostconditionQueriesBehv :: Behaviour -> [Query]
mkPostconditionQueriesBehv behv@(Behaviour _ _ (Interface ifaceName decls) preconds ifs postconds stateUpdates _) = mkQuery <$> postconds
  where
    -- declare vars
    storage = concatMap (declareStorageLocation . locFromRewrite) stateUpdates
    args = declareArg ifaceName <$> decls
    envs = declareEthEnv <$> ethEnvFromBehaviour behv

    -- constraints
    pres = mkAssert ifaceName <$> preconds <> ifs
    updates = encodeUpdate ifaceName <$> stateUpdates

    mksmt e = SMTExp
      { _storage = storage
      , _calldata = args
      , _environment = envs
      , _assertions = [mkAssert ifaceName . Neg nowhere $ e] <> pres <> updates
      }
    mkQuery e = Postcondition (Behv behv) e (mksmt e)

mkPostconditionQueriesConstr :: Constructor -> [Query]
mkPostconditionQueriesConstr constructor@(Constructor _ (Interface ifaceName decls) preconds postconds _ initialStorage stateUpdates) = mkQuery <$> postconds
  where
    -- declare vars
    localStorage = declareInitialStorage <$> initialStorage
    externalStorage = concatMap (declareStorageLocation . locFromRewrite) stateUpdates
    args = declareArg ifaceName <$> decls
    envs = declareEthEnv <$> ethEnvFromConstructor constructor

    -- constraints
    pres = mkAssert ifaceName <$> preconds
    updates = encodeUpdate ifaceName <$> stateUpdates
    initialStorage' = encodeInitialStorage ifaceName <$> initialStorage

    mksmt e = SMTExp
      { _storage = localStorage <> externalStorage
      , _calldata = args
      , _environment = envs
      , _assertions = [mkAssert ifaceName . Neg nowhere $ e] <> pres <> updates <> initialStorage'
      }
    mkQuery e = Postcondition (Ctor constructor) e (mksmt e)

-- | For each invariant in the list of input claims, we first gather all the
--   specs relevant to that invariant (i.e. the constructor for that contract,
--   and all passing behaviours for that contract).
--
--   For the constructor we build a query that:
--     - Asserts that all preconditions hold
--     - Asserts that external storage has been updated according to the spec
--     - Asserts that internal storage values have the value given in the creates block
--     - Asserts that the invariant does not hold over the poststate
--
--   For the behaviours, we build a query that:
--     - Asserts that the invariant holds over the prestate
--     - Asserts that all preconditions hold
--     - Asserts that storage has been updated according to the spec
--     - Asserts that the invariant does not hold over the poststate
--
--   If all of the queries return `unsat` then we have an inductive proof that
--   the invariant holds for all possible contract states.
mkInvariantQueries :: Act -> [Query]
mkInvariantQueries (Act _ contracts) = fmap mkQuery gathered
  where
    mkQuery (inv, ctor, behvs) = Inv inv (mkInit inv ctor) (fmap (mkBehv inv ctor) behvs)
    gathered = concatMap getInvariants contracts

    getInvariants (Contract (c@Constructor{..}) behvs) = fmap (\i -> (i, c, behvs)) _invariants

    mkInit :: Invariant -> Constructor -> (Constructor, SMTExp)
    mkInit (Invariant _ invConds _ (_,invPost)) ctor@(Constructor _ (Interface ifaceName decls) preconds _ _ initialStorage stateUpdates) = (ctor, smt)
      where
        -- declare vars
        localStorage = declareInitialStorage <$> initialStorage
        externalStorage = concatMap (declareStorageLocation . locFromRewrite) stateUpdates
        args = declareArg ifaceName <$> decls
        envs = declareEthEnv <$> ethEnvFromConstructor ctor

        -- constraints
        pres = mkAssert ifaceName <$> preconds <> invConds
        updates = encodeUpdate ifaceName <$> stateUpdates
        initialStorage' = encodeInitialStorage ifaceName <$> initialStorage
        postInv = mkAssert ifaceName $ Neg nowhere invPost

        smt = SMTExp
          { _storage = localStorage <> externalStorage
          , _calldata = args
          , _environment = envs
          , _assertions = postInv : pres <> updates <> initialStorage'
          }

    mkBehv :: Invariant -> Constructor -> Behaviour -> (Behaviour, SMTExp)
    mkBehv (Invariant _ invConds invStorageBounds (invPre,invPost)) ctor behv = (behv, smt)
      where

        (Interface ctorIface ctorDecls) = _cinterface ctor
        (Interface behvIface behvDecls) = _interface behv
        -- storage locs mentioned in the invariant but not in the behaviour
        implicitLocs = Constant <$> (locsFromExp invPre \\ (locFromRewrite <$> _stateUpdates behv))

        -- declare vars
        invEnv = declareEthEnv <$> ethEnvFromExp invPre
        behvEnv = declareEthEnv <$> ethEnvFromBehaviour behv
        initArgs = declareArg ctorIface <$> ctorDecls
        behvArgs = declareArg behvIface <$> behvDecls
        storage = concatMap (declareStorageLocation . locFromRewrite) (_stateUpdates behv <> implicitLocs)

        -- constraints
        preInv = mkAssert ctorIface $ invPre
        postInv = mkAssert ctorIface . Neg nowhere $ invPost
        behvConds = mkAssert behvIface <$> _preconditions behv
        invConds' = mkAssert ctorIface <$> invConds <> invStorageBounds
        implicitLocs' = encodeUpdate ctorIface <$> implicitLocs
        updates = encodeUpdate behvIface <$> _stateUpdates behv

        smt = SMTExp
          { _storage = storage
          , _calldata = initArgs <> behvArgs
          , _environment = invEnv <> behvEnv
          , _assertions = [preInv, postInv] <> behvConds <> invConds' <> implicitLocs' <> updates
          }


--- ** Solver Interaction ** ---


-- | Checks the satisfiability of all smt expressions contained with a query, and returns the results as a list
runQuery :: SolverInstance -> Query -> IO (Query, [SMTResult])
runQuery solver query@(Postcondition trans _ smt) = do
  res <- checkSat solver (getPostconditionModel trans) smt
  pure (query, [res])
runQuery solver query@(Inv (Invariant _ _ _ predicate) (ctor, ctorSMT) behvs) = do
  ctorRes <- runCtor
  behvRes <- mapM runBehv behvs
  pure (query, ctorRes : behvRes)
  where
    runCtor = checkSat solver (getInvariantModel predicate ctor Nothing) ctorSMT
    runBehv (b, smt) = checkSat solver (getInvariantModel predicate ctor (Just b)) smt

-- | Checks the satisfiability of a single SMT expression, and uses the
-- provided `modelFn` to extract a model if the solver returns `sat`
checkSat :: SolverInstance -> (SolverInstance -> IO Model) -> SMTExp -> IO SMTResult
checkSat solver modelFn smt = do
  err <- sendLines solver ("(reset)" : (lines . show . pretty $ smt))
  case err of
    Nothing -> do
      sat <- sendCommand solver "(check-sat)"
      case sat of
        "sat" -> Sat <$> modelFn solver
        "unsat" -> pure Unsat
        "timeout" -> pure Unknown
        "unknown" -> pure Unknown
        _ -> pure $ Error 0 $ "Unable to parse solver output: " <> sat
    Just msg -> do
      pure $ Error 0 msg

-- | Global settings applied directly after each solver instance is spawned
smtPreamble :: [SMT2]
smtPreamble = [ "(set-logic ALL)" ]

-- | Arguments used when spawing a solver instance
solverArgs :: SMTConfig -> [String]
solverArgs (SMTConfig solver timeout _) = case solver of
  Z3 ->
    [ "-in"
    , "-t:" <> show timeout]
  CVC4 ->
    [ "--lang=smt"
    , "--interactive"
    , "--no-interactive-prompt"
    , "--produce-models"
    , "--tlimit-per=" <> show timeout]

-- | Spawns a solver instance, and sets the various global config options that we use for our queries
spawnSolver :: SMTConfig -> IO SolverInstance
spawnSolver config@(SMTConfig solver _ _) = do
  let cmd = (proc (show solver) (solverArgs config)) { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe }
  (Just stdin, Just stdout, Just stderr, process) <- createProcess cmd
  let solverInstance = SolverInstance solver stdin stdout stderr process

  _ <- sendCommand solverInstance "(set-option :print-success true)"
  err <- sendLines solverInstance smtPreamble
  case err of
    Nothing -> pure solverInstance
    Just msg -> error $ "could not spawn solver: " <> msg

-- | Cleanly shutdown a running solver instnace
stopSolver :: SolverInstance -> IO ()
stopSolver (SolverInstance _ stdin stdout stderr process) = cleanupProcess (Just stdin, Just stdout, Just stderr, process)

-- | Sends a list of commands to the solver. Returns the first error, if there was one.
sendLines :: SolverInstance -> [SMT2] -> IO (Maybe String)
sendLines solver smt = case smt of
  [] -> pure Nothing
  hd : tl -> do
    suc <- sendCommand solver hd
    if suc == "success"
       then sendLines solver tl
       else pure (Just suc)

-- | Sends a single command to the solver, returns the first available line from the output buffer
sendCommand :: SolverInstance -> SMT2 -> IO String
sendCommand (SolverInstance _ stdin stdout _ _) cmd =
  if null cmd || ";" `isPrefixOf` cmd then pure "success" -- blank lines and comments do not produce any output from the solver
  else do
    hPutStr stdin (cmd <> "\n")
    hFlush stdin
    hGetLine stdout


--- ** Model Extraction ** ---


-- | Extracts an assignment of values for the variables in the given
-- transition. Assumes that a postcondition query for the given transition has
-- previously been checked in the given solver instance.
getPostconditionModel :: Transition -> SolverInstance -> IO Model
getPostconditionModel (Ctor ctor) solver = getCtorModel ctor solver
getPostconditionModel (Behv behv) solver = do
  let locs = locsFromBehaviour behv
      env = ethEnvFromBehaviour behv
      Interface ifaceName decls = _interface behv
  prestate <- mapM (getStorageValue solver ifaceName Pre) locs
  poststate <- mapM (getStorageValue solver ifaceName Post) locs
  calldata <- mapM (getCalldataValue solver ifaceName) decls
  environment <- mapM (getEnvironmentValue solver) env
  pure $ Model
    { _mprestate = prestate
    , _mpoststate = poststate
    , _mcalldata = (ifaceName, calldata)
    , _menvironment = environment
    , _minitargs = []
    }

-- | Extracts an assignment of values for the variables in the given
-- transition. Assumes that an invariant query has previously been checked
-- in the given solver instance.
getInvariantModel :: InvariantPred -> Constructor -> Maybe Behaviour -> SolverInstance -> IO Model
getInvariantModel _ ctor Nothing solver = getCtorModel ctor solver
getInvariantModel predicate ctor (Just behv) solver = do
  let locs = nub $ locsFromBehaviour behv <> locsFromExp (invExp predicate)
      env = nub $ ethEnvFromBehaviour behv <> ethEnvFromExp (invExp predicate)
      Interface behvIface behvDecls = _interface behv
      Interface ctorIface ctorDecls = _cinterface ctor
  -- TODO: v ugly to ignore the ifaceName here, but it's safe...
  prestate <- mapM (getStorageValue solver "" Pre) locs
  poststate <- mapM (getStorageValue solver "" Post) locs
  behvCalldata <- mapM (getCalldataValue solver behvIface) behvDecls
  ctorCalldata <- mapM (getCalldataValue solver ctorIface) ctorDecls
  environment <- mapM (getEnvironmentValue solver) env
  pure $ Model
    { _mprestate = prestate
    , _mpoststate = poststate
    , _mcalldata = (behvIface, behvCalldata)
    , _menvironment = environment
    , _minitargs = ctorCalldata
    }

-- | Extracts an assignment for the variables in the given contructor
getCtorModel :: Constructor -> SolverInstance -> IO Model
getCtorModel ctor solver = do
  let locs = locsFromConstructor ctor
      env = ethEnvFromConstructor ctor
      Interface ifaceName decls = _cinterface ctor
  poststate <- mapM (getStorageValue solver ifaceName Post) locs
  calldata <- mapM (getCalldataValue solver ifaceName) decls
  environment <- mapM (getEnvironmentValue solver) env
  pure $ Model
    { _mprestate = []
    , _mpoststate = poststate
    , _mcalldata = (ifaceName, calldata)
    , _menvironment = environment
    , _minitargs = []
    }

-- | Gets a concrete value from the solver for the given storage location
getStorageValue :: SolverInstance -> Id -> When -> StorageLocation -> IO (StorageLocation, TypedExp)
getStorageValue solver ifaceName whn loc@(Loc typ _) = do
  output <- getValue solver name
  -- TODO: handle errors here...
  pure (loc, parseModel typ output)
  where
    name = if isMapping loc
            then withInterface ifaceName
                 $ select
                    (nameFromLoc whn loc)
                    (NonEmpty.fromList $ ixsFromLocation loc)
            else nameFromLoc whn loc

-- | Gets a concrete value from the solver for the given calldata argument
getCalldataValue :: SolverInstance -> Id -> Decl -> IO (Decl, TypedExp)
getCalldataValue solver ifaceName decl@(Decl (FromAbi tp) _) = do
  val <- parseModel tp <$> getValue solver (nameFromDecl ifaceName decl)
  pure (decl, val)

-- | Gets a concrete value from the solver for the given environment variable
getEnvironmentValue :: SolverInstance -> EthEnv -> IO (EthEnv, TypedExp)
getEnvironmentValue solver env = do
  output <- getValue solver (prettyEnv env)
  let val = case lookup env defaultStore of
        Just (FromAct typ) -> parseModel typ output
        _ -> error $ "Internal Error: could not determine a type for" <> show env
  pure (env, val)

-- | Calls `(get-value)` for the given identifier in the given solver instance.
getValue :: SolverInstance -> String -> IO String
getValue solver name = sendCommand solver $ "(get-value (" <> name <> "))"

-- | Parse the result of a call to getValue as the supplied type.
parseModel :: SType a -> String -> TypedExp
parseModel = \case
  SInteger -> _TExp . LitInt  nowhere . read       . parseSMTModel
  SBoolean -> _TExp . LitBool nowhere . readBool   . parseSMTModel
  SByteStr -> _TExp . ByLit   nowhere . fromString . parseSMTModel
  SContract -> error "unexpected contract type"
  where
    readBool "true" = True
    readBool "false" = False
    readBool s = error ("Could not parse " <> s <> "into a bool")

-- | Extracts a string representation of the value in the output from a call to `(get-value)`
parseSMTModel :: String -> String
parseSMTModel s = if length s0Caps == 1
                  then if length s1Caps == 1 then head s1Caps else head s0Caps
                  else ""
  where
    -- output should be in the form "((identifier value))" for positive integers / booleans / strings
    -- or "((identifier (value)))" for negative integers.
    -- The stage0 regex first extracts either value or (value), and then the
    -- stage1 regex is used to strip the additional brackets if required.
    stage0 = "\\`\\(\\([a-zA-Z0-9_]+ ([ \"\\(\\)a-zA-Z0-9_\\-]+)\\)\\)\\'"
    stage1 = "\\(([ a-zA-Z0-9_\\-]+)\\)"

    s0Caps = getCaptures s stage0
    s1Caps = getCaptures (head s0Caps) stage1

    getCaptures str regex = captures
      where (_, _, _, captures) = str =~ regex :: (String, String, String, [String])


--- ** SMT2 Generation ** ---


-- | encodes a storage update from a constructor creates block as an smt assertion
encodeInitialStorage :: Id -> StorageUpdate -> SMT2
encodeInitialStorage behvName (Update _ item expr) =
  let
    postentry  = withInterface behvName $ expToSMT2 (TEntry nowhere Post item)
    expression = withInterface behvName $ expToSMT2 expr
  in "(assert (= " <> postentry <> " " <> expression <> "))"

-- | declares a storage location that is created by the constructor, these
--   locations have no prestate, so we declare a post var only
declareInitialStorage :: StorageUpdate -> SMT2
declareInitialStorage (locFromUpdate -> Loc _ item) = case ixsFromItem item of
  []       -> constant (nameFromItem Post item)             (itemType item)
  (ix:ixs) -> array    (nameFromItem Post item) (ix :| ixs) (itemType item)

-- | encodes a storge update rewrite as an smt assertion
encodeUpdate :: Id -> Rewrite -> SMT2
encodeUpdate _        (Constant loc)   = "(assert (= " <> nameFromLoc Pre loc <> " " <> nameFromLoc Post loc <> "))"
encodeUpdate behvName (Rewrite update) = encodeInitialStorage behvName update

-- | declares a storage location that exists both in the pre state and the post
--   state (i.e. anything except a loc created by a constructor claim)
declareStorageLocation :: StorageLocation -> [SMT2]
declareStorageLocation (Loc _ item) = case ixsFromItem item of
  []       -> [ constant (nameFromItem Pre item) (itemType item)
              , constant (nameFromItem Post item) (itemType item) ]
  (ix:ixs) -> [ array (nameFromItem Pre item) (ix :| ixs) (itemType item)
              , array (nameFromItem Post item) (ix :| ixs) (itemType item) ]

-- | produces an SMT2 expression declaring the given decl as a symbolic constant
declareArg :: Id -> Decl -> SMT2
declareArg behvName d@(Decl typ _) = constant (nameFromDecl behvName d) (fromAbiType typ)

-- | produces an SMT2 expression declaring the given EthEnv as a symbolic constant
declareEthEnv :: EthEnv -> SMT2
declareEthEnv env = constant (prettyEnv env) tp
  where tp = fromJust . lookup env $ defaultStore

-- | encodes a typed expression as an smt2 expression
typedExpToSMT2 :: TypedExp -> Ctx SMT2
typedExpToSMT2 (TExp _ e) = expToSMT2 e

-- | encodes the given Exp as an smt2 expression
expToSMT2 :: Exp a -> Ctx SMT2
expToSMT2 expr = case expr of
  -- booleans
  And _ a b -> binop "and" a b
  Or _ a b -> binop "or" a b
  Impl _ a b -> binop "=>" a b
  Neg _ a -> unop "not" a
  LT _ a b -> binop "<" a b
  LEQ _ a b -> binop "<=" a b
  GEQ _ a b -> binop ">=" a b
  GT _ a b -> binop ">" a b
  LitBool _ a -> pure $ if a then "true" else "false"

  -- integers
  Add _ a b -> binop "+" a b
  Sub _ a b -> binop "-" a b
  Mul _ a b -> binop "*" a b
  Div _ a b -> binop "div" a b
  Mod _ a b -> binop "mod" a b
  Exp _ a b -> expToSMT2 $ simplifyExponentiation a b
  LitInt _ a -> pure $ if a >= 0
                      then show a
                      else "(- " <> (show . negate $ a) <> ")" -- cvc4 does not accept negative integer literals
  IntEnv _ a -> pure $ prettyEnv a

  -- bounds
  IntMin p a -> expToSMT2 . LitInt p $ intmin a
  IntMax _ a -> pure . show $ intmax a
  UIntMin _ a -> pure . show $ uintmin a
  UIntMax _ a -> pure . show $ uintmax a

  -- bytestrings
  Cat _ a b -> binop "str.++" a b
  Slice p a start end -> triop "str.substr" a start (Sub p end start)
  ByStr _ a -> pure a
  ByLit _ a -> pure $ show a
  ByEnv _ a -> pure $ prettyEnv a

  -- contracts
  Create _ _ _ _ -> error "contracts not supported"
  -- polymorphic
  Eq _ _ a b -> binop "=" a b
  NEq p s a b -> unop "not" (Eq p s a b)
  ITE _ a b c -> triop "ite" a b c
  Var _ _ a -> nameFromVarId a
  TEntry _ w item -> entry item w
  where
    unop :: String -> Exp a -> Ctx SMT2
    unop op a = ["(" <> op <> " " <> a' <> ")" | a' <- expToSMT2 a]

    binop :: String -> Exp a -> Exp b -> Ctx SMT2
    binop op a b = ["(" <> op <> " " <> a' <> " " <> b' <> ")"
                      | a' <- expToSMT2 a, b' <- expToSMT2 b]

    triop :: String -> Exp a -> Exp b -> Exp c -> Ctx SMT2
    triop op a b c = ["(" <> op <> " " <> a' <> " " <> b' <> " " <> c' <> ")"
                        | a' <- expToSMT2 a, b' <- expToSMT2 b, c' <- expToSMT2 c]

    entry :: TStorageItem a -> When -> Ctx SMT2
    entry item whn = case ixsFromItem item of
      []       -> pure $ nameFromItem whn item
      (ix:ixs) -> select (nameFromItem whn item) (ix :| ixs)

-- | SMT2 has no support for exponentiation, but we can do some preprocessing
--   if the RHS is concrete to provide some limited support for exponentiation
simplifyExponentiation :: Exp AInteger -> Exp AInteger -> Exp AInteger
simplifyExponentiation a b = fromMaybe (error "Internal Error: no support for symbolic exponents in SMT lib")
                           $ [LitInt nowhere $ a' ^ b'                         | a' <- eval a, b' <- evalb]
                         <|> [foldr (Mul nowhere) (LitInt nowhere 1) (genericReplicate b' a) | b' <- evalb]
  where
    evalb = eval b -- TODO is this actually necessary to prevent double evaluation?

-- | declare a constant in smt2
constant :: Id -> ActType -> SMT2
constant name tp = "(declare-const " <> name <> " " <> sType tp <> ")"

-- | encode the given boolean expression as an assertion in smt2
mkAssert :: Id -> Exp ABoolean -> SMT2
mkAssert c e = "(assert " <> withInterface c (expToSMT2 e) <> ")"

-- | declare a (potentially nested) array in smt2
array :: Id -> NonEmpty TypedExp -> ActType -> SMT2
array name (hd :| tl) ret = "(declare-const " <> name <> " (Array " <> sType' hd <> " " <> valueDecl tl <> "))"
  where
    valueDecl [] = sType ret
    valueDecl (h : t) = "(Array " <> sType' h <> " " <> valueDecl t <> ")"

-- | encode an array lookup in smt2
select :: String -> NonEmpty TypedExp -> Ctx SMT2
select name (hd :| tl) = do
  inner <- ["(" <> "select" <> " " <> name <> " " <> hd' <> ")" | hd' <- typedExpToSMT2 hd]
  foldM (\smt ix -> ["(select " <> smt <> " " <> ix' <> ")" | ix' <- typedExpToSMT2 ix]) inner tl

-- | act -> smt2 type translation
sType :: ActType -> SMT2
sType AInteger = "Int"
sType ABoolean = "Bool"
sType AByteStr = "String"
sType AContract = error "contracts not supported"

-- | act -> smt2 type translation
sType' :: TypedExp -> SMT2
sType' (TExp t _) = sType $ actType t

--- ** Variable Names ** ---

-- Construct the smt2 variable name for a given storage item
nameFromItem :: When -> TStorageItem a -> Id
nameFromItem whn (Item _ _ ref) = nameFromStorageRef ref @@ show whn

nameFromStorageRef :: StorageRef -> Id
nameFromStorageRef (SVar _ c name) = c @@ name
nameFromStorageRef (SMapping _ e _) = nameFromStorageRef e
nameFromStorageRef (SField _ _ _ _) = error "contracts not supported"

-- Construct the smt2 variable name for a given storage location
nameFromLoc :: When -> StorageLocation -> Id
nameFromLoc whn (Loc _ item) = nameFromItem whn item

-- Construct the smt2 variable name for a given decl
nameFromDecl :: Id -> Decl -> Id
nameFromDecl ifaceName (Decl _ name) = ifaceName @@ name

-- Construct the smt2 variable name for a given act variable
nameFromVarId :: Id -> Ctx Id
nameFromVarId name = [behvName @@ name | behvName <- ask]

(@@) :: String -> String -> String
x @@ y = x <> "_" <> y

--- ** Util ** ---

-- | The target expression of a query.
target :: Query -> Exp ABoolean
target (Postcondition _ e _)         = e
target (Inv (Invariant _ _ _ e) _ _) = invExp e

getQueryContract :: Query -> Id
getQueryContract (Postcondition (Ctor ctor) _ _) = _cname ctor
getQueryContract (Postcondition (Behv behv) _ _) = _contract behv
getQueryContract (Inv (Invariant c _ _ _) _ _) = c

isFail :: SMTResult -> Bool
isFail Unsat = False
isFail _ = True

isPass :: SMTResult -> Bool
isPass = not . isFail

getBehvName :: Query -> Doc
getBehvName (Postcondition (Ctor _) _ _) = (text "the") <+> (bold . text $ "constructor")
getBehvName (Postcondition (Behv behv) _ _) = (text "behaviour") <+> (bold . text $ _name behv)
getBehvName (Inv {}) = error "Internal Error: invariant queries do not have an associated behaviour"

identifier :: Query -> Doc
identifier q@(Inv (Invariant _ _ _ e) _ _)    = (bold . text . prettyInvPred $ e) <+> text "of" <+> (bold . text . getQueryContract $ q)
identifier q@Postcondition {} = (bold . text . prettyExp . target $ q) <+> text "in" <+> getBehvName q <+> text "of" <+> (bold . text . getQueryContract $ q)

getSMT :: Query -> Doc
getSMT (Postcondition _ _ smt) = pretty smt
getSMT (Inv _ (_, csmt) behvs) = text "; constructor" <$$> sep' <$$> line <> pretty csmt <$$> vsep (fmap formatBehv behvs)
  where
    formatBehv (b, smt) = line <> text "; behaviour: " <> (text . _name $ b) <$$> sep' <$$> line <> pretty smt
    sep' = text "; -------------------------------"

ifExists :: Foldable t => t a -> Doc -> Doc
ifExists a b = if null a then empty else b
