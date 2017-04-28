{-# LANGUAGE ScopedTypeVariables #-}

module Lib where

import Options.Applicative
import System.Clock
import GHC.Int
import System.Random

import Control.Monad.IO.Class (liftIO)
import Control.Monad (unless)
import Data.Maybe (fromMaybe)
import Data.Monoid ((<>))
import Data.List (nub)
import Control.Concurrent (threadDelay)
import qualified Control.Distributed.Process as D
import qualified Control.Distributed.Process.Node as D


import Network.Transport
import Network.Transport.TCP (createTransport, defaultTCPParameters)

import qualified Data.ByteString.Char8 as B8

import qualified Control.Distributed.Process.Raft as Raft

data Config = Config
  { cfgPeersFile :: FilePath
  , cfgListen :: String
  , cfgHeartbeatRate :: Int -- millis
  , cfgElectionTimeout :: Int -- millis
  , cfgSendFor :: Int -- seconds
  , cfgWaitFor :: Int -- seconds
  , cfgRndSeed :: Maybe Int
  }

config :: Parser Config
config = Config
  <$>  strOption
        (long "peers" <>
         metavar "FILE" <>
         help "specify whitespace-separated list of peers")
  <*>  strOption
        (long "listen" <> short 'l' <>
         metavar "IP:PORT" <>
         help "specify current node's hostname:port to listen on")
  <*>  option auto
        (long "heartbeat" <> short 'b' <>
        metavar "MILLIS" <>
        help "set hearbeat in milliseconds" <>
        value 30)
  <*>  option auto
        (long "election-timeout" <> short 'e' <>
        metavar "MILLIS" <>
        help "set election timeout's lower boundary (higher boundary is 2x of lower boundary)" <>
        value 100)
  <*>  option auto
        (long "send-for" <> short 's' <>
        metavar "SECONDS" <>
        help "duration of the sending period")
  <*>  option auto
        (long "wait-for" <> short 'w' <>
        metavar "SECONDS" <>
        help "duration of the receiving period")
  <*>  optional (option auto
        (long "with-seed" <> short 'r' <>
        metavar "SEED" <>
        help ""))

makeNodeId :: String -> D.NodeId
makeNodeId = D.NodeId . EndPointAddress . B8.pack . (++ ":0")

readPeers :: FilePath -> IO [D.NodeId]
readPeers fn = map makeNodeId . words <$> readFile fn

start :: IO ()
start = do
  cfg <-
    execParser $ info
      (helper <*> config)
      (fullDesc <> progDesc "Temezi node")

  let host = takeWhile (/= ':') (cfgListen cfg)
      port = drop 1 . dropWhile (/= ':') $ cfgListen cfg

  peerNodes <-
      filter (/= makeNodeId (cfgListen cfg)) .
        nub <$>
          readPeers (cfgPeersFile cfg)

  transport <-
    either (error . show) id <$>
      createTransport host port defaultTCPParameters

  node <- D.newLocalNode transport D.initRemoteTable

  let raftConfig =
        Raft.RaftConfig
          (cfgElectionTimeout cfg)
          (cfgHeartbeatRate cfg)
          peerNodes

  case mkStdGen <$> cfgRndSeed cfg of
    Just seed -> setStdGen seed
    Nothing -> return ()

  sendPeriodStart <- getTime Monotonic
  let sendPeriodEnd = sec sendPeriodStart + fromIntegral (cfgSendFor cfg)

  D.runProcess node $ do
    server <- Raft.startRaft raftConfig :: D.Process (Raft.RaftServer Double)

    runSendPeriod server sendPeriodEnd

    liftIO (threadDelay (cfgWaitFor cfg * 1000000))
    D.say "Retrieving..."
    consensusLog <- fromMaybe [] <$> Raft.retrieve server
    liftIO (print (makeResultTuple consensusLog))

makeResultTuple :: [Double] -> (Int, Double)
makeResultTuple consensusLog = (l, s)
  where
    l = length consensusLog
    s = sum [i * x | (i, x) <- zip [0..] consensusLog]

commitNumber :: Raft.RaftServer Double -> Int64 -> Double -> D.Process ()
commitNumber server sendPeriodEnd number = do
    result <- Raft.commit server number
    liftIO (threadDelay 100000)
    currentTime <- liftIO (getTime Monotonic)
    unless (result || (sec currentTime >= sendPeriodEnd)) $
      D.say "Retrying commit..." >> commitNumber server sendPeriodEnd number


runSendPeriod :: Raft.RaftServer Double -> Int64 -> D.Process ()
runSendPeriod server sendPeriodEnd = do
    randomNumber <- liftIO (randomRIO (0.0001 :: Double, 1))
    commitNumber server sendPeriodEnd randomNumber
    currentTime <- liftIO (getTime Monotonic)
    unless (sec currentTime >= sendPeriodEnd) $
      D.say "Sending next value" >> runSendPeriod server sendPeriodEnd
