{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

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
import Control.Exception (SomeException, finally, try)
import Control.Monad (forM_, forever, unless, void, when)
import Data.IORef
import Data.List (foldl')
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
  , parseBatch
  , parseMetricsTick
  )
import Monitor.Collector.SSH (fullScript, metricsScript, runRemote)
import Monitor.Core.Types
import Monitor.Storage.SQLite
  ( cleanup
  , saveCaddyStats
  , saveEvent
  , saveMetrics
  )

-- | Fork one worker per configured server.
startWorkers :: AppState -> MonitorConfig -> IO ()
startWorkers st cfg =
  mapM_
    (forkIO . monitorServer st (cfgAlerts cfg) (cfgCollection cfg))
    (cfgServers cfg)

-- | Mutable state private to one server worker.
data WorkerLocal = WorkerLocal
  { wlBusy         :: IORef Bool
  , wlFails        :: IORef Int
  , wlLastFull     :: IORef UTCTime
  , wlLastStatus   :: IORef ServerStatus
  , wlPrevNet      :: IORef (Maybe (UTCTime, Map Text (Integer, Integer)))
  , wlCpuHighSince :: IORef (Maybe UTCTime)
  , wlHealthFails  :: IORef (Map Text Int)
  , wlLastCleanup  :: IORef UTCTime
  }

newWorkerLocal :: IO WorkerLocal
newWorkerLocal = do
  now <- getCurrentTime
  WorkerLocal
    <$> newIORef False
    <*> newIORef 0
    <*> newIORef (addUTCTime (-100000) now)
    <*> newIORef Offline
    <*> newIORef Nothing
    <*> newIORef Nothing
    <*> newIORef Map.empty
    <*> newIORef now

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
  atomically (modifyTVar' (serverStates st) (Map.insert sid (emptyState cfg)))
  void (try (cleanup (dbPath st) (ccRetentionDays coll)) :: IO (Either SomeException ()))
  forever (loop wl)
  where
    sid = scId cfg

    loop wl = do
      fails <- readIORef (wlFails wl)
      let base = max 5 (scIntervalSec cfg)
          delaySec = min (ccBackoffMaxSec coll) (base * (2 :: Int) ^ min fails 6)
      threadDelay (delaySec * 1000000)
      wasBusy <- atomicModifyIORef' (wlBusy wl) (True,)
      unless wasBusy $
        finally (tick wl) (writeIORef (wlBusy wl) False)

    tick wl = do
      now <- getCurrentTime
      lastFullT <- readIORef (wlLastFull wl)
      let doFull = diffUTCTime now lastFullT >= fromIntegral (ccFullIntervalSec coll)
      r <- try (runRemote cfg (ccTimeoutSec coll) (if doFull then fullScript cfg else metricsScript))
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
      let msg = T.pack (show e)
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
        when (lastSt /= Offline) (writeTChan (events st) (StatusEvent sid Offline))
      when (lastSt /= Offline) (writeIORef (wlLastStatus wl) Offline)
      writeIORef (wlCpuHighSince wl) Nothing
      writeIORef (wlHealthFails wl) Map.empty

    -- Light tick: core metrics + per-interface counters for live rates.
    onMetricsTick wl now (mMetrics, ifaces, days, caddy, errs) = do
      rates <- computeRates wl now ifaces
      let m' = fmap (setRates rates) mMetrics
      updateCpuState wl now m'
      cpuCond <- cpuCondition wl now m'
      transitions <- alertTransitions now
        (maybeToList cpuCond ++ [ AlertCond "offline" SevCritical False "reachable again" ])
      emitAlertEvents transitions
      forM_ m' (saveMetrics (dbPath st) sid)
      lastSt <- readIORef (wlLastStatus wl)
      atomically $ do
        m <- readTVar (serverStates st)
        am <- readTVar (alertStates st)
        let prev = Map.findWithDefault (emptyState cfg) sid m
            prevCaddy = ssCaddy prev
            newCaddy = mergeCaddy prevCaddy caddy now
            st' = prev
              { ssStatus = Online
              , ssMetrics = m'
              , ssNetIfaces = ifaces
              , ssVnstatDays = days
              , ssCaddy = newCaddy
              , ssAlerts = activeAlerts am
              , ssSectionErrors = Map.union errs (ssSectionErrors prev)
              , ssLastError = Nothing
              , ssUpdatedAt = now
              }
        modifyTVar' (serverStates st) (Map.insert sid st')
        when (lastSt /= Online) (writeTChan (events st) (StatusEvent sid Online))
        forM_ m' (writeTChan (events st) . MetricsEvent sid)
      when (lastSt /= Online) (writeIORef (wlLastStatus wl) Online)

    -- Full tick: everything, plus threshold / health / TLS / backup alerts.
    onFullTick wl now p = do
      rates <- computeRates wl now (pNetIfaces p)
      let m' = fmap (setRates rates) (pMetrics p)
      updateCpuState wl now m'
      cpuCond <- cpuCondition wl now m'
      healthConds <- healthConditions wl p
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
        saveCaddyStats (dbPath st) sid (clSizeBytes c) (clLines c) now
      cleanupIfDue wl
      lastSt <- readIORef (wlLastStatus wl)
      atomically $ do
        m <- readTVar (serverStates st)
        am <- readTVar (alertStates st)
        let prev = Map.findWithDefault (emptyState cfg) sid m
            prevCaddy = ssCaddy prev
            newCaddy = mergeCaddy prevCaddy (pCaddy p) now
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
              , ssSectionErrors = Map.union (pErrors p) (ssSectionErrors prev)
              , ssLastError = Nothing
              , ssUpdatedAt = now
              }
        modifyTVar' (serverStates st) (Map.insert sid st')
        when (lastSt /= Online) (writeTChan (events st) (StatusEvent sid Online))
        forM_ m' (writeTChan (events st) . MetricsEvent sid)
      when (lastSt /= Online) (writeIORef (wlLastStatus wl) Online)

    cleanupIfDue wl = do
      now <- getCurrentTime
      lastClean <- readIORef (wlLastCleanup wl)
      when (diffUTCTime now lastClean >= 6 * 3600) $ do
        writeIORef (wlLastCleanup wl) now
        void (try (cleanup (dbPath st) (ccRetentionDays coll)) :: IO (Either SomeException ()))

    -- ---------------------------------------------------------------
    -- Alert engine (STM dedup / recovery / cooldown)
    -- ---------------------------------------------------------------

    alertTransitions now conds =
      atomically $ do
        m <- readTVar (alertStates st)
        let entries = Map.findWithDefault Map.empty sid m
            go (entries', evs) cond =
              let (newEntry, mPayload) = applyCond now (Map.lookup (condKey cond) entries') cond
              in case mPayload of
                   Nothing -> (Map.insert (condKey cond) newEntry entries', evs)
                   Just payload -> (Map.insert (condKey cond) newEntry entries', payload : evs)
            (entries', evs) = foldl' go (entries, []) conds
        writeTVar (alertStates st) (Map.insert sid entries' m)
        pure (reverse evs)

    applyCond now mEntry cond =
      let entry = fromMaybe (AlertEntry False now (addUTCTime (-100000) now) SevInfo "") mEntry
          cooldownEnd = addUTCTime (fromIntegral (acCooldownSec alerts)) (aeLastTransition entry)
      in case (condActive cond, aeActive entry) of
           (True, False)
             | now >= cooldownEnd ->
                 let e' = AlertEntry True now now (condSeverity cond) (condMessage cond)
                 in (e', Just (AlertPayload (condKey cond) (condSeverity cond) (condMessage cond) now "fired"))
             | otherwise -> (entry, Nothing)  -- suppressed by cooldown
           (True, True) -> (entry, Nothing)
           (False, True) ->
             let e' = AlertEntry False (aeSince entry) now (aeSeverity entry) (aeMessage entry)
             in (e', Just (AlertPayload (condKey cond) (condSeverity cond) (condMessage cond) (aeSince entry) "resolved"))
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
          curKeys = Map.keysSet cur
          curTotal = (sum (map fst (Map.elems cur)), sum (map snd (Map.elems cur)))
          allMap = Map.fromList [ (niName n, (niRx n, niTx n)) | n <- ifaces ]
      writeIORef (wlPrevNet wl) (Just (now, allMap))
      case prev of
        Just (t0, prevMap) ->
          let prevCur = Map.restrictKeys prevMap curKeys
              prevTotal = (sum (map fst (Map.elems prevCur)), sum (map snd (Map.elems prevCur)))
              dt = realToFrac (diffUTCTime now t0) :: Double
          in if dt <= 0
               then pure (0, 0)
               else pure ( fromIntegral (fst curTotal - fst prevTotal) / dt
                         , fromIntegral (snd curTotal - snd prevTotal) / dt
                         )
        Nothing -> pure (0, 0)

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
      [ AlertCond ("tls:" <> tcHost c) SevWarning (tcDaysLeft c < acTlsMinDays alerts) msg
      | c <- pTlsCerts p
      , let msg = "TLS " <> tcHost c <> " expires in " <> T.pack (show (tcDaysLeft c)) <> " days"
      ]

    healthConditions wl p = do
      old <- readIORef (wlHealthFails wl)
      let newMap = Map.fromList
            [ (hcUrl h, if hcOk h then 0 else 1 + Map.findWithDefault 0 (hcUrl h) old)
            | h <- pHealth p
            ]
      writeIORef (wlHealthFails wl) newMap
      pure
        [ AlertCond ("health:" <> hcUrl h) SevCritical
            (Map.findWithDefault 0 (hcUrl h) newMap >= acHealthMaxFails alerts) msg
        | h <- pHealth p
        , let fails = Map.findWithDefault 0 (hcUrl h) newMap
        , let msg = "health check " <> hcUrl h <> " failing (" <> T.pack (show fails) <> "x): " <> hcStatus h
        ]

    backupConditions now p = case pBackup p of
      Nothing -> []
      Just b ->
        AlertCond "backup-failed" SevCritical (bkFailed b == Just True) "backup service reported failure"
          : case bkNewestEpoch b of
               Nothing -> []
               Just epoch ->
                 let ageHours = diffUTCTime now (posixSecondsToUTCTime (fromIntegral epoch)) / 3600
                     stale = ageHours >= fromIntegral (acBackupMaxAgeHours alerts)
                     msg = "newest backup is " <> T.pack (show (round ageHours :: Int)) <> "h old"
                 in [ AlertCond "backup" SevCritical stale msg ]

    fmt1 d = T.pack (show (fromIntegral (round (d * 10) :: Int) / 10 :: Double))

    -- Merge a fresh caddy sample with the previous one to derive growth.
    -- The light script only fetches the size, so a missing line count is
    -- carried over from the previous full sample instead of being dropped.
    mergeCaddy _ Nothing _ = Nothing
    mergeCaddy prev (Just c) now =
      let withLines = case clLines c of
            Just _ -> c
            Nothing -> c { clLines = prev >>= clLines }
      in Just withLines
        { clGrowthBps = case prev of
            Just p ->
              let dt = realToFrac (diffUTCTime now (clMtime p)) :: Double
                  dSize = fromIntegral (clSizeBytes c - clSizeBytes p)
              in if dt > 0 then dSize / dt else 0
            Nothing -> 0
        }
