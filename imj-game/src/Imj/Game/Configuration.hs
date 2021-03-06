{-# OPTIONS_HADDOCK hide #-}

{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE AllowAmbiguousTypes #-}

module Imj.Game.Configuration
      ( BackendType(..)
      , BackendTypeValue(..)
      , Debug(..)
      , ServerOnly(..)
      , WithAudio(..)
      ) where

import           Imj.Prelude
import           Data.Map.Strict((!))
import           Options.Applicative(long, help, flag)

import           Imj.Arg.Class
import           Imj.Audio
import           Imj.Game.Audio.Class
import           Imj.Game.Sound

data BackendType = BackendType {
    _fromCLI :: !Bool
  , _value :: BackendTypeValue
} deriving (Show)

data BackendTypeValue =
    Console
  | OpenGLWindow
  deriving (Show)

newtype Debug = Debug Bool
  deriving (Show)

newtype ServerOnly = ServerOnly Bool

newtype WithAudio = WithAudio Bool
  deriving (Show)
instance Audio WithAudio where
  withAudio (WithAudio yes) maxMidiJitter x
    | yes = do
        liftIO $ setMaxMIDIJitter maxMidiJitter
        usingAudioOutput x >>= either (fail . show) return
    | otherwise = x

  triggerLaserSound (WithAudio useAudio)
    | useAudio = liftIO $ void $ laserSound
    | otherwise = return ()

  playMusic (WithAudio useAudio) instrumentMap mus
    | useAudio = liftIO $ void $ play $ fmap ((!) instrumentMap) mus
    | otherwise = return ()

  -- WARNING when changing this, also change 'parseArg'
  defaultAudio = enabledAudio

  {-# INLINABLE triggerLaserSound #-}
  {-# INLINABLE defaultAudio #-}
  {-# INLINABLE playMusic #-}
  {-# INLINABLE withAudio #-}
instance Arg WithAudio where
  -- WARNING when changing this, also change 'defaultAudio'
  parseArg = Just $
    flag enabledAudio disabledAudio
      (  long "silent"
      <> help
      "[Client] disables music and audio effects."
      )

enabledAudio :: WithAudio
enabledAudio = WithAudio True

disabledAudio :: WithAudio
disabledAudio = WithAudio False
