{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Core types shared across the monitor backend.
--
-- Design principle: read-only by construction. The API surface only exposes
-- GET endpoints; there is no remote-shell capability anywhere. Section-level
-- failures are carried as data (empty lists / 'Nothing' / 'ssSectionErrors'),
-- never as a failure of the whole collection.
module Monitor.Core.Types
  ( ServerId (..)
  , ServerConfig (..)
  , certHostsOf
  , ServerStatus (..)
  , Metrics (..)
  , Container (..)
  , Service (..)
  , Fail2banJail (..)
  , BackupInfo (..)
  , HealthCheck (..)
  , DiskMount (..)
  , DockerRow (..)
  , DockerUsage (..)
  , AptUpgrades (..)
  , TlsCert (..)
  , TcpPort (..)
  , SshLogin (..)
  , UfwRule (..)
  , IptablesRule (..)
  , Firewall (..)
  , VnstatDay (..)
  , NetIface (..)
  , Fingerprint (..)
  , M3u8Job (..)
  , M3u8Queue (..)
  , GiteaInfo (..)
  , CaddyLogs (..)
  , Severity (..)
  , Alert (..)
  , AlertConfig (..)
  , defaultAlertConfig
  , CollectionConfig (..)
  , defaultCollectionConfig
  , ServerState (..)
  , emptyState
  , MonitorEvent (..)
  , AlertPayload (..)
  , AlertEntry (..)
  , AppState (..)
  , MonitorConfig (..)
  ) where

import Control.Concurrent.STM (TChan, TVar)
import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , object
  , withObject
  , (.:)
  , (.:?)
  , (.!=)
  , (.=)
  )
import Data.Aeson.Types (Parser)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import GHC.Generics (Generic)

-- | Identifier of a monitored server.
newtype ServerId = ServerId Text
  deriving (Eq, Ord, Show, Generic)

instance ToJSON ServerId where
  toJSON (ServerId t) = toJSON t

instance FromJSON ServerId where
  parseJSON = fmap ServerId . parseJSON

-- | Static configuration for one monitored server.
data ServerConfig = ServerConfig
  { scId          :: ServerId
  , scName        :: Text
  , scSshHost     :: Text
  , scSshPort     :: Int
  , scSshUser     :: Text
  , scSshKey      :: FilePath
  , scIntervalSec :: Int
  , scPublicUrls  :: [Text]
  , scCertHosts   :: [Text]
  }
  deriving (Show, Generic)

instance FromJSON ServerConfig where
  parseJSON = withObject "ServerConfig" $ \o ->
    ServerConfig . ServerId <$> o .: "id"
      <*> o .: "name"
      <*> o .: "sshHost"
      <*> o .:? "sshPort" .!= 22
      <*> o .: "sshUser"
      <*> o .: "sshKey"
      <*> o .:? "intervalSec" .!= 20
      <*> o .:? "publicUrls" .!= []
      <*> o .:? "certHosts" .!= []

instance ToJSON ServerConfig where
  toJSON sc = object
    [ "id"         .= scId sc
    , "name"       .= scName sc
    , "sshHost"    .= scSshHost sc
    , "sshPort"    .= scSshPort sc
    , "sshUser"    .= scSshUser sc
    , "intervalSec" .= scIntervalSec sc
    , "publicUrls" .= scPublicUrls sc
    , "certHosts"  .= scCertHosts sc
    ]

-- | Hosts whose TLS certificates should be probed. Falls back to the
-- hostnames of the configured public URLs.
certHostsOf :: ServerConfig -> [Text]
certHostsOf cfg =
  case scCertHosts cfg of
    [] -> map urlHost (scPublicUrls cfg)
    hs -> hs
  where
    urlHost u
      | "://" `T.isInfixOf` u =
          T.takeWhile (/= '/') (T.drop 3 (T.dropWhile (/= ':') u))
      | otherwise = T.takeWhile (/= '/') u

-- | Online/offline status of a server (transport-level reachability).
data ServerStatus = Online | Offline
  deriving (Eq, Show, Generic)

