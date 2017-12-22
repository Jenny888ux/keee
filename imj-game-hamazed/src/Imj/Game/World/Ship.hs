{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE LambdaCase #-}

module Imj.Game.World.Ship
        ( shipAnims
        , createShipPos
        ) where

import           Imj.Prelude

import           Data.Char( intToDigit )
import           Data.List( foldl' )
import           Data.Maybe( isNothing )

import           Imj.Animation

import           Imj.Game.World.Space
import           Imj.Game.Event

import           Imj.Geo.Discrete
import           Imj.Geo.Conversion

-- | If the ship is colliding and not in "safe time", and the event is a gamestep,
--     this function creates an animation where the ship and the colliding number explode.
--
--   The ship animation will have the initial speed of the number and vice-versa,
--     to mimic the rebound due to the collision.
shipAnims :: (Draw e, MonadReader e m, MonadIO m)
          => BattleShip
          -> Event
          -> [BoundedAnimationUpdate m]
shipAnims (BattleShip (PosSpeed shipCoords shipSpeed) _ safeTime collisions) =
  \case
    Timeout GameStep k ->
      if not (null collisions) && isNothing safeTime
        then
          -- when number and ship explode, they exchange speeds
          let collidingNumbersSpeed = foldl' sumCoords zeroCoords $ map (\(Number (PosSpeed _ speed) _) -> speed) collisions
              (Number _ n) = head collisions
          in  map (`BoundedAnimationUpdate` WorldFrame) $
                  fragmentsFreeFallThenExplode (speed2vec collidingNumbersSpeed) shipCoords k (Speed 1) '|'
                  ++
                  fragmentsFreeFallThenExplode (speed2vec shipSpeed) shipCoords k (Speed 1) (intToDigit n)
        else
          []
    _ -> []


createShipPos :: Space -> [Number] -> IO PosSpeed
createShipPos space numbers = do
  let numPositions = map (\(Number (PosSpeed pos _) _) -> pos) numbers
  candidate@(PosSpeed pos _) <- createRandomPosSpeed space
  if pos `notElem` numPositions
    then
      return candidate
    else
      createShipPos space numbers