{-# LANGUAGE NoImplicitPrelude #-}

module Test.Imj.Sums
         ( testSums
         ) where

import           Imj.Prelude
import           Prelude(logBase)
import           Control.Exception (evaluate)
import           Data.List(foldl', length)
import qualified Data.Set as Set(fromList, empty, singleton, filter, size)
import           Data.Text(pack)
import qualified Data.Text.IO as Text (putStr)
import           System.IO(putStr, putStrLn)

import           Imj.Graphics.Color
import           Imj.Graphics.Text.ColorString
import           Imj.Sums
import           Imj.Timing
import qualified Imj.Tree as Tree

testSums :: IO ()
testSums = do
  mkSums Set.empty 0 `shouldBe` Set.singleton Set.empty
  mkSums (Set.fromList [1,2,3,4,5]) 3
   `shouldBe` Set.fromList (map Set.fromList [[3],[1,2]])
  mkSums (Set.fromList [2,3,4,5]) 18
   `shouldBe` Set.empty
  mkSums (Set.fromList [2,3,4,5]) 1
   `shouldBe` Set.empty
  let maxHamazedNumbers = [1..15]
      maxSum = sum maxHamazedNumbers `quot` 2

  mkSumsArray Set.empty 0 `shouldBe` Set.singleton Set.empty
  mkSumsArray (Set.fromList [1,2,3,4,5]) 3
   `shouldBe` Set.fromList (map Set.fromList [[3],[1,2]])
  mkSumsArray (Set.fromList [2,3,4,5]) 18
   `shouldBe` Set.empty
  mkSumsArray (Set.fromList [2,3,4,5]) 1
   `shouldBe` Set.empty

  -- Using different implementations to find the number
  -- of different combinations of length < 6.
  -- The fastest way is to use a 'StrictTree' ('mkSumsStrict').

  let !numbers = Set.fromList maxHamazedNumbers
      measure n countCombinations =
        time $ void $ evaluate $
          countCombinations numbers (quot (maxSum * n) n) -- trick to force a new evaluation
      tests =
        [ ((\a b -> Set.size $ Set.filter  (\s -> Set.size s < 6) $ mkSums       a b)              , "mkSums")
        , ((\a b -> Set.size $ Set.filter  (\s -> Set.size s < 6) $ mkSumsArray  a b)              , "mkSumsArray")
        , ((\a b -> length   $ filter      (\s -> length   s < 6) $ mkSumsArray' a b)              , "mkSumsArray'")
        , ((\a b -> length   $ Tree.filter' (\s -> length   s < 6) $ mkSumsStrict a b)             , "mkSumsStrict filter'")
        , ((\a b -> length   $ Tree.toList $ Tree.filter (\s -> length   s < 6) $ mkSumsStrict a b), "mkSumsStrict filter")
        , ((\a b -> length   $ Tree.filter' (\s -> length   s < 6) $ mkSumsLazy   a b)             , "mkSumsLazy filter'")
        , ((\a b -> length   $ Tree.toList $ Tree.filter (\s -> length   s < 6) $ mkSumsLazy   a b), "mkSumsLazy filter")
        ]
  times <- mapM (\n -> mapM (measure n . fst) tests) [1..100] :: IO [[Time Duration System]]
  printTimes $ zip (map snd tests) $ map toMicros $ foldl' (zipWith (|+|)) (replicate 10 $ fromSecs 0) times

printTimes :: [(String, Int64)] -> IO ()
printTimes times = do
  putStrLn "(Graphical time has a logarithmic scale)"
  mapM_ (\(desc, dt) -> do
    let n = round $ countStars dt
        s = show dt
        s' = replicate (nCharsTime - length s) ' ' ++ s
        inColor = safeBuildTxt $ colored (pack $ replicate n '+') green <>
                                 colored (pack $ replicate (nStars - n) '.') (gray 14)
    putStr $ s' ++ " "
    Text.putStr inColor
    putStr $ " " ++ desc ++ "\n") times
 where
  nCharsTime = length $ show $ maximum $ map snd times
  nStars = 120
  countStars dt =
    let d = logBase minD (fromIntegral dt)
    in succ $ fromIntegral (pred nStars) * (d - 1) / (ratioMax - 1)
  ratioMax = logBase minD maxD
  maxD = fromIntegral $ maximum $ map snd times
  minD = fromIntegral $ minimum $ map snd times :: Float
time :: IO () -> IO (Time Duration System)
time action = do
  start <- getSystemTime
  action
  end <- getSystemTime
  return $ start...end

shouldBe :: (Show a, Eq a) => a -> a -> IO ()
shouldBe actual expected =
  if actual == expected
    then
      return ()
    else
      error $ "expected\n" ++ show expected ++ " but got\n" ++ show actual