instance ToJSON ServerStatus where
  toJSON Online  = "online"
  toJSON Offline = "offline"

instance FromJSON ServerStatus where
  parseJSON v = go <$> (parseJSON v :: Parser Text)
    where
      go "online"  = Online
      go "offline" = Offline
      go _         = Offline

-- | A snapshot of core system metrics.
data Metrics = Metrics
  { mCpu         :: Double
  , mMemUsedPct  :: Double
  , mLoad1       :: Double
  , mLoad5       :: Double
  , mLoad15      :: Double
  , mUptimeSec   :: Int
  , mDiskUsedPct :: Double
  , mRxBytes     :: Integer     -- ^ WAN rx today (bytes, from vnstat)
  , mTxBytes     :: Integer     -- ^ WAN tx today (bytes, from vnstat)
  , mRxRate      :: Double      -- ^ bytes/sec over the last interval
  , mTxRate      :: Double      -- ^ bytes/sec over the last interval
  , mTimestamp   :: UTCTime
  }
  deriving (Show, Generic)

instance ToJSON Metrics where
  toJSON m = object
    [ "cpu"        .= mCpu m
    , "mem"        .= mMemUsedPct m
    , "load1"      .= mLoad1 m
    , "load5"      .= mLoad5 m
    , "load15"     .= mLoad15 m
    , "uptimeSec"  .= mUptimeSec m
    , "disk"       .= mDiskUsedPct m
    , "rxBytes"    .= mRxBytes m
    , "txBytes"    .= mTxBytes m
    , "rxRate"     .= mRxRate m
    , "txRate"     .= mTxRate m
    , "timestamp"  .= mTimestamp m
    ]

-- | Docker container snapshot.
data Container = Container
  { cName   :: Text
  , cImage  :: Text
  , cStatus :: Text
  , cCpuPct :: Maybe Double
  , cMemPct :: Maybe Double
  }
  deriving (Show, Generic)

instance ToJSON Container where
  toJSON c = object
    [ "name"   .= cName c
    , "image"  .= cImage c
    , "status" .= cStatus c
    , "cpuPct" .= cCpuPct c
    , "memPct" .= cMemPct c
    ]

-- | systemd service state.
data Service = Service
  { svcName   :: Text
  , svcActive :: Bool
  }
  deriving (Show, Generic)

instance ToJSON Service where
  toJSON s = object
    [ "name"   .= svcName s
    , "active" .= svcActive s
    ]

-- | Fail2ban jail state.
data Fail2banJail = Fail2banJail
  { fjName    :: Text
  , fjBanned  :: Int
  , fjTotal   :: Int
  }
  deriving (Show, Generic)

instance ToJSON Fail2banJail where
  toJSON f = object
    [ "name"   .= fjName f
    , "banned" .= fjBanned f
    , "total"  .= fjTotal f
    ]

-- | Backup status snapshot.
data BackupInfo = BackupInfo
  { bkLastRun     :: Maybe Text
  , bkNextRun     :: Maybe Text
  , bkCount       :: Int
  , bkLatest      :: Maybe Text
  , bkNewestEpoch :: Maybe Int
  , bkFailed      :: Maybe Bool
  }
  deriving (Show, Generic)

instance ToJSON BackupInfo where
  toJSON b = object
    [ "lastRun"  .= bkLastRun b
    , "nextRun"  .= bkNextRun b
    , "count"    .= bkCount b
    , "latest"   .= bkLatest b
    , "newestEpoch" .= bkNewestEpoch b
    , "failed"   .= bkFailed b
    ]

-- | One HTTP health probe of a public entry point.
data HealthCheck = HealthCheck
  { hcUrl       :: Text
  , hcOk        :: Bool
  , hcLatencyMs :: Int
  , hcStatus    :: Text
  }
  deriving (Show, Generic)

instance ToJSON HealthCheck where
  toJSON h = object
    [ "url"       .= hcUrl h
    , "ok"        .= hcOk h
    , "latencyMs" .= hcLatencyMs h
    , "status"    .= hcStatus h
    ]

