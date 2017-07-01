{-# language FlexibleContexts #-}
{-# language GADTs #-}
{-# language LambdaCase #-}
{-# language NamedFieldPuns #-}
{-# language TemplateHaskell #-}
module Planetary.Core.Eval
  ( Err(..)
  , EvalEnv(..)
  , ForeignM
  , CurrentHandlers
  , step
  , run
  , runEvalM
  ) where

import Bound
import Control.Lens hiding ((??))
import Control.Monad.Except
import Control.Monad.State
import Network.IPLD hiding (Row, Value)
import qualified Network.IPLD as IPLD

import Planetary.Core.Syntax
import Planetary.Core.Syntax.Patterns
import Planetary.Core.UIdMap
import Planetary.Util

data Err
  = RowBound
  | IndexErr
  | Halt
  | FailedHandlerLookup
  | FailedIpldConversion
  | FailedForeignFun
  | CantCut ContinuationI TmI
  deriving (Eq, Show)

type CurrentHandlers = UIdMap Cid [SpineI -> ForeignM TmI]
type ValueStore      = UIdMap Cid IPLD.Value
data EvalEnv         = EvalEnv
  { _currentHandlers :: CurrentHandlers
  , _valueStore      :: ValueStore
  }

data EvalState = EvalState
  { _evalStack :: Stack ContinuationI
  , _evalEnv   :: EvalEnv
  }

-- This is the monad you write FFI operations in.
-- TODO: what is a foreignm?
type ForeignM =
  ExceptT Err
  (StateT ValueStore
  IO)

-- Maintain a stack of continuations to resume as we evaluate the current
-- target to a value
type EvalM =
  ExceptT Err
  (StateT EvalState
  IO)

makeLenses ''EvalEnv
makeLenses ''EvalState

runHandler :: Cid -> Row -> Spine Cid Int -> EvalM TmI
runHandler cid row spine = do
  cont <- gets (^? evalEnv . currentHandlers . ix cid . ix row)
    >>= (?? FailedHandlerLookup)
  let action = cont spine
  runForeignM action

-- TODO: do this without casing? mmorph
runForeignM :: ForeignM a -> EvalM a
runForeignM action = do
  store <- gets (^. evalEnv . valueStore)
  val <- liftIO $ runExceptT action `evalStateT` store
  case val of
    Left err -> throwError err
    Right a -> pure a

runEvalM
  :: EvalEnv -> Stack ContinuationI -> EvalM TmI
  -> IO (Either Err TmI, EvalState)
runEvalM env stack action = runStateT
  (runExceptT action)
  (EvalState stack env)

run
  :: EvalEnv -> Stack ContinuationI -> TmI
  -> IO (Either Err ValueI, EvalState)
run env stack = \case
  Value v -> pure (Right v, EvalState stack env)
  tm -> do
    (eitherTm, evst@(EvalState stack' env')) <- runEvalM env stack (step tm)
    case eitherTm of
      Left err -> pure (Left err, evst)
      Right tm' -> run env' stack' tm'

halt :: EvalM a
halt = throwError Halt

-- TODO: have a `terminal` judgement
step :: TmI -> EvalM TmI
step v@(Value _) = pure v -- ?
step (Cut cont scrutinee) = stepCut cont scrutinee
  -- case scrutinee of
  --   Value v -> stepCut cont v
  --   _other -> do
  --     modify (cont:)
  --     pure scrutinee
step Variable{}           = halt
step InstantiatePolyVar{} = halt -- XXX
step Annotation{}         = halt
step Letrec{} = todo "step letrec"

stepCut :: ContinuationI -> TmI -> EvalM TmI
stepCut (Application spine) (LambdaV _names scope)
  -- TODO: safe
  = pure $ instantiate (spine !!) scope
stepCut (Application spine) (CommandV uid row) =
  -- handler <- findHandler
  runHandler uid row spine
  -- handleCommand cid row spine handlers
stepCut (Case _uid1 rows) (DataConstructorV _uid2 rowNum args) = do
  (_, row) <- rows ^? ix rowNum ?? IndexErr
  -- TODO: maybe we need to evaluate the args to a value first
  pure (instantiate (args !!) row)
stepCut (Handle _adj _peg _handlers handleValue) v@Value{} =
  pure $ instantiate1 v handleValue

stepCut (Let _polyty _name body) rhs@Value{} = pure $ instantiate1 rhs body
stepCut cont cut@Cut {} = stepCut cont =<< step cut
stepCut cont scrutinee = throwError (CantCut cont scrutinee)

-- withHandlers :: AdjustmentHandlersI -> Scope () (Tm Cid Int) Int -> EvalM a -> EvalM a
-- withHandlers (AdjustmentHandlers handlers) handleValue action $ do

handleCommand
  :: Cid
  -> Row
  -> SpineI
  -- -> TmI
  -> AdjustmentHandlersI
  -> EvalM TmI
handleCommand uid row spine (AdjustmentHandlers (UIdMap handlers)) = do
  -- look up n_c (handler)
  -- TODO this should actually just fall through not error
  handlers' <- handlers  ^? ix uid ?? IndexErr
  handler   <- handlers' ^? ix row ?? IndexErr

  let instantiator = \case
        Nothing -> LambdaV (todo "XXX") (todo "command instantiator")
        Just i -> spine !! i
  -- \case
  --       -- XXX really not sure this is right
  --       Nothing -> Value (Lambda (abstract Just val))
  --       Just i -> spine !! i

  pure (instantiate instantiator handler)
