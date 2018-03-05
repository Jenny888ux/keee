{-# OPTIONS_HADDOCK hide #-}

{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}

module Imj.Game.Hamazed.KeysMaps
    ( eventFromKey
    ) where

import           Imj.Prelude

import qualified Data.Map as Map(lookup)

import           Imj.Game.Hamazed.Loop.Event.Types
import           Imj.Game.Hamazed.State.Types
import           Imj.Game.Hamazed.Network.Types
import           Imj.Game.Hamazed.Types
import           Imj.Geo.Discrete.Types
import           Imj.Input.Types

-- | Maps a 'Key' (pressed by the player) to an 'Event'.
eventFromKey :: (MonadState AppState m)
             => PlatformEvent
             -> m (Maybe GenEvent)
eventFromKey k = case k of
  Message msgLevel txt -> return $ Just $ Evt $ Log msgLevel txt
  StopProgram -> return $ Just $ Evt $ Interrupt Quit
  KeyPress key -> case key of
    Escape      -> return $ Just $ Evt $ Interrupt Quit
    Tab -> return $ Just $ Evt $ ChatCmd ToggleEditing
    _ -> getChatMode >>= \case
      Editing -> return $ case key of
        Delete     -> Just $ Evt $ ChatCmd DeleteAtEditingPosition
        BackSpace  -> Just $ Evt $ ChatCmd DeleteBeforeEditingPosition
        AlphaNum c -> Just $ Evt $ ChatCmd $ Insert c
        Arrow dir  -> Just $ Evt $ ChatCmd $ Navigate dir
        Enter      -> Just $ Evt SendChatMessage
        _ -> Nothing
      NotEditing -> case key of
        AlphaNum 'y' -> return $ Just $ Evt CycleRenderingOptions
        _ -> do
          (ClientState activity state) <- getClientState
          case activity of
            Over -> return Nothing
            Ongoing -> case state of
              Excluded -> return Nothing
              Setup -> return $ case key of
                AlphaNum ' ' -> Just $ CliEvt $ ExitedState Setup
                AlphaNum c   -> Just $ Evt $ Configuration c
                _ -> Nothing
              PlayLevel status -> case status of
                Running -> getLevelOutcome >>= return . maybe
                  (case key of
                    AlphaNum c -> case c of
                      'k' -> Just $ CliEvt $ Action Laser Down
                      'i' -> Just $ CliEvt $ Action Laser Up
                      'j' -> Just $ CliEvt $ Action Laser LEFT
                      'l' -> Just $ CliEvt $ Action Laser RIGHT
                      'd' -> Just $ CliEvt $ Action Ship Down
                      'e' -> Just $ CliEvt $ Action Ship Up
                      's' -> Just $ CliEvt $ Action Ship LEFT
                      'f' -> Just $ CliEvt $ Action Ship RIGHT
                      'r'-> Just $ Evt ToggleEventRecording
                      _   -> Nothing
                    _ -> Nothing)
                  (const Nothing)
                WhenAllPressedAKey _ (Just _) _ -> return Nothing
                WhenAllPressedAKey x Nothing havePressed ->
                  getMyShipId >>= maybe
                    (return Nothing)
                    (\me -> maybe (error "logic") (\iHavePressed ->
                            if iHavePressed
                              then return Nothing
                              else return $ Just $ Evt $ Continue x)
                              $ Map.lookup me havePressed)
                New -> return Nothing
                Paused _ _ -> return Nothing
                Countdown _ _ -> return Nothing
                OutcomeValidated _ -> return Nothing
                CancelledNoConnectedPlayer -> return Nothing
                WaitingForOthersToEndLevel _ -> return Nothing