-- | One physical filesystem mount point.
data DiskMount = DiskMount
  { dmFs    :: Text
  , dmSize  :: Text
  , dmUsed  :: Text
  , dmAvail :: Text
  , dmPct   :: Double
  , dmMount :: Text
  }
  deriving (Show, Generic)

instance ToJSON DiskMount where
  toJSON d = object
    [ "fs"    .= dmFs d
    , "size"  .= dmSize d
    , "used"  .= dmUsed d
    , "avail" .= dmAvail d
    , "pct"   .= dmPct d
    , "mount" .= dmMount d
    ]

-- | One row of 'docker system df'.
data DockerRow = DockerRow
  { drCount :: Int
  , drSize  :: Text
  }
  deriving (Show, Generic)

instance ToJSON DockerRow where
  toJSON r = object
    [ "count" .= drCount r
    , "size"  .= drSize r
    ]

-- | Docker disk usage by category ('docker system df').
data DockerUsage = DockerUsage
  { duImages      :: DockerRow
  , duContainers  :: DockerRow
  , duVolumes     :: DockerRow
  , duBuildCache  :: DockerRow
  }
  deriving (Show, Generic)

instance ToJSON DockerUsage where
  toJSON d = object
    [ "images"     .= duImages d
    , "containers" .= duContainers d
    , "volumes"    .= duVolumes d
    , "buildCache" .= duBuildCache d
    ]

-- | apt upgrade availability.
data AptUpgrades = AptUpgrades
  { apCount    :: Int
  , apPackages :: [Text]
  }
  deriving (Show, Generic)

instance ToJSON AptUpgrades where
  toJSON a = object
    [ "count"    .= apCount a
    , "packages" .= apPackages a
    ]

-- | A probed TLS certificate.
data TlsCert = TlsCert
  { tcHost        :: Text
  , tcSubject     :: Text
  , tcIssuer      :: Text
  , tcNotAfter    :: UTCTime
  , tcDaysLeft    :: Int
  , tcFingerprint :: Text
  }
  deriving (Show, Generic)

instance ToJSON TlsCert where
  toJSON t = object
    [ "host"        .= tcHost t
    , "subject"     .= tcSubject t
    , "issuer"      .= tcIssuer t
    , "notAfter"    .= tcNotAfter t
    , "daysLeft"    .= tcDaysLeft t
    , "fingerprint" .= tcFingerprint t
    ]

-- | A listening TCP/UDP socket.
data TcpPort = TcpPort
  { tpPort    :: Int
  , tpProto   :: Text
  , tpLocal   :: Text
  , tpProcess :: Maybe Text
  , tpExposed :: Bool
  }
  deriving (Show, Generic)

instance ToJSON TcpPort where
  toJSON p = object
    [ "port"    .= tpPort p
    , "proto"   .= tpProto p
    , "local"   .= tpLocal p
    , "process" .= tpProcess p
    , "exposed" .= tpExposed p
    ]

-- | One recent SSH auth line (success or failure).
data SshLogin = SshLogin
  { slTime :: Text
  , slOk   :: Bool
  , slUser :: Text
  , slFrom :: Text
  }
  deriving (Show, Generic)

instance ToJSON SshLogin where
  toJSON s = object
    [ "time" .= slTime s
    , "ok"   .= slOk s
    , "user" .= slUser s
    , "from" .= slFrom s
    ]

-- | One normalized UFW rule.
data UfwRule = UfwRule
  { ufTo     :: Text
  , ufAction :: Text
  , ufFrom   :: Text
  }
  deriving (Show, Generic)

instance ToJSON UfwRule where
  toJSON r = object
    [ "to"     .= ufTo r
    , "action" .= ufAction r
    , "from"   .= ufFrom r
    ]

