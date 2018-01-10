{-# OPTIONS_HADDOCK hide #-}

{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

module Imj.Game.Hamazed.Parameters
      ( updateFromChar
      , draw'
      ) where

import           Imj.Prelude

import           Control.Monad.IO.Class(MonadIO)
import           Control.Monad.Reader.Class(MonadReader)

import           Imj.Game.Hamazed.Types
import           Imj.Game.Hamazed.Color
import           Imj.Game.Hamazed.World.Space
import           Imj.Geo.Discrete
import           Imj.Graphics.Class.Positionable
import           Imj.Graphics.Text.Alignment
import           Imj.Graphics.UI.Colored
import           Imj.Graphics.UI.RectContainer


updateFromChar :: Char -> GameParameters -> GameParameters
updateFromChar c p@(GameParameters shape wallType mode) =
  case c of
    '1' -> GameParameters Square wallType mode
    '2' -> GameParameters Rectangle2x1 wallType mode
    'e' -> GameParameters shape None mode
    'r' -> GameParameters shape Deterministic mode
    't' -> GameParameters shape (Random $ RandomParameters minRandomBlockSize StrictlyOneComponent) mode
    'd' -> GameParameters shape wallType CenterSpace
    'f' -> GameParameters shape wallType CenterShip
    _ -> p


{-# INLINABLE dText #-}
dText :: (Draw e, MonadReader e m, MonadIO m)
      => Text
      -> Coords Pos
      -> m (Coords Pos)
dText txt pos =
  drawTxt txt pos configColors >> return (translateInDir Down pos)

{-# INLINABLE dText_ #-}
dText_ :: (Draw e, MonadReader e m, MonadIO m)
       => Text
       -> Coords Pos
       -> m ()
dText_ txt pos =
  void (dText txt pos)

dTextAl :: (Render e, MonadReader e m, MonadIO m)
          => Text -> Alignment -> m Alignment
dTextAl txt = drawAligned (Colored configColors txt)

dTextAl_ :: (Render e, MonadReader e m, MonadIO m)
           => Text -> Alignment -> m ()
dTextAl_ a b = void $ dTextAl a b

{-# INLINABLE draw' #-}
draw' :: (Render e, MonadReader e m, MonadIO m)
      => GameState
      -> m ()
draw' (GameState _ _ (World _ _ _ _ (InTerminal _ _ sz)) _ _ _) = do
  let (topMiddle@(Coords _ c), bottomCenter, Coords r _, _) =
        getSideCenters $ mkRectContainerWithTotalArea sz
      left = move 12 LEFT (Coords r c)

  dTextAl "Game configuration" (mkCentered $ translateInDir Down topMiddle)
    >>= dTextAl_ "------------------"
  dTextAl_ "Hit 'Space' to start game" (mkCentered $ translateInDir Up bottomCenter)

  translateInDir Down <$> dText "- World shape" (move 5 Up left)
    >>= dText "'1' -> width = height"
    >>= dText_ "'2' -> width = 2 x height"
  translateInDir Down <$> dText "- World walls" left
    >>= dText "'e' -> No walls"
    >>= dText "'r' -> Deterministic walls"
    >>= dText "'t' -> Random walls"
    >>= return . translateInDir Down
    >>= dText "- Center view on:"
    >>= dText "'d' -> Space"
    >>= dText_ "'f' -> Ship"
