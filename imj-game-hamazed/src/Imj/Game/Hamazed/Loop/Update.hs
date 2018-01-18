{-# OPTIONS_HADDOCK hide #-}

{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE FlexibleContexts #-}

module Imj.Game.Hamazed.Loop.Update
      ( update
      ) where

import           Imj.Prelude

import           Data.Maybe(catMaybes, isNothing)

import           Imj.Game.Hamazed.Types
import           Imj.Game.Hamazed.Color
import           Imj.Game.Hamazed.Infos
import           Imj.Game.Hamazed.Loop.Create
import           Imj.Game.Hamazed.Loop.Event
import           Imj.Game.Hamazed.Loop.Event.Priorities
import           Imj.Game.Hamazed.Loop.Timing
import           Imj.Game.Hamazed.State
import           Imj.Game.Hamazed.World
import           Imj.Game.Hamazed.World.Number
import           Imj.Game.Hamazed.World.Ship
import           Imj.Game.Hamazed.World.Space
import           Imj.Game.Hamazed.World.Space.Types
import           Imj.GameItem.Weapon.Laser
import           Imj.Geo.Continuous
import           Imj.Geo.Discrete
import           Imj.Physics.Discrete.Collision
import           Imj.Graphics.ParticleSystem.Design.Types
import           Imj.Graphics.ParticleSystem.Design.Update
import           Imj.Graphics.ParticleSystem
import           Imj.Graphics.UI.RectContainer
import           Imj.Util


-- | Updates the state. It needs IO just to generate random numbers in case
-- 'Event' is 'StartLevel'
{-# INLINABLE update #-}
update :: (MonadState AppState m, MonadIO m)
       => Event
       -- ^ The 'Event' that should be handled here.
       -> m ()
update evt =
  getGame >>= updateGame >>= putGameState
 where
   updateGame
    (Game _ params
     state@(GameState b world@(World c d space systems) futWorld f h@(Level level target mayLevelFinished) anim s)) =
    case evt of
      StartLevel nextLevel -> do
        (Screen sz _) <- getCurScreen
        mkInitialState params sz nextLevel (Just state) >>= \case
          Left err -> error err
          Right st -> return st
      (Timeout (Deadline gt _ AnimateUI)) -> do
        let st@(GameState _ _ _ _ _ anims _) = updateAnim gt state
        if isFinished anims
          then flip startGameState st <$> liftIO getSystemTime
          else return st
      (Timeout (Deadline _ _ DisplayContinueMessage)) ->
        return $ case mayLevelFinished of
          Just (LevelFinished stop finishTime _) ->
            let newLevel = Level level target (Just $ LevelFinished stop finishTime ContinueMessage)
            in GameState b world futWorld f newLevel anim s
          Nothing -> state
      (Timeout (Deadline k priority AnimateParticleSystems)) -> do
        let newSystems = mapMaybe (\pr@(Prioritized p a) ->
                                      if p == priority && getDeadline a == k
                                        then fmap (Prioritized p) $ updateParticleSystem a
                                        else Just pr) systems
        return $ GameState b (World c d space newSystems) futWorld f h anim s
      (Timeout (Deadline gt _ MoveFlyingItems)) -> do
        let movedState = GameState (Just $ addDuration gameMotionPeriod gt) (moveWorld gt world) futWorld f h anim s
        onHasMoved movedState gt
      Action Laser dir ->
        if isFinished anim
          then do
            t <- liftIO getSystemTime
            onLaser state dir t
          else
            return state
      Action Ship dir ->
        return $ accelerateShip' dir state
      (Interrupt _) -> return state
      ToggleEventRecording -> return state
      EndGame -> -- TODO instead, go back to game configuration ?
        return state

onLaser :: (MonadState AppState m)
        => GameState
        -> Direction
        -> SystemTime
        -> m GameState
onLaser (GameState b world@(World _ (BattleShip posspeed ammo safeTime collisions)
                                  space@(Space _ sz _) systems)
                   futureWorld g level@(Level i target finished)
                   (UIAnimation (UIEvolutions j upDown left) k l) s)
  dir t = do
  mode <- getMode
  (Screen _ center) <- getCurScreen
  let (remainingBalls, destroyedBalls, maybeLaserRay, newAmmo) = laserEventAction dir world
  outerSpaceParticleSystems_ <-
    if null destroyedBalls
      then
        maybe (return []) (outerSpaceParticleSystems t world) maybeLaserRay
      else
        return []
  newSystems <- destroyedNumbersParticleSystems (Left t) dir world destroyedBalls
  let laserSystems = maybe [] (`laserParticleSystems` t) maybeLaserRay
      allSystems = newSystems ++ laserSystems ++ outerSpaceParticleSystems_ ++ systems
      newWorld = World remainingBalls (BattleShip posspeed newAmmo safeTime collisions)
                       space allSystems
      destroyedNumbers = map (\(Number _ n) -> n) destroyedBalls
      allShotNumbers = g ++ destroyedNumbers
      newLeft =
        if null destroyedNumbers && ammo == newAmmo
          then
            left
          else
            let frameSpace = mkRectContainerWithCenterAndInnerSize center sz
                infos = mkLeftInfo Normal newAmmo allShotNumbers level
                (horizontalDist, verticalDist) = computeViewDistances mode
                (_, _, leftMiddle, _) = getSideCenters $ mkRectContainerAtDistance frameSpace horizontalDist verticalDist
            in mkTextAnimRightAligned leftMiddle leftMiddle infos 1 0 -- 0 duration, since animation is over anyway
      newFinished = finished <|> checkTargetAndAmmo newAmmo (sum allShotNumbers) target t
      newLevel = Level i target newFinished
      newAnim = UIAnimation (UIEvolutions j upDown newLeft) k l
  return $ assert (isFinished newAnim) $ GameState b newWorld futureWorld allShotNumbers newLevel newAnim s

-- | The world has moved, so we update it.
onHasMoved :: (MonadState AppState m)
           => GameState
           -> KeyTime
           -> m GameState
onHasMoved
  (GameState b world@(World balls ship@(BattleShip _ _ safeTime collisions) space systems)
             futureWorld shotNums (Level i target finished) anim s)
  keyTime@(KeyTime t) = do
  newSystems <- shipParticleSystems world keyTime
  let remainingBalls =
        if isNothing safeTime
          then
            filter (`notElem` collisions) balls
          else
            balls
      newWorld = World remainingBalls ship space (newSystems ++ systems)
      finishIfShipCollides =
        maybe
          (case map (\(Number _ n) -> n) collisions of
            [] -> Nothing
            l  -> Just $ LevelFinished (Lost $ "collision with " <> showListOrSingleton l) t InfoMessage )
          (const Nothing)
            safeTime
      newLevel = Level i target (finished <|> finishIfShipCollides)
  return $ assert (isFinished anim) $ GameState b newWorld futureWorld shotNums newLevel anim s

outerSpaceParticleSystems :: (MonadState AppState m)
                          => SystemTime
                          -> World
                          -> LaserRay Actual
                          -> m [Prioritized ParticleSystem]
outerSpaceParticleSystems t world@(World _ _ space _) ray@(LaserRay dir _ _) = do
  let laserTarget = afterEnd ray
      char = materialChar Wall
  case location laserTarget space of
        InsideWorld -> return []
        OutsideWorld ->
          if distanceToSpace laserTarget space > 0
            then do
              let color _fragment _level _frame =
                    if 0 == _fragment `mod` 2
                      then
                        cycleOuterColors1 $ quot _frame 4
                      else
                        cycleOuterColors2 $ quot _frame 4
                  pos = translateInDir dir laserTarget
                  (speedAttenuation, nRebounds) = (0.3, 3)
              mode <- getMode
              screen <- getCurScreen
              case scopedLocation world mode screen NegativeWorldContainer pos of
                  InsideWorld -> outerSpaceParticleSystems' world NegativeWorldContainer pos
                                  dir speedAttenuation nRebounds color char t
                  OutsideWorld -> return []
            else do
              let color _fragment _level _frame =
                    if 0 == _fragment `mod` 3
                      then
                        cycleWallColors1 $ quot _frame 4
                      else
                        cycleWallColors2 $ quot _frame 4
                  (speedAttenuation, nRebounds) = (0.4, 5)
              outerSpaceParticleSystems' world (WorldScope Wall) laserTarget
                   dir speedAttenuation nRebounds color char t

outerSpaceParticleSystems' :: (MonadState AppState m)
                           => World
                           -> Scope
                           -> Coords Pos
                           -> Direction
                           -> Float
                           -> Int
                           -> (Int -> Int -> Frame -> LayeredColor)
                           -> Char
                           -> SystemTime
                           -> m [Prioritized ParticleSystem]
outerSpaceParticleSystems' world scope afterLaserEndPoint dir speedAttenuation nRebounds colorFuncs char t = do
  let speed = scalarProd 0.8 $ speed2vec $ coordsForDirection dir
  envFuncs <- envFunctions world scope
  return
    $ fmap (Prioritized particleSystDefaultPriority)
    $ fragmentsFreeFallWithReboundsThenExplode
        speed afterLaserEndPoint speedAttenuation nRebounds colorFuncs char
        (Speed 1) envFuncs (Left t)


laserParticleSystems :: LaserRay Actual
                     -> SystemTime
                     -> [Prioritized ParticleSystem]
laserParticleSystems ray t =
  catMaybes [fmap (Prioritized particleSystLaserPriority)
            $ laserShot ray cycleLaserColors (Left t)]


accelerateShip' :: Direction -> GameState -> GameState
accelerateShip' dir (GameState c (World wa ship wc wd) b f g h s) =
  let newShip = accelerateShip dir ship
      world = World wa newShip wc wd
  in GameState c world b f g h s

updateAnim :: KeyTime -> GameState -> GameState
updateAnim kt (GameState _ curWorld futWorld j k (UIAnimation evolutions _ it) s) =
  let nextIt@(Iteration _ nextFrame) = nextIteration it
      (world, worldAnimDeadline) =
        maybe
          (futWorld, Nothing)
          (\dt ->
           (curWorld, Just $ addDuration (floatSecondsToDiffTime dt) kt))
          $ getDeltaTime evolutions nextFrame
      wa = UIAnimation evolutions worldAnimDeadline nextIt
  in GameState Nothing world futWorld j k wa s
