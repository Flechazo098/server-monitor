{-# LANGUAGE OverloadedStrings #-}

-- | SQLite storage for historical metrics and events.
--
-- Live state lives in TVars; SQLite only holds history. Nothing here is
-- ever written from an API request. Connections are opened per operation
-- with WAL + a busy timeout so the single-writer constraint never turns
-- into a crash: concurrent writers simply wait.
module Monitor.Storage.SQLite
  ( EventRow (..)
  , CaddySample (..)
  , initDb
  , saveMetrics
  , saveEvent
  , loadHistory
  , loadRecentEvents
  , saveCaddyStats
  , loadCaddyStats
  , cleanup
  ) where

import Control.Exception (SomeException, bracket, try)
import Control.Monad (unless)
import Data.Aeson (ToJSON (..), object, (.=))
import Data.String (fromString)
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
  , csLines :: Maybe Int
  }
  deriving (Show)

instance ToJSON CaddySample where
  toJSON c = object
    [ "ts"    .= csTs c
    , "size"  .= csSize c
    , "lines" .= csLines c
    ]

-- | Flat row shape for the metrics table (12 columns: sqlite-simple
-- only provides tuple instances up to arity 10, so we spell it out).
data MetricRow = MetricRow
  { mrServer :: Text
  , mrTs     :: Text
  , mrCpu    :: Double
  , mrMem    :: Double
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
    [ toField (mrServer r), toField (mrTs r), toField (mrCpu r), toField (mrMem r)
    , toField (mrLoad1 r), toField (mrLoad5 r), toField (mrLoad15 r)
    , toField (mrRx r), toField (mrTx r), toField (mrDisk r)
    , toField (mrRxRate r), toField (mrTxRate r)
    ]

instance FromRow MetricRow where
  fromRow =
    MetricRow
      <$> field <*> field <*> field <*> field <*> field <*> field
      <*> field <*> field <*> field <*> field <*> field <*> field

-- | Open a connection with sane pragmas, run an action, close it.
withConn :: FilePath -> (Connection -> IO a) -> IO a
withConn path = bracket (openConn path) close
  where
    openConn p = do
      conn <- SQL.open p
      execute_ conn "PRAGMA busy_timeout = 5000"
      execute_ conn "PRAGMA journal_mode = WAL"
      execute_ conn "PRAGMA synchronous = NORMAL"
      pure conn

-- | Create schema and migrate older databases in place.
initDb :: FilePath -> IO ()
initDb path = do
  withConn path $ \conn -> do
    execute_ conn
      ( "CREATE TABLE IF NOT EXISTS metrics (server_id TEXT, ts TEXT, cpu REAL, mem REAL, "
        <> "load1 REAL, load5 REAL, load15 REAL, rx INTEGER, tx INTEGER, disk REAL, "
        <> "rx_rate REAL, tx_rate REAL)" )
    execute_ conn
      "CREATE TABLE IF NOT EXISTS events (server_id TEXT, ts TEXT, type TEXT, severity TEXT, state TEXT, message TEXT)"
    execute_ conn
      "CREATE TABLE IF NOT EXISTS log_stats (server_id TEXT, ts TEXT, size INTEGER, lines INTEGER)"
    execute_ conn
      "CREATE INDEX IF NOT EXISTS idx_metrics_server_ts ON metrics (server_id, ts)"
    execute_ conn
      "CREATE INDEX IF NOT EXISTS idx_events_ts ON events (ts)"
    execute_ conn
      "CREATE INDEX IF NOT EXISTS idx_log_stats_server_ts ON log_stats (server_id, ts)"
    -- v1 -> v2 migrations: add missing columns to tables created by older builds.
    addColumnIfMissing conn "metrics" "disk" "REAL"
    addColumnIfMissing conn "metrics" "rx_rate" "REAL"
    addColumnIfMissing conn "metrics" "tx_rate" "REAL"
    addColumnIfMissing conn "events" "severity" "TEXT"
    addColumnIfMissing conn "events" "state" "TEXT"

addColumnIfMissing :: Connection -> Text -> Text -> Text -> IO ()
addColumnIfMissing conn table column colType = do
  cols <- query_ conn (fromString ("PRAGMA table_info(" <> T.unpack table <> ")"))
    :: IO [(Int, Text, Text, Int, Maybe Text, Int)]
  unless (any (\(_, name, _, _, _, _) -> name == column) cols) $
    execute_ conn (fromString ("ALTER TABLE " <> T.unpack table <> " ADD COLUMN " <> T.unpack column <> " " <> T.unpack colType))

saveMetrics :: FilePath -> ServerId -> Metrics -> IO ()
saveMetrics path (ServerId sid) m =
  ignoreSqliteError "saveMetrics" (withConn path $ \conn ->
    execute conn
      ( "INSERT INTO metrics (server_id, ts, cpu, mem, load1, load5, load15, rx, tx, disk, rx_rate, tx_rate) "
        <> "VALUES (?,?,?,?,?,?,?,?,?,?,?,?)" )
      ( MetricRow sid (fmtTs (mTimestamp m)) (mCpu m) (mMemUsedPct m)
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

-- | Load metrics history for the last @hours@ hours (oldest first).
loadHistory :: FilePath -> ServerId -> Int -> IO [Metrics]
loadHistory path (ServerId sid) hours = do
  now <- getCurrentTime
  let cutoff = fmtTs (addUTCTime (fromIntegral (-hours) * 3600) now)
  rows <- withConn path $ \conn ->
    query conn
      ( "SELECT ts, cpu, mem, load1, load5, load15, rx, tx, "
        <> "COALESCE(disk, 0), COALESCE(rx_rate, 0), COALESCE(tx_rate, 0) "
        <> "FROM metrics WHERE server_id = ? AND ts >= ? ORDER BY ts ASC LIMIT 5000" )
      (sid, cutoff)
  pure [ mkMetrics t row
       | row <- rows
       , Just t <- [parseTs (mrTs row)]
       ]
  where
    mkMetrics t row = Metrics
      { mCpu = mrCpu row, mMemUsedPct = mrMem row, mLoad1 = mrLoad1 row
      , mLoad5 = mrLoad5 row, mLoad15 = mrLoad15 row
      , mUptimeSec = 0, mDiskUsedPct = mrDisk row, mRxBytes = mrRx row, mTxBytes = mrTx row
      , mRxRate = mrRxRate row, mTxRate = mrTxRate row, mTimestamp = t
      }

-- | Most recent events (up to @limit@), newest first.
loadRecentEvents :: FilePath -> Int -> IO [EventRow]
loadRecentEvents path limit = do
  rows <- withConn path $ \conn ->
    query conn
      ( "SELECT ts, server_id, type, COALESCE(severity, 'info'), COALESCE(state, ''), message "
        <> "FROM events ORDER BY ts DESC LIMIT ?" )
      (Only (max 1 limit))
  pure [ EventRow ts sid typ sev st msg
       | (ts, sid, typ, sev, st, msg) <- rows
       ]

-- | Append one caddy log-size sample.
saveCaddyStats :: FilePath -> ServerId -> Integer -> Maybe Int -> UTCTime -> IO ()
saveCaddyStats path (ServerId sid) size mlines ts =
  ignoreSqliteError "saveCaddyStats" (withConn path $ \conn ->
    execute conn
      "INSERT INTO log_stats (server_id, ts, size, lines) VALUES (?,?,?,?)"
      (sid, fmtTs ts, size, mlines))

-- | Caddy log-size history for the last @hours@ hours (oldest first).
loadCaddyStats :: FilePath -> ServerId -> Int -> IO [CaddySample]
loadCaddyStats path (ServerId sid) hours = do
  now <- getCurrentTime
  let cutoff = fmtTs (addUTCTime (fromIntegral (-hours) * 3600) now)
  rows <- withConn path $ \conn ->
    query conn
      "SELECT ts, size, lines FROM log_stats WHERE server_id = ? AND ts >= ? ORDER BY ts ASC LIMIT 5000"
      (sid, cutoff)
  pure [ CaddySample ts size mlines
       | (ts, size, mlines) <- rows
       ]

-- | Drop history older than @days@ days.
cleanup :: FilePath -> Int -> IO ()
cleanup path days = do
  now <- getCurrentTime
  let cutoff = fmtTs (addUTCTime (fromIntegral (-days) * 86400) now)
  ignoreSqliteError "cleanup" (withConn path $ \conn -> do
    execute conn "DELETE FROM metrics WHERE ts < ?" (Only cutoff)
    execute conn "DELETE FROM events WHERE ts < ?" (Only cutoff)
    execute conn "DELETE FROM log_stats WHERE ts < ?" (Only cutoff)
    execute_ conn "PRAGMA wal_checkpoint(TRUNCATE)"
    )
