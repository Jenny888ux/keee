{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE BangPatterns #-}

{- | A 'ColoredGlyphList' is a colored string, with the notion of font.-}

module Imj.Graphics.Text.ColoredGlyphList
            (
            -- * Type
              ColoredGlyphList(..)
            -- * Constructors
            , colored
            , colored'
            , concat
            , intercalate
            -- * Utilities
            , take
            -- * Reexports
            , LayeredColor(..)
            , IsString(..)
            ) where

import           Imj.Prelude

import           Control.Monad.Reader.Class(asks)
import           Data.String(IsString(..))
import qualified Data.List as List(length, take, splitAt, break, dropWhile, intercalate)

import           Imj.Geo.Discrete.Types
import           Imj.Graphics.Color.Types

import           Imj.Graphics.Class.DiscreteInterpolation
import           Imj.Graphics.Class.Draw
import           Imj.Graphics.Class.Positionable
import           Imj.Graphics.Class.Words
import           Imj.Graphics.Font
import           Imj.Graphics.Text.ColorString.Interpolation

newtype ColoredGlyphList = ColoredGlyphList [(Glyph, LayeredColor)]
  deriving(Show, Generic)
-- we can't use the Generic one because of missing instance for 'Text'
instance PrettyVal ColoredGlyphList where
  prettyVal (ColoredGlyphList l) = prettyVal $ map (fst . decodeGlyph . fst) l
instance IsString ColoredGlyphList where
  fromString str =
    let !color = whiteOnBlack
    in ColoredGlyphList $ map (\c -> (textGlyph c, color)) str
instance Semigroup ColoredGlyphList where
  (ColoredGlyphList x) <> (ColoredGlyphList y) = ColoredGlyphList $ x ++ y
instance Monoid ColoredGlyphList where
  mempty = ColoredGlyphList []
  mappend = (<>)
instance Characters ColoredGlyphList where
  length (ColoredGlyphList l) = List.length l
  empty (ColoredGlyphList l) = null l

  cons c (ColoredGlyphList l) = ColoredGlyphList $ (textGlyph c, whiteOnBlack):l

  intercalate (ColoredGlyphList i) =
    ColoredGlyphList . List.intercalate i . map (\(ColoredGlyphList s) -> s)

  take n (ColoredGlyphList l) =
    ColoredGlyphList $ List.take n l

  splitAt idx (ColoredGlyphList l) =
    (ColoredGlyphList left
   , ColoredGlyphList right)
    where
      (left,right) = List.splitAt idx l

  concat = ColoredGlyphList . concatMap (\(ColoredGlyphList s) -> s)

  unwords = intercalate (ColoredGlyphList [(sp, color)])
   where
    !sp = textGlyph ' '
    !color = whiteOnBlack

  words (ColoredGlyphList str) =
    map ColoredGlyphList $ go str
   where
    isSpace = (' ' ==) . fst . decodeGlyph . fst
    go s = case List.dropWhile isSpace s of
            [] -> []
            s' -> w : go s''
              where
                (w, s'') = List.break isSpace s'

  colorize color (ColoredGlyphList l) =
    ColoredGlyphList $ map (\(t, _) -> (t, color)) l

  drawOnPath positions (ColoredGlyphList l) = do
    d <- asks drawGlyph'
    zipWithM_ (\pos (glyph, color) -> d glyph pos color) positions l
  {-# INLINABLE drawOnPath #-}
  {-# INLINABLE splitAt #-}
  {-# INLINABLE concat #-}
  {-# INLINABLE intercalate #-}
  {-# INLINABLE take #-}
  {-# INLINABLE cons #-}
  {-# INLINABLE empty #-}
  {-# INLINABLE length #-}
  {-# INLINABLE words #-}
  {-# INLINABLE unwords #-}
-- | First interpolating characters, then color.
instance DiscreteDistance ColoredGlyphList where
  distance (ColoredGlyphList s1) (ColoredGlyphList s2) =
    let colorDist (_, color) (_, color') = distance color color'
        n1 = List.length s1
        n2 = List.length s2

        (c1', remaining) = interpolateChars s1 s2 countTextChanges
        s1' = assert (remaining == 0) c1'
        l = zipWith colorDist s1' s2 -- since color interpolation happens AFTER char changes,
                                     -- we compare colors with result of char interpolation
        colorDistance = fromMaybe 1 $ maximumMaybe l

        str1 = map fst s1
        str2 = map fst s2
        lPref = List.length $ commonPrefix str1 str2
        lSuff = List.length $ commonSuffix (drop lPref str1) (drop lPref str2)
        countTextChanges = max n1 n2 - (lPref + lSuff)
    in colorDistance + countTextChanges

-- | First interpolating characters, then color.
instance DiscreteInterpolation ColoredGlyphList where
  interpolate (ColoredGlyphList s1) (ColoredGlyphList s2) i =
    let (s1', remaining) = interpolateChars s1 s2 i
    in ColoredGlyphList $
        if remaining >= 0
          then
            s1'
          else
            interpolateColors s1' s2 (negate remaining)
instance Positionable ColoredGlyphList where
  drawAt s pos =
    drawOnPath (map (\n -> move n RIGHT pos) [0..]) s
  width = fromIntegral . length
  height _ = 1
  {-# INLINABLE drawAt #-}
  {-# INLINABLE width #-}
  {-# INLINABLE height #-}


colored' :: [Glyph] -> LayeredColor -> ColoredGlyphList
colored' l color =
  ColoredGlyphList $ map (\c -> (c,color)) l

colored :: [Glyph] -> Color8 Foreground -> ColoredGlyphList
colored t c = colored' t $ onBlack c
