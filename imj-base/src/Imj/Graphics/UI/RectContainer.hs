{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE LambdaCase #-}

module Imj.Graphics.UI.RectContainer
        (
          -- * RectContainer
          {- | 'RectContainer' Represents a rectangular UI container. It
          contains the 'Size' of its /content/, and an upper left coordinate. -}
          RectContainer(..)
        , getSideCentersAtDistance
        ) where

import           Imj.Prelude

import           Data.List( mapAccumL, zip )
import           Control.Monad.IO.Class(MonadIO)
import           Control.Monad.Reader.Class(MonadReader)

import           Imj.Graphics.Draw
import           Imj.Geo.Discrete
import           Imj.Graphics.Interpolation
import           Imj.Graphics.UI.RectContainer.InterpolateParallel4

{-|

@
r----------------------------+
| u--+                       |
| |//|                       |
| |//|                       |
| +--l                       |
|                            |
+----------------------------+

r = Terminal origin, at (0,0)
/ = RectContainer's content, of size (2,2)
u = RectContainer's upper left corner, at (2,1)
l = RectContainer's lower left corner, at (5,4)
@
-}
data RectContainer = RectContainer {
    _rectFrameContentSize :: !Size
    -- ^ /Content/ size.
  , _rectFrameUpperLeft :: !(Coords Pos)
    -- ^ Upper left corner.
  , _rectFrameColors :: !LayeredColor
    -- ^ Foreground and background colors
} deriving(Eq, Show)


-- | Smoothly transforms the 4 sides of the rectangle simultaneously, from their middle
-- to their extremities.
instance DiscretelyInterpolable RectContainer where
  distance (RectContainer s  _ _ )
           (RectContainer s' _ _ ) -- TODO animate colors too
    | s == s'   = 1 -- no animation because sizes are equal
    | otherwise = 1 + quot (1 + max (maxLength s) (maxLength s')) 2

  {-# INLINABLE interpolateIO #-}
  interpolateIO from to frame
    | frame <= 0         = renderWhole from
    | frame >= lastFrame = renderWhole to
    | otherwise          = renderRectFrameInterpolation from to lastFrame frame
    where
      lastFrame = pred $ distance from to

{-# INLINABLE renderWhole #-}
renderWhole :: (Draw e, MonadReader e m, MonadIO m)
            => RectContainer
            -> m ()
renderWhole (RectContainer sz upperLeft color) =
  renderPartialRectContainer sz color (upperLeft, 0, countRectContainerChars sz - 1)

{-# INLINABLE renderRectFrameInterpolation #-}
renderRectFrameInterpolation :: (Draw e, MonadReader e m, MonadIO m)
                             => RectContainer
                             -> RectContainer
                             -> Int
                             -> Int
                             -> m ()
renderRectFrameInterpolation rf1@(RectContainer sz1 upperLeft1 _)
                 rf2@(RectContainer sz2 upperLeft2 _) lastFrame frame = do
  let (Coords _ (Coord dc)) = diffCoords upperLeft1 upperLeft2
      render di1 di2 = do
        let fromRanges = ranges (lastFrame-(frame+di1)) sz1 Extremities
            toRanges   = ranges (lastFrame-(frame+di2)) sz2 Middle
        mapM_ (renderRectFrameRange rf1) fromRanges
        mapM_ (renderRectFrameRange rf2) toRanges
  if dc >= 0
    then
      -- expanding animation
      render dc 0
    else
      -- shrinking animation
      render 0 (negate dc)


{-# INLINABLE renderRectFrameRange #-}
renderRectFrameRange :: (Draw e, MonadReader e m, MonadIO m)
                     => RectContainer
                     -> (Int, Int)
                     -> m ()
renderRectFrameRange (RectContainer sz r color) (min_, max_) =
  renderPartialRectContainer sz color (r, min_, max_)


data BuildFrom = Middle
               | Extremities -- generates the complement

ranges :: Int
       -- ^ Progress of the interpolation
       -> Size
       -- ^ Size of the content, /not/ the container
       -> BuildFrom
       -- ^ The building strategy
       -> [(Int, Int)]
ranges progress sz =
  let h = countRectContainerVerticalChars sz
      w = countRectContainerHorizontalChars sz

      diff = quot (w - h) 2 -- vertical and horizontal animations should start at the same time

      extW = rangeByRemovingFromTotal progress w
      extH = rangeByRemovingFromTotal (max 0 $ progress-diff) h

      exts = [extW, extH, extW, extH]
      lengths = [w,h,w,h]

      (total, starts) = mapAccumL (\acc v -> (acc + v, acc)) 0 lengths
      res = map (\(ext, s) -> ext s) $ zip exts starts
  in \case
        Middle      -> res
        Extremities -> complement 0 (total-1) res

complement :: Int -> Int -> [(Int, Int)] -> [(Int, Int)]
complement a max_ []          = [(a, max_)]
complement a max_ l@((b,c):_) = (a, pred b) : complement (succ c) max_ (tail l)

rangeByRemovingFromTotal :: Int -> Int -> Int -> (Int, Int)
rangeByRemovingFromTotal remove total start =
  let min_ = remove
      max_ = total - 1 - remove
  in (start + min_, start + max_)


-- TODO split : function to make the container at a distance, and function to take the centers.
{- | Returns points centered on the sides of a container which is at a given distance
from the reference container.

[container at a distance from another container]
In this illustration, @cont'@ is at distance 3 from @cont@:

@
    cont'
    +--------+..-
    |        |  |  dy = 3
    |  cont  |  |
    |  +--+..|..-
    |  |  |  |
    |  |  |  |
    |  +--+  |
    |  .     |
    |  .     |
    +--------+
    .  .
    .  .
   >|--|<
    dx = 3
@

[Favored direction for centers of horizontal sides]
When computing the /center/ of an horizontal side, if the side has an /even/ length,
we must favor a 'Direction'.
(Note that if the side has an /odd/ length, there is no ambiguity.)

In 'Text.Alignment.align' implementation, 'Text.Alignment.Centered' alignment
favors the 'RIGHT' 'Direction':

@
   1
   12
  123
  1234
   ^
@


* If we, too, favor the 'RIGHT' 'Direction', when the returned point is used as
reference for a 'Centered' alignment, the text will tend to be too far to the 'RIGHT',
as illustrated here (@^@ indicates the chosen center):

@
   1
 +--+
   12
 +--+
  123
 +--+
  1234
 +--+
   ^
@

* So we will favor the 'LEFT' 'Direction', to counterbalance the choice made in
'Text.Alignment.align' 's implementation:

@
  1
 +--+
  12
 +--+
 123
 +--+
 1234
 +--+
  ^
@
-}
getSideCentersAtDistance :: RectContainer
                         -- ^ Reference container
                         -> Int
                         -- ^ A distance
                         -> (Coords Pos, Coords Pos, Coords Pos)
                         -- ^ (center Up, center Down, center Left)
getSideCentersAtDistance (RectContainer (Size rs' cs') upperLeft' _) dist =
  (centerUp, centerDown, leftMiddle)
 where
  deltaLength =
    2 *    -- in both directions
      (1 +   -- from inner content to outer container
       dist) -- from container to container'
  rs = rs' + fromIntegral deltaLength
  cs = cs' + fromIntegral deltaLength
  upperLeft = translate' (fromIntegral $ -dist) (fromIntegral $ -dist) upperLeft'

  cHalf = quot (cs-1) 2 -- favors 'LEFT' 'Direction', see haddock comments.
  rHalf = quot (rs-1) 2 -- favors 'Up' 'Direction'
  rFull = rs-1

  centerUp   = translate' 0     cHalf upperLeft
  centerDown = translate' rFull cHalf upperLeft
  leftMiddle = translate' rHalf 0     upperLeft