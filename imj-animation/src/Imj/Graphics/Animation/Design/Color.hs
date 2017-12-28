{-# OPTIONS_HADDOCK hide #-}

{-# LANGUAGE NoImplicitPrelude #-}

module Imj.Graphics.Animation.Design.Color
        ( colorFromFrame
        ) where

import           Imj.Prelude

import           Imj.Graphics.Color
import           Imj.Iteration

-- | Returns the color used to draw an animation, based on the frame number
-- (relative to the parent animation, if any).
colorFromFrame :: Frame -> LayeredColor
colorFromFrame (Frame f) = onBlack $ rgb r g b
  where
    r = assert (f >= 0) 4
    g = fromIntegral $ (0 + quot f 6) `mod` 2 -- [0..1] , slow changes
    b = fromIntegral $ (0 + quot f 3) `mod` 3 -- [0..2] , 2x faster changes