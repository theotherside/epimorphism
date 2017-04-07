module Parser where

import Prelude
import Config (SystemST)
import Data.Array (length)
import Data.Array (sort, length, (..)) as A
import Data.Foldable (foldl)
import Data.Library (Library, getLib, mD)
import Data.Maybe (Maybe(Nothing, Just))
import Data.StrMap (lookup, StrMap, fold, empty, keys, size, foldM, insert)
import Data.String (joinWith)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..), snd)
import Data.Types (Epi, EpiS, ModuleD)
import System (loadLib)
import Util (dbg, forceInt, indentLines, replaceAll)

type Shaders = {vert :: String, main :: String, disp :: String, aux :: Array String}
type CompRes = {component :: String, zOfs :: Int, parOfs :: Int, images :: Array String}

foreign import parseT :: String -> String

parseShader :: forall eff h. SystemST h -> Library h -> String -> Array String -> EpiS eff h (Tuple String (Array String))
parseShader systemST lib mid includes = do
  modD <- mD <$> getLib lib mid "parseShader mid"
  modRes <- parseModule modD systemST lib 0 0 []

  let modRes' = spliceUniformSizes modRes
  allIncludes' <- traverse (\x -> loadLib x systemST.componentLib "includes") includes
  let allIncludes = "//INCLUDES\n" <> (joinWith "\n\n" (map (\x -> x.body) allIncludes')) <> "\n//END INCLUDES\n"

  pure $ Tuple (allIncludes <> modRes'.component) (modRes'.images)

spliceUniformSizes :: CompRes -> CompRes
spliceUniformSizes cmp@{ component, zOfs, parOfs, images } =
  cmp{component = component'''}
  where
    component'   = replaceAll "#par#" (show $ parOfs + 1) component
    component''  = replaceAll "#zn#" (show $ zOfs + 1) component'
    component''' = replaceAll "#aux#" (show $ length images + 1) component''

-- parse a shader.  substitutions, submodules, par & zn
parseModule :: forall eff h. ModuleD -> SystemST h -> Library h -> Int -> Int -> (Array String) -> EpiS eff h CompRes
parseModule mod systemST lib zOfs parOfs images = do
  -- substitutions (make sure this is always first)
  comp <- loadLib mod.component systemST.componentLib "parse component"
  sub' <- preProcessSub mod.sub
  let component' = fold handleSub comp.body sub'

  -- pars
  let k = (A.sort $ keys mod.par)
  let component'' = snd $ foldl handlePar (Tuple parOfs component') k
  let parOfs' = parOfs + (forceInt $ size mod.par)

  -- zn
  let component''' = foldl handleZn component'' (A.(..) 0 ((A.length mod.zn) - 1))
  let zOfs' = zOfs + A.length mod.zn

  -- images
  let component'''' = foldl handleImg component''' (A.(..) 0 ((A.length mod.images) - 1))
  let images' = images <> mod.images

  -- submodules
  mod' <- loadModules mod.modules lib
  foldM (handleChild systemST) { component: component'''', zOfs: zOfs', parOfs: parOfs', images: images' } mod'
  where
    handleSub dt k v = replaceAll ("\\$" <> k <> "\\$") v dt
    handlePar (Tuple n dt) v = Tuple (n + 1) (replaceAll ("@" <> v <> "@") ("par[" <> show n <> "]") dt)
    handleZn dt v = replaceAll ("zn\\[#" <> show v <> "\\]") ("zn[" <> (show $ (v + zOfs)) <> "]") dt
    handleImg dt v = replaceAll ("aux\\[#" <> show v <> "\\]") ("aux[" <> (show $ (v + (A.length images))) <> "]") dt
    handleChild :: SystemST h -> CompRes -> String -> ModuleD -> EpiS eff h CompRes
    handleChild systemST' {component, zOfs: zOfs', parOfs: parOfs', images: images'} k v = do
      res <- parseModule v systemST' lib zOfs' parOfs' images'
      let iC = "//" <> k <> "\n  {\n" <> (indentLines 2 res.component) <> "\n  }"
      let child = replaceAll ("%" <> k <> "%") iC component
      pure $ res { component = child }

-- preprocess substitutions.  just parses t expressions
preProcessSub :: forall eff. StrMap String -> Epi eff (StrMap String)
preProcessSub sub = do
  case (lookup "t_expr" sub) of
    (Just expr) -> do
      expr' <- parseTexp expr
      let sub' = insert "t_expr" expr' sub
      pure sub'
    Nothing -> do
      pure sub

parseTexp :: forall eff. String -> Epi eff String
parseTexp expr = do
  let expr1 = parseT expr
  let subs = [["\\+","A"],["\\-","S"],["\\~","CONJ"],["\\+","A"],["\\-","S"],["\\*","M"],["/","D"],["sinh","SINHZ"],
              ["cosh","COSHZ"],["tanh","TANHZ"],["sin","SINZ"],["cos","COSZ"],["tan","TANZ"],["exp","EXPZ"],["sq","SQZ"]]

  pure $ foldl f expr1 subs
  where
    f exp [a, b] = replaceAll a b exp
    f exp _ = exp


-- Bulk load a list of modules
loadModules :: forall eff h. StrMap String -> Library h -> EpiS eff h (StrMap ModuleD)
loadModules mr lib = do
  foldM handle empty mr
  where
    handle :: (StrMap ModuleD) -> String -> String -> EpiS eff h (StrMap ModuleD)
    handle dt k v = do
      modD <- mD <$> getLib lib v "parse loadModules"
      pure $ insert k modD dt