-- | One iptables INPUT-chain counter row.
data IptablesRule = IptablesRule
  { irPkts   :: Integer
  , irBytes  :: Integer
  , irTarget :: Text
  , irProto  :: Text
  , irSource :: Text
  , irDest   :: Text
  }
  deriving (Show, Generic)

instance ToJSON IptablesRule where
  toJSON r = object
    [ "pkts"   .= irPkts r
    , "bytes"  .= irBytes r
    , "target" .= irTarget r
    , "proto"  .= irProto r
    , "source" .= irSource r
    , "dest"   .= irDest r
    ]

-- | Firewall summary: UFW status/rules and INPUT-chain counters.
data Firewall = Firewall
  { fwActive    :: Bool
  , fwRules     :: [UfwRule]
  , fwIptables  :: [IptablesRule]
  }
  deriving (Show, Generic)

instance ToJSON Firewall where
  toJSON f = object
    [ "active"   .= fwActive f
    , "rules"    .= fwRules f
    , "iptables" .= fwIptables f
    ]

-- | One day of vnstat traffic history.
data VnstatDay = VnstatDay
  { vdDate :: Text
  , vdRx   :: Integer
  , vdTx   :: Integer
  }
  deriving (Show, Generic)

instance ToJSON VnstatDay where
  toJSON v = object
    [ "date" .= vdDate v
    , "rx"   .= vdRx v
    , "tx"   .= vdTx v
    ]

-- | Per-interface byte counters from /proc/net/dev.
data NetIface = NetIface
  { niName :: Text
  , niRx   :: Integer
  , niTx   :: Integer
  }
  deriving (Show, Generic)

instance ToJSON NetIface where
  toJSON n = object
    [ "name" .= niName n
    , "rx"   .= niRx n
    , "tx"   .= niTx n
    ]

-- | A public key fingerprint (SSH host keys).
data Fingerprint = Fingerprint
  { fpFile :: Text
  , fpAlgo :: Text
  , fpHash :: Text
  }
  deriving (Show, Generic)

instance ToJSON Fingerprint where
  toJSON f = object
    [ "file" .= fpFile f
    , "algo" .= fpAlgo f
    , "hash" .= fpHash f
    ]

-- | One job in the m3u8 download queue.
data M3u8Job = M3u8Job
  { mjTitle    :: Text
  , mjStatus   :: Text
  , mjProgress :: Int
  , mjTotal    :: Int
  , mjUpdated  :: Text
  }
  deriving (Show, Generic)

instance ToJSON M3u8Job where
  toJSON j = object
    [ "title"    .= mjTitle j
    , "status"   .= mjStatus j
    , "progress" .= mjProgress j
    , "total"    .= mjTotal j
    , "updated"  .= mjUpdated j
    ]

-- | m3u8 downloader queue (read-only view of its jobs.db + /health).
data M3u8Queue = M3u8Queue
  { mqHealth :: Maybe Text
  , mqCounts :: Map Text Int
  , mqRecent :: [M3u8Job]
  }
  deriving (Show, Generic)

instance ToJSON M3u8Queue where
  toJSON q = object
    [ "health" .= mqHealth q
    , "counts" .= mqCounts q
    , "recent" .= mqRecent q
    ]

-- | Gitea health and repository activity.
data GiteaInfo = GiteaInfo
  { giHealth     :: Maybe Text
  , giRepos      :: Maybe Int
  , giUsers      :: Maybe Int
  , giActiveWeek :: Maybe Int
  , giLastPush   :: Maybe Int
  }
  deriving (Show, Generic)

instance ToJSON GiteaInfo where
  toJSON g = object
    [ "health"     .= giHealth g
    , "repos"      .= giRepos g
    , "users"      .= giUsers g
    , "activeWeek" .= giActiveWeek g
    , "lastPush"   .= giLastPush g
    ]

-- | Caddy access-log size and growth.
data CaddyLogs = CaddyLogs
  { clSizeBytes :: Integer
  , clLines     :: Maybe Int
  , clMtime     :: UTCTime
  , clGrowthBps :: Double
  }
  deriving (Show, Generic)

