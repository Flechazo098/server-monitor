{-# LANGUAGE OverloadedStrings #-}

-- | monitor-backend entry point.
--
-- Protocol with the Tauri shell:
--   monitor-backend [--token <token>] [--config <path>]
-- prints @READY <port> <token>@ on stdout, then serves the read-only API on
-- 127.0.0.1:<port> until terminated.
module Main (main) where

import Control.Concurrent.STM (newTChanIO, newTVarIO)
import Control.Exception (SomeException, displayException, try)
import Data.Aeson (eitherDecodeFileStrict)
import Data.Text (Text)
import qualified Data.Text as T
import Monitor.Api.Server (runBackend)
import Monitor.Core.Types
import Monitor.Runtime.Worker (startWorkers)
import Monitor.Storage.SQLite (initDb)
import System.Directory (doesFileExist)
import System.Environment (getArgs, getExecutablePath)
import System.Exit (die)
import System.FilePath (takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)
import System.Random (newStdGen, randomRs)

-- | Parsed command-line options.
data Cli = Cli
  { cliToken  :: Maybe Text
  , cliConfig :: FilePath
  }

parseArgs :: [String] -> Cli
parseArgs = go (Cli Nothing "config.json")
  where
    go acc [] = acc
    go acc ("--token" : v : rest) = go acc { cliToken = Just (T.pack v) } rest
    go acc ("--config" : v : rest) = go acc { cliConfig = v } rest
    go acc (_ : rest) = go acc rest

-- | Resolve the config path. When the requested path does not exist,
-- fall back to @config.json@ next to the executable (the packaged layout,
-- and what a user double-clicking the binary expects).
resolveConfigPath :: FilePath -> IO FilePath
resolveConfigPath requested = do
  exists <- doesFileExist requested
  if exists
    then pure requested
    else do
      exe <- getExecutablePath
      let nextToExe = takeDirectory exe </> "config.json"
      existsExe <- doesFileExist nextToExe
      pure (if existsExe then nextToExe else requested)

-- | Fallback token when neither CLI nor config provides one.
genToken :: IO Text
genToken = do
  g <- newStdGen
  let chars = "abcdef0123456789"
      n = 32
  pure (T.pack (take n (map (chars !!) (randomRs (0, length chars - 1) g))))

main :: IO ()
main = do
  args <- getArgs
  let cli = parseArgs args
  cfgPath <- resolveConfigPath (cliConfig cli)
  hPutStrLn stderr ("monitor-backend: config " <> cfgPath)
  cfgResult <- try (eitherDecodeFileStrict cfgPath)
    :: IO (Either SomeException (Either String MonitorConfig))
  cfg <- case cfgResult of
    Left ex ->
      die
        ( "cannot load " <> cfgPath <> ": " <> displayException ex
          <> "\nusage: monitor-backend [--token <t>] [--config <path>]"
        )
    Right (Left err) -> die ("invalid config " <> cfgPath <> ": " <> err)
    Right (Right c) -> pure c
  initDb (cfgDbPath cfg)
  token <- maybe (maybe genToken pure (cfgToken cfg)) pure (cliToken cli)
  state <- AppState
    <$> newTVarIO mempty
    <*> newTChanIO
    <*> pure (cfgDbPath cfg)
    <*> newTVarIO mempty
  startWorkers state cfg
  hPutStrLn stderr
    ( "monitor-backend: monitoring " <> show (length (cfgServers cfg))
      <> " server(s), db=" <> cfgDbPath cfg
    )
  runBackend state token
