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
import Control.Monad (unless)
import Data.Aeson (eitherDecodeFileStrict)
import Data.Char (isAlphaNum, isSpace)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Monitor.Api.Server (runBackend)
import Monitor.Core.Types
import Monitor.Runtime.Worker (startWorkers)
import Monitor.Storage.SQLite (initDb)
import System.Directory (doesFileExist)
import System.Environment (getArgs, getExecutablePath)
import System.Exit (die)
import System.FilePath (isRelative, normalise, takeDirectory, (</>))
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
  either (\err -> die ("invalid config " <> cfgPath <> ": " <> err)) pure (validateConfig cfg)
  let db = cfgDbPath cfg
      resolvedDb = normalise (if isRelative db then takeDirectory cfgPath </> db else db)
      resolvedCfg = cfg { cfgDbPath = resolvedDb }
  keysExist <- mapM (doesFileExist . scSshKey) (cfgServers resolvedCfg)
  unless (and keysExist) (die "invalid config: one or more SSH key files do not exist")
  initDb (cfgDbPath resolvedCfg)
  token <-
    maybe
      (maybe (die "authentication token required: pass --token or configure token") pure (cfgToken resolvedCfg))
      pure
      (cliToken cli)
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
      <> " server(s), db=" <> cfgDbPath resolvedCfg
    )
  runBackend state token

validateConfig :: MonitorConfig -> Either String ()
validateConfig cfg = do
  require (not (null servers)) "servers must not be empty"
  require (length ids == Set.size (Set.fromList ids)) "server ids must be unique"
  mapM_ validateServer servers
  require (between 1 100 (acDiskPct alerts)) "alerts.diskPct must be between 1 and 100"
  require (between 1 100 (acMemPct alerts)) "alerts.memPct must be between 1 and 100"
  require (between 1 100 (acCpuPct alerts)) "alerts.cpuPct must be between 1 and 100"
  require (acCpuSustainSec alerts >= 0) "alerts.cpuSustainSec must be non-negative"
  require (acTlsMinDays alerts >= 0) "alerts.tlsMinDays must be non-negative"
  require (acHealthMaxFails alerts >= 1) "alerts.healthMaxFails must be at least 1"
  require (acBackupMaxAgeHours alerts >= 1) "alerts.backupMaxAgeHours must be at least 1"
  require (acCooldownSec alerts >= 0) "alerts.cooldownSec must be non-negative"
  require (betweenInt 10 86400 (ccFullIntervalSec collection)) "collection.fullIntervalSec must be between 10 and 86400"
  require (betweenInt 5 300 (ccTimeoutSec collection)) "collection.timeoutSec must be between 5 and 300"
  require (betweenInt 1 3650 (ccRetentionDays collection)) "collection.retentionDays must be between 1 and 3650"
  require (betweenInt 5 3600 (ccBackoffMaxSec collection)) "collection.backoffMaxSec must be between 5 and 3600"
  where
    servers = cfgServers cfg
    alerts = cfgAlerts cfg
    collection = cfgCollection cfg
    ids = [sid | ServerId sid <- map scId servers]

    require True _ = Right ()
    require False msg = Left msg
    between lo hi value = value >= lo && value <= hi
    betweenInt lo hi value = value >= lo && value <= hi

    validateServer server = do
      let ServerId sid = scId server
      require (validId sid) "server id must contain only letters, digits, '.', '_' or '-'"
      require (not (T.null (T.strip (scName server)))) "server name must not be empty"
      require (validSshHost (scSshHost server)) "sshHost contains invalid characters"
      require (validSshUser (scSshUser server)) "sshUser contains invalid characters"
      require (betweenInt 1 65535 (scSshPort server)) "sshPort must be between 1 and 65535"
      require (betweenInt 5 3600 (scIntervalSec server)) "intervalSec must be between 5 and 3600"
      require (all validUrl (scPublicUrls server)) "publicUrls must use http:// or https:// and contain no whitespace"
      require (all validHost (certHostsOf server)) "certHosts must be plain DNS names"

    validId value = not (T.null value) && T.all (\c -> isAlphaNum c || c `elem` ("._-" :: String)) value
    validUrl value =
      ("https://" `T.isPrefixOf` value || "http://" `T.isPrefixOf` value)
        && not (T.any isSpace value)
    validHost value =
      not (T.null value)
        && T.all (\c -> isAlphaNum c || c `elem` (".-" :: String)) value
    validSshHost value =
      not (T.null value)
        && T.all (\c -> isAlphaNum c || c `elem` (".:-" :: String)) value
    validSshUser value =
      not (T.null value)
        && T.all (\c -> isAlphaNum c || c `elem` ("._-" :: String)) value
