{-# LANGUAGE RecursiveDo #-}
module TodoUndoSpec (
  spec
) where

import           Relude

import           Test.Hspec
import           Test.Hspec.Contrib.HUnit  (fromHUnitTest)
import           Test.HUnit

import           Reflex
import           Reflex.Host.Basic
import           Reflex.Potato.TestHarness


import qualified Data.List                 as L
import           Data.Maybe                (fromJust)
import           TodoUndo


-- N.B. Clear is not implemented yet
data AppCmd = New Text | Clear | Undo | Redo | Tick Int | Untick Int | Remove Int deriving (Show)


todoredo_network :: forall t m. BasicGuestConstraints t m => Event t AppCmd -> BasicGuest t m (Event t [Todo])
todoredo_network ev = do
  let
    trc = TodoUndoConfig {
        _trconfig_new = flip fmapMaybe ev $ \case
          New s -> Just s
          _ -> Nothing
        , _trconfig_clearCompleted = flip fmapMaybe ev $ \case
          Clear -> Just ()
          _ -> Nothing
        , _trconfig_undo            = flip fmapMaybe ev $ \case
          Undo -> Just ()
          _ -> Nothing
        , _trconfig_redo            = flip fmapMaybe ev $ \case
          Redo -> Just ()
          _ -> Nothing
        , _trconfig_tick            = flip fmapMaybe ev $ \case
          Tick n -> Just n
          _ -> Nothing
        , _trconfig_untick          = flip fmapMaybe ev $ \case
          Untick n -> Just n
          _ -> Nothing
        , _trconfig_remove          = flip fmapMaybe ev $ \case
          Remove n -> Just n
          _ -> Nothing
      }
  todos <- holdTodo trc
  return $ updated (_tr_todos todos)

basic_test :: Test
basic_test = TestLabel "basic" $ TestCase $ do
  return ()
  let
    bs = [
      New "1",
      New "2",
      New "3", -- [f1,f2,f3]
      Undo, Undo, Redo, -- [f1,f2]
      Tick 0, -- [t1,f2]
      New "4", New "5", -- [t1,f2,f4,f5]
      Tick 3, -- [t1,f2,f4,t5]
      Clear, Undo, Redo, -- [f2,f4]
      New "6"] -- [f2,f4,f6]
    run :: IO [[Maybe [Todo]]]
    run = basicHostWithStaticEvents bs todoredo_network
  v <- liftIO run
  mapM_ (print . fmap fromJust) (v)
  return ()
  --L.last v @?= Just 103

spec :: Spec
spec = do
  describe "Todo Redo" $ do
    fromHUnitTest basic_test