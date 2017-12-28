{-# OPTIONS_HADDOCK hide #-}

{-# LANGUAGE NoImplicitPrelude #-}

module Imj.Game.Hamazed.World.Number(
    getColliding
  , computeActualLaserShot
  , destroyedNumbersAnimations
  ) where

import           Imj.Prelude

import           Data.Char( intToDigit )

import           Imj.Game.Hamazed.World.Types
import           Imj.Game.Hamazed.Event
import           Imj.GameItem.Weapon.Laser
import           Imj.Geo.Continuous
import           Imj.Geo.Discrete
import           Imj.Graphics.Animation
import           Imj.Timing

getColliding :: Coords Pos -> [Number] -> [Number]
getColliding pos = filter (\(Number (PosSpeed pos' _) _) -> pos == pos')

destroyedNumbersAnimations :: KeyTime
                           -> Event
                           -> [Number]
                           -> [BoundedAnimation]
destroyedNumbersAnimations keyTime event =
  let laserSpeed = case event of
        (Action Laser dir) -> speed2vec $ coordsForDirection dir
        _                  -> Vec2 0 0
  in concatMap (destroyedNumberAnimations keyTime laserSpeed)

destroyedNumberAnimations :: KeyTime
                          -> Vec2 Vel
                          -> Number
                          -> [BoundedAnimation]
destroyedNumberAnimations keyTime laserSpeed (Number (PosSpeed pos _) n) =
  let char = intToDigit n
  in map (`BoundedAnimation` WorldFrame)
        $ animatedPolygon n pos keyTime (Speed 1) char
        : fragmentsFreeFallThenExplode (scalarProd 0.8 laserSpeed) pos keyTime (Speed 2) char