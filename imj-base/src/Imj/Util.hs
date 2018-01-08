{-# LANGUAGE NoImplicitPrelude #-}

module Imj.Util
    ( -- * List utilities
      showListOrSingleton
    , replicateElements
    , range
    , takeWhileInclusive
      -- * String utilities
    , multiLine
    , commonPrefix
    , commonSuffix
      -- * Math utilities
    , randomRsIO
    , clamp
    , zigzag
      -- * Reexports
    , Int64
    ) where

import           Imj.Prelude
import           Prelude(length)

import           Data.Int(Int64)
import           Data.List(reverse)
import           Data.Text(Text, pack)

import           Control.Arrow( first )

import           System.Random( Random(..)
                              , getStdRandom
                              , split )


{-# INLINABLE showListOrSingleton #-}
-- | If list is a singleton, show the element, else show the list.
showListOrSingleton :: Show a => [a] -> Text
showListOrSingleton [e] = pack $ show e
showListOrSingleton l   = pack $ show l

{-# INLINE replicateElements #-}
-- | Replicates each list element n times and concatenates the result.
replicateElements :: Int -> [a] -> [a]
replicateElements n = concatMap (replicate n)

-- | Takes elements, until (inclusively) a condition is met.
takeWhileInclusive :: (a -> Bool) -> [a] -> [a]
takeWhileInclusive _ [] = []
takeWhileInclusive p (x:xs) =
  x : if p x
        then
          takeWhileInclusive p xs
        else
          []

{-# INLINABLE range #-}
{- | Builds a range with no constraint on the order of bounds:

@
range 3 5 == [3,4,5]
range 5 3 == [5,4,3]
@
-}
range :: Enum a => Ord a
      => a -- ^ First inclusive bound
      -> a -- ^ Second inclusive bound
      -> [a]
range n m =
  if m < n
    then
      [n,(pred n)..m]
    else
      [n..m]

-- | Produces an infinite triangle signal given a linear input.
{-# INLINABLE zigzag #-}
zigzag :: Integral a
       => a
       -- ^ Inclusive min
       -> a
       -- ^ Inclusive max
       -> a
       -- ^ Value
       -> a
zigzag from' to' v =
  let from = min from' to'
      to = max from' to'
      d = to-from
      v' = v `mod` (2*d)
  in from + if v' <= d
              then v'
              else
                2*d - v'

-- | Returns a list of random values uniformly distributed in the closed interval
-- [lo,hi].
--
-- It is unspecified what happens if lo>hi
randomRsIO :: Random a
           => a -- ^ lo : lower bound
           -> a -- ^ hi : upper bound
           -> IO [a]
randomRsIO from to =
  getStdRandom $ split >>> first (randomRs (from, to))

commonPrefix :: String -> String -> String
commonPrefix (x:xs) (y:ys)
    | x == y    = x : commonPrefix xs ys
commonPrefix _ _ = []

commonSuffix :: String -> String -> String
commonSuffix s s' = reverse $ commonPrefix (reverse s) (reverse s')

-- | Layouts a 'String' on multiple lines.
multiLine :: String
          -> Int
          -- ^ Maximum length of a line.
          -> [String]
multiLine str maxLineSize =
  map (unwords . reverse) $ reverse $ toMultiLine' (words str) 0 [] [[]]
 where
  toMultiLine' :: [String] -> Int -> [String] -> [[String]] -> [[String]]
  toMultiLine' [] _ []      curLines = curLines
  toMultiLine' [] _ curLine curLines = curLine : curLines
  toMultiLine' a@(x:xs) curLineSize curLine curLines =
    let l = length x
        sz = 1 + l + curLineSize
    in if sz > maxLineSize
        then
          toMultiLine' a 0 [] (curLine : curLines)
        else
          toMultiLine' xs sz (x:curLine) curLines

-- | Expects the bounds to be in the right order.
{-# INLINABLE clamp #-}
clamp :: Ord a
      => a
      -- ^ The value
      -> a
      -- ^ The inclusive minimum bound
      -> a
      -- ^ The inclusive maximum bound
      -> a
clamp n min_ max_
  | n < min_ = min_
  | n > max_ = max_
  | otherwise = n
