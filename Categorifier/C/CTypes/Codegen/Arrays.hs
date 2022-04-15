{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TupleSections #-}

-- | Generate code to convert C types to arrays of primitives suitable for calling
-- the autogenerated flight control functions.
-- Currently generates C++ so that we can use typed C array references and get compile-time
-- length mismatch errors.
module Categorifier.C.CTypes.Codegen.Arrays
  ( ToOrFromArrays (..),
    WrittenArrayFunctions (..),
    CheckFinite (..),
    toArraysModule,
    withArrayCounts,
    incrementalConvertArrays',
    whenNonFiniteParamExpr,
    nonFiniteStatsParamExpr,
    nonFiniteStatsParam,
    NonFiniteField (..),

    -- * for test generation
    ArraysFunType (..),
    toArraysFunctionName',
  )
where

import qualified Barbies
import Categorifier.C.CTypes.ArrayLengths
  ( Mismatch,
    arrayLengthsCCon,
    arrayLengthsCType,
    checkForMismatches,
  )
import Categorifier.C.CTypes.Codegen.Arrays.Types
  ( ArraysFunType (..),
    CheckFinite (..),
    ToOrFromArrays (..),
    passByValue,
    toArrayIdentPrefix,
    toArrayIdentifier,
    toArrayIdentifier',
  )
import Categorifier.C.CTypes.Codegen.Helpers (CStructOrUnion (..))
import Categorifier.C.CTypes.Codegen.NonFinite
  ( NonFiniteField (..),
    fpPrimFunctionBody,
    makeNonFiniteParams,
    needsNonFiniteParams,
    nonFiniteStatsParam,
    nonFiniteStatsParamExpr,
    safeNonFiniteAccess,
    whenNonFiniteParamExpr,
    whenNonFiniteParamIdent,
  )
import Categorifier.C.CTypes.DSL.CxxAst
  ( CExpr (..),
    CFunction (..),
    CTypeWithBackdoor (..),
    Comment (..),
    CxxModule (..),
    CxxTarget (..),
    Identifier (..),
    Include (..),
    Param (..),
    ParamType (..),
    SystemLib (Def, Math),
    TapeElement (..),
    dereference,
    natExpr,
    oldCCast,
    (!),
    (#!),
  )
import Categorifier.C.CTypes.DSL.FunctionWriter
  ( comment,
    force_,
    loopWithType,
    runFunWriter,
    unionCast,
    unsafeNewNamed,
    (=:),
  )
import qualified Categorifier.C.CTypes.Render as R
import Categorifier.C.CTypes.Types
  ( CBitfield (..),
    CCon,
    CConF (..),
    CEnum (..),
    CNat (..),
    CStructF (..),
    CType,
    CTypeF (..),
    CUnion,
    CUnionConF (..),
    CUnionF (..),
    CxxType (..),
    bfprimToPrim,
    cnatValue,
    pattern CTypePrim',
  )
import Categorifier.C.Prim
  ( ArrayCount (..),
    Arrays,
    Prim (..),
    allPrimTypes,
    arrayPrims,
    toPrim,
    pattern DoubleType,
    pattern FloatType,
  )
import Categorifier.C.Recursion (hembed, hproject)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State.Strict (StateT (..), execStateT, get, put, runStateT)
import Data.Foldable (traverse_)
import qualified Data.Foldable as F
import Data.Functor.Const (Const (..))
import Data.Functor.Product (Product (..))
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Map.Strict as M
import Data.Proxy (Proxy (..))
import qualified Data.Text as T
import qualified Data.Vector as V
import PyF (fmt)

-- | Renders an @ArraysFunType@ underlying type using the 'Kitty.CTypes.Render' library.
renderAfType :: ArraysFunType -> T.Text
renderAfType (AfCType r) = R.renderCType r
renderAfType (AfCUnionCon r) = R.renderCUnionConType r

data WrittenArrayFunctions = WrittenArrayFunctions [CFunction] (M.Map ArraysFunType CFunction)

toArraysModule ::
  ToOrFromArrays ->
  [CEnum Proxy] ->
  [CStructOrUnion] ->
  [CType Proxy] ->
  Either (NonEmpty (T.Text, Arrays Mismatch)) CxxModule
toArraysModule toOrFrom cenums cstructsOrUnions carrays = do
  WrittenArrayFunctions functions _ <- execStateT writeFunctions (WrittenArrayFunctions [] mempty)
  pure
    CxxModule
      { moduleIncludes = [IncludeModule CTypes, IncludeSystemLib Math, IncludeSystemLib Def],
        moduleDefines = [],
        moduleTypedefs = [],
        moduleUsingDecls = [],
        moduleFunctions = reverse functions,
        moduleTypeLevelFunctions = []
      }
  where
    writeFunctions = do
      traverse_ (toArraysFunction toOrFrom . AfCType . CTypePrim) allPrimTypes
      traverse_ (toArraysFunction toOrFrom . AfCType . CTypeEnum) cenums
      traverse_ toSUArraysFunction cstructsOrUnions
      traverse_ (toArraysFunction toOrFrom . AfCType) carrays
      where
        toSUArraysFunction (CU cunion) = toArraysFunction toOrFrom (AfCType (CTypeUnion cunion))
        toSUArraysFunction (CS cstruct) = toArraysFunction toOrFrom (AfCType (CTypeStruct cstruct))

toArraysFunction ::
  ToOrFromArrays ->
  ArraysFunType ->
  StateT WrittenArrayFunctions (Either (NonEmpty (T.Text, Arrays Mismatch))) CFunction
toArraysFunction toOrFrom afType = do
  WrittenArrayFunctions _ funMap0 <- get
  case M.lookup afType funMap0 of
    Just r -> pure r
    Nothing -> do
      body <- case afType of
        AfCType (CTypeArray cnat elemType _) ->
          arrayOfElemFunctionBody toOrFrom cnat $ hproject elemType
        AfCType (CTypePrim cprim) -> pure $ primFunctionBody toOrFrom cprim
        AfCType (CTypeEnum cenum) -> pure $ enumFunctionBody toOrFrom cenum
        AfCType (CTypeStruct cstruct@(CStruct _ ccon)) ->
          conFunctionBody toOrFrom (R.renderCStructType cstruct) ccon
        AfCType (CTypeUnion cunion@CUnion {}) -> unionFunctionBody toOrFrom cunion
        AfCUnionCon unionCon@(CUnionCon _ ccon) ->
          conFunctionBody toOrFrom (R.renderCUnionConType unionCon) ccon
      let fun =
            UnsafeCFunction
              { cfName = toArraysFunctionName toOrFrom afType,
                cfInlineOverloadName = Nothing,
                cfReturnType = Nothing,
                cfStaticLinkage = False,
                cfComment = (Just . Comment . renderAfType) afType,
                cfParams = toFunctionParams toOrFrom afType,
                cfTape = body
              }
      WrittenArrayFunctions funs funMap <- get
      put $ WrittenArrayFunctions (fun : funs) (M.insert afType fun funMap)
      pure fun

-- Variable name for the struct/enum/etc, as opposed to the arrays.
valueParamName :: T.Text
valueParamName = "value"

valueParamIdent :: Identifier
valueParamIdent = Identifier valueParamName

valueParamExpr :: CExpr
valueParamExpr = Ident valueParamIdent

newtype ArrayIdent a = ArrayIdent Identifier deriving (Show)

toArrayIdents :: ToOrFromArrays -> Arrays ArrayIdent
toArrayIdents toOrFrom = Barbies.bmap toArrayIdent arrayPrims
  where
    toArrayIdent (Const cprim) = ArrayIdent $ toArrayIdentifier toOrFrom cprim

toArrayIdents' :: T.Text -> Arrays ArrayIdent
toArrayIdents' prefix = Barbies.bmap toArrayIdent arrayPrims
  where
    toArrayIdent (Const cprim) = ArrayIdent $ toArrayIdentifier' prefix cprim

withPrimitiveArrays :: forall a. (Prim Proxy -> Int -> a) -> Arrays ArrayCount -> [a]
withPrimitiveArrays f = Barbies.bfoldMap g . Barbies.bzip arrayPrims
  where
    g :: Product (Const (Prim Proxy)) ArrayCount b -> [a]
    g (Pair (Const cprim) (ArrayCount n)) = pure (f cprim n)

-- Form the input or output parameter list.
toFunctionParams :: ToOrFromArrays -> ArraysFunType -> [Param]
toFunctionParams toOrFrom afType =
  valueParam : withPrimitiveArrays toBufferParam arrayCounts <> nonFiniteParams
  where
    valueParam =
      Param
        { pType = case afType of
            AfCType ctype -> ParamCxxType (CxxTypeCType ctype)
            AfCUnionCon cunionCon -> ParamCUnionCon cunionCon,
          pId = valueParamIdent,
          pUnused = case afType of -- nullary con needs "__attribute__((unused))"
            AfCType (CTypeStruct (CStruct _ (CNullaryCon _))) -> True
            AfCUnionCon (CUnionCon _ (CNullaryCon _)) -> True
            AfCType (CTypeArray (CNatInt 0) _elemType _) -> True
            _ -> False,
          pMutable = case toOrFrom of
            ToArrays' -> False
            FromArrays' -> True
        }

    arrayCounts = case afType of
      AfCType ctype -> arrayLengthsCType ctype
      AfCUnionCon (CUnionCon _ ccon) -> arrayLengthsCCon ccon
    whenNonFiniteParam = valueParam {pId = whenNonFiniteParamIdent}
    nonFiniteParams =
      if needsNonFiniteParams arrayCounts toOrFrom
        then [whenNonFiniteParam, nonFiniteStatsParam]
        else mempty
    toBufferParam :: Prim Proxy -> Int -> Param
    toBufferParam cprim n =
      Param
        { pType =
            ParamCxxType (CxxTypeCType (CTypeArray (CNatInt n) elemType (replicate n elemType))),
          pId = toArrayIdentifier toOrFrom cprim,
          pUnused = n == 0,
          pMutable = case toOrFrom of
            ToArrays' -> True
            FromArrays' -> False
        }
      where
        elemType = hembed $ CTypePrim cprim

toArraysFunctionName :: ToOrFromArrays -> ArraysFunType -> Identifier
toArraysFunctionName toOrFrom afType = Identifier [fmt|{show toOrFrom}_{fakeTemplateParams}|]
  where
    countsStrings :: [T.Text]
    countsStrings = Barbies.bfoldMap (\(ArrayCount n) -> [T.pack (show n)]) arrayLengths
      where
        arrayLengths = case afType of
          AfCType ctype -> arrayLengthsCType ctype
          AfCUnionCon (CUnionCon _ ccon) -> arrayLengthsCCon ccon
    toTypeName :: ArraysFunType -> T.Text
    toTypeName (AfCType (CTypeArray cnat elemType _)) =
      [fmt|{cnatValue cnat}{R.renderCNat cnat}_{toTypeName (AfCType $ hproject elemType)}|]
    toTypeName (AfCType ctype) = R.renderCType ctype
    toTypeName (AfCUnionCon unionCon) = R.renderCUnionConType unionCon
    typeName = toTypeName afType
    fakeTemplateParams = T.intercalate "_" (typeName : countsStrings)

-- for test generation
toArraysFunctionName' :: ToOrFromArrays -> CType Proxy -> T.Text
toArraysFunctionName' toOrFrom = unIdentifier . toArraysFunctionName toOrFrom . AfCType

primFunctionBody :: ToOrFromArrays -> Prim Proxy -> [TapeElement]
primFunctionBody toOrFrom cprim = runFunWriter $
  case toOrFrom of
    ToArrays' -> arrayIdent ! LiteralInt 0 =: valueParamExpr
    FromArrays' -> case cprim of
      DoubleType -> fpBody "Double"
      FloatType -> fpBody "Float"
      _ -> body
  where
    fpBody = fpPrimFunctionBody cprim toOrFrom valueParamExpr
    -- TODO(MP): Actually do the nan comparison once the appropriate pointer exists!
    arrayIdent = Ident $ toArrayIdentifier toOrFrom cprim
    body = dereference valueParamExpr =: primValue
    primValue = arrayIdent ! LiteralInt 0

enumFunctionBody :: ToOrFromArrays -> CEnum Proxy -> [TapeElement]
enumFunctionBody toOrFrom cenum@CEnum {ceData = value} = runFunWriter $ do
  let cprim = toPrim value
      arrayIdent = Ident $ toArrayIdentifier toOrFrom cprim
  case toOrFrom of
    ToArrays' -> arrayIdent ! LiteralInt 0 =: oldCCast (CTypePrim cprim) valueParamExpr
    FromArrays' ->
      dereference valueParamExpr =: oldCCast (CTypeEnum cenum) (arrayIdent ! LiteralInt 0)

conFunctionBody ::
  ToOrFromArrays ->
  T.Text ->
  CCon Proxy ->
  StateT WrittenArrayFunctions (Either (NonEmpty (T.Text, Arrays Mismatch))) [TapeElement]
conFunctionBody _ typeName (CNullaryCon _) =
  pure
    [ Comment'
        [fmt|\
Nothing to do for nullary constructor {typeName}.|]
    ]
conFunctionBody toOrFrom typeName (CBitfieldCon (CBitfield _ _ bfvalue)) = pure tape
  where
    underlyingType = bfprimToPrim bfvalue
    uintFun = Ident (toArraysFunctionName toOrFrom (AfCType (CTypePrim underlyingType)))
    params = toFunctionParams toOrFrom (AfCType (CTypePrim underlyingType))
    -- In order to properly convert a bitfield into an array we need two separate To_Array
    -- function calls. The first is passed the BitFieldStruct itself. This BitFieldStruct is
    -- converted using an anonymous union into its underlying primitive. Then the To_Array
    -- function for the underlying primitive is called and passed the primitive type.
    -- This is why we call tail on the callParams and replace the first parameter with
    -- the primitive.
    callParams = tail $ fmap (Ident . pId) params
    tape = runFunWriter $ case toOrFrom of
      ToArrays' -> do
        asUint <- unionCast (CTypeBackdoor typeName) (CTypePrim' underlyingType) valueParamExpr
        force_ $ uintFun #! (asUint : callParams)
      FromArrays' -> do
        comment "Initialize to be defensive against undefined behavior."
        asUint <- unsafeNewNamed "as_uint" (CTypePrim' underlyingType) (LiteralInt 0)
        force_ $ uintFun #! (TakeAddress asUint : callParams)
        asStruct <- unionCast (CTypePrim' underlyingType) (CTypeBackdoor typeName) asUint
        dereference valueParamExpr =: asStruct
conFunctionBody toOrFrom typeName ccon@(CNormalCon _ _ fields) = do
  -- convert fields to CExprs
  let toCExpr (fieldName, fieldType') =
        ( fieldExpr,
          fieldType,
          -- Always generate non-finite recovery code.
          StructMember fieldName
        )
        where
          fieldType = hproject fieldType'
          -- TODO(greg): handle this with FunctionWriter internally.
          fieldExpr = maybeAddressOf $ valueParamExpr :-> fieldName
          maybeAddressOf
            | passByValue toOrFrom (AfCType fieldType) = id
            | otherwise = TakeAddress
  -- call each field
  (fieldCalls, totalFieldArrayLengths) <-
    incrementalConvertArrays
      toOrFrom
      (toCExpr <$> F.toList fields)
  -- check for length mismatch
  case checkForMismatches totalFieldArrayLengths (arrayLengthsCCon ccon) of
    Nothing -> pure fieldCalls
    Just mismatches -> lift . Left $ pure (typeName, mismatches)

arrayOfElemFunctionBody ::
  ToOrFromArrays ->
  CNat ->
  CType Proxy ->
  StateT WrittenArrayFunctions (Either (NonEmpty (T.Text, Arrays Mismatch))) [TapeElement]
arrayOfElemFunctionBody toOrFrom cnat elemType = do
  elemArraysFun <- toArraysFunction toOrFrom (AfCType elemType)
  let elemSize :: Arrays ArrayCount
      elemSize = arrayLengthsCType elemType
      params :: CExpr -> [CExpr]
      params k =
        valueParam :
        Barbies.bfoldMap (pure . toArrayExpr) (Barbies.bzip elemSize (toArrayIdents toOrFrom))
          <> nonFiniteParams
        where
          valueParam = maybeAddress (valueParamExpr ! k)
          whenNonFiniteParam = safeNonFiniteAccess . maybeAddress $ whenNonFiniteParamExpr ! k
          nonFiniteParams =
            if needsNonFiniteParams (arrayLengthsCType elemType) toOrFrom
              then [whenNonFiniteParam, nonFiniteStatsParamExpr]
              else mempty
          maybeAddress
            | passByValue toOrFrom (AfCType elemType) = id
            | otherwise = TakeAddress
          -- pass the same pointer through
          toArrayExpr (Pair (ArrayCount 0) (ArrayIdent arrayIdent)) = Ident arrayIdent
          -- &(foo[3*k])
          toArrayExpr (Pair (ArrayCount n) (ArrayIdent arrayIdent)) =
            TakeAddress $ Ident arrayIdent ! index
            where
              index = LiteralInt (fromIntegral n) :* k

  pure $
    if cnat == CNatInt 0
      then mempty
      else runFunWriter . loopWithType (CTypePrim' (PrimInt32 Proxy)) (natExpr cnat) $
        \k -> force_ $ elemArraysFun #! params k

unionFunctionBody ::
  ToOrFromArrays ->
  CUnion Proxy ->
  StateT WrittenArrayFunctions (Either (NonEmpty (T.Text, Arrays Mismatch))) [TapeElement]
unionFunctionBody toOrFrom cunion@CUnion {cuCons = cons} = do
  let toCUnionConFun ccon =
        (ccon,)
          <$> toArraysFunction toOrFrom (AfCUnionCon (CUnionCon cunion ccon))
  conFuns <- traverse toCUnionConFun cons
  let consWithFloat :: [CCon Proxy]
      consWithFloat =
        foldMap
          ( \(con, _) ->
              if needsNonFiniteParams (arrayLengthsCCon con) toOrFrom
                then pure con
                else mempty
          )
          conFuns
  let conFunMap :: M.Map (CCon Proxy) CFunction
      conFunMap = M.fromListWith (error "got duplicate ccons") (V.toList conFuns)
      arrayIdents :: Arrays ArrayIdent
      arrayIdents = toArrayIdents toOrFrom
      -- the tag increments one, the others start at 0
      arrayExprs :: [CExpr]
      arrayExprs = Barbies.bfoldMap (pure . toArrayExpr) (Barbies.bzip arrayPrims arrayIdents)
        where
          toArrayExpr :: Product (Const (Prim Proxy)) ArrayIdent a -> CExpr
          toArrayExpr (Pair (Const cprim) (ArrayIdent arrayIdent))
            | cprim == toPrim (cuTag cunion) = TakeAddress (Ident arrayIdent ! LiteralInt 1)
            | otherwise = TakeAddress (Ident arrayIdent ! LiteralInt 0)
      switchFun :: CCon Proxy -> CExpr -> [TapeElement]
      switchFun ccon cconExpr = case M.lookup ccon conFunMap of
        Nothing -> error $ "missing CCon " <> show ccon
        Just conFun ->
          let arrayCounts = arrayLengthsCCon ccon
              nonFiniteParams =
                if needsNonFiniteParams arrayCounts toOrFrom
                  then
                    [ safeNonFiniteAccess
                        . maybeAddressOf
                        $ AsUnionCon whenNonFiniteParamExpr ccon,
                      nonFiniteStatsParamExpr
                    ]
                  else mempty
           in [ FunctionCall
                  conFun
                  (maybeAddressOf cconExpr : arrayExprs <> nonFiniteParams)
                  Nothing
              ]
        where
          maybeAddressOf
            | passByValue toOrFrom (AfCUnionCon (CUnionCon cunion ccon)) = id
            | otherwise = TakeAddress
  pure $
    if length consWithFloat < 2
      then [CUnionConSwitch (Ident (Identifier valueParamName)) cunion switchFun]
      else
        error
          [fmt|Multiple union constructors with floating-point elements not supported!
The following {show $ length consWithFloat} constructors conflict:

    {show consWithFloat}

There is no support for code-generating a corresponding product of fallback values for such a
sum type, which might contain non-finite values in more than one branch.  Please see
#54 for more details.
|]

-- | Used in "Kitty.Codegen.Cxx.WrapKGenCFunction".
withArrayCounts :: forall a. (Prim Proxy -> Int -> a) -> Arrays ArrayCount -> [a]
withArrayCounts f = Barbies.bfoldMap g . Barbies.bzip arrayPrims
  where
    g :: Product (Const (Prim Proxy)) ArrayCount b -> [a]
    g (Pair (Const cprim) (ArrayCount n)) = pure (f cprim n)

mapAccumM :: (Monad m, Traversable t) => (a -> b -> m (c, a)) -> a -> t b -> m (t c, a)
mapAccumM f = flip (runStateT . traverse (StateT . flip f))

incrementalConvertArrays ::
  ToOrFromArrays ->
  [(CExpr, CType Proxy, NonFiniteField)] ->
  StateT
    WrittenArrayFunctions
    (Either (NonEmpty (T.Text, Arrays Mismatch)))
    ([TapeElement], Arrays ArrayCount)
incrementalConvertArrays toOrFrom =
  incrementalConvertArrays' (toArrayIdentPrefix toOrFrom) toOrFrom

incrementalConvertArrays' ::
  T.Text ->
  ToOrFromArrays ->
  [(CExpr, CType Proxy, NonFiniteField)] ->
  StateT
    WrittenArrayFunctions
    (Either (NonEmpty (T.Text, Arrays Mismatch)))
    ([TapeElement], Arrays ArrayCount)
incrementalConvertArrays' prefix toOrFrom fields = do
  let arrayIdents :: Arrays ArrayIdent
      arrayIdents = toArrayIdents' prefix
      toCallParams :: Maybe (CExpr, CExpr) -> CExpr -> Arrays ArrayCount -> [CExpr]
      toCallParams mbNonFiniteParams fieldExpr arrayIndices =
        fieldExpr :
        Barbies.bfoldMap (pure . toArrayCExpr) (Barbies.bzip arrayIndices arrayIdents)
          <> maybe mempty (\(nfe, stats) -> [nfe, stats]) mbNonFiniteParams
        where
          toArrayCExpr :: Product ArrayCount ArrayIdent a -> CExpr
          toArrayCExpr (Pair (ArrayCount k) (ArrayIdent arrayIdent)) =
            TakeAddress (Ident arrayIdent ! LiteralInt (fromIntegral k))
      toFieldCall ::
        Arrays ArrayCount ->
        (CExpr, CType Proxy, NonFiniteField) ->
        StateT
          WrittenArrayFunctions
          (Either (NonEmpty (T.Text, Arrays Mismatch)))
          (TapeElement, Arrays ArrayCount)
      toFieldCall arrayIndices (fieldExpr, fieldType, fieldName) = do
        fieldFun <- toArraysFunction toOrFrom (AfCType fieldType)
        let params :: [CExpr]
            params = toCallParams nonFiniteParams fieldExpr arrayIndices
            lengths = arrayLengthsCType fieldType
            nonFiniteParams = makeNonFiniteParams toOrFrom lengths fieldName fieldType
        pure
          ( FunctionCall
              fieldFun
              params
              Nothing,
            arrayIndices <> lengths
          )
  mapAccumM toFieldCall mempty fields
