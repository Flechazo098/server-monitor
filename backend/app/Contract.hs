{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Aeson (Value, object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Time (UTCTime)
import Monitor.Api.Server (HealthInfo (..))
import Monitor.Core.Types
import Monitor.Storage.SQLite (CaddySample (..), EventRow (..))
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.FilePath (takeDirectory)
import System.IO (hPutStrLn, stderr)
import System.Exit (exitFailure)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [output] -> do
      createDirectoryIfMissing True (takeDirectory output)
      Aeson.encodeFile output contractBundle
      putStrLn output
    _ -> do
      hPutStrLn stderr "usage: monitor-contract <output.json>"
      exitFailure

contractBundle :: Value
contractBundle = object
  [ "config" .= sampleConfig
  , "health" .= HealthInfo "ok" 2 1 defaultAlertConfig defaultCollectionConfig
  , "servers" .= [fullState, offlineState]
  , "containers" .= ssContainers fullState
  , "services" .= ssServices fullState
  , "fail2ban" .= ssFail2ban fullState
  , "backup" .= ssBackup fullState
  , "history" .= maybe [] pure (ssMetrics fullState)
  , "caddy" .= [CaddySample timestampText 8388608]
  , "events" .=
      [ EventRow timestampText "contract" "alert" "critical" "fired" "disk full"
      , EventRow timestampText "contract" "status" "info" "resolved" "server came online"
      ]
  , "ws" .=
      [ object ["type" .= ("snapshot" :: String), "servers" .= [fullState, offlineState]]
      , Aeson.toJSON (ServerEvent (ServerId "contract") fullState)
      , Aeson.toJSON (StatusEvent (ServerId "contract") Offline)
      , Aeson.toJSON (AlertEvent (ServerId "contract") firedAlert)
      , Aeson.toJSON (AlertEvent (ServerId "contract") resolvedAlert)
      ]
  ]

sampleTime :: UTCTime
sampleTime = read "2026-08-17 12:34:56 UTC"

timestampText :: Text
timestampText = "2026-08-17T12:34:56Z"

serverConfig :: ServerConfig
serverConfig = ServerConfig
  { scId = ServerId "contract"
  , scName = "Contract Server"
  , scSshHost = "example.invalid"
  , scSshPort = 22
  , scSshUser = "monitor"
  , scSshKey = "unused"
  , scIntervalSec = 20
  , scPublicUrls = ["https://example.invalid/health"]
  , scCertHosts = ["example.invalid"]
  }

sampleConfig :: MonitorConfig
sampleConfig = MonitorConfig
  { cfgServers = [serverConfig]
  , cfgDbPath = "monitor.db"
  , cfgAlerts = defaultAlertConfig
  , cfgCollection = defaultCollectionConfig
  }

sampleMetrics :: Metrics
sampleMetrics = Metrics
  { mCpu = 42.5
  , mCpuUser = 20.5
  , mCpuSystem = 12.5
  , mCpuIowait = 9.5
  , mMemUsedPct = 73.2
  , mMemAvailableBytes = 4294967296
  , mMemCacheBytes = 2147483648
  , mMemBuffersBytes = 134217728
  , mSwapUsedBytes = 268435456
  , mSwapTotalBytes = 1073741824
  , mLoad1 = 1.2
  , mLoad5 = 0.8
  , mLoad15 = 0.4
  , mUptimeSec = 86400
  , mDiskUsedPct = 81
  , mRxBytes = 123456789
  , mTxBytes = 98765432
  , mRxRate = 12345.6
  , mTxRate = 6543.2
  , mTimestamp = sampleTime
  }

fullState :: ServerState
fullState = ServerState
  { ssConfig = serverConfig
  , ssStatus = Online
  , ssMetrics = Just sampleMetrics
  , ssContainers =
      [ Container "api" "example/api:1" "Up 2 hours" (Just 1.2) (Just 3.4)
      , Container "worker" "example/worker:1" "Exited" Nothing Nothing
      ]
  , ssServices = [Service "caddy" True, Service "backup" False]
  , ssFail2ban = [Fail2banJail "sshd" 1 12 ["192.0.2.10"]]
  , ssBackup = Just (BackupInfo (Just timestampText) (Just timestampText) 3
      (Just "backup.tar.zst") (Just 1786966496) (Just False))
  , ssHealth =
      [ HealthCheck "https://example.invalid/health" True 42 "200"
      , HealthCheck "https://offline.invalid/health" False 8000 "000"
      ]
  , ssDisks = [DiskMount "/dev/vda2" "ext4" "120G" "97G" "23G" 81 "/"]
  , ssDockerUsage = Just (DockerUsage
      (DockerRow 3 "4.7GB") (DockerRow 2 "180MB")
      (DockerRow 4 "73MB") (DockerRow 42 "4.6GB"))
  , ssApt = Just (AptUpgrades 2 ["openssl", "curl"])
  , ssTlsCerts = [TlsCert "example.invalid" "CN=example.invalid" "CN=Example CA"
      sampleTime 29 "SHA256:AA:BB"]
  , ssPorts =
      [ TcpPort 443 "tcp" "0.0.0.0:443" (Just "caddy") True
      , TcpPort 53 "udp" "127.0.0.1:53" Nothing False
      ]
  , ssSshLogins =
      [ SshLogin timestampText True "alice" "192.0.2.20"
      , SshLogin timestampText False "root" "198.51.100.2"
      ]
  , ssFirewall = Just (Firewall True
      [UfwRule "443/tcp" "ALLOW" "Anywhere"]
      [IptablesRule 12 768 "DROP" "tcp" "198.51.100.2" "0.0.0.0/0"])
  , ssVnstatDays = [VnstatDay "2026-08-17" 1048576 524288]
  , ssNetIfaces = [NetIface "eth0" 123456789 98765432]
  , ssFingerprints = [Fingerprint "/etc/ssh/ssh_host_ed25519_key.pub" "ED25519" "SHA256:abc"]
  , ssM3u8 = Just (M3u8Queue (Just "200") (Map.fromList [("queued", 2), ("done", 4)])
      [M3u8Job "Example" "queued" 3 10 timestampText])
  , ssGitea = Just (GiteaInfo (Just "200") (Just 12) (Just 3) (Just 4) (Just 1786966496))
  , ssCaddy = Just (CaddyLogs 8388608 sampleTime 64)
  , ssAlerts =
      [ Alert "disk:/" SevCritical "disk full" sampleTime
      , Alert "tls:example.invalid" SevWarning "certificate expiring" sampleTime
      , Alert "notice" SevInfo "informational" sampleTime
      ]
  , ssSectionErrors = Map.fromList [("APT", "unsupported")]
  , ssLastError = Nothing
  , ssUpdatedAt = sampleTime
  }

offlineState :: ServerState
offlineState = (emptyState serverConfig)
  { ssStatus = Offline
  , ssLastError = Just "connection timed out"
  , ssUpdatedAt = sampleTime
  }

firedAlert :: AlertPayload
firedAlert = AlertPayload "disk:/" SevCritical "disk full" sampleTime sampleTime "fired"

resolvedAlert :: AlertPayload
resolvedAlert = AlertPayload "disk:/" SevCritical "disk recovered" sampleTime sampleTime "resolved"