instance ToJSON CaddyLogs where
  toJSON c = object
    [ "sizeBytes" .= clSizeBytes c
    , "lines"     .= clLines c
    , "mtime"     .= clMtime c
    , "growthBps" .= clGrowthBps c
    ]

-- | Alert severity levels.
data Severity = SevInfo | SevWarning | SevCritical
  deriving (Eq, Ord, Show, Generic)

instance ToJSON Severity where
  toJSON SevInfo     = "info"
  toJSON SevWarning  = "warning"
  toJSON SevCritical = "critical"

instance FromJSON Severity where
  parseJSON v = go <$> (parseJSON v :: Parser Text)
    where
      go "info"     = SevInfo
      go "warning"  = SevWarning
      go "critical" = SevCritical
      go _          = SevInfo

-- | An active alert attached to a server state.
data Alert = Alert
  { alKey      :: Text
  , alSeverity :: Severity
  , alMessage  :: Text
  , alSince    :: UTCTime
  }
  deriving (Show, Generic)

instance ToJSON Alert where
  toJSON a = object
    [ "key"      .= alKey a
    , "severity" .= alSeverity a
    , "message"  .= alMessage a
    , "since"    .= alSince a
    ]

-- | Alert thresholds and durations. Every value has a sane default so
-- existing config files keep working.
data AlertConfig = AlertConfig
  { acDiskPct         :: Double  -- ^ disk usage percent that fires (default 80)
  , acMemPct          :: Double  -- ^ memory percent (default 90)
  , acCpuPct          :: Double  -- ^ cpu percent (default 85)
  , acCpuSustainSec   :: Int     -- ^ cpu must stay high this long (default 180)
  , acTlsMinDays      :: Int     -- ^ TLS alert below this many days (default 30)
  , acHealthMaxFails  :: Int     -- ^ consecutive health failures to fire (default 3)
  , acBackupMaxAgeHours :: Int   -- ^ newest backup older than this fires (default 26)
  , acCooldownSec     :: Int     -- ^ min seconds between fire -> recover -> re-fire (default 3600)
  }
  deriving (Show, Generic)

defaultAlertConfig :: AlertConfig
defaultAlertConfig = AlertConfig
  { acDiskPct = 80
  , acMemPct = 90
  , acCpuPct = 85
  , acCpuSustainSec = 180
  , acTlsMinDays = 30
  , acHealthMaxFails = 3
  , acBackupMaxAgeHours = 26
  , acCooldownSec = 3600
  }

instance FromJSON AlertConfig where
  parseJSON = withObject "AlertConfig" $ \o ->
    AlertConfig
      <$> o .:? "diskPct" .!= acDiskPct defaultAlertConfig
      <*> o .:? "memPct" .!= acMemPct defaultAlertConfig
      <*> o .:? "cpuPct" .!= acCpuPct defaultAlertConfig
      <*> o .:? "cpuSustainSec" .!= acCpuSustainSec defaultAlertConfig
      <*> o .:? "tlsMinDays" .!= acTlsMinDays defaultAlertConfig
      <*> o .:? "healthMaxFails" .!= acHealthMaxFails defaultAlertConfig
      <*> o .:? "backupMaxAgeHours" .!= acBackupMaxAgeHours defaultAlertConfig
      <*> o .:? "cooldownSec" .!= acCooldownSec defaultAlertConfig

instance ToJSON AlertConfig where
  toJSON a = object
    [ "diskPct" .= acDiskPct a
    , "memPct" .= acMemPct a
    , "cpuPct" .= acCpuPct a
    , "cpuSustainSec" .= acCpuSustainSec a
    , "tlsMinDays" .= acTlsMinDays a
    , "healthMaxFails" .= acHealthMaxFails a
    , "backupMaxAgeHours" .= acBackupMaxAgeHours a
    , "cooldownSec" .= acCooldownSec a
    ]

