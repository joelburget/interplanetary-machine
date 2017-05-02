{-# language ConstraintKinds #-}
{-# language DataKinds #-}
{-# language FlexibleInstances #-}
{-# language GeneralizedNewtypeDeriving #-}
{-# language NamedFieldPuns #-}
{-# language PackageImports #-}
{-# language StandaloneDeriving #-}
{-# language TupleSections #-}
-- A simple Core Frank parser based on the frankjnr implementation
module Planetary.Support.Parser where

import Control.Applicative
import Control.Lens (unsnoc)
import Data.Functor (($>))
import Data.Maybe (fromMaybe)

-- TODO: be suspicious of `try`, see where it can be removed
-- http://blog.ezyang.com/2014/05/parsec-try-a-or-b-considered-harmful/
import Text.Trifecta -- hiding (try)
import "indentation-trifecta" Text.Trifecta.Indentation

import Data.Char

import Text.Parser.Token as Tok
import Text.Parser.Token.Style
import qualified Text.Parser.Token.Highlight as Hi
import qualified Data.HashSet as HashSet
import Bound

import Planetary.Core
import Planetary.Util

type Tm' = Tm String String String
type Construction = Tm'
type Use = Tm'
type Cont' = Continuation String String String
type Value' = Value String String String

newtype CoreParser t m a =
  CoreParser { runCoreParser :: IndentationParserT t m a }
  deriving (Functor, Alternative, Applicative, Monad, Parsing
           , IndentationParsing)

deriving instance (DeltaParsing m) => (CharParsing (CoreParser Char m))
deriving instance (DeltaParsing m) => (CharParsing (CoreParser Token m))
deriving instance (DeltaParsing m) => (TokenParsing (CoreParser Char m))

instance DeltaParsing m => TokenParsing (CoreParser Token m) where
  someSpace = CoreParser $ buildSomeSpaceParser someSpace haskellCommentStyle
  nesting = CoreParser . nesting . runCoreParser
  semi = CoreParser $ runCoreParser semi
  highlight h = CoreParser . highlight h . runCoreParser
  token p = (CoreParser $ token (runCoreParser p)) <* whiteSpace

type MonadicParsing m = (TokenParsing m, IndentationParsing m, Monad m)

planetaryStyle :: MonadicParsing m => IdentifierStyle m
planetaryStyle = IdentifierStyle {
    _styleName = "Planetary"
  , _styleStart = satisfy (\c -> isAlpha c || c == '_')
  , _styleLetter = satisfy (\c -> isAlphaNum c || c == '_' || c == '\'')
  , _styleReserved = HashSet.fromList
    [ "data"
    , "interface"
    , "let"
    , "letrec"
    , "in"
    , "forall"
    , "case"
    , "handle"
    , "of"
    , "with"
    ]
  , _styleHighlight = Hi.Identifier
  , _styleReservedHighlight = Hi.ReservedIdentifier }

arr, bar, assign, bang :: MonadicParsing m => m String
arr = symbol "->"
bar = symbol "|"
assign = symbol "="
bang = symbol "!"

reserved :: MonadicParsing m => String -> m ()
reserved = Tok.reserve planetaryStyle

identifier :: MonadicParsing m => m String
identifier = Tok.ident planetaryStyle
  <?> "identifier"

parseUid :: MonadicParsing m => m String
-- TODO: get an exact count of digits
parseUid = token (some alphaNum)
  <?> "uid"

parseValTy :: MonadicParsing m => m (ValTy String String)
parseValTy = try parseDataTy <|> parseValTy' -- TODO: bad use of try
  <?> "Val Ty"

parseValTy' :: MonadicParsing m => m (ValTy String String)
parseValTy' = parens parseValTy
          <|> SuspendedTy <$> braces parseCompTy
          <|> VariableTy <$> identifier
          <?> "Val Ty (not data)"

parseTyArg :: MonadicParsing m => m (TyArg String String)
parseTyArg = TyArgVal <$> parseValTy'
         <|> TyArgAbility <$> brackets parseAbilityBody
         <?> "Ty Arg"

parseConstructors :: MonadicParsing m => m (Vector (ConstructorDecl String String))
parseConstructors = sepBy parseConstructor bar <?> "Constructors"

parseConstructor :: MonadicParsing m => m (ConstructorDecl String String)
parseConstructor = ConstructorDecl <$> many parseValTy' <?> "Constructor"

-- Parse a potential datatype. Note it may actually be a type variable.
parseDataTy :: MonadicParsing m => m (ValTy String String)
parseDataTy = DataTy
  -- Since a nice surface syntax is not a primary concern we can add tokens to
  -- disambiguate and make our job here easier.
  <$> (string "d" *> colon *> parseUid)
  <*> many parseTyArg
  -- <*> localIndentation Gt (many parseTyArg)
  <?> "Data Ty"

parseTyVar :: MonadicParsing m => m (String, Kind)
parseTyVar = (,EffTy) <$> brackets parseEffectVar
         <|> (,ValTy) <$> identifier
         <?> "Ty Var"

parseEffectVar :: MonadicParsing m => m String
parseEffectVar = do
  mx <- optional identifier
  return $ fromMaybe "0" mx

-- 0 | 0|Interfaces | e|Interfaces | Interfaces
-- TODO: change to comma?
-- TODO: allow explicit e? `[e]`
parseAbilityBody :: MonadicParsing m => m (Ability String String)
parseAbilityBody =
  let closedAb = do
        _ <- symbol "0"
        instances <- option [] (bar *> parseInterfaceInstances)
        return $ Ability ClosedAbility (uIdMapFromList instances)
      varAb = do
        var <- option "e" (try identifier)
        instances <- option [] (bar *> parseInterfaceInstances)
        return $ Ability OpenAbility (uIdMapFromList instances)
  in closedAb <|> varAb <?> "Ability Body"

parseAbility :: MonadicParsing m => m (Ability String String)
parseAbility = do
  mxs <- optional $ brackets parseAbilityBody
  return $ fromMaybe emptyAbility mxs

-- liftClosed :: (Traversable f, Alternative m) => f String -> m (f Int)
-- liftClosed tm = case closed tm of
--   Nothing -> empty
--   Just tm' -> pure tm'

parsePeg :: MonadicParsing m => m (Peg String String)
parsePeg = Peg
  <$> parseAbility
  <*> parseValTy
  <?> "Peg"

parseCompTy :: MonadicParsing m => m (CompTy String String)
parseCompTy = CompTy
  <$> many (try (parseValTy <* arr)) -- TODO: bad use of try
  <*> parsePeg
  <?> "Comp Ty"

parseInterfaceInstance :: MonadicParsing m => m (String, [TyArg String String])
parseInterfaceInstance = (,) <$> parseUid <*> many parseTyArg
  <?> "Interface Instance"

parseInterfaceInstances :: MonadicParsing m => m [(String, [TyArg String String])]
parseInterfaceInstances = sepBy parseInterfaceInstance comma
  <?> "Interface Instances"

parseDataDecl :: MonadicParsing m => m (String, DataTypeInterface String String)
parseDataDecl = do
  reserved "data"
  name <- identifier
  tyArgs <- many parseTyVar
  _ <- assign
  ctrs <- localIndentation Gt parseConstructors
  return (name, DataTypeInterface tyArgs ctrs)

-- only value arguments and result type
parseCommandType :: MonadicParsing m => m (Vector (ValTy String String), ValTy String String)
parseCommandType = do
  vs <- sepBy1 parseValTy arr
  maybe empty pure (unsnoc vs)
  -- maybe empty pure . unsnoc =<< sepBy1 parseValTy arr

parseCommandDecl :: MonadicParsing m => m (CommandDeclaration String String)
parseCommandDecl = uncurry CommandDeclaration <$> parseCommandType
  <?> "Command Decl"

parseInterfaceDecl :: MonadicParsing m => m (String, EffectInterface String String)
parseInterfaceDecl = (do
  reserved "interface"
  name <- identifier
  tyVars <- many parseTyVar
  _ <- assign
  -- inBoundTys
  xs <- localIndentation Gt $ sepBy1 parseCommandDecl bar
  return (name, EffectInterface tyVars xs)
  ) <?> "Interface Decl"

parseDataOrInterfaceDecls
  :: MonadicParsing m
  => m [Either (String, DataTypeInterface String String)
               (String, EffectInterface String String)
       ]
parseDataOrInterfaceDecls = some
  (Left <$> parseDataDecl <|> Right <$> parseInterfaceDecl)
  <?> "Data or Interface Decls"

parseApplication :: MonadicParsing m => m Use
parseApplication =
  let parser = do
        fun <- Variable <$> identifier -- TODO: not sure this line is right
        spine <- choice [some parseTmNoApp, bang $> []]
        pure $ Cut (Application spine) fun
  in parser <?> "Application"

parseValue :: MonadicParsing m => m Value'
parseValue = choice
  -- [ parseDataConstructor
  -- parseCommand
  [ parseLambda
  ]

parseCase :: MonadicParsing m => m Tm'
parseCase = do
  _ <- reserved "case"
  m <- parseTm
  _ <- reserved "of"
  (uid, branches) <- localIndentation Gt $ do
    uid <- parseUid
    branches <- localIndentation Gt $ many $ absoluteIndentation $ do
      _ <- bar
      vars <- many identifier
      _ <- arr
      rhs <- parseTm
      pure (vars, rhs)
    pure (uid, branches)
  pure $ Cut (case_ uid branches) m

parseHandle :: MonadicParsing m => m Tm'
parseHandle = do
  _ <- reserved "handle"
  adj <- parens parseAdjustment
  peg <- parens parsePeg
  target <- parseTm
  _ <- reserved "with"
  (handlers, fallthrough) <- localIndentation Gt $ do
    -- parse handlers
    -- TODO: many vs some?
    handlers <- many $ absoluteIndentation $ do
      uid <- parseUid
      _ <- colon

      rows <- localIndentation Gt $ many $ absoluteIndentation $ do
        _ <- bar
        vars <- many identifier
        _ <- arr
        kVar <- arr
        _ <- arr
        rhs <- parseTm
        pure (vars, kVar, rhs)

      pure (uid, rows)

    -- and fallthrough
    fallthrough <- localIndentation Eq $ do
      _ <- bar
      var <- identifier
      _ <- arr
      rhs <- parseTm
      pure (var, rhs)

    pure (uIdMapFromList handlers, fallthrough)

  let cont = handle adj peg handlers fallthrough
  pure (Cut {cont, target})

parseTm :: MonadicParsing m => m Tm'
parseTm = (do
  tms <- some parseTmNoApp
  case tms of
    []       -> empty
    [tm]     -> pure tm
    tm:spine -> pure (Cut (Application spine) tm)
  ) <?> "Tm"

parseTmNoApp :: MonadicParsing m => m Tm'
parseTmNoApp
  = parens parseTm
  <|> Value <$> parseValue
  <|> parseCase
  <|> parseHandle
  <|> parseLet
  <|> Variable <$> identifier
  <?> "Tm (no app)"

parseAdjustment :: MonadicParsing m => m (Adjustment String String)
parseAdjustment = (do
  -- TODO: re parseUid: also parse name?
  let adjItem = (,) <$> parseUid <*> many parseTyArg
  rows <- adjItem `sepBy1` symbol "+"
  pure $ Adjustment $ uIdMapFromList rows
  ) <?> "Adjustment"

-- parseContinuation

parseLambda :: MonadicParsing m => m Value'
parseLambda = lam
  <$> (symbol "\\" *> some identifier) <*> (arr *> parseTm)
  <?> "Lambda"

parsePolyty :: MonadicParsing m => m (Polytype String String)
parsePolyty = do
  reserved "forall"
  args <- many parseTyVar
  _ <- dot
  result <- parseValTy
  pure (polytype args result)

parseLet :: MonadicParsing m => m Construction
parseLet =
  let parser = do
        reserved "let"
        name <- identifier
        _ <- colon
        ty <- parsePolyty
        _ <- assign
        rhs <- parseTm
        reserved "in"
        body <- parseTm
        pure (let_ name ty rhs body)
  in parser <?> "Let"

-- reorgTuple :: (a, b, c) -> (a, (c, b))
-- reorgTuple (a, b, c) = (a, (c, b))

-- parseLetRec :: MonadicParsing m => m Construction
-- parseLetRec =
--   let parser = do
--         reserved "letrec"
--         definitions <- some $ (,,)
--           <$> identifier <* colon
--           <*> parsePolyty <* assign
--           <*> parseLambda
--         reserved "in"
--         body <- parseConstruction
--         let (names, binderVals) = unzip (reorgTuple <$> definitions)
--         return $ letrec names binderVals body
--   in parser <?> "Letrec"

parseDecl :: MonadicParsing m => m (Construction, ValTy String String)
parseDecl =
  let parser = do
        -- name <- identifier
        _ <- colon
        ty <- parseValTy -- differs from source `parseSigType`
        construction <- localIndentation Gt $ do
          _ <- assign
          parseTm
        pure (construction, ty)
  in parser <?> "declaration"

evalCharIndentationParserT
  :: Monad m => CoreParser Char m a -> IndentationState -> m a
evalCharIndentationParserT = evalIndentationParserT . runCoreParser

evalTokenIndentationParserT
  :: Monad m => CoreParser Token m a -> IndentationState -> m a
evalTokenIndentationParserT = evalIndentationParserT . runCoreParser

runParse
  :: (t -> IndentationState -> Parser b) -> t -> String -> Either String b
runParse ev p input
 = let indA = ev p $ mkIndentationState 0 infIndentation True Ge
   in case parseString indA mempty input of
    Failure (ErrInfo errDoc _deltas) -> Left (show errDoc)
    Success t -> Right t

--runCharParse = runParse evalCharIndentationParserT
runTokenParse :: CoreParser Token Parser b -> String -> Either String b
runTokenParse p = runParse evalTokenIndentationParserT p

-- runTokenLocParse :: CoreParser Token Parser b -> String -> Either String b
-- runTokenLocParse p =
--   let ind = _
--   in case parseString ind mempty of
