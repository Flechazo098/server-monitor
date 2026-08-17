{-# LANGUAGE OverloadedStrings #-}

-- | SQLite storage for historical metrics and events.
--
-- Live measurements live in TVars; SQLite holds history and the alert
-- transition state required to preserve deduplication across restarts.
-- Nothing here is ever written from an API request. Connections are opened per operation
-- with WAL + a busy timeout so the single-writer constraint never turns
-- into a crash: concurrent writers simply wait.
module Monitor.Storage.SQLite
  ( EventRow (..)
  , CaddySample (..)
  , initDb
  , saveMetrics
  , saveEvent
  , loadAlertEntries
  , saveAlertEntries
  , loadHistory
  , loadRecentEvents
  , saveCaddyStats
  , loadCaddyStats
  , cleanup
  ) where

import Control.Exception (SomeException, bracket, try)
import Control.Monad (forM_)
import Data.Aeson (ToJSON (..), object, (.=))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time
  ( UTCTime
  , addUTCTime
  , defaultTimeLocale
  , formatTime
  , getCurrentTime
  , parseTimeM
  )
import Database.SQLite.Simple
  ( Connection
  , FromRow (..)
  , Only (..)
  , ToRow (..)
  , execute
  , execute_
  , close
  , field
  , query
  , query_
  )
import Database.SQLite.Simple.ToField (ToField (..))
import qualified Database.SQLite.Simple as SQL
import Monitor.Core.Types
import System.IO (hPutStrLn, stderr)

-- | ISO-8601 UTC, second precision.
fmtTs :: UTCTime -> Text
fmtTs = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

parseTs :: Text -> Maybe UTCTime
parseTs = parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" . T.unpack

-- | Run a SQLite action and log failures instead of throwing them. History
-- persistence must never take down the live collection loop.
ignoreSqliteError :: String -> IO () -> IO ()
ignoreSqliteError what action = do
  result <- try action :: IO (Either SomeException ())
  case result of
    Left e -> hPutStrLn stderr (what ++ " failed: " ++ show e)
    Right () -> pure ()

-- | One row of the events table.
data EventRow = EventRow
  { erTs       :: Text
  , erServer   :: Text
  , erType     :: Text
  , erSeverity :: Text
  , erState    :: Text
  , erMessage  :: Text
  }
  deriving (Show)

instance ToJSON EventRow where
  toJSON e = object
    [ "ts"       .= erTs e
    , "server"   .= erServer e
    , "type"     .= erType e
    , "severity" .= erSeverity e
    , "state"    .= erState e
    , "message"  .= erMessage e
    ]

-- | One sample of the caddy access-log size.
data CaddySample = CaddySample
  { csTs    :: Text
  , csSize  :: Integer
  }
  deriving (Show)

instance ToJSON CaddySample where
  toJSON c = object
    [ "ts"    .= csTs c
    , "size"  .= csSize c
    ]

-- | Flat row shape for the metrics table (20 columns: sqlite-simple
-- only provides tuple instances up to arity 10, so we spell it out).
data MetricRow = MetricRow
  { mrServer :: Text
  , mrTs     :: Text
  , mrCpu    :: Double
  , mrCpuUser :: Double
  , mrCpuSystem :: Double
  , mrCpuIowait :: Double
  , mrMem    :: Double
  , mrMemAvailable :: Integer
  , mrMemCache :: Integer
  , mrMemBuffers :: Integer
  , mrSwapUsed :: Integer
  , mrSwapTotal :: Integer
  , mrLoad1  :: Double
  , mrLoad5  :: Double
  , mrLoad15 :: Double
  , mrRx     :: Integer
  , mrTx     :: Integer
  , mrDisk   :: Double
  , mrRxRate :: Double
  , mrTxRate :: Double
  }

instance ToRow MetricRow where
  toRow r =
    [ toField (mrServer r), toField (mrTs r), toField (mrCpu r)
    , toField (mrCpuUser r), toField (mrCpuSystem r), toField (mrCpuIowait r)
    , toField (mrMem r), toField (mrMemAvailable r), toField (mrMemCache r)
    , toField (mrMemBuffers r), toField (mrSwapUsed r), toField (mrSwapTotal r)
    , toField (mrLoad1 r), toField (mrLoad5 r), toField (mrLoad15 r)
    , toField (mrRx r), toField (mrTx r), toField (mrDisk r)
    , toField (mrRxRate r), toField (mrTxRate r)
    ]

instance FromRow MetricRow where
  fromRow =
    MetricRow
      <$> field <*> field <*> field <*> field <*> field <*> field
      <*> field <*> field <*> field <*> field <*> field <*> field
      <*> field <*> field <*> field <*> field <*> field <*> field
      <*> field <*> field

-- | Open a connection with sane pragmas, run an action, close it.
withConn :: FilePath -> (Connection -> IO a) -> IO a
withConn path = bracket (openConn path) close
  where
    openConn p = do
      conn <- SQL.open p
      execute_ conn "PRAGMA busy_timeout = 5000"
      execute_ conn "PRAGMA synchronous = NORMAL"
      pure conn

-- | Create schema and migrate older databases in place.
initDb :: FilePath -> IO ()
initDb path = do
  withConn path $ \conn -> do
    versions <- query_ conn "PRAGMA user_version" :: IO [Only Int]
    let currentVersion = case versions of
          (Only value : _) -> value
          [] -> 0
    if currentVersion == schemaVersion
      then createSchema conn
      else do
        execute_ conn "DROP TABLE IF EXISTS metrics"
        execute_ conn "DROP TABLE IF EXISTS events"
        execute_ conn "DROP TABLE IF EXISTS log_stats"
        execute_ conn "DROP TABLE IF EXISTS alert_state"
        createSchema conn
        execute_ conn "PRAGMA user_version = 5"

schemaVersion :: Int
schemaVersion = 5

createSchema :: Connection -> IO ()
createSchema conn = do
    execute_ conn "PRAGMA journal_mode = WAL"
    execute_ conn
      ( "CREATE TABLE IF NOT EXISTS metrics (server_id TEXT NOT NULL, ts TEXT NOT NULL, cpu REAL NOT NULL, "
        <> "cpu_user REAL NOT NULL, cpu_system REAL NOT NULL, cpu_iowait REAL NOT NULL, mem REAL NOT NULL, "
        <> "mem_available INTEGER NOT NULL, mem_cache INTEGER NOT NULL, mem_buffers INTEGER NOT NULL, "
        <> "swap_used INTEGER NOT NULL, swap_total INTEGER NOT NULL, load1 REAL NOT NULL, load5 REAL NOT NULL, "
        <> "load15 REAL NOT NULL, rx INTEGER NOT NULL, tx INTEGER NOT NULL, disk REAL NOT NULL, "
        <> "rx_rate REAL NOT NULL, tx_rate REAL NOT NULL, PRIMARY KEY (server_id, ts)) WITHOUT ROWID" )
    execute_ conn
      ( "CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY AUTOINCREMENT, server_id TEXT NOT NULL, "
        <> "ts TEXT NOT NULL, type TEXT NOT NULL, severity TEXT NOT NULL, state TEXT NOT NULL, message TEXT NOT NULL)" )
    execute_ conn
      ( "CREATE TABLE IF NOT EXISTS log_stats (server_id TEXT NOT NULL, ts TEXT NOT NULL, size INTEGER NOT NULL, "
        <> "PRIMARY KEY (server_id, ts)) WITHOUT ROWID" )
    execute_ conn
      ( "CREATE TABLE IF NOT EXISTS alert_state (server_id TEXT NOT NULL, alert_key TEXT NOT NULL, "
        <> "active INTEGER NOT NULL, notified INTEGER NOT NULL, since_ts TEXT NOT NULL, "
        <> "transition_ts TEXT NOT NULL, severity TEXT NOT NULL, message TEXT NOT NULL, "
        <> "PRIMARY KEY (server_id, alert_key)) WITHOUT ROWID" )
    execute_ conn
      "CREATE INDEX IF NOT EXISTS idx_events_ts ON events (ts DESC, id DESC)"

saveMetrics :: FilePath -> ServerId -> Metrics -> IO ()
saveMetrics path (ServerId sid) m =
  ignoreSqliteError "saveMetrics" (withConn path $ \conn ->
    execute conn
      ( "INSERT INTO metrics (server_id, ts, cpu, cpu_user, cpu_system, cpu_iowait, mem, "
        <> "mem_available, mem_cache, mem_buffers, swap_used, swap_total, "
        <> "load1, load5, load15, rx, tx, disk, rx_rate, tx_rate) "
        <> "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)" )
      ( MetricRow sid (fmtTs (mTimestamp m)) (mCpu m) (mCpuUser m) (mCpuSystem m) (mCpuIowait m)
          (mMemUsedPct m) (mMemAvailableBytes m) (mMemCacheBytes m) (mMemBuffersBytes m)
          (mSwapUsedBytes m) (mSwapTotalBytes m)
          (mLoad1 m) (mLoad5 m) (mLoad15 m) (mRxBytes m) (mTxBytes m)
          (mDiskUsedPct m) (mRxRate m) (mTxRate m)
      ))

saveEvent :: FilePath -> ServerId -> Text -> Severity -> Text -> Text -> IO ()
saveEvent path (ServerId sid) typ sev state msg = do
  now <- getCurrentTime
  ignoreSqliteError "saveEvent" (withConn path $ \conn ->
    execute conn
      "INSERT INTO events (server_id, ts, type, severity, state, message) VALUES (?,?,?,?,?,?)"
      (sid, fmtTs now, typ, severityText sev, state, msg))

severityText :: Severity -> Text
severityText SevInfo     = "info"
severityText SevWarning  = "warning"
severityText SevCritical = "critical"

parseSeverity :: Text -> Severity
parseSeverity "warning"  = SevWarning
parseSeverity "critical" = SevCritical
parseSeverity _          = SevInfo

-- | Restore alert-engine state so an application restart does not emit a
-- duplicate fired event for an alert that is already active.
loadAlertEntries :: FilePath -> ServerId -> IO (Map Text AlertEntry)
loadAlertEntries path (ServerId sid) = do
  rows <- withConn path $ \conn ->
    query conn
      ( "SELECT alert_key, active, notified, since_ts, transition_ts, severity, message "
        <> "FROM alert_state WHERE server_id = ?" )
      (Only sid)
  pure $ Map.fromList
    [ (key, AlertEntry (active /= (0 :: Int)) (notified /= (0 :: Int)) since transition
        (parseSeverity severity) message)
    | (key, active, notified, sinceText, transitionText, severity, message) <- rows
    , Just since <- [parseTs sinceText]
    , Just transition <- [parseTs transitionText]
    ]

-- | Persist the complete state for one server in a single connection. The
-- key set is small, and UPSERT avoids churn when only one condition changes.
saveAlertEntries :: FilePath -> ServerId -> Map Text AlertEntry -> IO ()
saveAlertEntries path (ServerId sid) entries =
  ignoreSqliteError "saveAlertEntries" (withConn path $ \conn ->
    forM_ (Map.toList entries) $ \(key, entry) ->
      execute conn
        ( "INSERT INTO alert_state (server_id, alert_key, active, notified, since_ts, transition_ts, severity, message) "
          <> "VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(server_id, alert_key) DO UPDATE SET "
          <> "active=excluded.active, notified=excluded.notified, since_ts=excluded.since_ts, "
          <> "transition_ts=excluded.transition_ts, severity=excluded.severity, message=excluded.message" )
        ( sid, key, boolInt (aeActive entry), boolInt (aeNotified entry)
        , fmtTs (aeSince entry), fmtTs (aeLastTransition entry)
        , severityText (aeSeverity entry), aeMessage entry
        ))
  where
    boolInt True  = 1 :: Int
    boolInt False = 0

-- | Load metrics history for the last @hours@ hours (oldest first).
loadHistory :: FilePath -> ServerId -> Int -> IO [Metrics]
loadHistory path (ServerId sid) hours = do
  now <- getCurrentTime
  let boundedHours = max 1 (min (24 * 365) hours)
      cutoff = fmtTs (addUTCTime (fromIntegral (-boundedHours) * 3600) now)
      bucketSec = max 1 ((boundedHours * 3600) `div` 3000)
  rows <- withConn path $ \conn ->
    query conn
      ( "SELECT server_id, MAX(ts), AVG(cpu), AVG(cpu_user), AVG(cpu_system), AVG(cpu_iowait), AVG(mem), "
        <> "CAST(AVG(mem_available) AS INTEGER), CAST(AVG(mem_cache) AS INTEGER), "
        <> "CAST(AVG(mem_buffers) AS INTEGER), CAST(AVG(swap_used) AS INTEGER), CAST(AVG(swap_total) AS INTEGER), "
        <> "AVG(load1), AVG(load5), AVG(load15), MAX(rx), MAX(tx), AVG(disk), AVG(rx_rate), AVG(tx_rate) "
        <> "FROM metrics WHERE server_id = ? AND ts >= ? "
        <> "GROUP BY server_id, CAST(strftime('%s', ts) AS INTEGER) / ? ORDER BY MAX(ts) ASC LIMIT 5000" )
      (sid, cutoff, bucketSec)
  pure [ mkMetrics t row
       | row <- rows
       , Just t <- [parseTs (mrTs row)]
       ]
  where
    mkMetrics t row = Metrics
      { mCpu = mrCpu row, mCpuUser = mrCpuUser row, mCpuSystem = mrCpuSystem row
      , mCpuIowait = mrCpuIowait row, mMemUsedPct = mrMem row
      , mMemAvailableBytes = mrMemAvailable row, mMemCacheBytes = mrMemCache row
      , mMemBuffersBytes = mrMemBuffers row, mSwapUsedBytes = mrSwapUsed row
      , mSwapTotalBytes = mrSwapTotal row, mLoad1 = mrLoad1 row
      , mLoad5 = mrLoad5 row, mLoad15 = mrLoad15 row
      , mUptimeSec = 0, mDiskUsedPct = mrDisk row, mRxBytes = mrRx row, mTxBytes = mrTx row
      , mRxRate = mrRxRate row, mTxRate = mrTxRate row, mTimestamp = t
      }

-- | Most recent events (up to @limit@), newest first.
loadRecentEvents :: FilePath -> Int -> IO [EventRow]
loadRecentEvents path limit = do
  rows <- withConn path $ \conn ->
    query conn
      ( "SELECT ts, server_id, type, severity, state, message "
        <> "FROM events ORDER BY ts DESC, id DESC LIMIT ?" )
      (Only (max 1 (min 1000 limit)))
  pure [ EventRow ts sid typ sev st msg
       | (ts, sid, typ, sev, st, msg) <- rows
       ]

-- | Append one caddy log-size sample.
saveCaddyStats :: FilePath -> ServerId -> Integer -> UTCTime -> IO ()
saveCaddyStats path (ServerId sid) size ts =
  ignoreSqliteError "saveCaddyStats" (withConn path $ \conn ->
    execute conn
      "INSERT INTO log_stats (server_id, ts, size) VALUES (?,?,?)"
      (sid, fmtTs ts, size))

-- | Caddy log-size history for the last @hours@ hours (oldest first).
loadCaddyStats :: FilePath -> ServerId -> Int -> IO [CaddySample]
loadCaddyStats path (ServerId sid) hours = do
  now <- getCurrentTime
  let boundedHours = max 1 (min (24 * 365) hours)
      cutoff = fmtTs (addUTCTime (fromIntegral (-boundedHours) * 3600) now)
  rows <- withConn path $ \conn ->
    query conn
      "SELECT ts, size FROM log_stats WHERE server_id = ? AND ts >= ? ORDER BY ts ASC LIMIT 5000"
      (sid, cutoff)
  pure [ CaddySample ts size
       | (ts, size) <- rows
       ]

-- | Drop history older than @days@ days.
cleanup :: FilePath -> Int -> IO ()
cleanup path days = do
  now <- getCurrentTime
  let boundedDays = max 1 days
      cutoff = fmtTs (addUTCTime (fromIntegral (-boundedDays) * 86400) now)
  ignoreSqliteError "cleanup" (withConn path $ \conn -> do
    execute conn "DELETE FROM metrics WHERE ts < ?" (Only cutoff)
    execute conn "DELETE FROM events WHERE ts < ?" (Only cutoff)
    execute conn "DELETE FROM log_stats WHERE ts < ?" (Only cutoff)
    execute_ conn "PRAGMA wal_checkpoint(TRUNCATE)"
    )
