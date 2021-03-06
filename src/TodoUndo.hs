{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RecursiveDo     #-}

-- same as TodoUndo but uses an adjustable list internally
module TodoUndo (
  Todo(..)
  , TodoUndoConfig(..)
  , TodoUndo(..)
  , todoUndoConnect
  , holdTodo
) where

import           Relude

import           Reflex
import           Reflex.Data.ActionStack
import           Reflex.Data.Sequence
import Reflex.Data.Stack
import           Reflex.Potato.Helpers

import           Control.Monad.Fix
import Control.Exception (assert)

import qualified Data.Sequence as Seq
import Data.Foldable (foldrM)
import qualified Text.Show
import qualified Data.Text
import           Data.Dependent.Sum              ((==>))
import           Data.Functor.Misc
import Data.These

-- helper methods
foldrWithIndexM :: forall a b m. (Monad m) =>  (Int -> a -> b -> m b) -> b -> Seq a -> m b
foldrWithIndexM f z xs = do
  -- internal fold function has type 'a -> (Int -> m b) -> m (Int -> m b)'
  r <- foldrM ((\x g -> return (\ !i -> g (i+1) >>= f i x))) (const (return z)) xs
  r 0


-- | reindexes indices such that each element is indexed as if all previous elements have been removed, O(n^2) lol
reindexForRemoval :: [(Int, a)] -> [(Int, a)]
reindexForRemoval [] = []
reindexForRemoval (r:xs) = r:reindexForRemoval rest where
  -- if this asserts that means you tried to remove the same index twice
  rest = map (\(x, a) -> assert (x /= fst r) $ if x > fst r then (x-1,a) else (x,a)) xs

-- TODO make sure this is correct lol
reindexForAddition :: [(Int, a)] -> [(Int, a)]
reindexForAddition = reverse . reindexForRemoval . reverse


data Todo = Todo {
  description :: Text
  , isDone    :: Bool
}

instance Show Todo where
  show (Todo d s) = Data.Text.unpack $ (if s then "t" else "f") <> d

-- each DynTodo element in the network has a dynamic var representing its state
-- note that it's possible to do a simpler first-order implementation where states are tracked in a separate dynamic
-- but for the purpose of this example, we want to do it using higher order frp
data DynTodo t = DynTodo {
  dtId     :: Int
  , dtDesc     :: Dynamic t Text
  , dtIsDone :: Dynamic t Bool
}
instance Show (DynTodo t) where
  show = show . dtId

data TodoUndoConfig t = TodoUndoConfig {
  -- input
  _trconfig_new              :: Event t Text
  , _trconfig_clearCompleted :: Event t ()
  , _trconfig_undo           :: Event t ()
  , _trconfig_redo           :: Event t ()
  , _trconfig_tick           :: Event t Int -- ^ ticking toggles a todo item as done or not done
  , _trconfig_remove         :: Event t Int
  , _trconfig_modify :: Event t (Int, Text)
}

data TodoUndo t = TodoUndo {
  _tr_todos :: Dynamic t [Todo]
}

-- TODO actually use these or delete
data TodoUndoConnector t = TodoUndoConnector {
  _trconnector_todo_connector_tick :: Dynamic t [Todo] -> (Event t Int, Event t Int)
}

todoUndoConnect :: TodoUndoConnector t -> TodoUndo t -> TodoUndoConfig t -> TodoUndoConfig t
todoUndoConnect (TodoUndoConnector cx) (TodoUndo todos) trc = trc {
    _trconfig_tick = fst . cx $ todos
  }

type UID = Int

data ItemCmd = ICTick | ICModify (Text, Text)

data TRCmd t =
  TRCNew (DynTodo t)
  | TRCClearCompleted
  | TRCDelete (Int, DynTodo t)
  | TRCTick Int
  | TRCModify (Int, Text, Text)

holdTodo ::
  forall t m. (Reflex t, MonadHold t m, MonadFix m, Adjustable t m)
  => TodoUndoConfig t
  -> m (TodoUndo t)
holdTodo TodoUndoConfig {..} = mdo

  let
    pushPrevDesc (i, after) = do
      todos <- sample . current $ _dynamicSeq_contents todosDyn
      -- index must be valid, will crash if it's invalid
      before <- sample . current . dtDesc $ Seq.index todos i
      if before == after  then
        return Nothing
      else
        return $ Just $ TRCModify (i, before, after)

    docmds = leftmostwarn "WARNING: received multiple commands at once" [
      -- construct element to put on
      fmap TRCNew $ pushAlways makeDynTodo _trconfig_new
      , fmap (const TRCClearCompleted) _trconfig_clearCompleted
      , fmap TRCTick _trconfig_tick
      , fmap TRCDelete $ pushAlways findDynTodo _trconfig_remove
      , push pushPrevDesc _trconfig_modify
      ]

    asc = ActionStackConfig {
        _actionStackConfig_do = docmds
        , _actionStackConfig_undo = _trconfig_undo
        , _actionStackConfig_redo = _trconfig_redo
        , _actionStackConfig_clear = never
      }

  as <- holdActionStack asc

  let
    doAction :: Event t (TRCmd t)
    doAction = _actionStack_do as
    undoAction :: Event t (TRCmd t)
    undoAction = _actionStack_undo as

    -- the only time we add a new element
    newEvSelect = \case
      TRCNew x -> Just x
      _ -> Nothing
    addNewEv = fmapMaybe newEvSelect doAction

    -- DynamicSeq event selectors
    -- --------------------------
    insert_do_push = \case
      TRCNew x -> do
        -- add to end
        s <- sample . current $ _dynamicSeq_contents todosDyn
        return $ Just (Seq.length s, Seq.singleton x)
      _ -> return Nothing
    insert_do_ev = push insert_do_push doAction

    insert_undo_push = \case
      -- put back element we just removed
      TRCDelete (n,x) -> return $ Just (n, Seq.singleton x)
      _ -> return Nothing
    insert_undo_ev = push insert_undo_push undoAction

    -- remove an element, note the snd tuple arg is needed for Undo so we ignore it
    remove_do_push = \case
      TRCDelete (n, _) -> return $ Just (n, 1)
      _ -> return Nothing
    remove_do_ev = push remove_do_push doAction

    remove_undo_push = \case
      TRCNew _ -> do
        -- remove from end
        s <- sample . current $ _dynamicSeq_contents todosDyn
        return $ Just (Seq.length s - 1, 1)
      _ -> return Nothing
    remove_undo_ev = push remove_undo_push undoAction

    -- DynamicSeq repeated event selectors
    -- --------------------------
    select_TRCClearCompleted = \case
      TRCClearCompleted -> Just ()
      _ -> Nothing
    clear_do_ev' = fmapMaybe select_TRCClearCompleted doAction
    clear_undo_ev' = fmapMaybe select_TRCClearCompleted undoAction
    clear_do_push _ = do
      s <- sample . current $ _dynamicSeq_contents todosDyn
      let
        foldfn :: Int -> DynTodo t -> [(Int, DynTodo t)] -> PushM t [(Int, DynTodo t)]
        foldfn i dyntodo xs = do
          done <- sample . current $ dtIsDone dyntodo
          if done
            then return $ (i,dyntodo):xs
            else return $ xs
      foldrWithIndexM foldfn [] s
    clear_do_ev :: Event t [(Int, DynTodo t)]
    clear_do_ev = pushAlways clear_do_push clear_do_ev'
    clear_undo_ev :: Event t ()
    clear_undo_ev = clear_undo_ev'

    -- DynTodo event selectors
    -- --------------------------
    -- maps tick/untick list index to Todo identifier
    -- we just toggle on do/undo so we don't need to distinguish between do and undo
    itemPushSelect :: TRCmd t -> PushM t (Maybe (UID, ItemCmd))
    itemPushSelect = let
        toggleFn index cmd = do
          tds <- sample . current $ _dynamicSeq_contents todosDyn
          return . Just $ (dtId $ Seq.index tds index, maybe ICTick id cmd)
      in
        \case
          TRCTick index -> toggleFn index Nothing
          TRCModify (index, before, after) -> toggleFn index (Just $ ICModify (before,after))
          _ -> return Nothing where


    makeDynTodo :: Text -> PushM t (DynTodo t)
    makeDynTodo s = do
      let
        modifySelect = \case
          ICModify x -> Just x
          _ -> Nothing
        tickSelect = \case
          ICTick -> Just ()
          _ -> Nothing
        textfoldfn (This (_, after)) _ = after
        textfoldfn (That (before,_)) _ = before
        textfoldfn _ _ = error "do and undo at the same time"
      !uid <- sample . current $ uidDyn
      let
        itemDoCmd = fmap dsum_to_dmap $ fmap (\(uid', cmd) -> Const2 uid' ==> cmd) $ push itemPushSelect doAction
        itemUndoCmd = fmap dsum_to_dmap $ fmap (\(uid', cmd) -> Const2 uid' ==> cmd) $ push itemPushSelect undoAction
        selectedItemDoCmd :: Event t (ItemCmd) = select (fan itemDoCmd) (Const2 uid)
        selectedItemUndoCmd :: Event t (ItemCmd) = select (fan itemUndoCmd) (Const2 uid)
      doneState <- toggle False $ leftmost $ fmap (fmapMaybe tickSelect) [selectedItemDoCmd, selectedItemUndoCmd]
      textState <- foldDyn textfoldfn s (alignEventWithMaybe Just (fmapMaybe modifySelect selectedItemDoCmd) (fmapMaybe modifySelect selectedItemUndoCmd))


      return DynTodo {
          dtId = uid
          , dtDesc = textState
          , dtIsDone = doneState
        }

    -- should be OK as this is similar to `attach` and not `attachPromptly`
    findDynTodo :: Int -> PushM t (Int, DynTodo t)
    findDynTodo index = do
      tds <- sample . current . _dynamicSeq_contents $ todosDyn
      return $ (index, Seq.index tds index)


  -- create id assigner
  -- --------------------------
  -- TODO switch this to use DirectoryIdAssigner
  uidDyn :: Dynamic t UID <-
    foldDyn (+) 0 (fmap (const 1) addNewEv)

  -- create clear completed stack
  -- ----------------------
  let
    clearedStackConfig = DynamicStackConfig {
        _dynamicStackConfig_push = clear_do_ev
      , _dynamicStackConfig_pop = clear_undo_ev
      , _dynamicStackConfig_clear = never
    }
  clearedStack :: DynamicStack t [(Int, DynTodo t)]
    <- holdDynamicStack [] clearedStackConfig
  remove_many_ev' :: Event t (Int, DynTodo t) <- repeatEvent $ fmap reindexForRemoval $ _dynamicStack_pushed clearedStack
  add_many_ev' :: Event t (Int, DynTodo t) <- repeatEvent $ fmap reindexForAddition $ _dynamicStack_popped clearedStack
  let
    remove_many_ev :: Event t (Int, Int)
    remove_many_ev = fmap (\(i,_) -> (i,1)) remove_many_ev'
    add_many_ev :: Event t (Int, Seq (DynTodo t))
    add_many_ev = fmap (\(i,e) -> (i,Seq.singleton e)) add_many_ev'


  -- create DynamicSeq
  -- ----------------------
  let
    dsc = DynamicSeqConfig {
        _dynamicSeqConfig_insert   = leftmost [insert_do_ev, insert_undo_ev, add_many_ev]
        , _dynamicSeqConfig_remove = leftmost [remove_do_ev, remove_undo_ev, remove_many_ev]
        , _dynamicSeqConfig_clear  = never
      }

  todosDyn :: DynamicSeq t (DynTodo t)
    <- holdDynamicSeq Seq.empty dsc

  -- assemble the final behavior
  ------------------------------
  let
    contents :: Dynamic t [DynTodo t]
    contents = toList <$> _dynamicSeq_contents todosDyn
    descriptions :: Dynamic t [Text]
    descriptions = join . fmap sequence $ dtDesc  <<$>> contents

    doneStates :: Dynamic t [Bool]
    doneStates = join . fmap sequence $ dtIsDone <<$>> contents

  return $ TodoUndo $ ffor2 descriptions doneStates (zipWith Todo)
