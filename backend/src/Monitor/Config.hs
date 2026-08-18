{-# LANGUAGE OverloadedStrings #-}

-- | Strict local configuration validation shared by the executable and tests.
module Monitor.Config
  ( resolveConfigPaths
  , validateConfig
  ) where

import Data.Char (isAlphaNum, isSpace)
import qualified Data.Set as Set
import qualified Data.Text as T
import Monitor.Core.Types
import System.FilePath (isRelative, normalise, (</>))

resolveConfigPaths :: FilePath -> MonitorConfig -> MonitorConfig
resolveConfigPaths base config = config
  { cfgDbPath = resolve (cfgDbPath config)
  , cfgServers = map resolveServer (cfgServers config)
  }
  where
    resolve path = normalise (if isRelative path then base </> path else path)
    resolveServer server = server { scSshKey = resolve (scSshKey server) }

validateConfig :: MonitorConfig -> Either String ()
validateConfig config = do
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
    servers = cfgServers config
    alerts = cfgAlerts config
    collection = cfgCollection config
    ids = [serverId | ServerId serverId <- map scId servers]

    require True _ = Right ()
    require False message = Left message
    between lower upper value = value >= lower && value <= upper
    betweenInt lower upper value = value >= lower && value <= upper

    validateServer server = do
      let ServerId serverId = scId server
      require (validId serverId) "server id must contain only letters, digits, '.', '_' or '-'"
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
