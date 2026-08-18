{-# LANGUAGE OverloadedStrings #-}

-- | monitor-backend entry point.
--
-- Protocol with the Tauri shell:
--   monitor-backend [--token <token>] [--config <path>]
-- prints @READY <port> <token>@ on stdout, then serves the read-only API on
-- 127.0.0.1:<port> until terminated.
module Main (main) where

import Control.Concurrent.STM (newTChanIO, newTVarIO)
import Control.Applicative ((<|>))
import Control.Exception (SomeException, displayException, try)
import Control.Monad (unless)
import Data.Aeson (eitherDecodeFileStrict, eitherDecodeStrict')
import Data.Char (isSpace)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Monitor.Api.Server (runBackend)
import Monitor.Config (resolveConfigPaths, validateConfig)
import Monitor.Core.Types
import Monitor.Runtime.Worker (startWorkers)
import Monitor.Storage.SQLite (initDb)
import System.Directory (doesFileExist, getCurrentDirectory)
import System.Environment (getArgs, getExecutablePath, lookupEnv)
import System.Exit (die)
import System.FilePath (takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)

-- | Parsed command-line options.
data Cli = Cli
  { cliToken  :: Maybe Text
  , cliConfig :: FilePath
  }

parseArgs :: [String] -> Either String Cli
parseArgs = go (Cli Nothing "config.json")
  where
    go acc [] = Right acc
    go acc ("--token" : v : rest) = go acc { cliToken = Just (T.pack v) } rest
    go acc ("--config" : v : rest) = go acc { cliConfig = v } rest
    go _ ["--token"] = Left "--token requires a value"
    go _ ["--config"] = Left "--config requires a value"
    go _ (arg : _) = Left ("unknown argument: " <> arg)

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

main :: IO ()
main = do
  args <- getArgs
  cli <- either (die . (<> "\nusage: monitor-backend [--token <t>] [--config <path>]")) pure (parseArgs args)
  (cfg, configBase, protectedSource) <- loadConfig cli
  either (die . ("invalid config: " <>)) pure (validateConfig cfg)
  let resolvedCfg = resolveConfigPaths configBase cfg
  keysExist <- mapM (doesFileExist . scSshKey) (cfgServers resolvedCfg)
  unless (and keysExist) (die "invalid config: one or more SSH key files do not exist")
  initDb (cfgDbPath resolvedCfg)
  environmentToken <- fmap T.pack <$> lookupEnv "SERVER_MONITOR_AUTH_TOKEN"
  token <- maybe (die "authentication token required") pure (cliToken cli <|> environmentToken)
  unless (T.length token >= 24 && T.all (not . isSpace) token) $
    die "authentication token must contain at least 24 non-whitespace characters"
  state <- AppState
    <$> newTVarIO mempty
    <*> newTChanIO
    <*> pure (cfgDbPath resolvedCfg)
    <*> newTVarIO mempty
    <*> pure (cfgAlerts resolvedCfg)
    <*> pure (cfgCollection resolvedCfg)
  startWorkers state resolvedCfg
  hPutStrLn stderr
    ( "monitor-backend: monitoring " <> show (length (cfgServers resolvedCfg))
      <> " server(s); configuration=" <> if protectedSource then "protected" else "file"
    )
  runBackend state token

loadConfig :: Cli -> IO (MonitorConfig, FilePath, Bool)
loadConfig cli = do
  environmentJson <- lookupEnv "SERVER_MONITOR_CONFIG_JSON"
  case environmentJson of
    Just raw -> do
      base <- lookupEnv "SERVER_MONITOR_CONFIG_DIR" >>= maybe getCurrentDirectory pure
      config <- either (die . ("invalid protected configuration: " <>)) pure
        (eitherDecodeStrict' (T.encodeUtf8 (T.pack raw)))
      pure (config, base, True)
    Nothing -> do
      configPath <- resolveConfigPath (cliConfig cli)
      configResult <- try (eitherDecodeFileStrict configPath)
        :: IO (Either SomeException (Either String MonitorConfig))
      config <- case configResult of
        Left exception ->
          die
            ( "cannot load configuration: " <> displayException exception
              <> "\nusage: monitor-backend [--token <t>] [--config <path>]"
            )
        Right (Left errorMessage) -> die ("invalid configuration: " <> errorMessage)
        Right (Right decoded) -> pure decoded
      pure (config, takeDirectory configPath, False)
