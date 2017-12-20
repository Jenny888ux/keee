
{-# LANGUAGE NoImplicitPrelude #-}

module Game.Types
    ( GameState(..)
    -- * Reexports
    , module Game.World.Types
    , module Game.Level.Types
    , module Game.Timing
    ) where

import           Imajuscule.Prelude

import           Game.World.Types
import           Game.Level.Types

import           Game.Timing


data GameState m = GameState {
    _gameStateNextMotionStep :: !(Maybe KeyTime)
  , _gameStateWorld :: !(World m)
  , _gameStateNextWorld :: !(World m)
  , _gameStateShotNumbers :: ![Int]
  , _gameStateLevel :: !Level
  , _gameStateWorldAnimation :: !WorldAnimation
}