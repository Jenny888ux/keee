{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-|
This is a multiplayer game where every player uses the keyboard as a synthesizer.

The enveloppe of the synthesizer can be tuned.

The music is shared between all players.
 -}

module Main where

import           Imj.Prelude
import           Prelude(length)

import           Codec.Midi hiding(key)
import           Control.Concurrent(forkIO, threadDelay)
import           Control.Concurrent.MVar.Strict(MVar, modifyMVar, modifyMVar_, newMVar, putMVar, takeMVar)
import           Control.DeepSeq(NFData)
import           Control.Monad.State.Strict(gets, execStateT)
import           Control.Monad.Reader(asks)
import           Data.Binary(Binary(..), encode, decodeOrFail)
import           Data.Bits (shiftR, shiftL, (.&.))
import qualified Data.ByteString.Lazy as BL
import           Data.List(replicate, concat, take)
import           Data.Map.Internal(Map(..))
import qualified Data.Map.Strict as Map
import           Data.Set(Set)
import qualified Data.Set as Set
import           Data.Text(pack, Text)
import           Data.Vector.Unboxed(Vector)
import qualified Data.Vector.Unboxed as V
import qualified Data.Vector.Storable as S
import           Data.Proxy(Proxy(..))
import           GHC.Generics(Generic)
import qualified Graphics.UI.GLFW as GLFW(Key(..), KeyState(..))
import           Numeric(showFFloat)
import qualified Sound.PortMidi as PortMidi
import           System.IO(withFile, IOMode(..))
import           System.Directory(doesFileExist)

import           Imj.Audio
import           Imj.Audio.Harmonics
import           Imj.Categorized
import           Imj.ClientView.Types
import           Imj.Event
import           Imj.File
import           Imj.Game.App(runGame)
import           Imj.Game.Draw
import           Imj.Game.Class
import           Imj.Game.Command
import           Imj.Game.KeysMaps
import           Imj.Game.Modify
import           Imj.Game.Show
import           Imj.Game.Status
import           Imj.Geo.Discrete.Types
import           Imj.Geo.Discrete.Resample
import           Imj.Graphics.Class.Positionable
import           Imj.Graphics.Class.UIInstructions
import           Imj.Graphics.Color
import           Imj.Graphics.Font
import           Imj.Graphics.Render.FromMonadReader
import           Imj.Graphics.Screen
import           Imj.Graphics.Text.ColorString(ColorString)
import qualified Imj.Graphics.Text.ColorString as CS
import           Imj.Graphics.Text.Render
import           Imj.Graphics.UI.RectContainer
import qualified Imj.Graphics.UI.Choice as UI
import           Imj.Music.Types
import           Imj.Music.PressedKeys
import           Imj.Music.Record
import           Imj.Server.Class hiding(Do)
import           Imj.Server.Connection
import           Imj.Server.Types
import           Imj.Server
import           Imj.Timing

main :: IO ()
main = runGame (Proxy :: Proxy SynthsGame)


-- TODO make a PortMidi example out of this for https://github.com/ninegua/PortMidi/issues/4
{-
main2 = usingAudioOutput readMidi
readMidi :: IO ()
readMidi = do
  PortMidi.initialize >>= either
    (\err -> putStrLn $ "midi initialize : " ++ show err)
    (const $ return ())
  PortMidi.getDefaultInputDeviceID >>= maybe
    (error "no default device")
    (\did -> do
      PortMidi.getDeviceInfo did >>= print
      PortMidi.openInput did >>= either
        (\err -> error $ "open:" ++ show err)
        (\stream -> do
            let f =
                  PortMidi.poll stream >>= either
                    (\err -> error $ "poll:" ++ show err)
                    (\case
                        PortMidi.NoError'NoData -> f
                        PortMidi.GotData ->
                          PortMidi.readEvents stream >>= \evts -> do
                            putStrLn ""
                            print evts
                            forM_ evts
                              (maybe
                                (putStrLn "unhandled")
                                (\case
                                    NoteOn _ key 0 -> onNoteOff key
                                    NoteOn _ key vel -> do
                                     let n = mkInstrumentNote (fromIntegral key) simpleInstrument
                                     play (StartNote n $ mkNoteVelocity vel) >>= either (error . show) return
                                    NoteOff _ key _ -> onNoteOff key
                                    _ -> putStrLn "unhandled"
                                    ) . msgToMidi . PortMidi.decodeMsg . PortMidi.message)
                            f
                           where
                             onNoteOff k = do
                               let n = mkInstrumentNote (fromIntegral k) simpleInstrument
                               play (StopNote n) >>= either (error . show) return
                            )
            f)
          )
  PortMidi.terminate >>= either
    (\err -> putStrLn $ "midi terminate : " ++ show err)
    (const $ return ())
-}

-- from https://hackage.haskell.org/package/Euterpea-2.0.2/src/Euterpea/IO/MIDI/MidiIO.lhs
msgToMidi :: PortMidi.PMMsg -> Maybe Message
msgToMidi (PortMidi.PMMsg m d1 d2) =
  let k = (m .&. 0xF0) `shiftR` 4
      c = fromIntegral (m .&. 0x0F)
  in case k of
    0x8 -> Just $ NoteOff c (fromIntegral d1) (fromIntegral d2)
    0x9 -> Just $ NoteOn  c (fromIntegral d1) (fromIntegral d2)
    0xA -> Just $ KeyPressure c (fromIntegral d1) (fromIntegral d2)
    0xB -> Just $ ControlChange c (fromIntegral d1) (fromIntegral d2)
    0xC -> Just $ ProgramChange c (fromIntegral d1)
    0xD -> Just $ ChannelPressure c (fromIntegral d1)
    0xE -> Just $ PitchWheel c (fromIntegral (d1 + d2 `shiftL` 8))
    0xF -> Nothing -- SysEx event not handled
    _   -> Nothing

