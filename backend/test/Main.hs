{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (finally)
import Control.Monad (forM_, unless, when)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromJust)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime)
import Monitor.Collector.Parse
import Monitor.Collector.SSH (fullScript, metricsScript)
import Monitor.Core.Types
import Monitor.Storage.SQLite
import System.Directory (doesFileExist, getTemporaryDirectory, removeFile)
import System.Exit (exitFailure)
import System.FilePath ((</>))

main :: IO ()
main = do
  testGeneratedScripts
  testBatchParser
  testSectionFailure
  testStorage
  putStrLn "monitor-tests: ok"

testGeneratedScripts :: IO ()
testGeneratedScripts = do
  assert "metrics script has no dangling group separator"
    (not ("\n; }" `T.isInfixOf` metricsScript server))
  assert "full script has no dangling group separator"
    (not ("\n; }" `T.isInfixOf` fullScript server))

assert :: String -> Bool -> IO ()
assert label condition = unless condition $ do
  putStrLn ("FAILED: " <> label)
  exitFailure

server :: ServerConfig
server = ServerConfig
  { scId = ServerId "test"
  , scName = "Test"
  , scSshHost = "127.0.0.1"
  , scSshPort = 22
  , scSshUser = "monitor"
  , scSshKey = "unused"
  , scIntervalSec = 20
  , scPublicUrls = ["https://example.com/health"]
  , scCertHosts = ["example.com"]
  }

sampleTime :: UTCTime
sampleTime = read "2026-08-17 00:00:00 UTC"

fixture :: Text
fixture = T.unlines
  [ "===CPU==="
  , "42.5|21.0|18.0|3.5"
  , "===MEM==="
  , "75.0|1073741824|536870912|67108864|134217728|268435456"
  , "===LOAD==="
  , "0.40, 0.30, 0.20"
  , "===UPTIME==="
  , "86400"
  , "===DISK==="
  , "81"
  , "===DISKMOUNTS==="
  , "/dev/vda1|ext4|50G|41G|9G|81|/"
  , "/dev/vdb1|xfs|100G|20G|80G|20|/data"
  , "===NETDEV==="
  , "eth0|1000000|2000000"
  , "===VNSTATD==="
  , "2026-08-17 1.00 GiB | 512.00 MiB | 1.50 GiB | 10.0 kbit/s"
  , "===VNSTATM==="
  , "Aug '26 10.00 GiB | 5.00 GiB | 15.00 GiB | 20.0 kbit/s"
  , "===TLS==="
  , "HOST:example.com"
  , "subject=CN = example.com"
  , "issuer=CN = Test CA"
  , "notAfter=Sep 16 00:00:00 2026 GMT"
  , "SHA256 Fingerprint=AA:BB:CC"
  , "===FINGERPRINTS==="
  , "/etc/ssh/ssh_host_ed25519_key.pub|SHA256:abc|(ED25519)"
  , "===PORTS==="
  , "tcp LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:((\"caddy\",pid=1,fd=7))"
  , "===SSHAUTH==="
  , "Aug 17 01:02:03 host sshd[1]: Accepted publickey for alice from 100.64.0.2 port 50000 ssh2"
  , "===FIREWALL==="
  , "--UFW--"
  , "Status: active"
  , "443/tcp                    ALLOW       Anywhere"
  , "--IPTABLES--"
  , "1 10 640 DROP tcp -- * * 1.2.3.4 0.0.0.0/0"
  , "--UFWREJECT--"
  , "1 5 320 REJECT all -- * * 5.6.7.8 0.0.0.0/0"
  , "===DOCKERDF==="
  , "TYPE            TOTAL ACTIVE SIZE RECLAIMABLE"
  , "Images          3 2 1.5GB 500MB"
  , "Containers      2 2 20MB 0B"
  , "Local Volumes   4 3 2GB 100MB"
  , "Build Cache     1 0 64MB 64MB"
  , "===APT==="
  , "2"
  , "openssl"
  , "curl"
  , "===M3U8==="
  , "200"
  , "{\"counts\":{\"queued\":2},\"recent\":[{\"t\":\"demo\",\"s\":\"queued\",\"p\":0,\"n\":10,\"u\":\"2026-08-17T00:00:00Z\"}]}"
  , "===GITEA==="
  , "200"
  , "12|3|4|1786924800"
  , "===CADDY==="
  , "1048576|1786924800"
  , "===BACKUP==="
  , "count=7"
  , "newestEpoch=1786924800"
  , "LastTriggerUSec=Sun 2026-08-16 03:30:00 UTC"
  , "NextElapseUSecRealtime=Mon 2026-08-17 03:30:00 UTC"
  , "serviceState=inactive"
  , "===SERVICES==="
  , "docker:active"
  , "===CONTAINERS==="
  , "gitea|gitea:latest|Up 1 day"
  , "===STATS==="
  , "gitea|1.2%|3.4%"
  , "===F2B==="
  , "Jail list: sshd"
  , "== sshd =="
  , "Currently banned: 2"
  , "Total banned: 9"
  , "Banned IP list: 1.2.3.4 5.6.7.8"
  , "===HEALTH==="
  , "https://example.com/health 302 0.125"
  ]

