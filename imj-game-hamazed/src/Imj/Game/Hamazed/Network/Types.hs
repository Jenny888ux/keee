{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

{-|
This module exports types related to networking.

Game events are sent by the clients, proccessed by the server. For example, if two players
play the game:

@
  - Ax = acceleration of ship x
  - Lx = laser shot of ship x
  - .  = end of a game period

        >>> time >>>
 . . . A1 . . A1 A2 L2 L1 .
              ^^^^^ ^^^^^
              |     |
              |     laser shots can't be aggregated.
              |
              accelerations can be aggregated, their order within a period is unimportant.
@

The order in which L1 L2 are handled by the server is the order in which they are received.
This is /unfair/ because one player (due to network delays) could have rendered the
last period 100ms before the other, thus having a significant advantage over the other player.
We could be more fair by keeping track of the perceived time on the player side:

in 'ClientAction' we could store the difference between the system time of the action
and the system time at which the last motion update was presented to the player.

Hence, to know how to order close laser shots, if the ships are on the same row or column,
the server should wait a little (max. 50 ms?) to see if the other player makes a
perceptually earlier shot.
-}

module Imj.Game.Hamazed.Network.Types
      ( ConnectionStatus(..)
      , NoConnectReason(..)
      , DisconnectReason(..)
      , SuggestedPlayerName(..)
      , PlayerName(..)
      , Player(..)
      , PlayerEssence(..)
      , mkPlayer
      , PlayerStatus(..) -- TODO should we merge with 'StateValue' ?
      , PlayerColors(..)
      , mkPlayerColors
      , getPlayerUIName'
      , getPlayerUIName''
      , ColorScheme(..)
      , ServerOwnership(..)
      , ClientState(..)
      , StateNature(..)
      , StateValue(..)
      , EventsForClient(..)
      , ClientEvent(..)
      , ServerEvent(..)
      , ServerReport(..)
      , Command(..)
      , ClientCommand(..)
      , ServerCommand(..)
      , ClientQueues(..)
      , Server(..)
      , ServerLogs(..)
      , ServerPort(..)
      , ServerName(..)
      , getServerNameAndPort
      , PlayerNotif(..)
      , GameNotif(..)
      , LeaveReason(..)
      , GameStep(..)
      , GameStatus(..)
      , GameStateEssence(..)
      , ShotNumber(..)
      , Operation(..)
      , applyOperations
      , welcome
      ) where

import           Imj.Prelude
import           Control.Concurrent.STM(TQueue)
import           Control.DeepSeq(NFData)
import           Data.Map.Strict(Map, elems)
import qualified Data.Binary as Bin(encode, decode)
import           Data.List(foldl')
import           Data.Set(Set)
import           Data.String(IsString)
import           Data.Text(unpack)
import qualified Data.Text.Lazy as Lazy(unpack)
import           Data.Text.Lazy.Encoding as LazyE(decodeUtf8)
import           Network.WebSockets(WebSocketsData(..), DataMessage(..))

import           Imj.Game.Hamazed.Chat
import           Imj.Game.Hamazed.Color
import           Imj.Game.Hamazed.Level.Types
import           Imj.Game.Hamazed.Loop.Event.Types
import           Imj.Game.Hamazed.World.Space.Types
import           Imj.Graphics.Font
import           Imj.Graphics.Text.ColorString(ColorString)
import qualified Imj.Graphics.Text.ColorString as ColorString(colored, intercalate)
import           Imj.Graphics.Text.ColoredGlyphList(ColoredGlyphList)
import qualified Imj.Graphics.Text.ColoredGlyphList as ColoredGlyphList(colored)

-- | a Server, seen from a Client's perspective
data Server = Distant !ServerName !ServerPort
            | Local !ServerLogs !ColorScheme !ServerPort
  deriving(Generic, Show)

data ServerLogs =
    NoLogs
  | ConsoleLogs
  deriving(Generic, Show)
instance NFData ServerLogs

data ColorScheme =
    UseServerStartTime
  | ColorScheme {-# UNPACK #-} !(Color8 Foreground)
  deriving(Generic, Show)
instance NFData ColorScheme


data ServerOwnership =
    ClientOwnsServer
    -- ^ Means if client is shutdown, server is shutdown too.
  | ClientDoesntOwnServer
  deriving(Generic, Show, Eq)
instance Binary ServerOwnership

data ClientState = ClientState {-unpack sum-} !StateNature {-unpack sum-} !StateValue
  deriving(Generic, Show, Eq)

data StateNature = Ongoing | Over
  deriving(Generic, Show, Eq)
instance Binary StateNature

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

-- | A client communicates with the server asynchronously, that-is, wrt the thread where
-- game state update and rendering occurs. Using 'TQueue' as a mean of communication
-- instead of 'MVar' has the benefit that in case of the connection being closed,
-- the main thread won't block.
data ClientQueues = ClientQueues { -- TODO Use -funbox-strict-fields to force deep evaluation of thunks when inserting in the queues
    getInputQueue :: {-# UNPACK #-} !(TQueue EventsForClient)
  , getOutputQueue :: {-# UNPACK #-} !(TQueue ClientEvent)
}

data EventsForClient =
    FromClient !Event
  | FromServer !ServerEvent
  deriving(Generic, Show)

-- | An event generated by the client, sent to the server.
data ClientEvent =
    Connect !SuggestedPlayerName {-unpack sum-} !ServerOwnership
  | ExitedState {-unpack sum-} !StateValue
  | WorldProposal {-# UNPACK #-} !WorldEssence
    -- ^ In response to 'WorldRequest'
  | CurrentGameState {-# UNPACK #-} !GameStateEssence
    -- ^ In response to ' CurrentGameStateRequest'
  | ChangeWallDistribution {-unpack sum-} !WallDistribution
  | ChangeWorldShape {-unpack sum-} !WorldShape
  | IsReady {-# UNPACK #-} !WorldId
  -- ^ When the level's UI transition is finished.
  | Action {-unpack sum-} !ActionTarget {-unpack sum-} !Direction
   -- ^ A player action on an 'ActionTarget' in a 'Direction'.
  | LevelEnded {-unpack sum-} !LevelOutcome
  | CanContinue {-unpack sum-} !GameStatus
  | RequestCommand {-unpack sum-} !ClientCommand
  -- ^ A Client wants to run a command, in response the server either sends 'CommandError'
  -- or 'RunCommand'
  | Do {-unpack sum-} !ServerCommand
  -- ^ A Client asks the server to do a task which can't fail.
  | Report !ServerReport
  -- ^ A client want to know an information on the server state. The server will answer by
  -- sending a 'Report'.
  deriving(Generic, Show)
instance Binary ClientEvent
data ServerEvent =
    ConnectionAccepted {-# UNPACK #-} !ShipId !(Map ShipId PlayerEssence)
  | ConnectionRefused {-# UNPACK #-} !NoConnectReason
  | Disconnected {-unpack sum-} !DisconnectReason
  | EnterState {-unpack sum-} !StateValue
  | ExitState {-unpack sum-} !StateValue
  | PlayerInfo {-unpack sum-} !PlayerNotif {-# UNPACK #-} !ShipId
  | GameInfo {-unpack sum-} !GameNotif
  | WorldRequest {-# UNPACK #-} !WorldSpec
  -- ^ Upon reception, the client should respond with a 'WorldProposal'.
  | ChangeLevel {-# UNPACK #-} !LevelEssence {-# UNPACK #-} !WorldEssence
  -- ^ Triggers a UI transition between the previous (if any) and the next level.
  | CurrentGameStateRequest
  -- ^ (reconnection scenario) Upon reception, the client should respond with a 'CurrentGameState'.
  | PutGameState {-# UNPACK #-} !GameStateEssence
  -- ^ (reconnection scenario) Upon reception, the client should set its gamestate accordingly.
  | GameEvent {-unpack sum-} !GameStep
  | CommandError {-unpack sum-} !ClientCommand {-# UNPACK #-} !Text
  -- ^ The command cannot be run, with a reason.
  | RunCommand {-# UNPACK #-} !ShipId {-unpack sum-} !ClientCommand
  -- ^ The server validated the use of the command, now it must be executed.
  | Reporting {-unpack sum-} !ServerReport !Text
  -- ^ Response to a 'Report'.
  | ServerError !String
  -- ^ A non-recoverable error occured in the server. Before crashing, the server sends the error to its clients.
  deriving(Generic, Show)
instance Binary ServerEvent
instance WebSocketsData ClientEvent where
  fromDataMessage (Text t _) =
    error $ "Text was received for ClientEvent : " ++ Lazy.unpack (LazyE.decodeUtf8 t)
  fromDataMessage (Binary bytes) = Bin.decode bytes
  fromLazyByteString = Bin.decode
  toLazyByteString = Bin.encode
  {-# INLINABLE fromDataMessage #-}
  {-# INLINABLE fromLazyByteString #-}
  {-# INLINABLE toLazyByteString #-}
instance WebSocketsData ServerEvent where
  fromDataMessage (Text t _) =
    error $ "Text was received for ServerEvent : " ++ Lazy.unpack (LazyE.decodeUtf8 t)
  fromDataMessage (Binary bytes) = Bin.decode bytes
  fromLazyByteString = Bin.decode
  toLazyByteString = Bin.encode
  {-# INLINABLE fromDataMessage #-}
  {-# INLINABLE fromLazyByteString #-}
  {-# INLINABLE toLazyByteString #-}

data PlayerStatus = Present | Absent
  deriving(Generic, Show)
instance Binary PlayerStatus

data Player = Player {
    getPlayerName :: {-# UNPACK #-} !PlayerName
  , getPlayerStatus :: {-unpack sum-} !PlayerStatus
  , getPlayerColors :: {-# UNPACK #-} !PlayerColors
} deriving(Generic, Show)
instance Binary Player

data PlayerEssence = PlayerEssence {
    playerEssenceName :: {-# UNPACK #-} !PlayerName
  , playerEssenceStatus :: {-unpack sum-} !PlayerStatus
  , playerEssenceColor :: {-# UNPACK #-} !(Color8 Foreground)
} deriving(Generic, Show)
instance Binary PlayerEssence

mkPlayer :: PlayerEssence -> Player
mkPlayer (PlayerEssence a b color) =
  Player a b $ mkPlayerColors color

data PlayerColors = PlayerColors {
    getPlayerColor :: {-# UNPACK #-} !(Color8 Foreground)
    -- ^ color of player name and ship.
  , getColorCycles :: {-# UNPACK #-} !ColorCycles
    -- ^ colors for particle systems
} deriving(Generic, Show, Eq)
instance Binary PlayerColors

mkPlayerColors :: Color8 Foreground -> PlayerColors
mkPlayerColors c = PlayerColors c $ mkColorCycles c

getPlayerUIName' :: Maybe Player -> ColorString
getPlayerUIName' = getPlayerUIName ColorString.colored

getPlayerUIName'' :: Maybe Player -> ColoredGlyphList
getPlayerUIName'' = getPlayerUIName (ColoredGlyphList.colored . map textGlyph . unpack)

getPlayerUIName :: (IsString a, Monoid a)
                => (Text -> Color8 Foreground -> a)
                -> Maybe Player
                -> a
-- 'Nothing' happens when 2 players disconnect while playing: the first one to reconnect will not
-- know about the name of the other disconnected player, until the other player reconnects (TODO is it still the case?).
getPlayerUIName _ Nothing = "? (away)"
getPlayerUIName f (Just (Player (PlayerName name) status (PlayerColors c _))) =
  case status of
    Present -> n
    Absent  -> n <> f " (away)" chatMsgColor
 where
  n = f name c

data Command =
    ClientCmd !ClientCommand
  | ServerCmd !ServerCommand
  | ServerRep !ServerReport
  deriving(Generic, Show, Eq) -- Eq needed for parse tests
instance Binary Command

-- | Describes what the client wants to know about the server.
data ServerReport =
    TellColorSchemeCenter
  deriving(Generic, Show, Eq) -- Eq needed for parse tests
instance Binary ServerReport

-- | Commands initiated by a client, executed by the server.
data ServerCommand =
    SetColorSchemeCenter {-# UNPACK #-} !(Color8 Foreground)
  deriving(Generic, Show, Eq) -- Eq needed for parse tests
instance Binary ServerCommand

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

data GameStateEssence = GameStateEssence {
    _essence :: {-# UNPACK #-} !WorldEssence
  , _shotNumbers :: ![ShotNumber]
  , _levelEssence :: {-unpack sum-} !LevelEssence
} deriving(Generic, Show)
instance Binary GameStateEssence

data ShotNumber = ShotNumber {
    _value :: {-# UNPACK #-} !Int
    -- ^ The numeric value
  , getOperation :: !Operation
  -- ^ How this number influences the current sum.
} deriving (Generic, Show)
instance Binary ShotNumber

data Operation = Add | Substract
  deriving (Generic, Show)
instance Binary Operation

applyOperations :: [ShotNumber] -> Int
applyOperations =
  foldl' (\v (ShotNumber n op) ->
            case op of
              Add -> v + n
              Substract -> v - n) 0
-- | 'PeriodicMotion' aggregates the accelerations of all ships during a game period.
data GameStep =
    PeriodicMotion {
    _shipsAccelerations :: !(Map ShipId (Coords Vel))
  , _shipsLostArmor :: !(Set ShipId)
}
  | LaserShot {-unpack sum-} !Direction {-# UNPACK #-} !ShipId
  deriving(Generic, Show)
instance Binary GameStep

data ConnectionStatus =
    NotConnected
  | Connected {-# UNPACK #-} !ShipId
  | ConnectionFailed {-# UNPACK #-} !NoConnectReason

data NoConnectReason =
    InvalidName !SuggestedPlayerName {-# UNPACK #-} !Text
  deriving(Generic, Show)
instance Binary NoConnectReason

data DisconnectReason =
    BrokenClient {-# UNPACK #-} !Text
    -- ^ One client is disconnected because its connection is unusable.
  | ClientShutdown
    -- ^ One client is disconnected because it decided so.
  | ServerShutdown {-# UNPACK #-} !Text
  -- ^ All clients are disconnected.
  deriving(Generic)
instance Binary DisconnectReason
instance Show DisconnectReason where
  show (ServerShutdown t) = unpack $ "Server shutdown < " <> t
  show ClientShutdown   = "Client shutdown"
  show (BrokenClient t) = unpack $ "Broken client < " <> t

data PlayerNotif =
    Joins
  | WaitsToJoin
  | StartsGame
  | Done {-unpack sum-} !ServerCommand {-# UNPACK #-} !Text
    -- ^ The server notifies whenever a 'Do' task is finished. Contains Text info that can be printed in the chat
    -- to inform every player of the task's execution.
  deriving(Generic, Show)
instance Binary PlayerNotif

data LeaveReason =
    ConnectionError !Text
  | Intentional
  deriving(Generic, Show, Eq)
instance Binary LeaveReason

data GameNotif =
    LevelResult {-# UNPACK #-} !Int {-unpack sum-} !LevelOutcome
  | GameWon
  deriving(Generic, Show)
instance Binary GameNotif

welcome :: Map ShipId Player -> ColorString
welcome l =
  text "Welcome! Players are: "
  <> ColorString.intercalate
      (text ", ")
      (map (getPlayerUIName' . Just) $ elems l)
 where
  text x = ColorString.colored x chatMsgColor

newtype SuggestedPlayerName = SuggestedPlayerName String
  deriving(Generic, Eq, Show, Binary, IsString)


getServerNameAndPort :: Server -> (ServerName, ServerPort)
getServerNameAndPort (Local _ _ p) = (ServerName "localhost", p)
getServerNameAndPort (Distant name p) = (name, p)

newtype ServerName = ServerName String
  deriving (Show, IsString, Eq)

newtype ServerPort = ServerPort Int
  deriving (Generic, Show, Num, Integral, Real, Ord, Eq, Enum)
