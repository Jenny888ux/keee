{-# OPTIONS_HADDOCK hide #-} -- so as to encourage users to use the optimized version

module Imj.Graphics.Render.Naive
          ( NaiveDraw(..)
          ) where

import Data.Text(unpack)

import Control.Monad.Reader(liftIO)

import System.IO(hFlush, stdout)
import System.Console.ANSI(setCursorPosition, clearFromCursorToScreenEnd)
import System.Console.ANSI.Codes(csi)

import Imj.Graphics.Draw.Class
import Imj.Geo.Discrete
import Imj.Graphics.Color

{- | Naive rendering for the terminal. Just for tests. It is very naïve in the sense that

* It doesn't have any state, so at every call it sets the color and the position,
even if it's not needed.
* There is no double buffering involved.

For an optimized version, see 'Delta' of module imj-render-delta-term.
-}
newtype NaiveDraw = NaiveDraw Int -- ^ Int is not used, I had to add it else () doesn't compile

move' :: Coords Pos -> IO ()
move' (Coords (Coord y) (Coord x)) =
  setCursorPosition y x

color :: LayeredColor -> IO ()
color (LayeredColor bg fg) = do
  let bgCodes = color8BgSGRToCode bg
      fgCodes = color8FgSGRToCode fg
  putStr $ csi (bgCodes ++ fgCodes) "m"

-- | Don't use for production, this is for tests only
-- and creates heavy screen tearing.
instance Draw NaiveDraw where
    drawChar'      _ b c d   = liftIO $ move' c >> color d >> putChar b
    drawChars'     _ b c d e = liftIO $ move' d >> color e >> putStr (replicate b c)
    drawTxt'       _ b c d   = liftIO $ move' c >> color d >> putStr (unpack b)
    drawStr'       _ b c d   = liftIO $ move' c >> color d >> putStr b
    renderDrawing' _         = liftIO $ hFlush stdout
                                        >> setCursorPosition 0 0
                                        >> clearFromCursorToScreenEnd
    {-# INLINABLE drawChar' #-}
    {-# INLINABLE drawChars' #-}
    {-# INLINABLE drawTxt' #-}
    {-# INLINABLE drawStr' #-}
    {-# INLINABLE renderDrawing' #-}