testBatchParser :: IO ()
testBatchParser = do
  let parsed = parseBatch server sampleTime fixture
      metrics = fromJust (pMetrics parsed)
      firewall = fromJust (pFirewall parsed)
      jail = head (pFail2ban parsed)
  assert "cpu total" (mCpu metrics == 42.5)
  assert "cpu detail" (mCpuUser metrics == 21 && mCpuSystem metrics == 18 && mCpuIowait metrics == 3.5)
  assert "memory detail" (mMemAvailableBytes metrics == 1073741824 && mSwapUsedBytes metrics == 134217728)
  assert "all mounts" (map dmMount (pDisks parsed) == ["/", "/data"] && map dmType (pDisks parsed) == ["ext4", "xfs"])
  assert "redirect health is healthy" (map hcOk (pHealth parsed) == [True])
  assert "firewall reject block" (length (fwIptables firewall) == 2)
  assert "fail2ban IPs" (fjBannedIps jail == ["1.2.3.4", "5.6.7.8"])
  assert "fingerprint shape" (map fpAlgo (pFingerprints parsed) == ["ED25519"])
  assert "backup keyed protocol" (bkCount (fromJust (pBackup parsed)) == 7)
  assert "no parser errors" (Map.null (pErrors parsed))

testSectionFailure :: IO ()
testSectionFailure = do
  let tick = parseMetricsTick sampleTime (T.unlines
        [ "===CPU==="
        , "ERR:permission denied"
        , "===UPTIME==="
        , "10"
        , "===VNSTATD==="
        , "today 2.00 GiB | 1.00 GiB | 3.00 GiB | 1.0 Mbit/s"
        ])
  assert "section error retained" (Map.lookup "CPU" (mtErrors tick) == Just "permission denied")
  assert "vnstat today row" (case mtMetrics tick of
    Just metrics -> mRxBytes metrics == 2 * 1024 ^ (3 :: Int)
    Nothing -> False)

testStorage :: IO ()
testStorage = do
  temp <- getTemporaryDirectory
  let path = temp </> "server-monitor-test-v5.db"
      parsed = parseBatch server sampleTime fixture
      metrics = fromJust (pMetrics parsed)
      dbFiles = [path, path <> "-wal", path <> "-shm"]
      cleanupFiles = forM_ dbFiles $ \file -> doesFileExist file >>= flip when (removeFile file)
  cleanupFiles
  (do
      initDb path
      saveMetrics path (ServerId "test") metrics
      rows <- loadHistory path (ServerId "test") (24 * 365)
      assert "history round trip" (case rows of
        [row] -> mCpuUser row == 21 && mMemCacheBytes row == 536870912
        _ -> False)
      let alertEntry = AlertEntry True True sampleTime sampleTime SevCritical "disk full"
      saveAlertEntries path (ServerId "test") (Map.singleton "disk:/" alertEntry)
      restored <- loadAlertEntries path (ServerId "test")
      assert "alert state round trip" (restored == Map.singleton "disk:/" alertEntry)
    ) `finally` cleanupFiles
