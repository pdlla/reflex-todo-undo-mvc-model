{-# LANGUAGE RecordWildCards #-}


import           Relude

import           GHC.Stats

import           Reflex
import           Reflex.Test.Host

import           Data.These

import           Control.Concurrent

import           TodoUndo

main :: IO ()
main = memtest


data AppCmd = New Text | Clear | Undo | Redo | Tick Int | Remove Int | Modify (Int, Text) deriving (Show)

todoundo_network ::  forall t m. (t ~ SpiderTimeline Global, m ~ SpiderHost Global)
  => (AppIn t () AppCmd -> PerformEventT t m (AppOut t () [Todo]))
todoundo_network AppIn {..} = do
  let
    ev = _appIn_event
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
        , _trconfig_remove          = flip fmapMaybe ev $ \case
          Remove n -> Just n
          _ -> Nothing
        , _trconfig_modify = flip fmapMaybe ev $ \case
          Modify s -> Just s
          _ -> Nothing
      }
  todos <- holdTodo trc
  return
    AppOut {
      _appOut_behavior = constant ()
      , _appOut_event = updated (_tr_todos todos)
    }

{-
basic_network :: forall t m.
  (t ~ SpiderTimeline Global, m ~ SpiderHost Global)
  => (AppIn t Int Int -> PerformEventT t m (AppOut t Int Int))
basic_network AppIn {..} = return
  AppOut {
    _appOut_behavior = fmap (*(-1)) _appIn_behavior
    , _appOut_event = fmap (\(b,e) -> e+b) $ attach _appIn_behavior _appIn_event
  }-}

toImportant :: RTSStats -> ImportantStats
toImportant RTSStats {..} = ImportantStats {
    _gcs = gcs
    , _max_live_bytes = max_live_bytes
    , _max_mem_in_use_bytes = max_mem_in_use_bytes
    , _gcdetails_allocated_bytes = gcdetails_allocated_bytes gc
    , _gcdetails_live_bytes = gcdetails_live_bytes gc
  }

data ImportantStats = ImportantStats {
  _gcs                         :: Word32
  , _max_live_bytes            :: Word64
  , _max_mem_in_use_bytes      :: Word64
  , _gcdetails_allocated_bytes :: Word64
  , _gcdetails_live_bytes      :: Word64
} deriving (Show)

memtest :: IO ()
memtest = runSpiderHost $ do
  --appFrame <- getAppFrame basic_network (1 :: Int)
  appFrame <- getAppFrame todoundo_network ()
  let
    loop n = do
      --out <- tickAppFrame appFrame (Just (That 1))
      out <- tickAppFrame appFrame $ case n `mod` 4 of
        0 -> Just (That (New "todo"))
        1 -> Just (That (Clear))
        2 -> Just (That (Undo))
        3 -> Just (That (Undo))
        _ -> error "never happnens"
      liftIO $ do
        putStrLn $ "ticked: " <> show out
        threadDelay 10000
        hasStats <- getRTSStatsEnabled
        when (not hasStats) $ error "no stats"
        stats <- getRTSStats
        print (toImportant stats)
      loop (n+1)
  loop 0
