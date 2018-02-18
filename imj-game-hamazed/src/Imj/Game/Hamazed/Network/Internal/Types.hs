{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Imj.Game.Hamazed.Network.Internal.Types
      ( ServerState(..)
      , Client(..)
      , mkClient
      , PlayerState(..)
      , Clients(..)
      , Intent(..)
      , CurrentGame(..)
      , mkCurrentGame
      , GameStatus(..)
      , newServerState
    ) where

import           Imj.Prelude
import           Control.Concurrent.MVar(MVar, newEmptyMVar)
import           Control.DeepSeq(NFData(..))
import           Data.Map.Strict(Map, empty)
import           Data.Set(Set)
import           Network.WebSockets(Connection)

import           Imj.Game.Hamazed.Types
import           Imj.Game.Hamazed.Network.Types

import           Imj.Geo.Discrete
import           Imj.Game.Hamazed.Loop.Timing

data Client = Client {
    getIdentity :: {-# UNPACK #-} !ClientId
  , getConnection :: {-# UNPACK #-} !Connection
  , getServerOwnership :: {-unpack sum-} !ServerOwnership
  , getCurrentWorld :: {-unpack sum-} !(Maybe WorldId)
  , getShipSafeUntil :: {-unpack sum-} !(Maybe (Time Point System))
  -- ^ At the beginning of each level, the ship is immune to collisions with 'Number's
  -- for a given time. This is the time at which the immunity ends. 'Nothing' values
  -- mean that there is no immunity.
  , getShipAcceleration :: !(Coords Vel)
  , getState :: {-unpack sum-} !(Maybe PlayerState)
  -- ^ When 'Nothing', the client is excluded from the current game.
} deriving(Generic)
instance NFData Client where
  rnf _ = ()

mkClient :: ClientId -> Connection -> ServerOwnership -> Client
mkClient a b c = Client a b c Nothing Nothing zeroCoords Nothing

data PlayerState = InGame | Finished
  deriving (Generic, Eq)
instance NFData PlayerState

-- | A 'Server' handles one game only (for now).
data ServerState = ServerState {
    getClients :: {-# UNPACK #-} !Clients
  , _gameTiming :: !GameTiming -- could / should this be part of CurrentGame?
  , getLevelSpec :: {-# UNPACK #-} !LevelSpec
  , getWorldParameters :: {-# UNPACK #-} !WorldParameters
  -- ^ The actual 'World' is stored on the 'Clients'
  , getLastRequestedWorldId' :: {-unpack sum-} !(Maybe WorldId)
  , getIntent' :: {-unpack sum-} !Intent
  -- ^ Influences the control flow (how 'ClientEvent's are handled).
  , getShouldTerminate :: {-unpack sum-} !Bool
  -- ^ Set on server shutdown
  , getScheduledGame :: {-# UNPACK #-} !(MVar CurrentGame)
  -- ^ When set, it informs the scheduler thread that it should run the game.
} deriving(Generic)
instance NFData ServerState

data CurrentGame = CurrentGame {
    getGameWorld :: {-# UNPACK #-} !WorldId
  , getGamePlayers :: !(Set ShipId)
  , getGameStatus :: {-unpack sum-} !GameStatus
}

mkCurrentGame :: WorldId -> Set ShipId -> CurrentGame
mkCurrentGame w s = CurrentGame w s New

data Intent =
    IntentSetup
  | IntentPlayGame
  | IntentLevelEnd !LevelOutcome
  deriving(Generic, Show, Eq)
instance NFData Intent

data Clients = Clients {
    getClients' :: !(Map ShipId Client)
  , getNextShipId :: !ShipId
} deriving(Generic)
instance NFData Clients

data GameTiming = GameTiming {
    _gameStateNextMotionStep :: !(Maybe (Time Point System))
  -- ^ When the next 'World' motion update should happen
  , _gameStateTimeMultiplicator :: !(Multiplicator GameTime)
} deriving(Generic)
instance NFData GameTiming

mkGameTiming :: GameTiming
mkGameTiming = GameTiming Nothing initalGameMultiplicator

mkClients :: Clients
mkClients = Clients empty (ShipId 0)

newServerState :: IO ServerState
newServerState =
  ServerState mkClients mkGameTiming (mkLevelSpec firstLevel)
              initialParameters Nothing IntentSetup False <$> newEmptyMVar
