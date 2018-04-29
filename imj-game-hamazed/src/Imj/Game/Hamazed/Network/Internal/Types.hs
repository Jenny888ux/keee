{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Imj.Game.Hamazed.Network.Internal.Types
      ( WorldState(..)
      , WorldCreation(..)
      , HamazedClient(..)
      , mkHamazedClient
      , HamazedClientEvent(..)
      , HamazedServerEvent(..)
      , PlayerState(..)
      , Clients
      , Intent(..)
      , CurrentGame(..)
      , mkCurrentGame
      , firstServerLevel
      , GameTiming(..)
      , PlayerName(..)
      , SuggestedPlayerName(..)
      , PlayerEssence(..)
      , PlayerStatus(..) -- TODO should we merge with 'StateValue' ?
      , StateValue(..)
      , Client
      , WorldRequestArg(..)
      , ServerReport(..)
      , ClientCommand(..)
      , ServerCommand(..)
      , SharedValueKey(..)
      , SharedEnumerableValueKey(..)
      , SharedValue(..)
      , PlayerNotif(..)
      , GameNotif(..)
      , LeaveReason(..)
      , GameStep(..)
      , GameStatus(..)
      -- * Game
      , GameStateEssence(..)
      , ShotNumber(..)
      , Operation(..)
      -- * Scheduler
      , RunResult(..)
    ) where

import           Imj.Prelude
import           Data.Map.Strict(Map)
import           Data.Set(Set)
import           Data.String(IsString)

import           Imj.ClientServer.Class
import           Imj.Game.Hamazed.World.Space.Types
import           Imj.Game.Hamazed.Level.Types
import           Imj.Game.Hamazed.Loop.Event.Types
import           Imj.Graphics.Color.Types

import           Imj.Game.Hamazed.Chat
import           Imj.Game.Hamazed.Loop.Timing
import           Imj.Game.Hamazed.Music
import           Imj.Music


-- | An event generated by the client, sent to the server.
data HamazedClientEvent =
    ExitedState {-unpack sum-} !StateValue
  | WorldProposal !WorldId !(MkSpaceResult WorldEssence) !(Map Properties Statistics)
    -- ^ In response to 'WorldRequest' 'Build'
  | CurrentGameState {-# UNPACK #-} !WorldId !(Maybe GameStateEssence)
    -- ^ In response to 'WorldRequest' 'GetGameState'
  | IsReady {-# UNPACK #-} !WorldId
  -- ^ When the level's UI transition is finished.
  | Action {-unpack sum-} !ActionTarget {-unpack sum-} !Direction
   -- ^ A player action on an 'ActionTarget' in a 'Direction'.
  | LevelEnded {-unpack sum-} !LevelOutcome
  | CanContinue {-unpack sum-} !GameStatus
  -- NOTE the 3 constructors below could be factored as 'OnCommand' 'Command'
  | RequestApproval {-unpack sum-} !ClientCommand
  -- ^ A Client asks for authorization to run a 'ClientCommand'.
  -- In response the server either sends 'CommandError' to disallow command execution or 'RunCommand' to allow it.
  | Do {-unpack sum-} !ServerCommand
  -- ^ A Client asks the server to run a 'ServerCommand'.
  -- In response, the server runs the 'ServerCommand' then publishes a 'PlayerNotif' 'Done' 'ServerCommand'.
  | Report !ServerReport
  -- ^ A client want to know an information on the server state. The server will answer by
  -- sending a 'Report'.
  deriving(Generic, Show)
instance Binary HamazedClientEvent

-- | An event generated by the server, sent to a client.
data HamazedServerEvent =
    EnterState {-unpack sum-} !StateValue
  | ExitState {-unpack sum-} !StateValue
  | PlayerInfo {-unpack sum-} !PlayerNotif
               {-# UNPACK #-} !ShipId
  | GameInfo {-unpack sum-} !GameNotif
  | WorldRequest {-# UNPACK #-} !WorldId
                                !WorldRequestArg
  | ChangeLevel {-# UNPACK #-} !LevelEssence -- TODO merge with WorldRequest
                {-# UNPACK #-} !WorldEssence
                {-# UNPACK #-} !WorldId
  -- ^ Triggers a UI transition between the previous (if any) and the next level.
  | PutGameState {-# UNPACK #-} !GameStateEssence  -- TODO merge with WorldRequest
                 {-# UNPACK #-} !WorldId
  | OnWorldParameters {-# UNPACK #-} !WorldParameters
  | MeetThePlayers !(Map ClientId PlayerEssence)
  -- ^ (reconnection scenario) Upon reception, the client should set its gamestate accordingly.
  | GameEvent {-unpack sum-} !GameStep
  | CommandError {-unpack sum-} !ClientCommand
                 {-# UNPACK #-} !Text
  -- ^ The command cannot be run, with a reason.
  | RunCommand {-# UNPACK #-} !ShipId
               {-unpack sum-} !ClientCommand
  -- ^ The server validated the use of the command, now it must be executed.
  | Reporting {-unpack sum-} !ServerCommand
  -- ^ Response to a 'Report'.
  | PlayMusic !Music !Instrument
  deriving(Generic, Show)
instance Binary HamazedServerEvent

data WorldRequestArg =
    Build {-# UNPACK #-} !(Time Duration System)
          {-# UNPACK #-} !WorldSpec
  | Cancel
  | GetGameState
  -- ^ Upon 'Build' reception, the client should respond with a 'WorldProposal', within the
  -- given duration, except if a later 'Cancel' for the same 'WorldId' is received.
  --
  -- Upon 'GetGameState' reception, the client responds with a 'CurrentGameState'
  deriving(Generic, Show)
instance Binary WorldRequestArg

data PlayerNotif =
    Joins
  | WaitsToJoin
  | StartsGame
  | Done {-unpack sum-} !ServerCommand
    -- ^ The server notifies whenever a 'Do' task is finished.
  deriving(Generic, Show)
instance Binary PlayerNotif

data GameNotif =
    LevelResult {-# UNPACK #-} !LevelNumber {-unpack sum-} !LevelOutcome
  | GameWon
  | CannotCreateLevel ![Text] {-# UNPACK #-} !LevelNumber
  deriving(Generic, Show)
instance Binary GameNotif

-- | Commands initiated by /one/ client or the server, authorized (and in part executed) by the server,
--  then executed (for the final part) by /every/ client.
data ClientCommand =
    AssignName {-# UNPACK #-} !PlayerName
  | AssignColor {-# UNPACK #-} !(Color8 Foreground)
  | Says {-# UNPACK #-} !Text
  | Leaves {-unpack sum-} !LeaveReason
  -- ^ The client shuts down. Note that clients that are 'ClientOwnsServer',
  -- will also gracefully shutdown the server.
  deriving(Generic, Show, Eq) -- Eq needed for parse tests
instance Binary ClientCommand

-- | Commands initiated by a client, executed by the server.
data ServerCommand =
    Put !SharedValue
  | Succ !SharedEnumerableValueKey
  | Pred !SharedEnumerableValueKey
  deriving(Generic, Show, Eq) -- Eq needed for parse tests
instance Binary ServerCommand

-- | Identifiers of values shared by all players.
data SharedEnumerableValueKey =
    BlockSize
  | WallProbability
  deriving(Generic, Show, Eq) -- Eq needed for parse tests
instance Binary SharedEnumerableValueKey

-- | Values shared by all players.
data SharedValue =
    ColorSchemeCenter {-# UNPACK #-} !(Color8 Foreground)
  | WorldShape {-unpack sum-} !WorldShape
  deriving(Generic, Show, Eq) -- Eq needed for parse tests
instance Binary SharedValue

-- | Describes what the client wants to know about the server.
data ServerReport =
    Get !SharedValueKey
  deriving(Generic, Show, Eq) -- Eq needed for parse tests
instance Binary ServerReport

-- | Identifiers of values shared by all players.
data SharedValueKey =
    ColorSchemeCenterKey
  | WorldShapeKey
  deriving(Generic, Show, Eq) -- Eq needed for parse tests
instance Binary SharedValueKey

data LeaveReason =
    ConnectionError !Text
  | Intentional
  deriving(Generic, Show, Eq)
instance Binary LeaveReason

-- | 'PeriodicMotion' aggregates the accelerations of all ships during a game period.
data GameStep =
  PeriodicMotion {
    _shipsAccelerations :: !(Map ShipId (Coords Vel))
    , _shipsLostArmor :: !(Set ShipId)
  }
  | LaserShot {-unpack sum-} !Direction {-# UNPACK #-} !ShipId
  deriving(Generic, Show)
instance Binary GameStep

data StateValue =
    Excluded
    -- ^ The player is not part of the game
  | Setup
  -- ^ The player is configuring the game
  | PlayLevel !GameStatus
  -- ^ The player is playing the game
  deriving(Generic, Show, Eq)
instance Binary StateValue
instance NFData StateValue

data GameStateEssence = GameStateEssence {
    _essence :: {-# UNPACK #-} !WorldEssence
  , _shotNumbers :: ![ShotNumber]
  , _levelEssence :: {-unpack sum-} !LevelEssence
} deriving(Generic, Show)
instance Binary GameStateEssence

data ShotNumber = ShotNumber {
    getNumberValue :: {-# UNPACK #-} !Int
    -- ^ The numeric value
  , getOperation :: !Operation
  -- ^ How this number influences the current sum.
} deriving (Generic, Show)
instance Binary ShotNumber

data Operation = Add | Substract
  deriving (Generic, Show)
instance Binary Operation

data HamazedClient = HamazedClient {
    getName :: {-# UNPACK #-} !PlayerName
  , getCurrentWorld :: {-unpack sum-} !(Maybe WorldId)
  , getShipSafeUntil :: {-unpack sum-} !(Maybe (Time Point System))
  -- ^ At the beginning of each level, the ship is immune to collisions with 'Number's
  -- for a given time. This is the time at which the immunity ends. 'Nothing' values
  -- mean that there is no immunity.
  , getShipAcceleration :: !(Coords Vel)
  , getState :: {-unpack sum-} !(Maybe PlayerState) -- TODO should we add Disconnected, and leave disconnected clients in the map?
  -- ^ When 'Nothing', the client is excluded from the current game.
  , getColor :: {-# UNPACK #-} !(Color8 Foreground)
  -- ^ Ship color, deduced from the 'centerColor' of the 'ServerState'
} deriving(Generic, Show)
instance NFData HamazedClient
instance ClientInfo HamazedClient where
  clientLogColor = Just . getColor
  clientFriendlyName  = Just . unPlayerName . getName


mkHamazedClient :: PlayerName -> Color8 Foreground -> HamazedClient
mkHamazedClient a color =
  HamazedClient a Nothing Nothing zeroCoords Nothing color

data PlayerState =
    Playing {-unpack sum-} !(Maybe LevelOutcome)
  | ReadyToPlay
  deriving (Generic, Eq, Show)
instance NFData PlayerState


data PlayerStatus = Present | Absent
  deriving(Generic, Show)
instance Binary PlayerStatus

data PlayerEssence = PlayerEssence {
    playerEssenceName :: {-# UNPACK #-} !PlayerName
  , playerEssenceStatus :: {-unpack sum-} !PlayerStatus
  , playerEssenceColor :: {-# UNPACK #-} !(Color8 Foreground)
} deriving(Generic, Show)
instance Binary PlayerEssence

newtype SuggestedPlayerName = SuggestedPlayerName String
  deriving(Generic, Eq, Show, Binary, IsString)


data WorldCreation = WorldCreation {
    creationState :: !WorldState
  , creationKey :: !WorldId
  , creationSpec :: !WorldSpec
  , creationStatistics :: !(Map Properties Statistics)
  -- ^ Statistics stop being gathered once the world is created
} deriving(Generic)
instance NFData WorldCreation

data WorldState =
    CreationAssigned !(Set ClientId) -- which clients are responsible for creating the world
  | Created
  deriving(Generic, Show)
instance NFData WorldState

data CurrentGame = CurrentGame {
    gameWorld :: {-# UNPACK #-} !WorldId
  , gamePlayers' :: !(Set ClientId)
  , status' :: {-unpack sum-} !GameStatus
  , score :: !Score
} deriving(Generic, Show)

mkCurrentGame :: WorldId -> Set ClientId -> CurrentGame
mkCurrentGame w s = CurrentGame w s New $ mkScore $ [mainTheme, secondVoice, thirdVoice]

data Intent =
    IntentSetup
  | IntentPlayGame !(Maybe LevelOutcome)
  deriving(Generic, Show, Eq)
instance NFData Intent

data GameTiming = GameTiming {
    _gameStateNextMotionStep :: !(Maybe (Time Point System))
  -- ^ When the next 'World' motion update should happen
  , _gameStateTimeMultiplicator :: !(Multiplicator GameTime)
} deriving(Generic)
instance NFData GameTiming

firstServerLevel :: LevelNumber
firstServerLevel = firstLevel

data RunResult =
    NotExecutedGameCanceled
  | NotExecutedTryAgainLater !(Time Duration System)
  -- ^ withe the duration to sleep before retrying
  | Executed !(Maybe (Time Duration System))
  -- ^ With an optional duration to wait before the next iteration
