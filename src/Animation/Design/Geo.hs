{-# LANGUAGE NoImplicitPrelude #-}

module Animation.Design.Geo
    ( gravityExplosionPure
    , simpleExplosionPure
    , quantitativeExplosionPure
    , animateNumberPure
    ) where

import           Imajuscule.Prelude

import           Data.List( length )

import           Animation.Types
import           Geo( Coords
                    , bresenham
                    , bresenhamLength
                    , Direction(..)
                    , mkSegment
                    , move
                    , polyExtremities
                    , rotateCcw
                    , translatedFullCircle
                    , translatedFullCircleFromQuarterArc
                    , parabola
                    , Vec2(..)
                    , pos2vec
                    , vec2coords )
import           Resample( resample )


gravityExplosionPure :: Vec2 -> Coords -> Frame -> [Coords]
gravityExplosionPure initialSpeed origin (Frame iteration) =
  let o = pos2vec origin
  in  [vec2coords $ parabola o initialSpeed iteration]

simpleExplosionPure :: Int -> Coords -> Frame -> [Coords]
simpleExplosionPure resolution center (Frame iteration) =
  let radius = fromIntegral iteration :: Float
      c = pos2vec center
  in map vec2coords $ translatedFullCircleFromQuarterArc c radius 0 resolution

quantitativeExplosionPure :: Int -> Coords -> Frame -> [Coords]
quantitativeExplosionPure number center (Frame iteration) =
  let numRand = 10 :: Int
      rnd = 2 :: Int -- TODO store the random number in the state of the animation
  -- rnd <- getStdRandom $ randomR (0,numRand-1)
      radius = fromIntegral iteration :: Float
      firstAngle = (fromIntegral rnd :: Float) * 2*pi / (fromIntegral numRand :: Float)
      c = pos2vec center
  in map vec2coords $ translatedFullCircle c radius firstAngle number

animateNumberPure :: Int -> Coords -> Frame -> [Coords]
animateNumberPure 1 = simpleExplosionPure 8
animateNumberPure 2 = rotatingBar Up
animateNumberPure n = polygon n

-- TODO make it rotate, like the name says :)
rotatingBar :: Direction -> Coords -> Frame -> [Coords]
rotatingBar dir first (Frame i) =
  let radius = animateRadius (assert (i > 0) i) 2
      centerBar = move i dir first
      orthoDir = rotateCcw 1 dir
      startBar = move radius orthoDir centerBar
      endBar = move (-radius) orthoDir centerBar
  in  connect2 startBar endBar

polygon :: Int -> Coords -> Frame -> [Coords]
polygon  nSides center (Frame i) =
  let startAngle = if odd nSides then pi else pi/4.0
      radius = animateRadius (1 + quot i 2) nSides
      extremities = polyExtremities nSides center radius startAngle
  in if radius <= 0
       then
         []
       else
         connect extremities

animateRadius :: Int -> Int -> Int
animateRadius i nSides =
  let limit
          | nSides <= 4 = 5
          | nSides <= 6 = 7
          | otherwise   = 10
  in if i < limit
       then
         i
       else
         max 0 (2 * limit - i)

connect :: [Coords] -> [Coords]
connect []  = []
connect l@[_] = l
connect (a:rest@(b:_)) = connect2 a b ++ connect rest

connect2 :: Coords -> Coords -> [Coords]
connect2 start end =
  let numpoints = 80 -- more than 2 * (max height width of world) to avoid spaces
  in sampledBresenham numpoints start end

sampledBresenham :: Int -> Coords -> Coords -> [Coords]
sampledBresenham nSamples start end =
  let l = bresenhamLength start end
      seg = mkSegment start end
      bres = bresenham seg
  in resample bres (assert (l == length bres) l) nSamples
