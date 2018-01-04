{-# OPTIONS_HADDOCK hide #-}

{-# LANGUAGE NoImplicitPrelude #-}

module Imj.Game.Hamazed.World.Number(
    getColliding
  , computeActualLaserShot
  , destroyedNumbersAnimations
  ) where

import           Imj.Prelude

import           Data.Char( intToDigit )

import           Imj.Game.Hamazed.Loop.Event
import           Imj.Game.Hamazed.World.Space.Types
import           Imj.GameItem.Weapon.Laser
import           Imj.Geo.Continuous
import           Imj.Geo.Discrete
import           Imj.Graphics.Animation

getColliding :: Coords Pos -> [Number] -> [Number]
getColliding pos =
  filter (\(Number (PosSpeed pos' _) _) -> pos == pos')

destroyedNumbersAnimations :: Either SystemTime KeyTime
                           -> Direction -- ^ 'Direction' of the laser shot
                           -> World -- ^ the 'World' the 'Number's live in
                           -> [Number]
                           -> [Animation]
destroyedNumbersAnimations keyTime dir world =
  let laserSpeed = speed2vec $ coordsForDirection dir
  in concatMap (destroyedNumberAnimations keyTime laserSpeed world)

destroyedNumberAnimations :: Either SystemTime KeyTime
                          -> Vec2 Vel
                          -> World
                          -> Number
                          -> [Animation]
destroyedNumberAnimations k laserSpeed world (Number (PosSpeed pos _) n) =
  let char = intToDigit n
      envFuncs = envFunctions world (WorldScope Air)
  in catMaybes [animatedPolygon n pos (Speed 1) k char]
     ++ fragmentsFreeFallThenExplode (scalarProd 0.8 laserSpeed) pos envFuncs (Speed 2) k char
