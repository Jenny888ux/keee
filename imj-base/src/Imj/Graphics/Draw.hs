{-# LANGUAGE NoImplicitPrelude #-}

module Imj.Graphics.Draw
        (
        -- * From MonadIO
          module Imj.Graphics.Draw.Class
        -- * From MonadReader
{- | The 'MonadReader' functions provide a way to abstract a global renderer, in a style adhering to
<https://www.fpcomplete.com/blog/2017/06/readert-design-pattern these recommendations>
regarding global state in a program.

As a user of these modules, you will run your program in a 'MonadReader' 'YourEnv' monad,
where 'YourEnv' is your environment equiped with a 'Draw' instance.

The functions below contain the boiler-plate code to access the 'Draw' methods
from the 'MonadReader' so you can simply write:

@
import Control.Monad.IO.Class(MonadIO)
import Control.Monad.Reader.Class(MonadReader)
import Control.Monad.Reader(runReaderT)

import Imj.Graphics.Draw.Class
import Imj.Graphics.Draw.Helpers.MonadReader(drawTxt, renderDrawing)

helloWorld :: (Draw e, MonadReader e m, MonadIO m)
           => m ()
helloWorld = do
  drawStr \"Hello\" (Coords 10 10) red
  drawStr \"World\" (Coords 20 20) green
  renderDrawing

main = do
  env <- createEnv
  runReaderT helloWorld env
@

<https://github.com/OlivierSohn/hamazed/blob/master/imj-game-hamazed/src/Imj/Hamazed/Env.hs This example>
follows this pattern.    -}
        , module Imj.Graphics.Draw.FromMonadReader
        -- * Reexports
        , LayeredColor(..)
        , Coords(..)
        , Alignment(..)
        , Text
        , MonadIO
        , MonadReader
        ) where

import           Control.Monad.Reader.Class(MonadReader)
import           Control.Monad.IO.Class(MonadIO)
import           Data.Text(Text)

import Imj.Graphics.Draw.Class
import Imj.Graphics.Draw.FromMonadReader

import Imj.Graphics.Color(LayeredColor(..))
import Imj.Geo.Discrete(Coords(..))
import Imj.Graphics.Text.Alignment(Alignment(..))