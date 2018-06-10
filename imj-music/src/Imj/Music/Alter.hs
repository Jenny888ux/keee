{-# LANGUAGE NoImplicitPrelude #-}

module Imj.Music.Alter
      (
      -- * alter VoiceInstruction
        transposeSymbol
      -- * combine [VoiceInstruction]
      , mixSymbols
      -- * alter Voice
      , mapVoice
      -- * alter Score
      , intersperse
      , intercalate
      , transpose
      , mute
      ) where

import           Imj.Prelude
import qualified Data.Vector as V

import qualified Data.List as List
import           Imj.Music.Types

mute :: [VoiceInstruction] -> [VoiceInstruction]
mute l = List.replicate (List.length l) Rest

mixSymbols :: [VoiceInstruction] -> [VoiceInstruction] -> [VoiceInstruction]
mixSymbols v1 v2 = concatMap (\(a,b) -> [a,b]) $ zip v1 v2

intercalateSymbols :: [VoiceInstruction] -> [VoiceInstruction] -> [VoiceInstruction]
intercalateSymbols s i = concatMap (\sy -> [sy] ++ i) s

mapVoice :: ([VoiceInstruction] -> [VoiceInstruction]) -> Voice -> Voice
mapVoice f v = v { voiceInstructions = V.fromList $ f $ V.toList $ voiceInstructions v }

transposeSymbol :: Int
                -- ^ Count of semi-tones
                -> VoiceInstruction
                -> VoiceInstruction
transposeSymbol s (Note n o) = uncurry Note $ midiPitchToNoteAndOctave (fromIntegral s + noteToMidiPitch' n o)
transposeSymbol _ Rest   = Rest
transposeSymbol _ Extend = Extend

intersperse :: VoiceInstruction -> Score -> Score
intersperse s (Score voices) =
  Score $
    map
      (mapVoice $ (\v ->
        mixSymbols v (repeat s)
        )) voices

intercalate :: [VoiceInstruction] -> Score -> Score
intercalate symbols (Score voices) =
  Score $
    map
      (mapVoice $ (\v ->
        intercalateSymbols v symbols
        )) voices

transpose :: Int -> Score -> Score
transpose n (Score voices) =
  Score $
    map
      (mapVoice $ map $ transposeSymbol n)
      voices
