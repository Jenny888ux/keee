{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module Imj.Game.HighScores
    ( HighScores(..)
    , HighScore(..)
    , mkEmptyHighScores
    , insertScore
    , prettyShowHighScores
    ) where

import           Imj.Prelude
import           Data.Aeson(ToJSON(..), FromJSON(..))
import           Data.Binary(Binary(..))
import qualified Data.Map.Strict as Map
import           Data.Tuple(swap)
import           Data.HashMap.Strict(HashMap)
import qualified Data.HashMap.Strict as HMap
import           Data.Set(Set)
import qualified Data.Set as Set
import           Data.Text hiding (map, concatMap, foldl', filter)

import           Imj.Network
import           Imj.Game.Level

newtype HighScores = HighScores (HashMap (Set (ClientName Approved)) LevelNumber)
  deriving(Generic,Show)
instance Binary HighScores where
  put (HighScores m) = put $ HMap.toList m
  get = HighScores . HMap.fromList <$> get
instance NFData HighScores
instance ToJSON HighScores
instance FromJSON HighScores

data HighScore = HighScore !LevelNumber !(Set (ClientName Approved))
  deriving(Generic,Show)
instance Binary HighScore
instance NFData HighScore
instance ToJSON HighScore
instance FromJSON HighScore

mkEmptyHighScores :: HighScores
mkEmptyHighScores = HighScores mempty

insertScore :: HighScore -> HighScores -> HighScores
insertScore (HighScore n players) (HighScores hs) =
  HighScores $ HMap.insertWith max players n hs

prettyShowHighScores :: HighScores -> [Text]
prettyShowHighScores (HighScores h) =
  map (uncurry prettyShowHighScore)
  $ Map.toDescList
  $ Map.fromListWith
      Set.union
      $ map (fmap Set.singleton . swap)
      $ filter valid $ HMap.toList h
 where
  valid (s,_) = not $ Set.null s

prettyShowHighScore :: LevelNumber -> Set (Set (ClientName Approved)) -> Text
prettyShowHighScore (LevelNumber score) players =
  unwords $ map (pack . show . unClientName) (concatMap Set.toList $ Set.toList players) ++ ["..."] ++ [pack $ show score]