-- | Collection scheduling and retention settings.
data CollectionConfig = CollectionConfig
  { ccFullIntervalSec :: Int  -- ^ seconds between heavy full batches (default 60)
  , ccTimeoutSec      :: Int  -- ^ remote script timeout (default 90)
  , ccRetentionDays   :: Int  -- ^ history retention (default 30)
  , ccBackoffMaxSec   :: Int  -- ^ max retry delay on repeated failures (default 300)
  }
  deriving (Show, Generic)

defaultCollectionConfig :: CollectionConfig
defaultCollectionConfig = CollectionConfig
  { ccFullIntervalSec = 60
  , ccTimeoutSec = 90
  , ccRetentionDays = 30
  , ccBackoffMaxSec = 300
  }

instance FromJSON CollectionConfig where
  parseJSON = withObject "CollectionConfig" $ \o ->
    CollectionConfig
      <$> o .:? "fullIntervalSec" .!= ccFullIntervalSec defaultCollectionConfig
      <*> o .:? "timeoutSec" .!= ccTimeoutSec defaultCollectionConfig
      <*> o .:? "retentionDays" .!= ccRetentionDays defaultCollectionConfig
      <*> o .:? "backoffMaxSec" .!= ccBackoffMaxSec defaultCollectionConfig

instance ToJSON CollectionConfig where
  toJSON c = object
    [ "fullIntervalSec" .= ccFullIntervalSec c
    , "timeoutSec" .= ccTimeoutSec c
    , "retentionDays" .= ccRetentionDays c
    , "backoffMaxSec" .= ccBackoffMaxSec c
    ]

-- | Full mutable snapshot for one server (held in a TVar).
data ServerState = ServerState
  { ssConfig         :: ServerConfig
  , ssStatus         :: ServerStatus
  , ssMetrics        :: Maybe Metrics
  , ssContainers     :: [Container]
  , ssServices       :: [Service]
  , ssFail2ban       :: [Fail2banJail]
  , ssBackup         :: Maybe BackupInfo
  , ssHealth         :: [HealthCheck]
  , ssDisks          :: [DiskMount]
  , ssDockerUsage    :: Maybe DockerUsage
  , ssApt            :: Maybe AptUpgrades
  , ssTlsCerts       :: [TlsCert]
  , ssPorts          :: [TcpPort]
  , ssSshLogins      :: [SshLogin]
  , ssFirewall       :: Maybe Firewall
  , ssVnstatDays     :: [VnstatDay]
  , ssNetIfaces      :: [NetIface]
  , ssFingerprints   :: [Fingerprint]
  , ssM3u8           :: Maybe M3u8Queue
  , ssGitea          :: Maybe GiteaInfo
  , ssCaddy          :: Maybe CaddyLogs
  , ssAlerts         :: [Alert]
  , ssSectionErrors  :: Map Text Text
  , ssLastError      :: Maybe Text
  , ssUpdatedAt      :: UTCTime
  }
  deriving (Show, Generic)

instance ToJSON ServerState where
  toJSON ss = object
    [ "id"            .= scId (ssConfig ss)
    , "name"          .= scName (ssConfig ss)
    , "status"        .= ssStatus ss
    , "metrics"       .= ssMetrics ss
    , "containers"    .= ssContainers ss
    , "services"      .= ssServices ss
    , "fail2ban"      .= ssFail2ban ss
    , "backup"        .= ssBackup ss
    , "health"        .= ssHealth ss
    , "disks"         .= ssDisks ss
    , "dockerUsage"   .= ssDockerUsage ss
    , "apt"           .= ssApt ss
    , "tlsCerts"      .= ssTlsCerts ss
    , "ports"         .= ssPorts ss
    , "sshLogins"     .= ssSshLogins ss
    , "firewall"      .= ssFirewall ss
    , "vnstatDays"    .= ssVnstatDays ss
    , "netIfaces"     .= ssNetIfaces ss
    , "fingerprints"  .= ssFingerprints ss
    , "m3u8"          .= ssM3u8 ss
    , "gitea"         .= ssGitea ss
    , "caddy"         .= ssCaddy ss
    , "alerts"        .= ssAlerts ss
    , "sectionErrors" .= ssSectionErrors ss
    , "lastError"     .= ssLastError ss
    , "updatedAt"     .= ssUpdatedAt ss
    ]

