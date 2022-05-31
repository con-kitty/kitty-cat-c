{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
-- Data.Text.Prettyprint.Doc.Render.Text is deprecated.
{-# OPTIONS_GHC -fno-warn-deprecations #-}

module Categorifier.C.Codegen.FFI.TH (embedFunction) where

import qualified Categorifier.C.CExpr.Cat as C
import Categorifier.C.CExpr.Cat.TargetOb (TargetOb)
import qualified Categorifier.C.CExpr.File as CExpr (FunctionText (..))
import qualified Categorifier.C.CExpr.IO as CExpr (layoutOptions)
import Categorifier.C.CExpr.Types.Core (CExpr)
import Categorifier.C.Codegen.FFI.ArraysCC (fromArraysCC)
import Categorifier.C.Codegen.FFI.Spec (SBVFunCall)
import Categorifier.C.KTypes.C (C)
import Categorifier.C.KTypes.CExpr.Generate (generateCExprFunction)
import Categorifier.C.PolyVec (PolyVec, pdevectorize, pvectorize, pvlengths)
import Categorifier.C.Prim (ArrayCount, Arrays)
import qualified Categorifier.Common.IO.Exception as Exception
import Control.Monad ((<=<))
import Data.Functor.Compose (Compose (..))
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Prettyprint.Doc.Render.Text as Prettyprint
import Data.Typeable (Typeable)
import Data.Vector (Vector)
import Language.Haskell.TH.Syntax
  ( Body (NormalB),
    Callconv (..),
    Clause (..),
    Dec (ForeignD, FunD, SigD),
    Exp (..),
    Foreign (ImportF),
    ForeignSrcLang (LangC),
    Pat (VarP),
    Q,
    Safety (Safe),
    Type (..),
  )
import qualified Language.Haskell.TH.Syntax as TH
import qualified Type.Reflection as TR

arraysFun ::
  forall i o.
  (PolyVec CExpr (TargetOb i), PolyVec CExpr (TargetOb o)) =>
  (i `C.Cat` o) ->
  Arrays (Compose Vector CExpr) ->
  IO (Arrays (Compose Vector CExpr))
arraysFun f =
  Exception.throwIOLeft . pvectorize . C.lowerCat f <=< Exception.throwIOLeft . pdevectorize

inputDims :: forall a. PolyVec C a => Proxy a -> Arrays ArrayCount
inputDims = pvlengths (Proxy @C)

getTypeName :: forall t. (Typeable t) => Proxy t -> String
getTypeName p =
  let tRep = TR.someTypeRep p -- (Proxy @t)
      tCon = TR.someTypeRepTyCon tRep
   in TR.tyConName tCon

embedFunction ::
  forall i o.
  (Typeable i, Typeable o, PolyVec CExpr (TargetOb i), PolyVec CExpr (TargetOb o), PolyVec C i) =>
  Text ->
  (i `C.Cat` o) ->
  Q [Dec]
embedFunction name f = do
  -- generate C FFI
  let cname = "c_" <> name
      cnameName = TH.mkName (T.unpack cname)
  codeC <-
    TH.runIO $ do
      x <- generateCExprFunction name (inputDims $ Proxy @i) (arraysFun f)
      case x of
        Left err -> Exception.impureThrow err
        Right (CExpr.FunctionText _ srcText) ->
          pure $ Prettyprint.renderStrict $ CExpr.layoutOptions srcText
  TH.addForeignSource LangC (T.unpack codeC)
  cfunFfi <-
    ForeignD . ImportF CCall Safe (T.unpack name) cnameName <$> [t|SBVFunCall|]
  -- generate high-level haskell
  let inputTy = ConT (TH.mkName (getTypeName (Proxy @i)))
      outputTy = ConT (TH.mkName (getTypeName (Proxy @o)))
      funName = TH.mkName (T.unpack ("hs_" <> name))
  hsfunSig <-
    SigD funName <$> [t|$(pure inputTy) -> IO $(pure outputTy)|]
  body <-
    [|fromArraysCC (Proxy @($(pure inputTy) -> $(pure outputTy))) $(pure (VarE cnameName)) input|]
  let hsfunDef = FunD funName [Clause [VarP (TH.mkName "input")] (NormalB body) []]
  --
  pure [cfunFfi, hsfunSig, hsfunDef]
