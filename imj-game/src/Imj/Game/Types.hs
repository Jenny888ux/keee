{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilyDependencies #-}
{-# LANGUAGE AllowAmbiguousTypes #-}

module Imj.Game.Types
      (
      -- * Client / GameLogic
        Client(..)
      , GameLogic(..)
      , EventsForClient(..)
      , Game(..)
      , AnimatedLine(..)
      , GenEvent(..)
      , UpdateEvent
      , CustomUpdateEvent
      , EventGroup(..)
      -- * AppState type
      , AppState(..)
      , GameState(..)
      , RecordMode(..)
      , OccurencesHist(..)
      , Occurences(..)
      , EventCategory(..)
      -- * Player
      , Player(..)
      , mkPlayer
      , PlayerColors(..)
      , mkPlayerColors
      , ColorTheme(..)
      -- * Helper types
      , Transitioning(..)
      , GameArgs(..)
      , Infos(..)
      , mkEmptyInfos
      -- * EventGroup
      , isPrincipal
      , mkEmptyGroup
      , visible
      , count
      , tryGrow
      -- * Access
      , getGameState
      , getIGame
      , getPlayers
      , getPlayer
      , getChatMode
      , getMyId
      , getGameConnection
      , getChat
      , getServerContent
      , getCurScreen
      , getLastRenderTime
      , hasVisibleNonRenderedUpdates
      -- * Modify
      , putGame
      , putAnimation
      , putCurScreen
      , putGameState
      , putIGame
      , putPlayer
      , putPlayers
      , putGameConnection
      , putServerContent
      , putDrawnState
      , stateChat
      , takeKeys
      -- * reexports
      , MonadState
      , TQueue
      , gets
      ) where

import           Imj.Prelude
import           Prelude(length)

import           Control.Concurrent.STM(TQueue)
import           Control.Monad.State.Class(MonadState)
import           Control.Monad.IO.Class(MonadIO)
import           Control.Monad.Reader.Class(MonadReader)
import           Control.Monad.State.Strict(gets, state, modify')
import           Data.Attoparsec.Text(Parser)
import qualified Data.Map.Strict as Map
import           Data.Map.Strict((!?),Map)
import           Data.Proxy(Proxy(..))
import           Data.Text(unpack)

import           Imj.Categorized
import           Imj.ClientView.Types
import           Imj.Control.Concurrent.AsyncGroups.Class
import           Imj.Event
import           Imj.Game.Audio.Class
import           Imj.Game.Configuration
import           Imj.Game.ColorTheme.Class
import           Imj.Game.Infos
import           Imj.Game.Player
import           Imj.Game.Priorities
import           Imj.Game.Status
import           Imj.Graphics.Class.DiscreteDistance
import           Imj.Graphics.Class.Draw
import           Imj.Graphics.Class.HasSizedFace
import           Imj.Graphics.Class.Render
import           Imj.Graphics.Color.Types
import           Imj.Graphics.Interpolation.Evolution
import           Imj.Graphics.ParticleSystem
import           Imj.Graphics.Render.Delta.Backend.OpenGL(PreferredScreenSize(..))
import           Imj.Graphics.RecordDraw
import           Imj.Graphics.Screen
import           Imj.Graphics.UI.Animation
import           Imj.Graphics.UI.RectContainer
import           Imj.Input.Types
import           Imj.Network
import           Imj.Server.Class
import           Imj.Server.Color
import           Imj.Server.Types
import           Imj.ServerView.Types

import           Imj.Graphics.UI.Chat
import           Imj.Game.Timing
import           Imj.Graphics.Text.ColoredGlyphList
import           Imj.Graphics.Text.ColorString

class GameLogic (GameLogicT c)
  => Client c
 where
  type GameLogicT c

  -- | Send a 'ClientEvent' to the server.
  sendToServer' :: (MonadIO m)
                => c
                -> ClientEvent (ServerT (GameLogicT c))
                -> m ()

  -- | The queue containing events that should be handled by the client.
  serverQueue :: c -> TQueue (EventsForClient (GameLogicT c))

  -- | Fill 'serverQueue'
  writeToClient' :: (MonadIO m)
                 => c -> EventsForClient (GameLogicT c) -> m ()

data EventsForClient g =
    FromClient !(Event (ClientOnlyEvtT g))
  | FromServer !(ServerEvent (ServerT g))
  deriving(Generic)
instance (GameLogic g) => Show (EventsForClient g) where
  show (FromClient e) = show ("FromClient", e)
  show (FromServer e) = show ("FromServer", e)

data GenEvent g =
    Evt {-unpack sum-} !(Event (ClientOnlyEvtT g))
    -- ^ Generated by the client, handled by the client immediately after creation.
  | CliEvt {-unpack sum-} !(ClientEvent (ServerT g))
    -- ^ Generated by the client, sent to the 'ServerT', which in turn may send back some 'ServerEvent'.
  | SrvEvt {-unpack sum-} !(ServerEvent (ServerT g))
    -- ^ Generated by either 'ServerT' or the client, handled by the client immediately upon reception.
    deriving(Generic)
instance GameLogic g => Show (GenEvent g) where
  show (Evt e) = show("Evt",e)
  show (CliEvt e) = show("CliEvt",e)
  show (SrvEvt e) = show("SrvEvt",e)

-- | Specifies which world we want information about (the one that is already displayed
-- is 'From', the new one is 'To'.)
data Transitioning = From | To

-- | 'GameLogic' Formalizes the client-side logic of a multiplayer game.
class (Server (ServerT g)
     , Categorized (ClientOnlyEvtT g)
     , Show (ClientOnlyEvtT g)
     , ColorTheme (ColorThemeT g)
     , Binary (ColorThemeT g)
     , LeftInfo (ClientInfoT g)
     )
      =>
     GameLogic g
     where

  type ServerT g = (r :: *) | r -> g
  -- ^ Server-side dual of 'GameLogic'

  type ClientOnlyEvtT g = (r :: *) | r -> g
  -- ^ Events generated on the client and handled by the client.

  type ColorThemeT g
  -- ^ The colors used by a player

  type ClientInfoT g

  gameName :: Proxy g -> String
  gameName _ = "Game"

  {- |
This method can be implemented to make /custom/ commands available in the chat window.

Commands issued in the chat have the following syntax:

  * First, @/@ indicates that we will write a command
  * then we write the command name (all alphanumerical characters)
  * then we write command parameters, separated by spaces.

When this method is called, the command name has not matched with any of the default commands
(the only defaut command today is '@name@'),
and the input has been consumed up until the /beginning/ of the command parameters:

@
'^' indicates the parse position when this method is called

/color 2 3 4
       ^
/color
      ^
@
  -}
  cmdParser :: Text
            -- ^ Command name (lowercased)
            -> Parser (Either Text (Command (ServerT g)))
  cmdParser cmd = fail $ "'" <> unpack cmd <> "' is an unknown command."

  getViewport :: Transitioning
              -> Screen
              -> g
              -> RectContainer
              -- ^ The screen region used to draw the game in 'drawGame'

  getClientsInfos :: Transitioning
                  -> g
                  -> Map ClientId (ClientInfoT g)
  getClientsInfos _ _ = mempty

  getFrameColor :: Maybe g
                -> LayeredColor

  mkWorldInfos :: InfoType
               -> Transitioning
               -> g
               -> Infos
  mkWorldInfos _ _ _ = mkEmptyInfos

  onAnimFinished :: (GameLogicT e ~ g
                   , MonadState (AppState (GameLogicT e)) m
                   , MonadReader e m, Client e
                   , MonadIO m)
                 => m ()
  onAnimFinished = return ()

  {- Handle your game's events. These are triggered either by a 'ServerT', or by a key press
  (see 'keyMaps') -}
  onCustomEvent :: (g ~ GameLogicT e
                  , MonadState (AppState g) m
                  , MonadReader e m, Client e, Render e, HasSizedFace e, AsyncGroups e, Audio e
                  , MonadIO m)
                => CustomUpdateEvent g
                -> m ()

  -- | Maps a 'Key' to a 'GenEvent', given a 'StateValue'.
  --
  -- This method is called only when the client 'StateNature' is 'Ongoing'. Hence,
  -- key presses while the client 'StateNature' is 'Over' are ignored.
  keyMaps :: (GameLogicT e ~ g
            , MonadState (AppState g) m
            , MonadReader e m, Client e)
           => Key
           -> StateValue
           -- ^ The current client state.
           -> m (Maybe (GenEvent g))

  drawGame :: (GameLogicT e ~ g
             , MonadState (AppState (GameLogicT e)) m
             , MonadReader e m, Draw e
             , MonadIO m)
           => m ()

data Infos = Infos {
    upInfos, downInfos :: !(Successive ColoredGlyphList)
  , leftUpInfos :: [Successive ColoredGlyphList]
  , leftDownInfos :: [Successive ColoredGlyphList]
}

mkEmptyInfos :: Infos
mkEmptyInfos = Infos (Successive [fromString ""]) (Successive [fromString ""]) [] []

data EventGroup g = EventGroup {
    events :: ![UpdateEvent g]
  , _eventGroupHasPrincipal :: !Bool
  , _eventGroupUpdateDuration :: !(Time Duration System)
  , _eventGroupVisibleTimeRange :: !(Maybe (TimeRange System))
  -- ^ TimeRange of /visible/ events deadlines
}

-- | Regroups events that can be handled immediately by the client.
type UpdateEvent g  = Either (ServerEvent (ServerT g)) (Event (ClientOnlyEvtT g))
type CustomUpdateEvent g = Either (ServerEventT (ServerT g)) (ClientOnlyEvtT g)

-- | No 2 principal events can be part of the same 'EventGroup'.
-- It allows to separate important game action on different rendered frames.
isPrincipal :: UpdateEvent g -> Bool
isPrincipal (Right e) = case e of
  (Timeout (Deadline _ _ (AnimateParticleSystem _))) -> False
  (Timeout (Deadline _ _ AnimateUI)) -> False
  _ -> True
isPrincipal (Left _) = True

mkEmptyGroup :: EventGroup g
mkEmptyGroup = EventGroup [] False zeroDuration Nothing

visible :: EventGroup g -> Bool
visible (EventGroup _ _ _ Nothing) = False
visible _ = True

count :: EventGroup g -> Int
count (EventGroup l _ _ _) = length l

tryGrow :: Maybe (UpdateEvent g) -> EventGroup g -> IO (Maybe (EventGroup g))
tryGrow Nothing group
 | null $ events group = return $ Just group -- Keep the group opened to NOT do a render
 | otherwise = return Nothing -- to do a render
tryGrow (Just e) (EventGroup l hasPrincipal updateTime range)
 | hasPrincipal && principal = return Nothing -- we don't allow two principal events in the same group
 | updateTime > fromSecs 0.01 = return Nothing -- we limit the duration of updates, to keep a stable render rate
 | otherwise = maybe mkRangeSingleton (flip extendRange) range <$> time >>= \range' -> return $
    let -- so that no 2 updates of the same particle system are done in the same group:
        maxDiameter = particleSystemDurationToSystemDuration $ 0.99 .* particleSystemPeriod
    in if timeSpan range' > maxDiameter
      then
        Nothing
      else
        withEvent $ Just range'
 where
  !principal = isPrincipal e
  withEvent = Just . EventGroup (e:l) (hasPrincipal || principal) updateTime
  time = case e of
    Right (Timeout (Deadline t _ _)) -> return t
    _ -> getSystemTime

type ParticleSystems = Map ParticleSystemKey (Prioritized ParticleSystem)

data Game g = Game {
    getClientState :: {-# UNPACK #-} !ClientState
  , getScreen :: {-# UNPACK #-} !Screen
  , getGameState' :: !(GameState g)
  , gameParticleSystems :: !ParticleSystems
    -- ^ Inter-level animation.
  , getDrawnClientState :: ![(ColorString    -- 'ColorString' is used to compare with new messages.
                             ,AnimatedLine)] -- 'AnimatedLine' is used for rendering.
  , getPlayers' :: !(Map ClientId (Player g))
  , _gameSuggestedClientName :: !(Maybe (ConnectIdT (ServerT g)))
  , getServerView' :: {-unpack sum-} !(ServerView (ServerT g))
  -- ^ The server that runs the game
  , connection' :: {-unpack sum-} !ConnectionStatus
  , getChat' :: !Chat
}

data GameState g = GameState {
    _game :: !(Maybe g)
  , _anim :: !UIAnimation
}

data Player g = Player {
    getPlayerName :: {-# UNPACK #-} !(ClientName Approved)
  , getPlayerStatus :: {-unpack sum-} !PlayerStatus
  , getPlayerColors :: {-# UNPACK #-} !(PlayerColors g)
} deriving(Generic, Show)
instance GameLogic g => Binary (Player g)

mkPlayer :: GameLogic g => PlayerEssence -> Player g
mkPlayer (PlayerEssence a b color) =
  Player a b $ mkPlayerColors color

mkPlayerColors :: GameLogic g
               => Color8 Foreground
               -> PlayerColors g
mkPlayerColors c = PlayerColors c $ mkColorTheme c

data PlayerColors g = PlayerColors {
    getPlayerColor :: {-# UNPACK #-} !(Color8 Foreground)
    -- ^ Main color of player
  , getColorCycles :: !(ColorThemeT g)
} deriving(Generic)
instance GameLogic g => Binary (PlayerColors g)
instance GameLogic g => Show (PlayerColors g) where
  show (PlayerColors c cy) = show ("PlayerColors",c,cy)
instance GameLogic g => Eq (PlayerColors g) where
  (PlayerColors c _) == (PlayerColors c' _) = c == c'

data AnimatedLine = AnimatedLine {
    getRecordDrawEvolution :: !(Evolution RecordDraw)
  , getALFrame :: !Frame
  , getALDeadline :: !(Maybe Deadline)
} deriving(Generic, Show)

data Occurences a = Occurences {
    _occurencesCount :: {-# UNPACK #-} !Int
  , _occurencesItem :: {-unpack sum-} !EventCategory
} deriving(Generic, Show)

data AppState g = AppState {
    timeAfterRender :: !(Time Point System)
  , game :: !(Game g)
  , eventsGroup :: !(EventGroup g)
  , _appStateEventHistory :: !OccurencesHist
  -- ^ Can record which events where handled, for debugging purposes.
  , _appStateRecordEvents :: !RecordMode
  -- ^ Should the handled events be recorded?
  , nextParticleSystemKey :: !ParticleSystemKey
  , _appStateDebug :: {-unpack sum-} !Debug
  -- ^ Print times and group information in the terminal.
}

data RecordMode = Record
                | DontRecord
                deriving(Eq)

data OccurencesHist = OccurencesHist {
    _occurencesHistList :: ![Occurences EventCategory]
  , _occurencesHistTailStr :: !ColorString
} deriving(Generic, Show)


data GameArgs g = GameArgs
  !ServerOnly
  !(Maybe ServerName)
  !(Maybe ServerPort)
  !(Maybe ServerLogs)
  !(Maybe ColorScheme)
  !(Maybe (ConnectIdT (ServerT g)))
  !(Maybe BackendType)
  !(Maybe PPU)
  !(Maybe PreferredScreenSize)
  !Debug
  !WithAudio


{-# INLINABLE getGameState #-}
getGameState :: MonadState (AppState g) m => m (GameState g)
getGameState = getGameState' <$> gets game

{-# INLINABLE getIGame #-}
getIGame :: MonadState (AppState g) m => m (Maybe g)
getIGame = _game <$> getGameState

{-# INLINABLE getServerView #-}
getServerView :: MonadState (AppState g) m => m (ServerView (ServerT g))
getServerView = getServerView' <$> gets game

{-# INLINABLE getChatMode #-}
getChatMode :: MonadState (AppState g) m => m IsEditing
getChatMode = getIsEditing <$> getChat

{-# INLINABLE getChat #-}
getChat :: MonadState (AppState g) m => m Chat
getChat = getChat' <$> gets game

{-# INLINABLE getCurScreen #-}
getCurScreen :: MonadState (AppState g) m => m Screen
getCurScreen = getScreen <$> gets game

{-# INLINABLE putCurScreen #-}
putCurScreen :: MonadState (AppState g) m => Screen -> m ()
putCurScreen s = gets game >>= \g -> putGame $ g { getScreen = s }

{-# INLINABLE getLastRenderTime #-}
getLastRenderTime :: MonadState (AppState g) m => m (Time Point System)
getLastRenderTime = gets timeAfterRender

{-# INLINABLE putGame #-}
putGame :: MonadState (AppState g) m => Game g -> m ()
putGame g = modify' $ \s -> s { game = g }

{-# INLINABLE putAnimation #-}
putAnimation :: MonadState (AppState s) m => UIAnimation -> m ()
putAnimation a =
  getGameState >>= \g -> putGameState $ g {_anim = a}

{-# INLINABLE putIGame #-}
putIGame :: MonadState (AppState s) m => s -> m ()
putIGame a =
  getGameState >>= \g -> putGameState $ g {_game = Just a}

{-# INLINABLE putServer #-}
putServer :: MonadState (AppState g) m => (ServerView (ServerT g)) -> m ()
putServer s =
  gets game >>= \g -> putGame $ g {getServerView' = s}

{-# INLINABLE putGameState #-}
putGameState :: MonadState (AppState g) m => GameState g -> m ()
putGameState s =
  gets game >>= \g -> putGame $ g {getGameState' = s}

{-# INLINABLE putGameConnection #-}
putGameConnection :: MonadState (AppState g) m => ConnectionStatus -> m ()
putGameConnection c =
  gets game >>= \g -> putGame $ g {connection' = c}

{-# INLINABLE getGameConnection #-}
getGameConnection :: MonadState (AppState g) m => m ConnectionStatus
getGameConnection = connection' <$> gets game

{-# INLINABLE getMyId #-}
getMyId :: MonadState (AppState g) m => m (Maybe ClientId)
getMyId =
  (\case
    Connected myId -> Just myId
    _ -> Nothing) <$> getGameConnection

{-# INLINABLE putServerContent #-}
putServerContent :: MonadState (AppState g) m => ValuesT (ServerT g) -> m ()
putServerContent p =
  getServerView >>= \s@(ServerView _ c) ->
    putServer s { serverContent = c { cachedValues = Just p } }

{-# INLINABLE getServerContent #-}
getServerContent :: MonadState (AppState g) m => m (Maybe (ValuesT (ServerT g)))
getServerContent =
  cachedValues . serverContent <$> getServerView

{-# INLINABLE getPlayers #-}
getPlayers :: MonadState (AppState g) m => m (Map ClientId (Player g))
getPlayers = getPlayers' <$> gets game

{-# INLINABLE getPlayer #-}
getPlayer :: MonadState (AppState g) m => ClientId -> m (Maybe (Player g))
getPlayer i = flip (!?) i <$> getPlayers

{-# INLINABLE putPlayers #-}
putPlayers :: MonadState (AppState g) m => Map ClientId (Player g) -> m ()
putPlayers m = gets game >>= \g -> putGame g {getPlayers' = m}

{-# INLINABLE putPlayer #-}
putPlayer :: MonadState (AppState g) m => ClientId -> Player g -> m ()
putPlayer sid player = getPlayers >>= \names -> putPlayers $ Map.insert sid player names

{-# INLINABLE takeKeys #-}
takeKeys :: MonadState (AppState g) m => Int -> m [ParticleSystemKey]
takeKeys n
  | n <= 0 = return []
  | otherwise =
      state $ \s ->
        let key = nextParticleSystemKey s
            endKey = key + fromIntegral n
        in ([key..pred endKey], s {nextParticleSystemKey = endKey })

{-# INLINABLE putDrawnState #-}
putDrawnState :: (MonadState (AppState g) m)
              => [(ColorString, AnimatedLine)]
              -> m ()
putDrawnState i =
  gets game >>= \g -> putGame $ g { getDrawnClientState = i }

{-# INLINABLE stateChat #-}
stateChat :: MonadState (AppState g) m => (Chat -> (Chat, a)) -> m a
stateChat f =
  gets game >>= \g -> do
    let (newChat, v) = f $ getChat' g
    putGame $ g { getChat' = newChat }
    return v

{-# INLINABLE hasVisibleNonRenderedUpdates #-}
hasVisibleNonRenderedUpdates :: MonadState (AppState g) m => m Bool
hasVisibleNonRenderedUpdates =
  visible <$> gets eventsGroup
