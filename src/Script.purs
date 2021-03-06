module Script where

import Prelude
import Control.Monad.Except.Trans (throwError)
import Control.Monad.ST (readSTRef, STRef)
import Control.Monad.Trans.Class (lift)
import Data.Array (foldM, elemIndex, updateAt)
import Data.Library (dat, getLib, getPatternD, mD, modLibD)
import Data.Maybe (Maybe(Just))
import Data.Set (union)
import Data.String (joinWith)
import Data.Types (EpiS, Module(..), Library, PMut(PMut, PMutNone), Script(Script), ScriptRes(ScriptRes), SystemST, ScriptFn)
import ScriptUtil (parseScript, serializeScript)
import Scripts (null, randomize, pause, incZn)
import Switch (finishSwitch, switch)
import System (mFold)
import Util (fromJustE, inj, log)

-- find script fuction given name
lookupScriptFN :: forall eff h. String -> EpiS eff h (ScriptFn eff h)
lookupScriptFN n = case n of
  "null"         -> pure null
  "switch"       -> pure switch
  "incZn"        -> pure incZn
  "finishSwitch" -> pure finishSwitch
  "pause"        -> pure pause
  "randomize"    -> pure randomize
  _              -> throwError $ "script function not found: " <> n


-- execute all scripts & script pool. abort as soon as something mutates the pattern
runScripts :: forall eff h. STRef h (SystemST h) -> Library h -> EpiS eff h PMut
runScripts ssRef lib = do
  patternD <- getPatternD lib "runScripts pattern"
  r0 <- mFold lib PMutNone patternD.main (runModScripts ssRef lib)
  r1 <- mFold lib r0 patternD.seed (runModScripts ssRef lib)
  r2 <- mFold lib r1 patternD.disp (runModScripts ssRef lib)
  mFold lib r2 patternD.vert (runModScripts ssRef lib)


runModScripts :: forall eff h. STRef h (SystemST h) -> Library h -> PMut -> String -> EpiS eff h PMut
runModScripts ssRef lib mut mid = do
  modD <- mD <$> getLib lib mid "mid runScripts"

  --lift $ log $ inj "Running scripts [%0]" [joinWith ", " modD.scripts]
  foldM (runScript ssRef lib mid) mut modD.scripts


runScript :: forall eff h. STRef h (SystemST h) -> Library h -> String -> PMut -> String -> EpiS eff h PMut
runScript ssRef lib mid pmut scr = do
  --lift $ log $ "Running Script : " <> scr <> " : for " <> mid
  --lift $ log x
  (Script name phase args) <- parseScript scr
  systemST <- lift $ readSTRef ssRef
  fn <- lookupScriptFN name
  let t' = systemST.t - phase

  mod@(Module _ modD) <- getLib lib mid "mid! runScript"
  --lift $ log mod
  idx <- fromJustE (elemIndex scr modD.scripts) "script not found m"
  --lift $ log $ inj "idx %0 in [%1]" [(show idx), (joinWith ", " modD.scripts)]

  (ScriptRes mut update) <- fn ssRef lib t' mid scr args -- run script
  case update of
    Just dt -> do
      let new = serializeScript (Script name phase dt)
      modD'     <- mD <$> getLib lib mid "mid' runScript"
      idx'      <- fromJustE (elemIndex scr modD'.scripts) "script not found m'"
      scripts'  <- fromJustE (updateAt idx' new modD'.scripts) "should be safe runScript"

      modLibD lib mod _ {scripts = scripts'}
    _ -> pure unit

  case pmut of
    PMutNone -> pure mut
    PMut pat res -> do
      case mut of
        PMutNone -> pure pmut
        PMut mutP mutS -> pure $ PMut pat (union res mutS)

--runScript _ _ _ x _ = pure x
