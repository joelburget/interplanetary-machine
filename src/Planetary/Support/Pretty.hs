{-# language DataKinds #-}
{-# language FlexibleInstances #-}
{-# language LambdaCase #-}
{-# language MultiParamTypeClasses #-}
{-# language NamedFieldPuns #-}
{-# language OverloadedStrings #-}
{-# language PatternSynonyms #-}
{-# language Rank2Types #-}
{-# language TupleSections #-}
{-# language TypeFamilies #-}
module Planetary.Support.Pretty where

import Control.Lens hiding (ix)
import Data.List (intersperse)
import Data.Semigroup ((<>))
import Data.Text (Text)
import qualified Data.Text as Text
import Network.IPLD hiding (Row)
import Data.Text.Encoding (decodeUtf8)
import Data.Text.Prettyprint.Doc
import Data.Text.Prettyprint.Doc.Render.Terminal

import Planetary.Core

data Ann = Highlighted | Error | Plain | Value | Term

annToAnsi :: Ann -> AnsiStyle
annToAnsi = \case
  Highlighted -> colorDull Blue
  Error       -> color Red <> bold
  Plain       -> mempty
  Value       -> colorDull Green
  Term        -> color Magenta

prettyEnv :: Stack [TmI] -> Doc Ann
prettyEnv stk =
  let
      lineFormatter i tm = pretty i <> ": " <> prettyTmPrec 0 tm
      stkLines = vsep . imap lineFormatter <$> stk
  in vsep
       [ annotate Highlighted "env:"
       , indent 2 (lineVsep "line" stkLines)
       ]

lineVsep :: Text -> [Doc ann] -> Doc ann
lineVsep head =
  let lineFormatter i line = vsep
        [ pretty head <+> pretty i <> ": "
        , indent 2 line
        ]
  in vsep . intersperse "" . imap lineFormatter

-- TODO show pure continuation
prettyCont :: Doc Ann -> Stack ContinuationFrame -> Doc Ann
prettyCont name stk =
  let prettyContFrame (ContinuationFrame _stk handler) = prettyTmPrec 0 handler
      lines = prettyContFrame <$> stk
  in vsep
       [ annotate Highlighted name
       , indent 2 (lineVsep "line" lines)
       ]

prettyEvalState :: EvalState -> Doc Ann
prettyEvalState (EvalState focus env cont fwdCont done) = vsep
  [ "EvalState" <> if done then " (done)" else ""
  , indent 2 $ vsep
    [ annotate Highlighted "focus:" <+> prettyTmPrec 0 focus
    , prettyEnv env
    , prettyCont "cont:" cont
    , case fwdCont of
        Nothing       -> mempty
        Just fwdCont' -> prettyCont "fwd cont:" fwdCont'
    ]
  ]

-- prettySequence :: [Doc ann] -> Doc ann
-- prettySequence xs =
--   let open      = flatAlt "" "{ "
--       close     = flatAlt "" " }"
--       separator = flatAlt "" "; "
--   in group (encloseSep open close separator xs)

prettyTyPrec :: (IsUid uid, Pretty uid) => Int -> TyFix uid -> Doc ann
prettyTyPrec d = \case
  DataTy ty tys -> angles $ fillSep $ prettyTyPrec 0 <$> ty : tys
  SuspendedTy ty -> braces $ prettyTyPrec 0 ty
  BoundVariableTy i -> showParens d $ "BV" <+> pretty i
  FreeVariableTy t -> pretty t
  UidTy uid -> pretty uid
  CompTy args peg -> fillSep $ intersperse "->" $
    prettyTyPrec 0 <$> args ++ [peg]
  Peg ab ty -> showParens d $ prettyTyPrec d ab <+> prettyTyPrec d ty
  TyArgVal ty -> prettyTyPrec d ty
  TyArgAbility ab -> prettyTyPrec d ab
  Ability init mapping ->
    let initP = case init of
          -- TODO real name
          OpenAbility -> "e"
          ClosedAbility -> "0"
        -- prettyArgs :: [TyFix uid] -> Doc ann
        prettyArgs = fillSep . fmap (prettyTyPrec 0)
        flatArgs = (\(i, r) -> pretty i <+> prettyArgs r) <$> toList mapping
        flatArgs' = if null flatArgs then [] else "+" : flatArgs

    in brackets $ fillSep $ initP : flatArgs'

prettyPolytype :: (IsUid uid, Pretty uid) => Int -> Polytype uid -> Doc ann
prettyPolytype d (Polytype binders val) =
  let prettyBinder (name, kind) = case kind of
        ValTyK -> pretty name
        EffTyK -> brackets (pretty name)
      prettyBinders binders = fillSep (prettyBinder <$> binders)
  in "forall" <+> prettyBinders binders <> "." <+> prettyTyPrec d val

showParens :: Int -> Doc ann -> Doc ann
showParens i = if i > 10 then parens else id

prettyTmPrec :: (IsUid uid, Pretty uid) => Int -> Tm uid -> Doc Ann
prettyTmPrec d = \case
  FreeVariable t -> pretty t
  BoundVariable depth col -> showParens d $
    "BV" <+> pretty depth <+> pretty col
  DataConstructor uid row args -> angles $ fillSep $
    let d' = if length args > 1 then 11 else 0
    in (pretty uid <> "." <> pretty row) : (prettyTmPrec d' <$> args)
  ForeignValue ty args locator -> showParens d $ fillSep $
    let d' = if length args > 1 then 11 else 0
    in "Foreign @" <> pretty ty : (prettyTyPrec d' <$> args) ++ [pretty locator]
  Lambda names body ->
    "\\" <> fillSep (pretty <$> names) <+> "->" <+>
      prettyTmPrec 0 (open (FreeVariable . (names !!)) body)
  Command uid row -> pretty uid <> "." <> pretty row
  Annotation tm ty -> parens $ fillSep [prettyTmPrec 0 tm, ":", prettyTyPrec 0 ty]
  -- TODO: show the division between normalized / non-normalized
  Application tm spine -> case spine of
    MixedSpine [] [] -> prettyTmPrec d tm <> "!"
    MixedSpine vals tms -> showParens d $ fillSep $
      prettyTmPrec 11 tm :
      fmap (annotate Value . prettyTmPrec 11) vals <>
      fmap (annotate Term  . prettyTmPrec 11) tms
    -- _ -> fillSep $ prettyTmPrec d <$> (tm : Foldable.toList spine)

  Case uid scrutinee handlers -> vsep
    [ "case" <+> prettyTmPrec 0 scrutinee <+> "of"
    -- TODO: use align or hang?
    , indent 2 $ vsep
      [ pretty uid <> ":"
      , indent 2 $ vsep $ flip fmap handlers $ \(names, body) -> fillSep
        [ "|"
        , angles $ fillSep $ "_" : fmap pretty names
        , "->"
        , prettyTmPrec 0 $ open (FreeVariable . (names !!)) body
        ]
      ]
    ]

  Handle tm _adj peg handlers (vName, vRhs) ->
    let
        prettyRow (names, kName, rhs) = fillSep
          ["|"
          , angles $ fillSep ("_" : fmap pretty names ++ ["->", pretty kName])
          , "->"
          , prettyTmPrec 0 $ open (FreeVariable . ((kName : names) !!)) rhs
          ]
        prettyHandler (uid, uidHandler) = vsep
          [ pretty uid <+> colon
          , indent 2 (align $ vsep $ fmap prettyRow uidHandler)
          ]
        handlers' = prettyHandler <$> toList handlers
    in vsep
         [ "Handle" <+> prettyTmPrec 0 tm <+> colon <+> prettyTyPrec 0 peg <+> "with"
         , indent 2 (align $ vsep handlers')
         , fillSep
           [ "|"
           , pretty vName
           , "->"
           , prettyTmPrec 0 (open1 (FreeVariable vName) vRhs)
           ]
         ]

  Let body ty name rhs -> fillSep
    [ "let"
    , pretty name
    , ":"
    , prettyPolytype 0 ty
    , "="
    , prettyTmPrec 0 body
    , "in"
    , prettyTmPrec 0 (open1 (FreeVariable name) rhs)
    ]

  Letrec names lambdas body ->
    let rowInfo = zip names lambdas
        rows = flip fmap rowInfo $ \(name, (ty, lam)) -> vsep
          [ pretty name <+> colon <+> prettyPolytype 0 ty
          , indent 2 $ "=" <+> prettyTmPrec 0 lam
          ]
    in vsep
         [ "letrec"
         , indent 2 $ vsep rows
         , "in" <+> prettyTmPrec 0 body
         ]

  Hole -> "_"

instance Pretty Cid where
  pretty = pretty . Text.cons '…' . Text.takeEnd 5 . decodeUtf8 . compact

layout :: Doc Ann -> Text
layout = renderStrict .
  layoutSmart LayoutOptions {layoutPageWidth = AvailablePerLine 80 1} .
  reAnnotate annToAnsi

logReturnState :: Text -> EvalState -> Text
logReturnState name st = layout $ vsep
  [ "Result of applying:" <+> annotate Highlighted (pretty name)
  , prettyEvalState st
  , ""
  ]

logIncomplete :: EvalState -> Text
logIncomplete st = layout $ vsep
  [ annotate Error "incomplete: no rule to handle"
  , prettyEvalState st
  ]