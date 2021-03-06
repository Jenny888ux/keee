{-# OPTIONS_HADDOCK hide #-}

{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Imj.Graphics.Interpolation.SequentiallyInterpolatedList(
         SequentiallyInterpolatedList(..)
       ) where

import           Imj.Prelude

import           Data.List(length, mapAccumL)

import           Imj.Graphics.Class.DiscreteInterpolation
import           Imj.Graphics.Class.Positionable
import           Imj.Util

-- | A 'List'-like type to interpolate sequentially (one index at a time) between same-index elements.
newtype SequentiallyInterpolatedList a =
  SequentiallyInterpolatedList [a]
  deriving(Eq, Ord, Show, PrettyVal, Generic)
instance Functor SequentiallyInterpolatedList where
  fmap f (SequentiallyInterpolatedList l) = SequentiallyInterpolatedList $ fmap f l
  {-# INLINE fmap #-}
instance (GeoTransform a) => GeoTransform (SequentiallyInterpolatedList a) where
  transform f = fmap (transform f)
  {-# INLINE transform #-}

-- | Interpolation between 2 'SequentiallyInterpolatedList', occuring sequentially
--   i.e interpolating between one pair of same-index elements at a time, starting with
-- 0 index and increasing.
--   Prerequisite : lists have the same lengths.
instance (DiscreteDistance a)
      => DiscreteDistance (SequentiallyInterpolatedList a) where
  distance (SequentiallyInterpolatedList l) (SequentiallyInterpolatedList l') =
    succ $ sum $ zipWith (\x y -> pred $ distance x y) l (assert (length l' == length l) l')

-- | Interpolation between 2 'SequentiallyInterpolatedList', occuring sequentially
--   i.e interpolating between one pair of same-index elements at a time, starting with
-- 0 index and increasing.
--   Prerequisite : lists have the same lengths.
instance (DiscreteInterpolation a)
      => DiscreteInterpolation (SequentiallyInterpolatedList a) where
  interpolate (SequentiallyInterpolatedList l) (SequentiallyInterpolatedList l') progress =
    SequentiallyInterpolatedList $ snd $
      mapAccumL
        (\acc (e,e') ->
          let d = pred $ distance e e'
              r = interpolate e e' $ clamp acc 0 d
          in (acc-d, r))
        progress
        $ zip l (assert (length l' == length l) l')