-- | Empty state used before the first collection completes.
emptyState :: ServerConfig -> ServerState
emptyState cfg = ServerState
  { ssConfig = cfg
  , ssStatus = Offline
  , ssMetrics = Nothing
  , ssContainers = []
  , ssServices = []
  , ssFail2ban = []
  , ssBackup = Nothing
  , ssHealth = []
  , ssDisks = []
  , ssDockerUsage = Nothing
  , ssApt = Nothing
  , ssTlsCerts = []
  , ssPorts = []
  , ssSshLogins = []
  , ssFirewall = Nothing
  , ssVnstatDays = []
  , ssNetIfaces = []
  , ssFingerprints = []
  , ssM3u8 = Nothing
  , ssGitea = Nothing
  , ssCaddy = Nothing
  , ssAlerts = []
  , ssSectionErrors = Map.empty
  , ssLastError = Nothing
  , ssUpdatedAt = posixSecondsToUTCTime 0
  }

-- | Payload of an alert event on the WS stream.
data AlertPayload = AlertPayload
  { apKey      :: Text
  , apSeverity :: Severity
  , apMessage  :: Text
  , apSince    :: UTCTime
  , apState    :: Text  -- ^ "fired" | "resolved"
  }
  deriving (Show, Generic)

instance ToJSON AlertPayload where
  toJSON a = object
    [ "key"      .= apKey a
    , "severity" .= apSeverity a
    , "message"  .= apMessage a
    , "since"    .= apSince a
    , "state"    .= apState a
    ]

-- | Events pushed to the WebSocket stream.
data MonitorEvent
  = MetricsEvent ServerId Metrics
  | StatusEvent ServerId ServerStatus
  | AlertEvent ServerId AlertPayload
  deriving (Show)

instance ToJSON MonitorEvent where
  toJSON (MetricsEvent sid m) = object
    [ "type" .= ("metrics" :: Text), "server" .= sid, "data" .= m ]
  toJSON (StatusEvent sid st) = object
    [ "type" .= ("status" :: Text), "server" .= sid, "data" .= st ]
  toJSON (AlertEvent sid a) = object
    [ "type" .= ("alert" :: Text), "server" .= sid, "data" .= a ]

-- | Global application state.
data AppState = AppState
  { serverStates :: TVar (Map ServerId ServerState)
  , events       :: TChan MonitorEvent
  , dbPath       :: FilePath
  , alertStates  :: TVar (Map ServerId (Map Text AlertEntry))
  }

-- | Deduplication bookkeeping for one alert key.
data AlertEntry = AlertEntry
  { aeActive         :: Bool
  , aeSince          :: UTCTime
  , aeLastTransition :: UTCTime
  , aeSeverity       :: Severity
  , aeMessage        :: Text
  }
  deriving (Show, Generic)

instance ToJSON AlertEntry where
  toJSON e = object
    [ "active" .= aeActive e
    , "since" .= aeSince e
    , "lastTransition" .= aeLastTransition e
    , "severity" .= aeSeverity e
    , "message" .= aeMessage e
    ]

-- | Top-level configuration file.
data MonitorConfig = MonitorConfig
  { cfgServers    :: [ServerConfig]
  , cfgDbPath     :: FilePath
  , cfgToken      :: Maybe Text
  , cfgAlerts     :: AlertConfig
  , cfgCollection :: CollectionConfig
  }
  deriving (Show, Generic)

instance FromJSON MonitorConfig where
  parseJSON = withObject "MonitorConfig" $ \o ->
    MonitorConfig
      <$> o .: "servers"
      <*> o .:? "dbPath" .!= "monitor.db"
      <*> o .:? "token"
      <*> o .:? "alerts" .!= defaultAlertConfig
      <*> o .:? "collection" .!= defaultCollectionConfig
