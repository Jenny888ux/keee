{-# OPTIONS_HADDOCK hide #-}

module Render.Delta.Cell
          ( Cell
          , mkCell
          -- ** Indexed cells
          , mkIndexedCell
          , expandIndexed
          , getIndex
          , expand
          ) where

import           Data.Bits(shiftL, shiftR, (.&.), (.|.))
import           Data.Char( chr, ord )
import           Data.Word( Word64, Word32, Word16, Word8 )

import           Color.Types
import           Render.Delta.Internal.Types
import           Render.Delta.Types


{-# INLINE firstWord8 #-}
firstWord8 :: Word64 -> Word8
firstWord8 w = fromIntegral $ w `shiftR` 56

{-# INLINE secondWord8 #-}
secondWord8 :: Word64 -> Word8
secondWord8 w = fromIntegral $ (w `shiftR` 48) .&. 0xFF

{-# INLINE secondWord16 #-}
secondWord16 :: Word64 -> Word16
secondWord16 w = fromIntegral $ (w `shiftR` 32) .&. 0xFFFF

{-# INLINE secondWord32 #-}
secondWord32 :: Word64 -> Word32
secondWord32 = fromIntegral

{-# INLINE getForegroundColor #-}
getForegroundColor :: Cell -> Color8 Foreground
getForegroundColor w = Color8 $ secondWord8 w

{-# INLINE getBackgroundColor #-}
getBackgroundColor :: Cell -> Color8 Background
getBackgroundColor w = Color8 $ firstWord8 w

{-# INLINE getCharacter #-}
getCharacter :: Cell -> Char
getCharacter w = chr $ fromIntegral $ secondWord32 w

-- Works only if the 'Cell' was created using mkIndexedCell,
-- else 0 is returned.
{-# INLINE getIndex #-}
getIndex :: Cell -> Dim Index
getIndex w = fromIntegral $ secondWord16 w

{-# INLINE expand #-}
expand :: Cell
       -> (Color8 Background, Color8 Foreground, Char)
expand w = (getBackgroundColor w
           ,getForegroundColor w
           ,getCharacter w)

{-# INLINE expandIndexed #-}
expandIndexed :: Cell
              -> (Color8 Background, Color8 Foreground, Dim Index, Char)
expandIndexed w =
  (getBackgroundColor w
  ,getForegroundColor w
  ,getIndex w
  ,getCharacter w)

{-# INLINE encodeColors #-}
encodeColors :: LayeredColor -> Word16
encodeColors (LayeredColor (Color8 bg') (Color8 fg')) =
  let fg = fromIntegral fg' :: Word16
      bg = fromIntegral bg' :: Word16
  in (bg `shiftL` 8) .|. fg

-- The memory layout is such that when sorted with 'compare', the order of
-- importance of fields is (by decreasing importance) :
--     backgroundColor (8 bits)
--     foregroundColor (8 bits)
--     index in buffer (16 bits)
--     character       (32 bits)
{-# INLINE mkIndexedCell #-}
mkIndexedCell :: Cell -> Dim Index -> Cell
mkIndexedCell cell idx' =
  cell .|. (idx `shiftL` 32)
 where
  idx = fromIntegral idx'

{-# INLINE mkCell #-}
mkCell :: LayeredColor -> Char -> Cell
mkCell colors char' =
  let color = fromIntegral $ encodeColors colors
      char = fromIntegral $ ord char'
  in (color `shiftL` 48) .|. char