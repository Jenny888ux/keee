{-# LANGUAGE NoImplicitPrelude #-}

{-|
= Purpose

Use this module to render animated colored frames in the console
with no [screen tearing](https://en.wikipedia.org/wiki/Screen_tearing).
It was initially developped for <https://github.com/OlivierSohn/hamazed hamazed>.

== What is screen tearing, and how we can avoid it.

When we render a frame, we fill stdout buffer with

* Char and String, using
<http://hackage.haskell.org/package/base-4.10.1.0/docs/Prelude.html#v:putChar putChar>
and
<http://hackage.haskell.org/package/base-4.10.1.0/docs/Prelude.html#v:putStr putStr>
:

    * visible (\'A\', "Hello world", ...)
    * invisible (\' \', \'\t\', ...)

* Escape sequences using
<https://hackage.haskell.org/package/ansi-terminal-0.7.1.1/docs/System-Console-ANSI.html#v:setSGR setSGR>
or
<http://hackage.haskell.org/package/base-4.10.1.0/docs/Prelude.html#v:putStr putStr>
:

    * color change : "\ESC[48;5;167;38;5;255m"
    * position change : "\ESC[150;42H"
    * <https://en.wikipedia.org/wiki/ANSI_escape_code etc...>

Once the buffer is full, it is flushed, thereby triggering a console render.
If it happens in the middle of a frame, screen tearing occurs because
a /partial/ frame is rendered.

There are two ways we can fix this:

=== Maximize stdout buffer size

TODO do that by default in initialization?

Using <https://hackage.haskell.org/package/base-4.10.1.0/docs/System-IO.html#v:hSetBuffering hSetBuffering>
with
<https://hackage.haskell.org/package/base-4.10.1.0/docs/System-IO.html#v:BlockBuffering BlockBuffering>
parameter:

> hSetBuffering stdout $ BlockBuffering $ Just (maxBound :: Int)

Note that using @BlockBuffering Nothing@ would not necessarily result in the
largest capacity being used : on my system, a size of 2048 is used for
@BlockBuffering Nothing@ whereas the maximum stdout size is 8096 (This size is
not documented but can be found visually using a binary search
on sizes with test 'testStdoutSizes').

=== Minimize rendering data

We use a double buffering technique to compute the /delta/ frame, which is
the difference between the current frame and the previous frame.

We render only the locations that are in the /delta/ frame (to avoir rendering
at locations where nothing changed), and we group them by colors to minimize
the amount of <https://en.wikipedia.org/wiki/ANSI_escape_code escape codes>
sent to stdout buffer.

We also take advantage of the fact that when rendering a
character using 'putChar', the cursor position automatically moves to the right,
this reduces the number of required "position change" escape sequences.

=== Future optimizations

We could also optimize the type of "position change" command we send: today
we use exclusively the 2 coordinates version (9 bytes on average), but it would
be more efficient to switch to the "go forward (optionally n times)" version
(3 to 5 bytes) when we are on the same row.


TODO stats on hamazed to see stdout buffer usage

= Usage

-- TODO hide the render size API, replace it by an optional Initialize function
which will allocate the buffers

Setup the frame size. You can use
<https://hackage.haskell.org/package/terminal-size#readme terminal-size package>
to retrieve the current size of the terminal.

> setFrameDimensions 300 90

Draw

> setForegroundColor $ xterm256ColorToCode $ RGBColor $ RGB 0 2 3
> setDrawLocation 10 20
> drawStr "Hello world!"

Render to the console

> renderFrame True {-reset the back buffer to the initial colors-}

= Global states

The functions of this module are in the IO monad because a top level
IORef is used to store states : current colors, current draw position,
front and back buffers, and internal buffers.

TODO should this module handle cursor hiding?

-- TODO include in this module functions to create colors to be able to write

> rgb 3 4 5
-}
module Render.Backends.Internal.Delta
       (
       -- * Setup
         setFrameDimensions
       -- * Fill the back buffer
       , fill
       -- * Draw to the back buffer
       -- ** Set states for subsequent 'draw***' calls
       -- *** Location
       , setDrawLocation
       -- *** Colors
       , setDrawColor
       , setDrawColors
       , restoreDrawColors
       -- ** Draw using states
       , drawChar
       , drawChars
       , drawStr
       , drawTxt
       -- * Render to the console
       , renderFrame
       -- * Reexports
       , module Render.Backends.Internal.Types
       ) where


import           Imajuscule.Prelude hiding (replicate)

import qualified Prelude ( putChar, putStr )

import           Data.Colour.SRGB( RGB(..) )
import           Data.IORef( IORef , newIORef , readIORef , writeIORef )
import           Data.Maybe( fromMaybe )
import           Data.String( String )
import           Data.Text( Text, unpack )
import           Data.Vector.Algorithms.Intro -- unstable sort
import           Data.Vector.Unboxed.Mutable( IOVector, replicate, read, write, unzip )
import           Data.Word( Word32, Word16 )

import           System.Console.ANSI( xterm256ColorToCode, Color8Code(..), Xterm256Color(..)
                                    , setCursorPosition, setSGRCode, SGR(..), ConsoleLayer(..) )
import           System.IO( stdout, hFlush )
import           System.IO.Unsafe( unsafePerformIO )

import           Render.Backends.Internal.BufferCell
import           Render.Backends.Internal.Types
import qualified Render.Backends.Internal.UnboxedDynamic as Dyn
                                ( IOVector, accessUnderlying, length
                                , new, read, clear, pushBack )


type BackFrontBuffer = IOVector (Cell, Cell)

newtype Buffer a = Buffer (IOVector Cell)

newtype Delta = Delta (Dyn.IOVector Cell)

-- | Buffer types
data Back
data Front

data Pencil = Pencil {
    _pencilBufferIndex :: {-# UNPACK #-} !Word16
  , _pencilColors :: {-# UNPACK #-} !Colors
}

data Buffers = Buffers {
    _renderStateBackBuffer :: !(Buffer Back)
  , _renderStateFrontBuffer :: !(Buffer Front)
  , _buffersSize :: !Word16
  , _buffersWidth :: !Word16
  , _buffersHeight :: !Word16
  , _buffersDelta :: !Delta
  -- ^ buffer used in renderFrame
}


-- | Resizes the canvas, if needed
--  (this function does nothing if it was previously called with the same arguments).
setFrameDimensions :: Word16
                    -- ^ Width
                    -> Word16
                    -- ^ Height
                    -> IO ()
setFrameDimensions width height = do
  (RenderState (Pencil idx colors) (Buffers _ _ _ prevWidth prevHeight _)) <- readIORef screenBuffer
  if prevWidth == width && prevHeight == height
    then
      return ()
    else do
      buffers@(Buffers _ _ size _ _ _) <- mkBuffers width height
      let newPencilIdx = idx `fastMod` size
      writeIORef screenBuffer $ RenderState (Pencil newPencilIdx colors) buffers


-- | Creates buffers for given width and height, replaces 0 width or height by 1.
mkBuffers :: Word16 -> Word16 -> IO Buffers
mkBuffers width' height' = do
  let width  = max 1 width'
      height = max 1 height'
      sz = fromIntegral width * fromIntegral height :: Word32
      sz' = fromIntegral sz
  -- indexed cells use a Word16 index so size cannot be too big
  when (sz > fromIntegral (maxBound :: Word16)) $
    error $ "buffer size cannot be bigger than " ++ show (maxBound :: Word16) ++
            " : " ++ show (sz, width, height)
  -- We initialize to different colors so that in first render the whole console is drawn to.
  buf <- newBufferArray sz' (initialCell, nocolorCell)
  delta <- Dyn.new $ fromIntegral sz -- reserve the maximum possible size
  let (back, front) = unzip buf
  return $ Buffers (Buffer back) (Buffer front) sz' width height (Delta delta)

data RenderState = RenderState {
    _renderStatePencil :: !Pencil
  , _renderStateBuffers :: !Buffers
}


-- TODO use phantom types for Cell (requires Data.Vector.Unboxed.Deriving to use newtype in vector)
newBufferArray :: Word16 -> (Cell, Cell) -> IO BackFrontBuffer
newBufferArray size = replicate (fromIntegral size)


-- TODO caller should be able to set this
initialForeground :: Color8Code
initialForeground = xterm256ColorToCode $ RGBColor $ RGB 5 5 5

initialBackground :: Color8Code
initialBackground = xterm256ColorToCode $ RGBColor $ RGB 0 0 0

noColor :: Color8Code
noColor = Color8Code (-1)


{-# INLINE initialCell #-}
initialCell :: Cell
initialCell =
  let res = 0x10E7000000000020 -- optimization for 'renderFrame' (TODO check if the compiler would have found it)
  in assert (mkCell initialColors ' ' == res) res


{-# INLINE initialColors #-}
initialColors :: Colors
initialColors = Colors initialBackground initialForeground


{-# INLINE noColors #-}
noColors :: Colors
noColors = Colors noColor noColor


nocolorCell :: Cell
nocolorCell = mkCell noColors ' '


{-# NOINLINE screenBuffer #-}
screenBuffer :: IORef RenderState
screenBuffer =
  unsafePerformIO $ do
    buffers <- mkBuffers 300 80 -- TODO should we use terminal-size?
    newIORef (RenderState mkInitialState buffers)


mkInitialState :: Pencil
mkInitialState = Pencil 0 initialColors


-- | Modulo optimized for cases where most of the time,
--    a < b (for a mod b)
{-# INLINE fastMod #-}
fastMod :: Word16 -> Word16 -> Word16
fastMod a b
  | 0 <= a && a < b = a          -- fast path
  | otherwise       = a `mod` b  -- slow path


{-# INLINE indexFromXY #-}
indexFromXY :: Buffers -> Word16 -> Word16 -> Word16
indexFromXY (Buffers _ _ size width _ _) x y =
  (y * width + x) `fastMod` size


{-# INLINE xyFromIndex #-}
xyFromIndex :: Buffers -> Word16 -> (Word16, Word16)
xyFromIndex (Buffers _ _ size width _ _) idx =
    (x, y)
  where
    pos' = idx `fastMod` size
    x = pos' - y * width
    y = pos' `div` width


setDrawColor :: ConsoleLayer -> Color8Code -> IO Colors
setDrawColor layer color = do
  (RenderState (Pencil idx prevColors@(Colors prevBg prevFg)) b ) <- readIORef screenBuffer
  let newColors = case layer of
        Foreground -> Colors prevBg color
        Background -> Colors color prevFg
  writeIORef screenBuffer $ RenderState (Pencil idx newColors) b
  return prevColors


setDrawColors :: Colors -> IO Colors
setDrawColors colors = do
  (RenderState (Pencil idx prevColors) b ) <- readIORef screenBuffer
  writeIORef screenBuffer $ RenderState (Pencil idx colors) b
  return prevColors


restoreDrawColors :: Colors -> IO ()
restoreDrawColors = void . setDrawColors


setDrawLocation :: Int -> Int -> IO ()
setDrawLocation x y
  | x < 0 || y < 0 = error $ "cannot draw to negative location " ++ show (x,y)
  | otherwise      = setDrawLocation' (fromIntegral x) (fromIntegral y)


setDrawLocation' :: Word16 -> Word16 -> IO ()
setDrawLocation' x y = do
  (RenderState (Pencil _ colors) b) <- readIORef screenBuffer
  let idx = indexFromXY b x y
  writeIORef screenBuffer $ RenderState (Pencil idx colors) b


-- | Draws a 'Char' at the current draw location, with the current draw colors.
drawChar :: Char
         -> IO ()
drawChar c = do
  (RenderState (Pencil idx colors) (Buffers back _ _ _ _ _)) <- readIORef screenBuffer
  putCharRawAt back idx colors c


putCharRawAt :: Buffer Back -> Word16 -> Colors -> Char -> IO ()
putCharRawAt back idx colors c =
  writeToBack back idx $ mkCell colors c


-- | Draws multiple times the same 'Char' starting from the current draw location,
--   using current draw colors.
drawChars :: Int
          -- ^ Number of repetitions.
          -> Char
          -> IO ()
drawChars count c = do
  (RenderState (Pencil idx colors) (Buffers back _ size _ _ _)) <- readIORef screenBuffer
  let cell = mkCell colors c
  mapM_ (\i -> let pos = (idx + fromIntegral i) `fastMod` size
               in writeToBack back pos cell) [0..pred count]


-- | Draws a 'String' starting from the current draw location,
--   using current draw colors.
drawStr :: String -> IO ()
drawStr str = do
  (RenderState (Pencil idx colors) (Buffers back _ size _ _ _)) <- readIORef screenBuffer
  mapM_ (\(c, i) -> putCharRawAt back (idx+i `fastMod` size) colors c) $ zip str [0..]


-- | Draws a 'Text' starting from the current draw location,
--   using current draw colors.
drawTxt :: Text -> IO ()
drawTxt text = drawStr $ unpack text


{-# INLINE writeToBack #-}
writeToBack :: Buffer Back -> Word16 -> Cell -> IO ()
writeToBack (Buffer b) pos = write b (fromIntegral pos)


-- | Fills the entire canvas with colors and a char.
fill :: Maybe Colors
     -- ^ When Nothing, the initial colors are used.
     -> Maybe Char
     -- ^ When Nothing, a space character is used.
     -> IO ()
fill mayColors mayChar = do
  let colors = fromMaybe initialColors mayColors
      char = fromMaybe ' ' mayChar
  _ <- setDrawColors colors
  (RenderState _ b) <- readIORef screenBuffer
  fillBackBuffer b colors char


fillBackBuffer :: Buffers -> Colors -> Char -> IO ()
fillBackBuffer (Buffers (Buffer b) _ size _ _ _) colors char = do
  let cell = mkCell colors char
  mapM_ (\pos -> write b pos cell) [0..fromIntegral $ pred size]


{- | This function does the following:

* Store the difference between front and back buffer in an auxiliary buffer.
* Copy the back buffer to the front buffer
* Reset (clear) the content of the back buffer
* Sort the auxiliary buffer by color first, then by positions.
* Sends rendering commands to the stdout buffer, based on the drawing sequence
defined by the sorted auxiliary buffer.
* Flush stdout.
-}
renderFrame :: Bool
              -- ^ If True, after submission the drawing is reset to the initial color.
              -- This can also be achieved by calling "fill Nothing Nothing" after this call,
              -- at the cost of one more traversal of the back buffer.
              -> IO ()
renderFrame clearBack = do
  (RenderState _ buffers@(Buffers _ _ _ _ _ (Delta delta))) <- readIORef screenBuffer
  computeDelta buffers 0 clearBack
  szDelta <- Dyn.length delta
  underlying <- Dyn.accessUnderlying delta

  -- On average, foreground and background color change command is 20 bytes :
  --   "\ESC[48;5;167;38;5;255m"
  -- On average, position change command is 9 bytes :
  --   "\ESC[150;42H"
  -- So we want to minimize the number of color changes first, and then mimnimize
  -- the number of position changes.
  -- In 'Cell', color is encoded in higher bits than position, so this sort
  -- sorts by color first, then by position, which is what we want.
  sort underlying

  -- We ignore this color value. We could store it and use it to initiate the recursion
  -- at next render but if the client renders with another library in-betweeen, this value
  -- would be wrong, so we can ignore it here for more robustness.
  _ <- renderDelta szDelta 0 Nothing Nothing buffers
  Dyn.clear delta
  hFlush stdout -- TODO could that be async?

renderDelta :: Int
            -> Int
            -> Maybe Colors
            -> Maybe Word16
            -> Buffers
            -> IO Colors
renderDelta size index prevColors prevIndex
  b@(Buffers _ _ _ _ _ (Delta delta))
 | index == size = return $ Colors (Color8Code 0) (Color8Code 0)
 | otherwise = do
    c <- Dyn.read delta index
    let (bg, fg, idx, char) = expandIndexed c
        prevRendered = maybe False (== pred idx) prevIndex
    setCursorPositionIfNeeded b idx prevRendered
    usedColor <- drawCell bg fg char prevColors
    renderDelta size (succ index) (Just usedColor) (Just idx) b


-- [before doing this micro optimization, verify that there is no side effect,
-- it could take longer to render]
-- TODO: optimize position changes which are 9 bytes on average :
-- if the distance between 2 consecutive differences (of the same row) is < 9,
-- and on the path there is no needed color change, we can avoid a position
-- change command and add all items of the path to the delta vector instead.
-- This requires that we mimic the logic of drawCell
computeDelta :: Buffers
             -> Word16
             -- ^ the buffer index
             -> Bool
             -- ^ should we clear the buffer containing the new values?
             -> IO ()
computeDelta
 b@(Buffers (Buffer backBuf) (Buffer frontBuf) size _ _ (Delta delta))
 idx
 clearBack
  | idx == size = return ()
  | otherwise = do
      let i = fromIntegral idx
      -- read from back buffer
      valueToDisplay <- read backBuf i
      -- clear back buffer
      when (clearBack && (initialCell /= valueToDisplay)) $ write backBuf i initialCell
      -- read from front buffer
      valueCurrentlyDisplayed <- read frontBuf i
      -- if differences are found, update front buffer and push the difference
      -- in delta vector
      when (valueToDisplay /= valueCurrentlyDisplayed) $ do
          write frontBuf i valueToDisplay
          Dyn.pushBack delta $ mkIndexedCell valueToDisplay idx
      -- recurse
      computeDelta b (succ idx) clearBack

-- | The command to set the cursor position to 123,45 is "\ESC[123;45H",
-- its size is 9 bytes : one order of magnitude more than the size
-- of a char, so we avoid sending this command when not strictly needed.
{-# INLINE setCursorPositionIfNeeded #-}
setCursorPositionIfNeeded :: Buffers
                          -> Word16
                          -- ^ the buffer index
                          -> Bool
                          -- ^ True if a char was rendered at the previous buffer index
                          -> IO ()
setCursorPositionIfNeeded b idx predPosRendered = do
  let (colIdx, rowIdx) = xyFromIndex b idx
      shouldSetCursorPosition =
      -- We assume that the buffer width is not equal to terminal width,
      -- so even if the previous position was rendered,
      -- the cursor may not be located at the beginning of the line.
        colIdx == 0
      -- If the previous buffer position was rendered, the cursor position has
      -- automatically advanced to the next column (or to the beginning of
      -- the next line if it was the last terminal column).
        || not predPosRendered
  when shouldSetCursorPosition $ setCursorPosition (fromIntegral rowIdx) (fromIntegral colIdx)

{-# INLINE drawCell #-}
drawCell :: Color8Code -> Color8Code -> Char -> Maybe Colors -> IO Colors
drawCell bg fg char maybeCurrentConsoleColor = do
  let (bgChange, fgChange, usedFg) =
        maybe
          (True, True, fg)
          (\(Colors bg' fg') ->
              -- use foreground color if we don't draw a space
              let useFg = char /= ' ' -- I don't use Data.Char.isSpace, it could be slower
                  usedFg' = if useFg
                             then
                               fg
                             else
                               fg'
              in (bg'/=bg, fg'/=usedFg', usedFg'))
            maybeCurrentConsoleColor
      sgrs = [SetPaletteColor Foreground fg | fgChange] ++
             [SetPaletteColor Background bg | bgChange]

  if bgChange || fgChange
    then
      Prelude.putStr $ setSGRCode sgrs ++ [char]
    else
      Prelude.putChar char
  return $ Colors bg usedFg
