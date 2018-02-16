{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

module Imj.Game.Hamazed.Network.Types
      ( GameNode(..)
      , ConnectionStatus(..)
      , NoConnectReason(..)
      , DisconnectReason(..)
      , SuggestedPlayerName(..)
      , PlayerName(..)
      , ClientType(..)
      , ServerOwnership(..)
      , ClientState(..)
      , StateNature(..)
      , StateValue(..)
      , ClientEvent(..)
      , ServerEvent(..)
      , ClientQueues(..)
      , Server(..)
      , ServerPort(..)
      , ServerName(..)
      , getServerNameAndPort
      , PlayerNotif(..)
      , GameNotif(..)
      , LeaveReason(..)
      , GameStep(..)
      , toTxt
      , toTxt'
      , welcome
      ) where

import           Imj.Prelude hiding(intercalate)
import           Control.Concurrent.STM(TQueue)
import           Control.DeepSeq(NFData)
import qualified Data.Binary as Bin(encode, decode)
import           Data.String(IsString)
import           Data.Text(intercalate, pack)
import           Data.Text.Lazy(unpack)
import           Data.Text.Lazy.Encoding(decodeUtf8)
import           Network.WebSockets(WebSocketsData(..), DataMessage(..))

import           Imj.Game.Hamazed.Chat
import           Imj.Game.Hamazed.Level.Types
import           Imj.Game.Hamazed.Loop.Event.Types
import           Imj.Game.Hamazed.World.Space.Types

-- | a Server, seen from a Client's perspective
data Server = Distant ServerName ServerPort
            | Local ServerPort
  deriving(Generic, Show)

-- | a Client, seen from a Server's perspective
data ClientType = ClientType {
    getOwnership :: {-# UNPACK #-} !ServerOwnership
}
  deriving(Generic, Show, Eq)
instance Binary ClientType

data ServerOwnership =
    ClientOwnsServer
    -- ^ Means if client is shutdown, server is shutdown too.
  | FreeServer
  deriving(Generic, Show, Eq)
instance Binary ServerOwnership

data ClientState = ClientState {-# UNPACK #-} !StateNature {-# UNPACK #-} !StateValue
  deriving(Generic, Show)

data StateNature = Ongoing | Done
  deriving(Generic, Show)
instance Binary StateNature

data StateValue =
    Excluded
    -- ^ The player is not part of the game
  | Setup
  -- ^ The player is configuring the game
  | PlayLevel
  -- ^ The player is playing the game
  deriving(Generic, Show, Eq)
instance Binary StateValue
instance NFData StateValue

data GameNode =
    GameServer {-# UNPACK #-} !Server
  | GameClient {-# UNPACK #-} !ClientQueues {-# UNPACK #-} !Server
  -- ^ A client can be connected to one server only.

-- | A client communicates with the server asynchronously, that-is, wrt the thread where
-- game state update and rendering occurs. Using 'TQueue' as a mean of communication
-- instead of 'MVar' has the benefit that in case of the connection being closed,
-- the main thread won't block.
data ClientQueues = ClientQueues { -- TODO Use -funbox-strict-fields to force deep evaluation of thunks when inserting in the queues
    getInputQueue :: !(TQueue ServerEvent)
  , getOutputQueue :: !(TQueue ClientEvent)
}

-- | An event generated by the client, sent to the server.
data ClientEvent =
    Connect {-# UNPACK #-} !SuggestedPlayerName {-# UNPACK #-} !ClientType
  | Disconnect
  -- ^ The client is shutting down. Note that for clients that are 'ClientOwnsServer',
  -- this also gracefully shutdowns the server.
  | EnteredState {-# UNPACK #-} !StateValue
  | ExitedState {-# UNPACK #-} !StateValue
  | WorldProposal {-# UNPACK #-} !WorldEssence
    -- ^ In response to 'WorldRequest'
  | ChangeWallDistribution {-# UNPACK #-} !WallDistribution
  | ChangeWorldShape {-# UNPACK #-} !WorldShape
  | IsReady {-# UNPACK #-} !WorldId
  -- ^ When the level's UI transition is finished.
  | Action {-# UNPACK #-} !ActionTarget {-# UNPACK #-} !Direction
   -- ^ A player action on an 'ActionTarget' in a 'Direction'.
  | LevelEnded {-# UNPACK #-} !LevelOutcome
  | Say {-# UNPACK #-} !Text
  deriving(Generic, Show)

data ServerEvent =
    ConnectionAccepted {-# UNPACK #-} !ClientId
  | ListPlayers ![PlayerName]
  | ConnectionRefused {-# UNPACK #-} !NoConnectReason
  | Disconnected {-# UNPACK #-} !DisconnectReason
  | EnterState {-# UNPACK #-} !StateValue
  | ExitState {-# UNPACK #-} !StateValue
  | PlayerInfo {-# UNPACK #-} !ClientId {-# UNPACK #-} !PlayerNotif
  | GameInfo {-# UNPACK #-} !GameNotif
  | WorldRequest {-# UNPACK #-} !WorldSpec
  -- ^ Sent to 'WorldCreator's, which should respond with a 'WorldProposal'.
  | ChangeLevel {-# UNPACK #-} !LevelSpec {-# UNPACK #-} !WorldEssence
    -- ^ Triggers a UI transition between the previous (if any) and the next level.
  | GameEvent {-# UNPACK #-} !GameStep
  | Error {-# UNPACK #-} !String
  -- ^ to have readable errors, we send errors to the client, so that 'error' can be executed in the client
  deriving(Generic, Show)

-- | 'PeriodicMotion' aggregates the accelerations of all ships during a game period.
data GameStep =
    PeriodicMotion {
    _shipsAccelerations :: {-# UNPACK #-} ![(ShipId, Coords Vel)]
  , _shipsLostArmor :: {-# UNPACK #-} ![ShipId]
}
  | LaserShot {-# UNPACK #-} !ShipId {-# UNPACK #-} !Direction
  deriving(Generic, Show)
instance Binary GameStep

instance Binary ClientEvent
instance Binary ServerEvent

instance WebSocketsData ClientEvent where
  fromDataMessage (Text t _) =
    error $ "Text was received for ClientEvent : " ++ unpack (decodeUtf8 t)
  fromDataMessage (Binary bytes) = Bin.decode bytes
  fromLazyByteString = Bin.decode
  toLazyByteString = Bin.encode
  {-# INLINABLE fromDataMessage #-}
  {-# INLINABLE fromLazyByteString #-}
  {-# INLINABLE toLazyByteString #-}
instance WebSocketsData ServerEvent where
  fromDataMessage (Text t _) =
    error $ "Text was received for ServerEvent : " ++ unpack (decodeUtf8 t)
  fromDataMessage (Binary bytes) = Bin.decode bytes
  fromLazyByteString = Bin.decode
  toLazyByteString = Bin.encode
  {-# INLINABLE fromDataMessage #-}
  {-# INLINABLE fromLazyByteString #-}
  {-# INLINABLE toLazyByteString #-}


data ConnectionStatus =
    NotConnected
  | Connected {-# UNPACK #-} !ClientId
  | ConnectionFailed {-# UNPACK #-} !NoConnectReason

data NoConnectReason =
    InvalidName {-# UNPACK #-} !SuggestedPlayerName {-# UNPACK #-} !Text
  deriving(Generic, Show)
instance Binary NoConnectReason

data DisconnectReason =
    BrokenClient {-# UNPACK #-} !Text
    -- ^ One client is disconnected because its connection is unusable.
  | ClientShutdown
    -- ^ One client is disconnected because it decided so.
  | ServerShutdown {-# UNPACK #-} !Text
  -- ^ All clients are disconnected.
  deriving(Generic, Show)
instance Binary DisconnectReason

data PlayerNotif =
    Joins
  | Leaves {-# UNPACK #-} !LeaveReason
  | StartsGame
  | Says {-# UNPACK #-} !Text
  deriving(Generic, Show)
instance Binary PlayerNotif

data LeaveReason =
    ConnectionError !Text
  | Intentional
  deriving(Generic, Show)
instance Binary LeaveReason

data GameNotif =
    LevelResult {-# UNPACK #-} !Int {-# UNPACK #-} !LevelOutcome
  | GameWon
  deriving(Generic, Show)
instance Binary GameNotif

toTxt :: PlayerNotif -> PlayerName -> Text
toTxt Joins (PlayerName n) = n <> " joins the game."
toTxt (Leaves Intentional) (PlayerName n)     = n <> " leaves the game."
toTxt (Leaves (ConnectionError t)) (PlayerName n) = n <> ": connection error : " <> t
toTxt StartsGame (PlayerName n) = n <> " starts the game."
toTxt (Says t) (PlayerName n) = n <> " : " <> t

toTxt' :: GameNotif -> Text
toTxt' (LevelResult n (Lost reason)) =
  "- Level " <> pack (show n) <> " was lost : " <> reason <> "."
toTxt' (LevelResult n Won) =
  "- Level " <> pack (show n) <> " was won!"
toTxt' GameWon =
  "- The game was won! Congratulations! "

welcome :: [PlayerName] -> Text
welcome l = "Welcome! Users: " <> intercalate ", " (map (\(PlayerName n) -> n) l)

newtype SuggestedPlayerName = SuggestedPlayerName String
  deriving(Generic, Eq, Show, Binary, IsString)


getServerNameAndPort :: Server -> (ServerName, ServerPort)
getServerNameAndPort (Local p) = (ServerName "localhost", p)
getServerNameAndPort (Distant name p) = (name, p)

newtype ServerName = ServerName String
  deriving (Show, IsString, Eq)

newtype ServerPort = ServerPort Int
  deriving (Generic, Show, Num, Integral, Real, Ord, Eq, Enum)


{- Visual representation of client events where 2 players play on the same multiplayer game:

Legend:
------
  - @Ax@ = acceleration of ship x
  - @Lx@ = laser shot of ship x
  - @.@  = end of a game period

@
        >>> time >>>
 . . . A1 . . A1 A2 L2 L1 .
              ^^^^^ ^^^^^
              |     |
              |     laser shots can't be aggregated.
              |
              accelerations can be aggregated, their order within a period is unimportant.
@

The order in which L1 L2 are handled is the order in which they are received by the server.
This is /unfair/ to the players because one player (due to network delays) could have rendered the
last period 100ms before the other, thus having a noticeable advantage over the other player.
We could be more fair by keeping track of the perceived time on the player side:

in 'ClientAction' we could store the difference between the system time of the action
and the system time at which the last motion update was presented to the player.

Hence, to know how to order close laser shots, if the ships are on the same row or column,
the server should wait a little (max. 50 ms?) to see if the other player makes a
perceptually earlier shot.
-}
