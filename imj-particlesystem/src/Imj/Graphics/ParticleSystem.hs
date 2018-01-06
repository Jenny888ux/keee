{-# LANGUAGE NoImplicitPrelude #-}

module Imj.Graphics.ParticleSystem
    (
    -- * Principal types
      {- | A 'ParticleSystem' handles 'Particle's living in a 'ParticleTree'.-}
      ParticleSystem(..)
    , ParticleTree(..)
    , Particle(..)
    -- * Particle functions
    {- | 'Particle's are produced by /particle functions/ which should enforce the following rules:

      * For every 'Frame', they produce a constant number of 'Particle's, and
      same-index 'Particle's are correlated,
      * until they (maybe) produce 0 'Particle' to indicate the end of the production. -}
    , particles
    , particlesFreefall
    , particlesExplosion
    , particlesPolygonExpandShrink
    , particlesLaser
     -- * ParticleSystem
      -- ** Create
    , mkSystem
    -- ** Update
      {- | During 'ParticleSystem' update, 'Particle's can interact
      ('CanInteract') with their environment, or be removed from the 'ParticleSystem'
       if they are too far away ('TooFar'). -}
    , EnvFunctions(..)
    , CanInteract(..)
    , InteractionResult(..)
    , Distance(..)
    , getDeadline
    , shouldUpdate
    , updateParticleSystem
    -- ** Render
    , drawSystem
    -- * Predefined ParticleSystems
    -- ** Explosive
    , simpleExplosion
    , quantitativeExplosionThenSimpleExplosion
    -- ** Free fall
    {- | 'freeFall' simulates the effect of gravity on an object that has an initial speed.

    'freeFallThenExplode' adds an explosion when the falling object hits the environment
     (ie when the 'InteractionResult' of an interaction between the object and
     the environment is 'Mutation').
    -}
    , freeFall
    , freeFallWithReboundsThenExplode
    , freeFallThenExplode
    -- ** Fragments
    {- | 'fragmentsFreeFall' gives the impression that the object disintegrated in multiple
    pieces before falling.

    'fragmentsFreeFallThenExplode' adds an explosion when the falling object is
    mutated by the environment.

    'fragmentsFreeFallWithReboundsThenExplode' adds rebounds before the final explosion.
    -}
    , fragmentsFreeFall
    , fragmentsFreeFallThenExplode
    , fragmentsFreeFallWithReboundsThenExplode
    -- ** Geometric
    , expandShrinkPolygon
    , laserShot
    -- ** Nice chars
    {-| 'niceChar' presents a list of 'Char's that /look good/
    when used in explosive and free fall particle systems. -}
    , niceChar
    -- * Internal
    , module Imj.Graphics.ParticleSystem.Internal
    -- * Reexports
    , module Imj.Timing
    , module Imj.Iteration
    , Coords
    ) where

import           Imj.Prelude

import           Imj.GameItem.Weapon.Laser.Types
import           Imj.Geo.Continuous
import           Imj.Geo.Discrete
import           Imj.Graphics.ParticleSystem.Chars
import           Imj.Graphics.ParticleSystem.Design.Create
import           Imj.Graphics.ParticleSystem.Design.Color
import           Imj.Graphics.ParticleSystem.Design.Draw
import           Imj.Graphics.ParticleSystem.Design.Timing
import           Imj.Graphics.ParticleSystem.Design.Types
import           Imj.Graphics.ParticleSystem.Design.Update
import           Imj.Graphics.ParticleSystem.Geo
import           Imj.Graphics.ParticleSystem.Internal
import           Imj.Graphics.Color
import           Imj.Iteration
import           Imj.Physics.Continuous.Types
import           Imj.Timing

defaultColors :: Frame -> LayeredColor
defaultColors = onBlack . colorFromFrame (rgb 4 0 0)

-- | Creates a 'ParticleSystem' representing a laser ray with a fade-out effect.
laserShot :: LaserRay Actual
          -- ^ The laser ray
          -> Either SystemTime KeyTime
          -- ^ 'Right' 'KeyTime' of the event's deadline
          -- that triggered this call, or 'Left' 'SystemTime'
          -- of the current time if a player action triggered this call
          -> Maybe ParticleSystem
laserShot ray@(LaserRay _ start len) keyTime
  | len == 0  = Nothing
  | otherwise = mkSystem posspeed [particlesLaser ray defaultColors] (Speed 1) envFunctions keyTime
 where
  -- speed doesn't matter to 'particlesLaser'
  posspeed = mkStaticVecPosSpeed $ pos2vec start
  envFunctions = EnvFunctions (const Stable) (const DistanceOK)

-- | Creates a 'ParticleSystem' chaining two circular explosions, the first explosion
-- can be configured in number of particles, the second has 32 particles.
quantitativeExplosionThenSimpleExplosion :: Int
                                         -- ^ Number of particles in the first explosion
                                         -> Coords Pos
                                         -- ^ Center of the first explosion
                                         -> Char
                                         -- ^ Character used when drawing the 'Particle'.
                                         -> Speed
                                         -- ^ ParticleSystem speed
                                         -> EnvFunctions
                                         -> Either SystemTime KeyTime
                                         -- ^ 'Right' 'KeyTime' of the event's deadline
                                         -- that triggered this call, or 'Left' 'SystemTime'
                                         -- of the current time if a player action triggered this call
                                         -> Maybe ParticleSystem
quantitativeExplosionThenSimpleExplosion num pos char =
  let firstAngle = 2*pi / 5
      funcs = [ particles (explosion num firstAngle) zeroForceMotion Interact char defaultColors
              , particles (explosion 32 0) zeroForceMotion Interact char defaultColors]
       -- speed doesn't matter to 'particlesExplosionByCircle' and 'particlesExplosionByQuartArcs':
      posspeed = mkStaticVecPosSpeed $ pos2vec pos
  in mkSystem posspeed funcs

-- | Creates a 'ParticleSystem' where a geometric figure (polygon or circle) expands then shrinks,
-- and doesn't interact with the environment.
expandShrinkPolygon :: Int
                    -- ^ If n==1, the geometric figure is a circle, else if n>1, a n-sided polygon
                    -> Coords Pos
                    -- ^ Center of the polygon (or circle)
                    -> Speed
                    -> EnvFunctions
                    -- ^ ParticleSystem speed
                    -> Either SystemTime KeyTime
                    -- ^ 'Right' 'KeyTime' of the event's deadline
                    -- that triggered this call, or 'Left' 'SystemTime'
                    -- of the current time if a player action triggered this call
                    -> Maybe ParticleSystem
expandShrinkPolygon n pos =
  mkSystem posspeed funcs
 where
  -- speed doesn't matter to 'particlesPolygonExpandShrink'
  posspeed = mkStaticVecPosSpeed $ pos2vec pos
  funcs = [particlesPolygonExpandShrink n defaultColors]

-- | A circular explosion configurable in number of particles
simpleExplosion :: Int
                -- ^ Number of particles in the explosion
                -> Coords Pos
                -- ^ Center of the explosion
                -> Char
                -- ^ Character used when drawing the 'Particle'.
                -> Speed
                -- ^ ParticleSystem speed
                -> EnvFunctions
                -> Either SystemTime KeyTime
                -- ^ 'Right' 'KeyTime' of the event's deadline
                -- that triggered this call, or 'Left' 'SystemTime'
                -- of the current time if a player action triggered this call
                -> Maybe ParticleSystem
simpleExplosion resolution pos char =
  mkSystem posspeed funcs
 where
  -- speed doesn't matter to 'simpleExplosion'
  posspeed = mkStaticVecPosSpeed $ pos2vec pos
  funcs = [particles (explosion resolution 0) zeroForceMotion Interact char defaultColors]

-- | ParticleSystem representing an object with an initial velocity disintegrating in
-- 4 different parts.
fragmentsFreeFall :: Vec2 Vel
                  -- ^ Initial speed
                  -> Coords Pos
                  -- ^ Initial position
                  -> Char
                  -- ^ Character used when drawing the 'Particle'.
                  -> Speed
                  -- ^ ParticleSystem speed
                  -> EnvFunctions
                  -> Either SystemTime KeyTime
                  -- ^ 'Right' 'KeyTime' of the event's deadline
                  -- that triggered this call, or 'Left' 'SystemTime'
                  -- of the current time if a player action triggered this call
                  -> [ParticleSystem]
fragmentsFreeFall speed pos char animSpeed envFuncs keyTime =
  mapMaybe (\sp -> freeFall sp pos char animSpeed envFuncs keyTime) $ variations speed

-- | ParticleSystem representing an object with an initial velocity disintegrating in
-- 4 different parts and rebounding several times until it explodes.
fragmentsFreeFallWithReboundsThenExplode :: Vec2 Vel
                                         -- ^ Initial speed
                                         -> Coords Pos
                                         -- ^ Initial position
                                         -> Float
                                         -- ^ Rebound speed attenuation factor, expected to be strictly positive.
                                         -> Int
                                         -- ^ Number of rebounds
                                         -> (Int -> Int -> Frame -> LayeredColor)
                                         -- ^ fragment index -> particle function level -> relative frame -> color
                                         -> Char
                                         -- ^ Character used when drawing the 'Particle'.
                                         -> Speed
                                         -- ^ ParticleSystem speed
                                         -> EnvFunctions
                                         -> Either SystemTime KeyTime
                                         -- ^ 'Right' 'KeyTime' of the event's deadline
                                         -- that triggered this call, or 'Left' 'SystemTime'
                                         -- of the current time if a player action triggered this call
                                         -> [ParticleSystem]
fragmentsFreeFallWithReboundsThenExplode speed pos velAtt nRebounds colorFuncs char animSpeed envFuncs keyTime =
  if velAtt <= 0
    then
      error "velocity attenuation should be > 0"
    else
      mapMaybe
        (\(idx,sp) ->
            freeFallWithReboundsThenExplode
              sp pos velAtt nRebounds (colorFuncs idx) char animSpeed envFuncs keyTime)
        $ zip [0..] $ variations speed

-- | Creates a 'ParticleSystem' simulating a gravity-based free-falling 'Particle'.
freeFall :: Vec2 Vel
         -- ^ Initial speed
         -> Coords Pos
         -- ^ Initial position
         -> Char
         -- ^ Character used when drawing the 'Particle'.
         -> Speed
         -- ^ ParticleSystem speed
         -> EnvFunctions
         -> Either SystemTime KeyTime
         -- ^ 'Right' 'KeyTime' of the event's deadline
         -- that triggered this call, or 'Left' 'SystemTime'
         -- of the current time if a player action triggered this call
         -> Maybe ParticleSystem
freeFall speed pos char =
  mkSystem posspeed funcs
 where
  posspeed = VecPosSpeed (pos2vec pos) speed
  funcs = [particlesFreefall 1 Interact char defaultColors]

-- | Same as 'freeFall', with several rebounds and a final
-- explosion.
freeFallWithReboundsThenExplode :: Vec2 Vel
                                -- ^ Initial speed
                                -> Coords Pos
                                -- ^ Initial position
                                -> Float
                                -- ^ Velocity attenuation factor on rebound, expected to be strictly positive.
                                -> Int
                                -- ^ Number of rebounds
                                -> (Int -> Frame -> LayeredColor)
                                -- ^ (particle function level -> relative frame -> color)
                                -> Char
                                -- ^ Character used when drawing the 'Particle'.
                                -> Speed
                                -- ^ ParticleSystem speed
                                -> EnvFunctions
                                -> Either SystemTime KeyTime
                                -- ^ 'Right' 'KeyTime' of the event's deadline
                                -- that triggered this call, or 'Left' 'SystemTime'
                                -- of the current time if a player action triggered this call
                                -> Maybe ParticleSystem
freeFallWithReboundsThenExplode speed pos velAtt nRebounds colorFuncs char =
  if velAtt <= 0
    then
      error "velocity attenuation should be > 0"
    else
      mkSystem posspeed funcs
 where
  posspeed = VecPosSpeed (pos2vec pos) $ scalarProd (recip velAtt) speed
  nFragments = 16
  funcs = map (particlesFreefall velAtt Interact char . colorFuncs) [0..pred nRebounds]
          ++ [particles (explosion nFragments (pi/16)) gravityMotion Interact char (colorFuncs nRebounds)]

-- | Creates a 'ParticleSystem' representing an object with an initial velocity disintegrating in
-- 4 different 'Particle's free-falling and then exploding.
fragmentsFreeFallThenExplode :: Vec2 Vel
                             -- ^ Initial speed
                             -> Coords Pos
                             -- ^ Initial position
                             -> Char
                             -- ^ Character used when drawing the 'Particle'.
                             -> Speed
                             -- ^ ParticleSystem speed
                             -> EnvFunctions
                             -> Either SystemTime KeyTime
                             -- ^ 'Right' 'KeyTime' of the event's deadline
                             -- that triggered this call, or 'Left' 'SystemTime'
                             -- of the current time if a player action triggered this call
                             -> [ParticleSystem]
fragmentsFreeFallThenExplode speed pos c s envFuncs k =
  mapMaybe (\sp -> freeFallThenExplode sp pos c s envFuncs k) $ variations speed

-- | Given an input speed, computes four slightly different input speeds
variations :: Vec2 Vel -> [Vec2 Vel]
variations sp =
  map (sumVec2d sp) [ Vec2 0.12     (-0.16)
                    , Vec2 (-0.22) (-0.116)
                    , Vec2 (-0.04)  0.36
                    , Vec2 0.48     0.08]

-- | Creates a 'ParticleSystem' by chaining a gravity-based free-fall and a
-- circular explosion of 32 particles.
freeFallThenExplode :: Vec2 Vel
                    -- ^ Initial speed
                    -> Coords Pos
                    -- ^ Initial position
                    -> Char
                    -- ^ Character used when drawing the 'Particle'.
                    -> Speed
                    -- ^ ParticleSystem speed
                    -> EnvFunctions
                    -> Either SystemTime KeyTime
                    -- ^ 'Right' 'KeyTime' of the event's deadline
                    -- that triggered this call, or 'Left' 'SystemTime'
                    -- of the current time if a player action triggered this call
                    -> Maybe ParticleSystem
freeFallThenExplode speed pos char =
  let funcs = [ particlesFreefall 1.0 Interact char defaultColors
              , particles (explosion 32 0) zeroForceMotion Interact char defaultColors]
  in mkSystem (VecPosSpeed (pos2vec pos) speed) funcs