{-# LANGUAGE NoImplicitPrelude #-}

module Imj.Graphics.Render.Delta.Backend.Console
    ( deltaRenderConsole
    , mkConsoleBackend
    ) where

import           Imj.Prelude
import qualified Prelude(putStr, putChar)

import           System.Console.Terminal.Size( size , Window(..))
import           System.Console.ANSI( clearScreen, hideCursor
                                    , setSGR, setCursorPosition, showCursor )
import           System.IO( hSetBuffering
                          , hGetBuffering
                          , hSetEcho
                          , BufferMode(..)
                          , stdin
                          , stdout )

import           Data.Vector.Unboxed.Mutable(read)

import qualified Imj.Data.Vector.Unboxed.Mutable.Dynamic as Dyn
                        (IOVector, unstableSort, accessUnderlying, length)

import           Imj.Graphics.Color.Types
import           Imj.Graphics.Render.Delta.Types
import           Imj.Graphics.Render.Delta.Backend.Types
import           Imj.Graphics.Render.Delta.Internal.Types
import           Imj.Graphics.Render.Delta.Cell


mkConsoleBackend :: Maybe BufferMode
                 -- ^ Preferred stdout 'BufferMode'.
                 -> Backend
mkConsoleBackend maybeStdoutBufferMode =
  let stdoutBufMode = fromMaybe defaultStdoutMode maybeStdoutBufferMode
  in Backend
      (configureConsoleFor Gaming stdoutBufMode)
      deltaRenderConsole
      (configureConsoleFor Editing LineBuffering)

-- | @=@ 'BlockBuffering' $ 'Just' 'maxBound'
defaultStdoutMode :: BufferMode
defaultStdoutMode =
  BlockBuffering $ Just maxBound -- maximize the buffer size to avoid screen tearing

data ConsoleConfig = Gaming | Editing

configureConsoleFor :: ConsoleConfig -> BufferMode -> IO ()
configureConsoleFor config stdoutMode =
  hSetBuffering stdout stdoutMode >>
  case config of
    Gaming  -> do
      hSetEcho stdin False
      hideCursor
      clearScreen -- do not clearFromCursorToScreenEnd with 0 0, so as to keep
                  -- the current console content above the game.
      let requiredInputBuffering = NoBuffering
      initialIb <- hGetBuffering stdin
      hSetBuffering stdin requiredInputBuffering
      ib <- hGetBuffering stdin
      when (ib /= requiredInputBuffering) $
         error $ "input buffering mode "
               ++ show initialIb
               ++ " could not be changed to "
               ++ show requiredInputBuffering
               ++ " instead it is now "
               ++ show ib
    Editing -> do
      hSetEcho stdin True
      showCursor
      -- do not clearFromCursorToScreenEnd, to retain a potential printed exception
      setSGR []
      size >>= maybe (return ()) (\(Window x _) -> setCursorPosition (pred x) 0)
      hSetBuffering stdout LineBuffering

deltaRenderConsole :: Delta -> Dim Width -> IO ()
  -- On average, foreground and background color change command is 20 bytes :
  --   "\ESC[48;5;167;38;5;255m"
  -- On average, position change command is 9 bytes :
  --   "\ESC[150;42H"
  -- So we want to minimize the number of color changes first, and then mimnimize
  -- the number of position changes.
  -- In 'Cell', color is encoded in higher bits than position, so this sort
  -- sorts by color first, then by position, which is what we want.
deltaRenderConsole (Delta delta) w = do
  Dyn.unstableSort delta
  renderDelta delta w

renderDelta :: Dyn.IOVector Cell
            -> Dim Width
            -> IO ()
renderDelta delta' w = do
  sz <- Dyn.length delta'
  delta <- Dyn.accessUnderlying delta'
      -- We pass the underlying vector, and the size instead of the dynamicVector
  let renderDelta' :: Dim BufferIndex
                   -> Maybe LayeredColor
                   -> Maybe (Dim BufferIndex)
                   -> IO LayeredColor
      renderDelta' index prevColors prevIndex
       | fromIntegral sz == index =
          return whiteOnBlack -- this value is not used
       | otherwise = do
          c <- read delta $ fromIntegral index
          let (bg, fg, idx, char) = expandIndexed c
              prevRendered = (== Just (pred idx)) prevIndex
          setCursorPositionIfNeeded w idx prevRendered
          usedColor <- renderCell bg fg char prevColors
          renderDelta' (succ index) (Just usedColor) (Just idx)
  void (renderDelta' 0 Nothing Nothing)

-- | The command to set the cursor position to 123,45 is "\ESC[123;45H",
-- its size is 9 bytes : one order of magnitude more than the size
-- of a char, so we avoid sending this command when not strictly needed.
{-# INLINE setCursorPositionIfNeeded #-}
setCursorPositionIfNeeded :: Dim Width
                          -> Dim BufferIndex
                          -- ^ the buffer index
                          -> Bool
                          -- ^ True if a char was rendered at the previous buffer index
                          -> IO ()
setCursorPositionIfNeeded w idx predPosRendered = do
  let (colIdx, rowIdx) = xyFromIndex w idx
      shouldSetCursorPosition =
      -- We assume that the buffer width is not equal to terminal width,
      -- so even if the previous position was rendered,
      -- the cursor may not be located at the beginning of the line.
        colIdx == 0
      -- If the previous buffer position was rendered, the cursor position has
      -- automatically advanced to the next column (or to the beginning of
      -- the next line if it was the last terminal column).
        || not predPosRendered
  when shouldSetCursorPosition
    $ Prelude.putStr $ setCursorPositionCode (fromIntegral rowIdx) (fromIntegral colIdx)

setCursorPositionCode :: Int -- ^ 0-based row to move to
                      -> Int -- ^ 0-based column to move to
                      -> String
setCursorPositionCode n m = csi [n + 1, m + 1] "H"

{-# INLINE renderCell #-}
renderCell :: Color8 Background
           -> Color8 Foreground
           -> Char
           -> Maybe LayeredColor
           -> IO LayeredColor
renderCell bg fg char maybeCurrentConsoleColor = do
  let (bgChange, fgChange, usedFg) =
        maybe
          (True, True, fg)
          (\(LayeredColor bg' fg') ->
              -- use foreground color if we don't draw a space
              let useFg = char /= ' ' -- I don't use Data.Char.isSpace, it could be slower
                  usedFg' = if useFg
                             then
                               fg
                             else
                               fg'
              in (bg'/=bg, fg'/=usedFg', usedFg'))
            maybeCurrentConsoleColor
      sgrs = concat $ [color8FgSGRToCode fg | fgChange] ++
                      [color8BgSGRToCode bg | bgChange]

  if bgChange || fgChange
    then
      Prelude.putStr $ csi sgrs "m" ++ [char]
    else
      Prelude.putChar char
  return $ LayeredColor bg usedFg


csi :: [Int]
    -> String
    -> String
csi args code = "\ESC[" ++ intercalate ";" (map show args) ++ code


{-# INLINE xyFromIndex #-}
xyFromIndex :: Dim Width -> Dim BufferIndex -> (Dim Col, Dim Row)
xyFromIndex w idx =
  getRowCol idx w

-- TODO use this formalism
{-
newtype SetPosition = Move2d !Int !Int
                    | Move1 Direction !Int

type Value = (Color8 Background, Color8 Foreground, Char)
type Location = (Row, Column)

screenLocations = { (row, column) | row <- [0..screenHeight], column <- [0..screenWidth] }

type Step = Int  -- represents a temporal game / animation step

frame :: Step -> Location -> Value  -- defines the desired content of animations

identicalLocations n = {loc | loc <- screenLocations && frame n loc == frame (pred n) loc}
deltaLocations     n = screenLocations \\ (identicalLocations n)

newtype RenderCmd   = SetPosition | SetColor | Char | !String
newtype SetPosition = Move2d Int Int | Move Direction Int
newtype SetColor    = SetColorForeground | SetColorBackground | SetColorBoth
newtype Direction   = Up | Left | Down | Right

cheapestChangePosition' :: (Row,Col) -> SetPosition
cheapestChangePosition :: (Row,Col) -> (Row,Col) -> Maybe SetPosition

cheapestChangeColor' :: (Background Color, Foreground Color) -> SetColor
cheapestChangeColor :: (Background Color, Foreground Color) -> (Background Color, Foreground Color) -> Maybe SetColor

cost :: RenderCmd -> Int -- the cost is in bytes

render :: [(Location,Value)] -> IO ()
render l = do
  let cmds = cheapestCmds l
      str = concatMap asString cmds
  printStr str
  hFlush stdout

cheapestCmds :: [(Location,Value)] -> [RenderCmd]
cheapestCmds [] = []
cheapestCmds l =
  let l' = sortDelta l
  in renderFirst (head l') ++ cheapestCmds' l'

cheapestCmds' :: [(Location,Value)] -> [RenderCmd]
cheapestCmds' [] = error ""
cheapestCmds' [a] = []
cheapestCmds' l@(a:b:_) = renderNext a b ++ cheapestCmds' (tail l)

sortDelta :: [(Location,Value)] -> [(Location,Value)]
sortDelta = sortByColorThenIncreasingLocation

renderFirst :: (Location, Value) -> RenderCmd
renderNext :: (Location,Value) -> (Location,Value) -> RenderCmd -- Choses the best command (the cheapest one) when there are multiple possibilities.
-}