data LoopId = LoopId {
    _loopCreator :: {-# UNPACK #-} !ClientId
  , _loopIndex :: {-# UNPACK #-} !Int
} deriving(Generic, Show, Ord, Eq)
instance Binary LoopId
instance NFData LoopId


data EnvelopePart = EnvelopePart {
    _plot :: [MinMax Float]
  , _nSamples :: !Int
} deriving(Show)

widthPart :: EnvelopePart -> Int
widthPart = length . _plot

widthEnvelope :: Int
widthEnvelope = 90

toParts :: EnvelopeViewMode -> [Vector Float] -> [EnvelopePart]
toParts mode l@[ahds,r]
  | totalSamples == 0 = []
  | otherwise = map (uncurry mkMinMaxEnv) $ zip [widthAHDS, widthEnvelope - widthAHDS] l
 where
  mkMinMaxEnv w c =
    EnvelopePart
      (case mode of
        LogView -> resampleMinMaxLogarithmic (V.toList c) (V.length c) $ fromIntegral w
        LinearView -> resampleMinMaxLinear (V.toList c) (V.length c) $ fromIntegral w)
      $ V.length c
  ahdsSamples = V.length ahds
  rSamples = V.length r
  totalSamples = rSamples + ahdsSamples
  widthAHDS = round (fromIntegral widthEnvelope * fromIntegral ahdsSamples / fromIntegral totalSamples :: Float)
toParts _ _ = error "not supported"

data EnvelopePlot = EnvelopePlot {
    envParts :: [EnvelopePart]
  , envViewMode :: !EnvelopeViewMode
} deriving(Show)

data EnvelopeViewMode = LinearView | LogView
  deriving(Show)

toggleView :: EnvelopeViewMode -> EnvelopeViewMode
toggleView = \case
  LinearView -> LogView
  LogView -> LinearView

data EditMode = Harmonics | Envelope
  deriving(Show)

data Edition = Edition {
    editMode :: !EditMode
  , envelopeIdx :: !Int
  -- ^ Index of the enveloppe parameter that will be edited on left/right arrows.
  , harmonicIdx :: !Int
  -- ^ Index of the harmonic parameter that will be edited on left/right arrows.
} deriving(Show)

mkEdition :: Edition
mkEdition = Edition Envelope 0 0

toggleEditMode :: Edition -> Edition
toggleEditMode e = case editMode e of
  Harmonics -> e {editMode = Envelope}
  Envelope -> e {editMode = Harmonics}

editiontIndex :: Edition -> Int
editiontIndex (Edition mode i j) = case mode of
  Envelope -> i
  Harmonics -> j

setEditionIndex :: Int -> Edition -> Edition
setEditionIndex idx (Edition mode i j) = case mode of
  Envelope -> Edition mode idx j
  Harmonics -> Edition mode i idx

data SynthsGame = SynthsGame {
    pianos :: !(Map ClientId PressedKeys)
  , pianoLoops :: !(Map SequencerId (Map LoopId PressedKeys))
  , clientPressedKeys :: !(Map GLFW.Key InstrumentNote)
  , instrument :: !Instrument
  , envelopePlot :: !EnvelopePlot
  , edition :: !Edition
} deriving(Show)

instance UIInstructions SynthsGame where
  instructions color (SynthsGame _ _ _ instr _ edit@(Edition mode _ _)) =
    case instr of
      Synth osc harmonics release (AHDSR'Envelope a h d r ai di ri s) -> case mode of
        Envelope -> envelopeInstructions
        Harmonics -> harmonicsInstructions

       where

        envelopeInstructions =
          [ ConfigUI "Auto-release"
              [ mkChoice 0 $ case release of
                  AutoRelease -> "Yes"
                  KeyRelease -> "No"
              ]
          , ConfigUI "Attack"
              [ mkChoice 1 $ show a
              , mkChoice 2 $ show ai
              ]
          , ConfigUI "Hold"
              [ mkChoice 3 $ show h]
          , ConfigUI "Decay"
              [ mkChoice 4 $ show d
              , mkChoice 5 $ show di
              ]
          , ConfigUI "Sustain"
              [ mkChoice 6 $ showFFloat (Just 3) s ""
              ]
          , ConfigUI "Release"
              [ mkChoice 7 $ show r
              , mkChoice 8 $ show ri
              ]
          ]

        harmonicsInstructions =
          [ hInst "Harmonics" volume 0
          , hInst "Phases" phase firstPhaseIdx
          , ConfigUI "Oscillator"
              [ mkChoice firstOscillatorIdx $ show osc]
              ]
         where
           hInst title f startIdx = ConfigUI title $
            map
             (\(i,har) -> mkChoice i $ showFFloat (Just 3) (f har) "")
             (zip [startIdx..] $ S.toList harmonics)

        mkChoice x v =
          Choice $ UI.Choice (pack v) right left color

         where

          right
            | x == idx = '>'
            | otherwise = ' '
          left
            | x == idx = '<'
            | otherwise = ' '
          idx = (editiontIndex edit) `mod` (countEditables mode)

      _ -> []


countHarmonics :: Int
countHarmonics = 10

countEditables :: EditMode -> Int
countEditables Envelope = 9
countEditables Harmonics = 2*countHarmonics + 1

firstPhaseIdx, firstOscillatorIdx :: Int
firstPhaseIdx = countHarmonics
firstOscillatorIdx = 2*firstPhaseIdx

predefinedAttackItp, predefinedDecayItp, predefinedReleaseItp :: Set Interpolation
predefinedDecayItp = allInterpolations
predefinedAttackItp = Set.delete ProportionaValueDerivative allInterpolations
predefinedReleaseItp = predefinedAttackItp

predefinedHarmonicsVolumes :: Set Float
predefinedHarmonicsVolumes = Set.fromList [0, 0.01, 0.1, 1]

predefinedHarmonicsPhases :: Set Float
predefinedHarmonicsPhases = Set.fromList $ takeWhile (< 2) $ map ((*) 0.1 . fromIntegral) [0::Int ..]

predefinedAttack, predefinedHolds, predefinedDecays, predefinedReleases :: Set Int
predefinedSustains :: Set Float
predefinedAttack =
  let l = 50:map (*2) l
  in Set.fromDistinctAscList $ take 12 l
predefinedHolds =
  let l = 5:map (*2) l
  in Set.fromDistinctAscList $ 0:take 12 l
predefinedDecays = predefinedAttack
predefinedReleases = predefinedAttack
predefinedSustains =
  let l = 0.01:map (*1.3) l
  in Set.fromDistinctAscList $ 0:takeWhile (< 1) l ++ [1]

withMinimumHarmonicsCount :: Instrument -> Instrument
withMinimumHarmonicsCount i =
  i { harmonics_ =
        (harmonics_ i) S.++
        (S.fromList $ replicate (countHarmonics - S.length (harmonics_ i)) (HarmonicProperties 0 0))
    }

initialGame :: IO SynthsGame
initialGame = do
  i <- withMinimumHarmonicsCount <$> loadInstrument
  let initialViewMode = LogView
  p <- flip EnvelopePlot initialViewMode . toParts initialViewMode <$> envelopeShape i
  return $ SynthsGame mempty mempty mempty i p mkEdition

data SynthsMode =
    PlaySynth
  | EditSynth
  deriving(Show)

data SynthsServer = SynthsServer {
    srvSequencers :: !(Map SequencerId (MVar (Sequencer LoopId)))
  , nextSeqId :: !SequencerId
} deriving(Generic)
instance NFData SynthsServer

data SynthsClientView = SynthsClientView {
    _piano :: !PressedKeys
    -- ^ What is currently pressed, by the player (excluding what is played by loops)
  , _recording :: !Recording
    -- ^ The ongoing recording of what is being played, which can be used to create a 'Loop'
  , _nextLoopPianoIdx :: !Int
} deriving(Generic, Show)
instance NFData SynthsClientView

thePianoValue :: SynthsClientView -> PressedKeys
thePianoValue (SynthsClientView x _ _) = x

-- | The server will also send 'PlayMusic' events, which are generic events.
data SynthsServerEvent =
    PianoValue !(Either ClientId (SequencerId, LoopId)) !PressedKeys
  | NewLine {-# UNPACK #-} !SequencerId {-# UNPACK #-} !LoopId
  deriving(Generic, Show)
instance DrawGroupMember SynthsServerEvent where
  exclusivityKeys = \case
    NewLine {} -> mempty
    PianoValue {} -> mempty -- we do this is so that interleaving 'PianoValue' events with 'PlayMusic' events
                           -- will still allow multiple play music events to be part of the same frame.
                           -- It is a bit of a hack, the better solution would be to handle audio events
                           -- client-side as soon as they are received (in the listening thread) (TODO).

instance Categorized SynthsServerEvent
instance NFData SynthsServerEvent
instance Binary SynthsServerEvent

data SynthClientEvent =
    PlayNote !MusicalEvent
  | WithMultiLineSequencer {-# UNPACK #-} !SequencerId
  | WithMonoLineSequencer
  | ForgetCurrentRecording
  deriving(Show,Generic)
instance Binary SynthClientEvent
instance Categorized SynthClientEvent

data SynthsGameEvent =
    ChangeInstrument !Instrument
  | ChangeEditedFeature {-# UNPACK #-} !Int
  | ToggleEditMode
  | ToggleEnvelopeViewMode
  | InsertPressedKey !GLFW.Key !InstrumentNote
  | RemovePressedKey !GLFW.Key
  deriving(Show)
instance Categorized SynthsGameEvent
instance DrawGroupMember SynthsGameEvent where
  exclusivityKeys _ = mempty

instance GameExternalUI SynthsGame where

  gameWindowTitle = const "Play some music!"

  -- NOTE 'getViewport' is never called unless 'putIGame' was called once.
  getViewport _ (Screen _ center) SynthsGame{} =
    mkCenteredRectContainer center $ Size 45 100

data SynthsStatefullKeys
instance GameStatefullKeys SynthsGame SynthsStatefullKeys where

  mapStateKey _ GLFW.Key'Space GLFW.KeyState'Pressed _ _ _ =
    return [CliEvt $ ClientAppEvt WithMonoLineSequencer]
  mapStateKey _ GLFW.Key'F1 GLFW.KeyState'Pressed _ _ _ =
    return [CliEvt $ ClientAppEvt $ WithMultiLineSequencer $ SequencerId 1]
  mapStateKey _ GLFW.Key'F2 GLFW.KeyState'Pressed _ _ _ =
    return [CliEvt $ ClientAppEvt $ WithMultiLineSequencer $ SequencerId 2]
  mapStateKey _ GLFW.Key'F3 GLFW.KeyState'Pressed _ _ _ =
    return [CliEvt $ ClientAppEvt $ WithMultiLineSequencer $ SequencerId 3]
  mapStateKey _ GLFW.Key'F4 GLFW.KeyState'Pressed _ _ _ =
    return [CliEvt $ ClientAppEvt $ WithMultiLineSequencer $ SequencerId 4]
  mapStateKey _ GLFW.Key'F5 GLFW.KeyState'Pressed _ _ _ =
    return [Evt $ AppEvent $ ToggleEditMode]
  mapStateKey _ GLFW.Key'F6 GLFW.KeyState'Pressed _ _ _ =
    return [Evt $ AppEvent $ ToggleEnvelopeViewMode]
  mapStateKey _ GLFW.Key'F10 GLFW.KeyState'Pressed _ _ _ =
    return [CliEvt $ ClientAppEvt ForgetCurrentRecording]
  mapStateKey _ k st _ _ g = maybe
    (return [])
    (\(SynthsGame _ _ pressed instr _ edit@(Edition mode _ _)) -> maybe
      (return $ case st of
        GLFW.KeyState'Repeating -> []
        GLFW.KeyState'Pressed -> maybe
            []
            (\noteSpec ->
              let spec = noteSpec instr
              in [CliEvt $ ClientAppEvt $ PlayNote $ StartNote spec 1
                , Evt $ AppEvent $ InsertPressedKey k spec])
            $ keyToNote k
        GLFW.KeyState'Released -> maybe
            []
            (\spec ->
               [CliEvt $ ClientAppEvt $ PlayNote $ StopNote spec
              , Evt $ AppEvent $ RemovePressedKey k])
            $ Map.lookup k pressed)
      (\dir -> return $ case instr of
          Synth{} -> case st of
            GLFW.KeyState'Pressed -> [configureInstrument]
            GLFW.KeyState'Repeating -> [configureInstrument]
            _ -> []

           where

            configureInstrument = case dir of
              LEFT  -> Evt $ AppEvent $ ChangeInstrument $ changeIntrumentValue (-1)
              RIGHT -> Evt $ AppEvent $ ChangeInstrument $ changeIntrumentValue 1
              Up   -> Evt $ AppEvent $ ChangeEditedFeature $ idx - 1
              Down -> Evt $ AppEvent $ ChangeEditedFeature $ idx + 1
             where
              changeIntrumentValue inc =
                case instr of
                  Synth osc harmonics release p@(AHDSR'Envelope a h d r ai di ri s) ->
                    case mode of
                      Envelope -> case idx of
                        0 -> instr { releaseMode_ = cycleReleaseMode release }
                        1 -> instr { envelope_ = p {ahdsrAttack = changeParam predefinedAttack a inc} }
                        2 -> instr { envelope_ = p {ahdsrAttackItp = changeParam predefinedAttackItp ai inc} }
                        3 -> instr { envelope_ = p {ahdsrHold = changeParam predefinedHolds h inc} }
                        4 -> instr { envelope_ = p {ahdsrDecay = changeParam predefinedDecays d inc} }
                        5 -> instr { envelope_ = p {ahdsrDecayItp = changeParam predefinedDecayItp di inc} }
                        6 -> instr { envelope_ = p {ahdsrSustain = changeParam predefinedSustains s inc} }
                        7 -> instr { envelope_ = p {ahdsrRelease = changeParam predefinedReleases r inc} }
                        8 -> instr { envelope_ = p {ahdsrReleaseItp = changeParam predefinedReleaseItp ri inc} }
                        _ -> error "logic"
                      Harmonics ->
                        if idx == firstOscillatorIdx
                          then
                            instr { oscillator = cycleOscillator inc osc }
                          else
                            let idx'
                                 | idx >= firstPhaseIdx = idx - firstPhaseIdx
                                 | otherwise = idx
                                h'
                                 | S.length harmonics <= idx' =
                                    harmonics S.++ (S.fromList $ replicate (1 + idx' - S.length harmonics) (HarmonicProperties 0 0))
                                 | otherwise = harmonics
                                oldVal = S.unsafeIndex h' idx'
                                newVal
                                  | idx >= firstPhaseIdx =
                                      oldVal { phase = changeParam predefinedHarmonicsPhases (phase oldVal) inc }
                                  | otherwise =
                                      oldVal { volume = changeParam predefinedHarmonicsVolumes (volume oldVal) inc }
                            in instr { harmonics_ = h' S.// [(idx', newVal)] }
                  _ -> instr


            idx = (editiontIndex edit) `mod` (countEditables mode)

          _ -> [])
        $ isArrow k)
    $ _game $ getGameState' g

   where

    keyToNote = \case
      -- NOTE GLFW uses the US keyboard layout to name keys: https://en.wikipedia.org/wiki/British_and_American_keyboards
      -- lower keys
      GLFW.Key'Z -> Just $ InstrumentNote Do $ noOctave - 1
      GLFW.Key'S -> Just $ InstrumentNote Réb $ noOctave - 1
      GLFW.Key'X -> Just $ InstrumentNote Ré $ noOctave - 1
      GLFW.Key'D -> Just $ InstrumentNote Mib $ noOctave - 1
      GLFW.Key'C -> Just $ InstrumentNote Mi $ noOctave - 1
      GLFW.Key'V -> Just $ InstrumentNote Fa $ noOctave - 1
      GLFW.Key'G -> Just $ InstrumentNote Solb $ noOctave - 1
      GLFW.Key'B -> Just $ InstrumentNote Sol $ noOctave - 1
      GLFW.Key'H -> Just $ InstrumentNote Lab $ noOctave - 1
      GLFW.Key'N -> Just $ InstrumentNote La $ noOctave - 1
      GLFW.Key'J -> Just $ InstrumentNote Sib $ noOctave - 1
      GLFW.Key'M -> Just $ InstrumentNote Si $ noOctave - 1
      GLFW.Key'Comma -> Just $ InstrumentNote Do $ noOctave + 0
      GLFW.Key'L -> Just $ InstrumentNote Réb $ noOctave + 0
      GLFW.Key'Period -> Just $ InstrumentNote Ré $ noOctave + 0
      GLFW.Key'Semicolon -> Just $ InstrumentNote Mib $ noOctave + 0
      GLFW.Key'Slash -> Just $ InstrumentNote Mi $ noOctave + 0
      -- upper keys
      GLFW.Key'Q -> Just $ InstrumentNote Do $ noOctave + 0
      GLFW.Key'2 -> Just $ InstrumentNote Réb $ noOctave + 0
      GLFW.Key'W -> Just $ InstrumentNote Ré $ noOctave + 0
      GLFW.Key'3 -> Just $ InstrumentNote Mib $ noOctave + 0
      GLFW.Key'E -> Just $ InstrumentNote Mi $ noOctave + 0
      GLFW.Key'R -> Just $ InstrumentNote Fa $ noOctave + 0
      GLFW.Key'5 -> Just $ InstrumentNote Solb $ noOctave + 0
      GLFW.Key'T -> Just $ InstrumentNote Sol $ noOctave + 0
      GLFW.Key'6 -> Just $ InstrumentNote Lab $ noOctave + 0
      GLFW.Key'Y -> Just $ InstrumentNote La $ noOctave + 0
      GLFW.Key'7 -> Just $ InstrumentNote Sib $ noOctave + 0
      GLFW.Key'U -> Just $ InstrumentNote Si $ noOctave + 0
      GLFW.Key'I -> Just $ InstrumentNote Do $ noOctave + 1
      GLFW.Key'9 -> Just $ InstrumentNote Réb $ noOctave + 1
      GLFW.Key'O -> Just $ InstrumentNote Ré $ noOctave + 1
      GLFW.Key'0 -> Just $ InstrumentNote Mib $ noOctave + 1
      GLFW.Key'P -> Just $ InstrumentNote Mi $ noOctave + 1
      GLFW.Key'LeftBracket -> Just $ InstrumentNote Fa $ noOctave + 1
      GLFW.Key'Equal -> Just $ InstrumentNote Solb $ noOctave + 1
      GLFW.Key'RightBracket -> Just $ InstrumentNote Sol $ noOctave + 1
      _ -> Nothing


changeParam :: (Ord a) => Set a -> a -> Int -> a
changeParam predefined current direction
  | direction < 0 = fromMaybe current $ Set.lookupLT current predefined
  | direction > 0 = fromMaybe current $ Set.lookupGT current predefined
  | otherwise = current

instrumentFile :: FilePath
instrumentFile = "instruments/last.inst"

loadInstrument :: IO Instrument
loadInstrument = doesFileExist instrumentFile >>= bool
  (return organicInstrument)
  (do
    bl <- BL.readFile instrumentFile
    let len = BL.length bl
    either
      (\(_,offset,str) -> fail $ "The file '" ++ instrumentFile ++ "' is corrupt:" ++ show (offset,str))
      (\(_,offset,res :: Instrument) ->
        if fromIntegral len == offset
          then
            return res
          else
            fail $ "Not all content has been used :" ++ show (len,offset) ) $
      (decodeOrFail bl))

saveInstrument :: Instrument -> IO ()
saveInstrument i = do
  createDirectories instrumentFile
  withFile instrumentFile WriteMode $ \h ->
    BL.hPutStr h (encode i)

instance GameLogic SynthsGame where

  type ServerT SynthsGame = SynthsServer
  type StatefullKeysT SynthsGame = SynthsStatefullKeys
  type ClientOnlyEvtT SynthsGame = SynthsGameEvent
  type PollContextT SynthsGame = PortMidi.PMStream

  produceEventsByPolling = EventProducerByPolling {
    initializeProducer = do
      PortMidi.initialize >>= either
        (return . Left . pack . (++) "midi initialize:" . show)
        (const $ PortMidi.getDefaultInputDeviceID >>= maybe
          (return $ Left "no default midi device")
          (\did ->
            PortMidi.openInput did >>= either
            (return . Left . pack . (++) "open midi device:" . show)
            (return . Right . Just)))
    , produceEvents = \stream mayGame -> do
      -- 100 microseconds is the minimal time between calls (measured using console prints).
      -- but this is achieved only by setting a lower value like so:
      let dt = fromSecs 0.000001
      PortMidi.poll stream >>= either
        (return . Left . pack . (++) "midi poll:" . show)
        (\case
            PortMidi.NoError'NoData -> do
              return $ Right ([],[],Just dt)
            PortMidi.GotData -> do
              -- even if mayGame is 'Nothing', we deque from the midi queue to avoid
              -- overflow.
              evts <- PortMidi.readEvents stream
              return $ maybe
                (Right ([],[],Just dt))
                (\(SynthsGame _ _ _ instr _ _) ->
                  (\l -> Right ([],map (ClientAppEvt . PlayNote) l,Just dt)) $
                    catMaybes $
                    map (maybe Nothing (\case
                      NoteOff _ key _ ->
                        Just $ StopNote $ mkInstrumentNote (fromIntegral key) instr
                      NoteOn _ key 0 ->
                        Just $ StopNote $ mkInstrumentNote (fromIntegral key) instr
                      NoteOn _ key vel ->
                        Just $ StartNote (mkInstrumentNote (fromIntegral key) instr) $ mkNoteVelocity vel
                      _ ->
                        Nothing
                      ) . msgToMidi . PortMidi.decodeMsg . PortMidi.message)
                      evts)
                mayGame)
    , terminateProducer =
        const $ PortMidi.terminate >>= either (return . Left . pack . show) (const $ return $ Right ())
    }

  mapInterpretedKey _ _ _ = return []

  onClientOnlyEvent e = do
    mayNewEnvMinMaxs <-
      getIGame >>= maybe (liftIO initialGame) return >>= \(SynthsGame _ _ _ instr (EnvelopePlot _ viewmode) _) ->
        case e of
          ChangeInstrument i -> do
            liftIO $ saveInstrument i
            Just . toParts viewmode <$> liftIO (envelopeShape i)
          ToggleEnvelopeViewMode -> Just . toParts (toggleView viewmode) <$> liftIO (envelopeShape instr)
          _ -> return Nothing
    getIGame >>= maybe (liftIO initialGame) return >>= \g@(SynthsGame _ _ pressed _ _ _) -> withAnim $ putIGame $ case e of
      ChangeInstrument i -> g {
          instrument = i
        , envelopePlot = EnvelopePlot (fromMaybe (error "logic") mayNewEnvMinMaxs) $ envViewMode $ envelopePlot g
      }
      ToggleEnvelopeViewMode -> g {
        envelopePlot = EnvelopePlot (fromMaybe (error "logic") mayNewEnvMinMaxs) $ toggleView $ envViewMode $ envelopePlot g }
      ToggleEditMode -> g {edition = toggleEditMode $ edition g}
      ChangeEditedFeature i -> g {edition = setEditionIndex i $ edition g}
      InsertPressedKey k n -> g { clientPressedKeys = Map.insert k n pressed }
      RemovePressedKey k -> g { clientPressedKeys = Map.delete k pressed }


  onServerEvent e =
    -- TODO force withAnim when using putIGame ?
    getIGame >>= maybe (liftIO initialGame) return >>= \g -> withAnim $ putIGame $ case e of
      NewLine seqId loopId ->
        g { pianoLoops = Map.insertWith Map.union seqId (Map.singleton loopId mkEmptyPressedKeys) $ pianoLoops g }
      PianoValue creator x -> either
        (\i ->
          g {pianos = Map.insert i x $ pianos g})
        (\(seqId,loopId) ->
          g {pianoLoops = Map.insertWith Map.union seqId (Map.singleton loopId x) $ pianoLoops g})
        creator

instance GameDraw SynthsGame where

  drawBackground (Screen _ center@(Coords _ centerC)) g@(SynthsGame pianoClients pianoLoops_ _ _ (EnvelopePlot curves _) _) = do
    drawInstructions Horizontally (Just 15) g (mkCentered $ move 21 Up center) >>= \(Alignment _ ref) -> do
      ref2 <- case curves of
        [] -> return ref
        [ahds,r] -> do
          let coordsEnv = move 45 LEFT $ move 1 Down ref
              heightPart = 20
              szAHDS = Size heightPart $ fromIntegral $ widthPart ahds
              szR = Size heightPart $ fromIntegral $ widthPart r
          drawEnv 0 ahds coordsEnv                        szAHDS (rgb 3 2 1)
          drawEnv 2 r    (move (widthPart ahds) RIGHT coordsEnv) szR    (rgb 2 3 1)
          return $ move (fromIntegral heightPart + 7) Down ref
        _ -> error "logic"
      ref3 <- showPianos
        "Players"
        showPlayerName
        pianoClients >>= drawPiano (move 1 Down ref2)
      foldM_
        (\r ((SequencerId seqId), seqPianoLoops) -> do
          showPianos
            ("Sequence " <> pack (show seqId))
            (\(LoopId creator idx) -> flip (<>) (" " <> CS.colored (pack (show idx)) (rgb 2 2 2)) <$> showPlayerName creator)
            seqPianoLoops >>= drawPiano r)
          ref3
          $ Map.assocs pianoLoops_
      return center

   where

    drawPiano (Coords r _) allStrs = do
      let maxL = fromMaybe 0 $ maximumMaybe $ map CS.countChars allStrs
          right = move (quot maxL 2) RIGHT $ Coords r centerC
      (Alignment _ res) <- foldM
        (\a str -> drawAligned str a)
        (mkRightAlign right)
        allStrs
      return res


    drawEnv offsetLegend (EnvelopePart resampled _) ul (Size h' _) fgColor = do
      let h = fromIntegral h'
          ll = move h Down ul
          color = onBlack fgColor
          heights (MinMax a b _) = [round (a*fromIntegral h)..round (b*fromIntegral h)]
      mapM_
        (\(i,mm) ->
          mapM_
            (\j -> drawGlyph (textGlyph '+') (translate ll $ Coords (-j) i) color)
            $ heights mm)
        $ zip [0..] resampled
      foldM_
        (\(cur,pos) (MinMax _ _ n) -> do
          let (q,r) = quotRem pos 4
              he
                | mod q 2 == 0 = 2
                | otherwise = 3
          when (r == 0) $ drawAt (CS.colored (pack $ show cur) fgColor) (move pos RIGHT $ move (offsetLegend + he) Down ll)
          return (cur + n,pos+1))
        (0,0)
        resampled
        {-
      drawAligned_
        (CS.colored (pack $ show nSamples) color)
        $ mkRightAlign $ move (fromIntegral w - 1) RIGHT $ move 3 Down ll
-}
instance ServerInit SynthsServer where

  type ClientViewT SynthsServer = SynthsClientView

  mkInitialState _ = return ((), SynthsServer mempty $ SequencerId 10) -- the first 9 sequencers are reserved

  mkInitialClient = SynthsClientView mkEmptyPressedKeys mkEmptyRecording 0

instance ServerInParallel SynthsServer


instance Server SynthsServer where

  type ServerEventT SynthsServer = SynthsServerEvent

  greetNewcomer' =
    -- Send the currently started notes so that the newcomer
    -- hears exactly what other players are hearing.

    -- In this loop we have no race condition because to modify currently pressed keys, a client
    -- handler must take the MVar lock of server state which we have taken here.
    map (fmap unClientView) . Map.assocs <$> gets clientsMap >>=
      return . concatMap
        (\(i,(SynthsClientView piano _ _)) -> pianoEvts (Left i) piano)

instance ServerClientLifecycle SynthsServer where

  onStartClient _ =
    Map.assocs <$> getsState srvSequencers >>=
      mapM_
        (\(seqId,s) -> do
          se@(Sequencer _ _ musLines) <- liftIO $ takeMVar s
          mapM_
            (\(loopId,(MusicLoop _ v)) -> do
              piano <- liftIO $ takeMVar v
              case pianoEvts (Right (seqId, loopId)) piano of
                [] -> return ()
                evts@(_:_) -> notifyClientN' evts
              liftIO $ putMVar v piano)
            $ Map.assocs musLines
          liftIO $ putMVar s se)

  clientCanJoin _ = do
    -- A client has just connected, we make it be part of the current game:
    notifyClient' $ EnterState $ Included $ PlayLevel Running
    return True

instance ServerClientHandler SynthsServer where

  type StateValueT  SynthsServer = GameStateValue -- This is required

  type ClientEventT SynthsServer = SynthClientEvent

  handleClientEvent e = case e of
    PlayNote n -> do
      onRecordableNote n >>= notifyEveryoneN'
      return []
    ForgetCurrentRecording -> do
      adjustClient_ $ \s -> s {_recording = mkEmptyRecording }
      return []
    WithMonoLineSequencer ->
      usingRecording $ \loopId recording now ->
        addSequencer Nothing loopId recording now
    WithMultiLineSequencer seqId ->
      usingRecording $ \loopId recording now ->
        Map.lookup seqId . srvSequencers <$> gets unServerState >>= maybe
          (addSequencer (Just seqId) loopId recording now)
          (\sequencer ->
            liftIO (modifyMVar sequencer (\s@(Sequencer start _ _) ->
              liftIO (insertRecording recording loopId s) >>= return . either
                (\err -> (s, Left err))
                (\(s',mus) -> (s', Right (s', mus, start...now))))) >>= either
                (\msg -> do
                  notifyClient' $ Warn msg
                  return [])
                (\((Sequencer start _ _), (MusicLoop mus pianoV), progress) -> do
                  notifyEveryone $ NewLine seqId loopId
                  return
                    [ (\v -> playOnceFrom
                          (\m -> do
                            (nChanged',newPiano') <- liftIO $ modifyMVar pianoV $ \piano ->
                              let (nChanged,newPiano) = onMusic m piano
                              in return $ (newPiano, (nChanged,newPiano))
                            when (nChanged' > 0) $
                              modifyMVar_ v $ execStateT $ playLoopMusic seqId loopId newPiano' m)
                          start progress mus)
                    ]))

   where

    onRecordableNote :: (MonadIO m, MonadState (ServerState SynthsServer) m, MonadReader ConstClientView m)
                       => MusicalEvent
                       -> m [ServerEvent SynthsServer]
    onRecordableNote n = do
      cid <- asks clientId
      fmap (_piano . unClientView) . Map.lookup cid <$> gets clientsMap >>= maybe
        (return []) -- should never happen
        (\piano -> do
          let (countChangedNotes, piano') = onMusic n piano
          if countChangedNotes == 0
            then
              return []
            else do
              t <- liftIO getSystemTime
              creator <- asks clientId
              newpiano <- _piano <$> adjustClient (\s@(SynthsClientView _ recording _) ->
                    s { _piano = piano'
                      , _recording = recordMusic (ATM n t) recording })
              return
                [ ServerAppEvt $ PianoValue (Left creator) newpiano
                , PlayMusic n
                ])

    playLoopMusic :: (MonadState (ServerState SynthsServer) m, MonadIO m)
                  => SequencerId -> LoopId -> PressedKeys -> MusicalEvent -> m ()
    playLoopMusic seqId loopId newPiano n =
      notifyEveryoneN'
        [ ServerAppEvt $ PianoValue (Right (seqId,loopId)) newPiano
        , PlayMusic n
        ]

    addSequencer maySeqId loopId recording now =
      liftIO (mkSequencerFromRecording loopId recording now) >>= either
        (\msg -> do
          notifyClient' $ Warn msg
          return [])
        (\sequencerV -> do
          sequencer <- liftIO $ newMVar sequencerV
          seqId <- modifyState' $ \(SynthsServer m i) ->
            let (sid,succI) = maybe (i,succ i) (\j -> (j,i)) maySeqId
            in (sid,SynthsServer (Map.insert sid sequencer m) succI)
          notifyEveryone $ NewLine seqId loopId
          return
            [ (\v -> forever $ do
                now' <- getSystemTime
                modifyMVar sequencer (\(Sequencer _ a b) -> do
                  let s = (Sequencer now' a b)
                  return (s,s))
                  >>= \(Sequencer startTime duration vecs) -> do
                    forM_ (Map.assocs vecs) $ \(lid,(MusicLoop vec pianoV)) ->
                      void $ forkIO $
                        playOnce
                          (\m -> do
                            (nChanged',newPiano') <- modifyMVar pianoV $ \piano ->
                              let (nChanged,newPiano) = onMusic m piano
                              in return $ (newPiano, (nChanged,newPiano))
                            when (nChanged' > 0) $
                              modifyMVar_ v $ execStateT $ playLoopMusic seqId lid newPiano' m)
                          vec
                          startTime
                    threadDelay $ fromIntegral $ toMicros $ duration)])

    usingRecording x = do
      cid <- asks clientId
      fmap (_piano . unClientView) . Map.lookup cid <$> gets clientsMap >>= maybe
        (return [])
        (\piano -> do
          concat <$> forM (releaseAllKeys piano) onRecordableNote >>= notifyEveryoneN'
          fmap (_recording . unClientView) . Map.lookup cid <$> gets clientsMap >>= maybe
            (return [])
            (\recording -> do
              creator <- asks clientId
              (SynthsClientView _ _ idx) <- adjustClient
                (\(SynthsClientView _ _ loopIdx) ->
                  SynthsClientView mkEmptyPressedKeys mkEmptyRecording $ loopIdx + 1)
              let loopId = LoopId creator $ idx - 1
              liftIO getSystemTime >>= x loopId recording))

pianoEvts :: Either ClientId (SequencerId,LoopId) -> PressedKeys -> [ServerEvent SynthsServer]
pianoEvts idx v@(PressedKeys m) =
  ServerAppEvt (PianoValue idx v) :
  concatMap
    (\(note,n) ->
      replicate n $ PlayMusic (StartNote note 1))
    (Map.assocs m)

instance ServerCmdParser SynthsServer


{-# INLINABLE showPianos #-}
showPianos :: MonadReader e m
           => Text
           -> (a -> m ColorString)
           -> Map a PressedKeys
           -> m [ColorString]
showPianos _ _ Tip = return []
showPianos title showKey m = do
  let minNote = noteToMidiPitch Do $ noOctave - 1
      maxNote = noteToMidiPitch Sol $ noOctave + 1
  showArray (Just (CS.colored title $ rgb 2 1 2,"")) <$> mapM
    (\(i,piano) -> flip (,) (CS.colored (pack $ showKeys minNote maxNote piano) $ rgb 3 1 2) <$> showKey i)
    (Map.assocs m)

showKeys :: MidiPitch
         -- ^ From
         -> MidiPitch
         -- ^ To
         -> PressedKeys
         -> String
showKeys from to (PressedKeys m) =
  go [] [from..to] $ Set.toAscList $ Map.keysSet m
 where
  go l [] _ = reverse l
  go l (k:ks) remainingPressed =
    case remainingPressed of
      [] -> go' freeChar remainingPressed
      (InstrumentNote pressedNoteName pressedNoteOctave _):ps ->
        if (pressedNoteName, pressedNoteOctave) == midiPitchToNoteAndOctave k
          then
            go' pressedChar ps
          else
            go' freeChar remainingPressed
   where
    go' c remPressed = go (maybeToList space ++ [c] ++ l) ks remPressed

    space = case ks of
      [] -> Nothing
      s:_ -> case fst $ midiPitchToNoteAndOctave s of
        Fa -> Just ' '
        Do -> Just ' '
        _ -> Nothing

    freeChar
      | whiteKeyPitch k = '-'
      | otherwise = '*'

    pressedChar
      | whiteKeyPitch k = '_'
      | otherwise = '.'
