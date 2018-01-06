{-# OPTIONS_HADDOCK hide #-}

{-# LANGUAGE NoImplicitPrelude #-}

module Imj.Graphics.Animation.Design.Update
    ( shouldUpdate
    , updateAnimation
    , getDeadline
    ) where


import           Imj.Prelude

import           Data.Either(partitionEithers)

import           Imj.Graphics.Animation.Design.Types
import           Imj.Graphics.Animation.Design.Timing
import           Imj.Iteration
import           Imj.Timing


{- | Returns 'True' if the 'KeyTime' is beyond the 'Animation' deadline or if the
time difference is within 'animationUpdateMargin'. -}
shouldUpdate :: Animation
             -> KeyTime
             -- ^ The current 'KeyTime'
             -> Bool
shouldUpdate a (KeyTime k) =
  let (KeyTime k') = getDeadline a
  in diffSystemTime k' k < animationUpdateMargin

updateAnimation :: Animation
                -- ^ The current animation
                -> Maybe Animation
                -- ^ The updated animation, or Nothing if the 'Animation'
                -- is over.
updateAnimation
 (Animation points update interaction (UpdateSpec k it@(Iteration _ frame))) =
  let newPoints = update interaction frame points
      newUpdateSpec = UpdateSpec (addDuration animationPeriod k) (nextIteration it)
      newAnim = Animation newPoints update interaction newUpdateSpec
  in if isActive newAnim
       then
         Just newAnim
       else
         Nothing

isActive :: Animation
         -> Bool
isActive (Animation points _ _ _) =
  hasActivePoints points

hasActivePoints :: Particles
                -> Bool
hasActivePoints (Particles Nothing _ _)         = False
hasActivePoints (Particles (Just []) _ _)       = False
hasActivePoints (Particles (Just branches) _ _) =
  let (children, activeCoordinates) = partitionEithers branches
      childrenActive = map hasActivePoints children
  in (not . null) activeCoordinates || or childrenActive

-- | Returns the time at which an 'Animation' should be updated.
getDeadline :: Animation -> KeyTime
getDeadline (Animation _ _ _ (UpdateSpec k _)) = k
