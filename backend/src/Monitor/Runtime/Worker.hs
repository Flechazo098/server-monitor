{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Background collection workers.
--
-- One thread per server. Each tick runs a fixed read-only batch script
-- over SSH, updates the shared TVar state, broadcasts events on the TChan
-- and appends metrics to SQLite history.
--
-- Scheduling policy:
--   * light metrics script every @intervalSec@ (fast rates + core metrics)
--   * full batch every @fullIntervalSec@ (docker, firewall, certs, ...)
--   * consecutive failures back off exponentially up to @backoffMaxSec@
--   * a tick is skipped when the previous one is still running, so SSH
--     sessions never pile up
--
-- Alerting policy (dedup + recovery + debounce):
--   * every condition is keyed; transitions (fired/resolved) emit exactly
--     one event and one DB row
--   * after a recovery the key stays quiet for @cooldownSec@, which stops
--     flapping from re-spamming events
module Monitor.Runtime.Worker
  ( startWorkers
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM
import Control.Exception (SomeException, fromException, try)
import Control.Monad (forM_, forever, void, when)
import Data.IORef
import Data.Either (fromRight)
import Data.List (find, foldl')
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, maybeToList)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time
  ( UTCTime
  , addUTCTime
  , diffUTCTime
  , getCurrentTime
  )
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Monitor.Collector.Parse
  ( Parsed (..)
  , MetricsTick (..)
  , parseBatch
  , parseMetricsTick
  )
import Monitor.Collector.SSH (CollectorError (..), fullScript, metricsScript, runRemote)
import Monitor.Core.Types
import Monitor.Storage.SQLite
  ( cleanup
  , loadAlertEntries
  , saveCaddyStats
  , saveAlertEntries
  , saveEvent
  , saveMetrics
  )

-- | Fork one worker per configured server.
startWorkers :: AppState -> MonitorConfig -> IO ()
startWorkers st cfg = do
  runCleanup
  void (forkIO cleanupLoop)
  mapM_
    (forkIO . monitorServer st (cfgAlerts cfg) (cfgCollection cfg))
    (cfgServers cfg)
  where
    retention = ccRetentionDays (cfgCollection cfg)
    runCleanup = void (try (cleanup (dbPath st) retention) :: IO (Either SomeException ()))
    cleanupLoop = forever $ do
      threadDelay (6 * 3600 * 1000000)
      runCleanup

-- | Mutable state private to one server worker.
data WorkerLocal = WorkerLocal
  { wlFails        :: IORef Int
  , wlLastFull     :: IORef UTCTime
  , wlLastStatus   :: IORef (Maybe ServerStatus)
  , wlPrevNet      :: IORef (Maybe (UTCTime, Map Text (Integer, Integer)))
  , wlCpuHighSince :: IORef (Maybe UTCTime)
  , wlHealthFails  :: IORef (Map Text Int)
  }

newWorkerLocal :: IO WorkerLocal
newWorkerLocal = do
  now <- getCurrentTime
  WorkerLocal
    <$> newIORef 0
    <*> newIORef (addUTCTime (-100000) now)
    <*> newIORef Nothing
    <*> newIORef Nothing
    <*> newIORef Nothing
    <*> newIORef Map.empty

-- | One alert condition evaluated on a tick.
data AlertCond = AlertCond
  { condKey      :: Text
  , condSeverity :: Severity
  , condActive   :: Bool
  , condMessage  :: Text
  }

-- | Per-server collection loop.
monitorServer :: AppState -> AlertConfig -> CollectionConfig -> ServerConfig -> IO ()
monitorServer st alerts coll cfg = do
  wl <- newWorkerLocal
  restoredResult <- try (loadAlertEntries (dbPath st) sid)
  let restored = fromRight Map.empty (restoredResult :: Either SomeException (Map Text AlertEntry))
  atomically $ do
    modifyTVar' (serverStates st) (Map.insert sid (emptyState cfg))
    modifyTVar' (alertStates st) (Map.insert sid restored)
  tick wl
  forever (loop wl)
  where
    sid = scId cfg

    loop wl = do
      fails <- readIORef (wlFails wl)
      let base = max 5 (scIntervalSec cfg)
          delaySec = min (ccBackoffMaxSec coll) (base * (2 :: Int) ^ min fails 6)
      threadDelay (delaySec * 1000000)
      tick wl

    tick wl = do
      now <- getCurrentTime
      lastFullT <- readIORef (wlLastFull wl)
      let doFull = diffUTCTime now lastFullT >= fromIntegral (ccFullIntervalSec coll)
      r <- try (runRemote cfg (ccTimeoutSec coll) (if doFull then fullScript cfg else metricsScript cfg))
      case r of
        Left (e :: SomeException) -> onFailure wl now e
        Right out
          | doFull -> do
              writeIORef (wlLastFull wl) now
              onFullTick wl now (parseBatch cfg now out)
          | otherwise -> onMetricsTick wl now (parseMetricsTick now out)

    -- Transport failure: keep the last good data, mark the server offline,
    -- fire the offline alert exactly once per episode.
    onFailure wl now e = do
      fails <- readIORef (wlFails wl)
      writeIORef (wlFails wl) (fails + 1)
      let msg = case fromException e of
            Just (CollectorError detail) -> detail
            Nothing -> "collector failed"
      transitions <- alertTransitions now
        [ AlertCond "offline" SevCritical True ("unreachable: " <> msg) ]
      emitAlertEvents transitions
      lastSt <- readIORef (wlLastStatus wl)
      atomically $ do
        m <- readTVar (serverStates st)
        am <- readTVar (alertStates st)
        let prev = Map.findWithDefault (emptyState cfg) sid m
        modifyTVar' (serverStates st) (Map.insert sid prev
          { ssStatus = Offline
          , ssAlerts = activeAlerts am
          , ssLastError = Just msg
          , ssUpdatedAt = now
          })
        when (lastSt /= Just Offline) (writeTChan (events st) (StatusEvent sid Offline))
      when (lastSt /= Just Offline) (writeIORef (wlLastStatus wl) (Just Offline))
      when (lastSt /= Just Offline) $
        saveEvent (dbPath st) sid "status" SevCritical "fired" "server went offline"
      writeIORef (wlCpuHighSince wl) Nothing
      writeIORef (wlHealthFails wl) Map.empty

    -- Light tick: core metrics + per-interface counters for live rates.
    onMetricsTick wl now tickData = do
      writeIORef (wlFails wl) 0
      rates <- computeRates wl now (mtNetIfaces tickData)
      let m' = fmap (setRates rates) (mtMetrics tickData)
      updateCpuState wl now m'
      cpuCond <- cpuCondition wl now m'
      healthConds <- healthConditions wl (mtHealth tickData)
      transitions <- alertTransitions now
        ( maybeToList cpuCond
          ++ maybeToList (memCondition m')
          ++ maybeToList (rootDiskCondition m')
          ++ healthConds
          ++ [AlertCond "offline" SevCritical False "reachable again"]
        )
      emitAlertEvents transitions
      forM_ m' (saveMetrics (dbPath st) sid)
      lastSt <- readIORef (wlLastStatus wl)
      atomically $ do
        m <- readTVar (serverStates st)
        am <- readTVar (alertStates st)
        let prev = Map.findWithDefault (emptyState cfg) sid m
            prevCaddy = ssCaddy prev
            newCaddy = mergeCaddy prevCaddy (mtCaddy tickData)
            st' = prev
              { ssStatus = Online
              , ssMetrics = m'
              , ssHealth = mtHealth tickData
              , ssNetIfaces = mtNetIfaces tickData
              , ssVnstatDays = mtVnstatDays tickData
              , ssCaddy = newCaddy
              , ssAlerts = activeAlerts am
              , ssSectionErrors = mergeLightErrors (ssSectionErrors prev) (mtErrors tickData)
              , ssLastError = Nothing
              , ssUpdatedAt = now
              }
        modifyTVar' (serverStates st) (Map.insert sid st')
        when (lastSt == Just Offline) (writeTChan (events st) (StatusEvent sid Online))
        writeTChan (events st) (ServerEvent sid st')
      writeIORef (wlLastStatus wl) (Just Online)
      when (lastSt == Just Offline) $
        saveEvent (dbPath st) sid "status" SevInfo "resolved" "server came online"

    -- Full tick: everything, plus threshold / health / TLS / backup alerts.
    onFullTick wl now p = do
      writeIORef (wlFails wl) 0
      rates <- computeRates wl now (pNetIfaces p)
      let m' = fmap (setRates rates) (pMetrics p)
      updateCpuState wl now m'
      cpuCond <- cpuCondition wl now m'
      healthConds <- healthConditions wl (pHealth p)
      let conds =
            maybeToList cpuCond
              ++ maybeToList (memCondition m')
              ++ diskConditions p
              ++ tlsConditions p
              ++ backupConditions now p
              ++ healthConds
              ++ [ AlertCond "offline" SevCritical False "reachable again" ]
      transitions <- alertTransitions now conds
      emitAlertEvents transitions
      forM_ m' (saveMetrics (dbPath st) sid)
      forM_ (pCaddy p) $ \c ->
        saveCaddyStats (dbPath st) sid (clSizeBytes c) now
      lastSt <- readIORef (wlLastStatus wl)
      atomically $ do
        m <- readTVar (serverStates st)
        am <- readTVar (alertStates st)
        let prev = Map.findWithDefault (emptyState cfg) sid m
            prevCaddy = ssCaddy prev
            newCaddy = mergeCaddy prevCaddy (pCaddy p)
            st' = prev
              { ssStatus = Online
              , ssMetrics = m'
              , ssContainers = pContainers p
              , ssServices = pServices p
              , ssFail2ban = pFail2ban p
              , ssBackup = pBackup p
              , ssHealth = pHealth p
              , ssDisks = pDisks p
              , ssDockerUsage = pDockerUsage p
              , ssApt = pApt p
              , ssTlsCerts = pTlsCerts p
              , ssPorts = pPorts p
              , ssSshLogins = pSshLogins p
              , ssFirewall = pFirewall p
              , ssVnstatDays = pVnstatDays p
              , ssNetIfaces = pNetIfaces p
              , ssFingerprints = pFingerprints p
              , ssM3u8 = pM3u8 p
              , ssGitea = pGitea p
              , ssCaddy = newCaddy
              , ssAlerts = activeAlerts am
              , ssSectionErrors = pErrors p
              , ssLastError = Nothing
              , ssUpdatedAt = now
              }
        modifyTVar' (serverStates st) (Map.insert sid st')
        when (lastSt == Just Offline) (writeTChan (events st) (StatusEvent sid Online))
        writeTChan (events st) (ServerEvent sid st')
      writeIORef (wlLastStatus wl) (Just Online)
      when (lastSt == Just Offline) $
        saveEvent (dbPath st) sid "status" SevInfo "resolved" "server came online"

    -- ---------------------------------------------------------------
    -- Alert engine (STM dedup / recovery / cooldown)
    -- ---------------------------------------------------------------

    alertTransitions now conds = do
      (entries', changed, payloads) <- atomically $ do
        m <- readTVar (alertStates st)
        let entries = Map.findWithDefault Map.empty sid m
            go (entries', evs) cond =
              let (newEntry, mPayload) = applyCond now (Map.lookup (condKey cond) entries') cond
              in case mPayload of
                   Nothing -> (Map.insert (condKey cond) newEntry entries', evs)
                   Just payload -> (Map.insert (condKey cond) newEntry entries', payload : evs)
            (entries', evs) = foldl' go (entries, []) conds
        writeTVar (alertStates st) (Map.insert sid entries' m)
        pure (entries', entries' /= entries, reverse evs)
      when changed (saveAlertEntries (dbPath st) sid entries')
      pure payloads

    applyCond now mEntry cond =
      let initialTransition = addUTCTime (negate (fromIntegral (acCooldownSec alerts)) - 1) now
          entry = fromMaybe (AlertEntry False False now initialTransition SevInfo "") mEntry
          cooldownEnd = addUTCTime (fromIntegral (acCooldownSec alerts)) (aeLastTransition entry)
      in case (condActive cond, aeActive entry) of
           (True, False)
             | now >= cooldownEnd ->
                 let e' = AlertEntry True True now now (condSeverity cond) (condMessage cond)
                 in (e', Just (AlertPayload (condKey cond) (condSeverity cond) (condMessage cond) now now "fired"))
             | otherwise ->
                 (entry
                    { aeActive = True
                    , aeNotified = False
                    , aeSince = now
                    , aeSeverity = condSeverity cond
                    , aeMessage = condMessage cond
                    }
                 , Nothing)
           (True, True)
             | not (aeNotified entry) && now >= cooldownEnd ->
                 let e' = entry
                       { aeNotified = True
                       , aeLastTransition = now
                       , aeSeverity = condSeverity cond
                       , aeMessage = condMessage cond
                       }
                 in (e', Just (AlertPayload (condKey cond) (condSeverity cond) (condMessage cond) (aeSince entry) now "fired"))
             | otherwise ->
                 (entry { aeSeverity = condSeverity cond, aeMessage = condMessage cond }, Nothing)
           (False, True) ->
             let e' = entry { aeActive = False, aeNotified = False, aeLastTransition = now }
                 payload = if aeNotified entry
                   then Just (AlertPayload (condKey cond) (aeSeverity entry) (condMessage cond) (aeSince entry) now "resolved")
                   else Nothing
             in (e', payload)
           (False, False) -> (entry, Nothing)

    emitAlertEvents payloads =
      forM_ payloads $ \p -> do
        saveEvent (dbPath st) sid "alert" (apSeverity p) (apState p) (apMessage p)
        atomically (writeTChan (events st) (AlertEvent sid p))

    activeAlerts am =
      [ Alert key (aeSeverity e) (aeMessage e) (aeSince e)
      | (key, e) <- Map.toList (Map.findWithDefault Map.empty sid am)
      , aeActive e
      ]

    -- ---------------------------------------------------------------
    -- Condition builders
    -- ---------------------------------------------------------------

    setRates (rxr, txr) m = m { mRxRate = rxr, mTxRate = txr }

    -- (rx, tx) bytes/sec from per-interface counters, summing physical NICs
    -- only (lo / tun / docker / veth / br- excluded).
    computeRates wl now ifaces = do
      prev <- readIORef (wlPrevNet wl)
      let cur = Map.fromList [ (niName n, (niRx n, niTx n)) | n <- ifaces, not (isVirtual (niName n)) ]
      writeIORef (wlPrevNet wl) (Just (now, cur))
      case prev of
        Just (t0, prevMap) ->
          let deltas = Map.elems (Map.intersectionWith delta cur prevMap)
              (rxDelta, txDelta) = foldl' (\(rx, tx) (drx, dtx) -> (rx + drx, tx + dtx)) (0, 0) deltas
              dt = realToFrac (diffUTCTime now t0) :: Double
          in if dt <= 0 || null deltas
               then pure (0, 0)
               else pure ( fromIntegral rxDelta / dt
                         , fromIntegral txDelta / dt
                         )
        Nothing -> pure (0, 0)
      where
        delta (rx, tx) (prevRx, prevTx) = (max 0 (rx - prevRx), max 0 (tx - prevTx))

    isVirtual n =
      let lower = T.toLower n
      in any (`T.isPrefixOf` lower)
           [ "lo", "tun", "tap", "docker", "veth", "br-", "virbr", "tailscale", "wg", "zt", "flannel", "cni" ]

    updateCpuState wl _ Nothing = writeIORef (wlCpuHighSince wl) Nothing
    updateCpuState wl now (Just m) = do
      highSince <- readIORef (wlCpuHighSince wl)
      if mCpu m >= acCpuPct alerts
        then case highSince of
          Just _ -> pure ()          -- still high
          Nothing -> writeIORef (wlCpuHighSince wl) (Just now)
        else writeIORef (wlCpuHighSince wl) Nothing

    cpuCondition wl now m = do
      highSince <- readIORef (wlCpuHighSince wl)
      pure $ case m of
        Nothing -> Nothing
        Just met ->
          let sustained = case highSince of
                Just t -> diffUTCTime now t >= fromIntegral (acCpuSustainSec alerts)
                Nothing -> False
              msg = if sustained
                      then "CPU " <> fmt1 (mCpu met) <> "% sustained >= " <> T.pack (show (acCpuSustainSec alerts)) <> "s"
                      else "CPU back to normal"
          in Just (AlertCond "cpu" SevWarning sustained msg)

    memCondition m = do
      met <- m
      let over = mMemUsedPct met >= acMemPct alerts
      pure (AlertCond "mem" SevCritical over
        (if over then "Memory " <> fmt1 (mMemUsedPct met) <> "% (limit " <> fmt1 (acMemPct alerts) <> "%)"
                 else "Memory back to normal"))

    diskConditions p =
      [ AlertCond ("disk:" <> dmMount d) SevCritical over msg
      | d <- pDisks p
      , let over = dmPct d >= acDiskPct alerts
      , let msg = "Disk " <> dmMount d <> " at " <> fmt1 (dmPct d) <> "%"
      ]

    tlsConditions p =
      concatMap conditionFor (certHostsOf cfg)
      where
        conditionFor host = case find ((== host) . tcHost) (pTlsCerts p) of
          Just cert ->
            [ AlertCond ("tls:" <> host) SevWarning (tcDaysLeft cert < acTlsMinDays alerts)
                (if tcDaysLeft cert < acTlsMinDays alerts
                  then "TLS " <> host <> " expires in " <> T.pack (show (tcDaysLeft cert)) <> " days"
                  else "TLS " <> host <> " validity is healthy")
            ]
          Nothing
            | Map.member ("tls:" <> host) (pErrors p) || Map.member "TLS" (pErrors p) ->
                [AlertCond ("tls:" <> host) SevCritical True ("TLS probe failed for " <> host)]
            | otherwise -> []

    healthConditions wl health = do
      old <- readIORef (wlHealthFails wl)
      let newMap = Map.fromList
            [ (hcUrl h, if hcOk h then 0 else 1 + Map.findWithDefault 0 (hcUrl h) old)
            | h <- health
            ]
      writeIORef (wlHealthFails wl) newMap
      pure
        [ AlertCond ("health:" <> hcUrl h) SevCritical
            (Map.findWithDefault 0 (hcUrl h) newMap >= acHealthMaxFails alerts) msg
        | h <- health
        , let fails = Map.findWithDefault 0 (hcUrl h) newMap
        , let msg = "health check " <> hcUrl h <> " failing (" <> T.pack (show fails) <> "x): " <> hcStatus h
        ]

    backupConditions now p = case pBackup p of
      Nothing -> []
      Just b ->
        AlertCond "backup-failed" SevCritical (bkFailed b == Just True) "backup service reported failure"
          : AlertCond "backup-empty" SevCritical (bkCount b <= 0)
              (if bkCount b <= 0 then "no local backup files found" else "backup files present")
          : case bkNewestEpoch b of
               Nothing -> []
               Just epoch ->
                 let ageHours = diffUTCTime now (posixSecondsToUTCTime (fromIntegral epoch)) / 3600
                     stale = ageHours >= fromIntegral (acBackupMaxAgeHours alerts)
                     msg = "newest backup is " <> T.pack (show (round ageHours :: Int)) <> "h old"
                 in [ AlertCond "backup" SevCritical stale msg ]

    fmt1 d = T.pack (show (fromIntegral (round (d * 10) :: Int) / 10 :: Double))

    rootDiskCondition m = do
      met <- m
      let over = mDiskUsedPct met >= acDiskPct alerts
      pure (AlertCond "disk:/" SevCritical over
        (if over then "Disk / at " <> fmt1 (mDiskUsedPct met) <> "%"
                 else "Disk / back to normal"))

    mergeLightErrors old fresh =
      Map.union fresh (foldr Map.delete old lightSections)
      where
        lightSections = ["CPU", "MEM", "LOAD", "UPTIME", "DISK", "NETDEV", "VNSTATD", "CADDY", "HEALTH"]

    -- Merge a fresh caddy sample with the previous one to derive growth.
    mergeCaddy _ Nothing = Nothing
    mergeCaddy prev (Just c) =
      Just c
        { clGrowthBps = case prev of
            Just p ->
              let dt = realToFrac (diffUTCTime (clMtime c) (clMtime p)) :: Double
                  dSize = fromIntegral (clSizeBytes c - clSizeBytes p)
              in if dt > 0 then max 0 (dSize / dt) else 0
            Nothing -> 0
        }
