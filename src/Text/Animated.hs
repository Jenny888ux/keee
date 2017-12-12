{-# LANGUAGE NoImplicitPrelude #-}

module Text.Animated
         ( TextAnimation(..)
         , AnchorChars
         , AnchorStrings
         , renderAnimatedTextCharAnchored
         , renderAnimatedTextStringAnchored
         , getAnimatedTextRenderStates
         , mkTextTranslation
         , mkSequentialTextTranslationsCharAnchored
         , mkSequentialTextTranslationsStringAnchored
         -- | reexports
         , module Evolution
         ) where

import           Imajuscule.Prelude
import qualified Prelude(length)

import           Control.Monad( zipWithM_ )
import           Data.Text( unpack, length )
import           Data.List(foldl', splitAt, unzip)

import           Evolution

import           Geo.Discrete

import           Math

import           Render.Console
import           Render

import           Text.ColorString


-- | To animate (in parallel) :
--    - the locations of either :
--      - each ColorString (use a = 'AnchorStrings')
--      - or each character (use a = 'AnchorChars')
--    - chars replacements, inserts, deletes
--    - chars color changes
data (Show a) => TextAnimation a = TextAnimation {
   _textAnimationFromTos :: ![Evolution ColorString] -- TODO is it equivalent to Evolution [ColorString]?
 , _textAnimationAnchorsFrom :: !(Evolution (SequentiallyInterpolatedList Coords))
 , _textAnimationClock :: !EaseClock
} deriving(Show)

data AnchorStrings = AnchorStrings deriving(Show)
data AnchorChars = AnchorChars deriving(Show)

renderAnimatedTextStringAnchored :: TextAnimation AnchorStrings -> Frame -> IORef Buffers -> IO ()
renderAnimatedTextStringAnchored (TextAnimation fromToStrs renderStatesEvolution _) i b = do
  let rss = getAnimatedTextRenderStates renderStatesEvolution i
  renderAnimatedTextStringAnchored' fromToStrs rss i b

renderAnimatedTextStringAnchored' :: [Evolution ColorString] -> [Coords] -> Frame -> IORef Buffers -> IO ()
renderAnimatedTextStringAnchored' [] _ _ _ = return ()
renderAnimatedTextStringAnchored' l@(_:_) rs i b = do
  let e = head l
      rsNow = head rs
      colorStr = evolve e i
  renderColored colorStr rsNow b
  >>=
    renderAnimatedTextStringAnchored' (tail l) (tail rs) i

renderAnimatedTextCharAnchored :: TextAnimation AnchorChars -> Frame -> IORef Buffers -> IO ()
renderAnimatedTextCharAnchored (TextAnimation fromToStrs renderStatesEvolution _) i b = do
  let rss = getAnimatedTextRenderStates renderStatesEvolution i
  renderAnimatedTextCharAnchored' fromToStrs rss i b

renderAnimatedTextCharAnchored' :: [Evolution ColorString] -> [Coords] -> Frame -> IORef Buffers -> IO ()
renderAnimatedTextCharAnchored' [] _ _ _ = return ()
renderAnimatedTextCharAnchored' l@(_:_) rs i b = do
  -- use length of from to know how many renderstates we should take
  let e@(Evolution (Successive colorStrings) _ _ _) = head l
      nRS = maximum $ map countChars colorStrings
      (nowRS, laterRS) = splitAt nRS rs
      (ColorString colorStr) = evolve e i
  renderColorStringAt colorStr nowRS b
  renderAnimatedTextCharAnchored' (tail l) laterRS i b

renderColorStringAt :: [(Text, Colors)] -> [Coords] -> IORef Buffers -> IO ()
renderColorStringAt [] _ _ = return ()
renderColorStringAt l@(_:_) rs b = do
  let (txt, color) = head l
      len = length txt
      (headRs, tailRs) = splitAt len $ assert (Prelude.length rs >= len) rs
  zipWithM_ (\char coord -> drawChar char coord color b) (unpack txt) headRs
  renderColorStringAt (tail l) tailRs b

getAnimatedTextRenderStates :: Evolution (SequentiallyInterpolatedList Coords)
                            -> Frame
                            -> [Coords]
getAnimatedTextRenderStates evolution i =
  let (SequentiallyInterpolatedList l) = evolve evolution i
  in l

build :: Coords -> Int -> [Coords]
build x sz = map (\i -> move i RIGHT x)  [0..pred sz]

-- | order of animation is: move, change characters, change color
mkSequentialTextTranslationsCharAnchored :: [([ColorString], Coords, Coords)]
                                         -- ^ list of text + start anchor + end anchor
                                         -> Float
                                         -- ^ duration in seconds
                                         -> TextAnimation AnchorChars
mkSequentialTextTranslationsCharAnchored l duration =
  let (from_,to_) =
        foldl'
          (\(froms, tos) (colorStrs, from, to) ->
            let sz = maximum $ map countChars colorStrs
            in (froms ++ build from sz, tos ++ build to sz))
          ([], [])
          l
      strsEv = map (\(txts,_,_) -> mkEvolution (Successive txts) duration) l
      fromTosLF = maximum $ map (\(Evolution _ lf _ _) -> lf) strsEv
      evAnchors@(Evolution _ anchorsLF _ _) =
        mkEvolution2 (SequentiallyInterpolatedList from_)
                     (SequentiallyInterpolatedList to_) duration
  in TextAnimation strsEv evAnchors $ mkEaseClock duration (max anchorsLF fromTosLF) invQuartEaseInOut

mkSequentialTextTranslationsStringAnchored :: [([ColorString], Coords, Coords)]
                                           -- ^ list of texts, start anchor, end anchor
                                           -> Float
                                           -- ^ duration in seconds
                                           -> TextAnimation AnchorStrings
mkSequentialTextTranslationsStringAnchored l duration =
  let (from_,to_) = unzip $ map (\(_,f,t) -> (f,t)) l
      strsEv = map (\(txts,_,_) -> mkEvolution (Successive txts) duration) l
      fromTosLF = maximum $ map (\(Evolution _ lf _ _) -> lf) strsEv
      evAnchors@(Evolution _ anchorsLF _ _) =
        mkEvolution2 (SequentiallyInterpolatedList from_)
                     (SequentiallyInterpolatedList to_) duration
  in TextAnimation strsEv evAnchors $ mkEaseClock duration (max anchorsLF fromTosLF) invQuartEaseInOut


-- | In this animation, the beginning and end states are text written horizontally
mkTextTranslation :: ColorString
                  -> Float
                  -- ^ duration in seconds
                  -> Coords
                  -- ^ left anchor at the beginning
                  -> Coords
                  -- ^ left anchor at the end
                  -> TextAnimation AnchorChars
mkTextTranslation text duration from to =
  let sz = countChars text
      strEv@(Evolution _ fromToLF _ _) = mkEvolution1 text duration
      from_ = build from sz
      to_ = build to sz
      strsEv = [strEv]
      fromTosLF = fromToLF
      evAnchors@(Evolution _ anchorsLF _ _) =
        mkEvolution2 (SequentiallyInterpolatedList from_)
                     (SequentiallyInterpolatedList to_) duration
  in TextAnimation strsEv evAnchors $ mkEaseClock duration (max anchorsLF fromTosLF) invQuartEaseInOut
