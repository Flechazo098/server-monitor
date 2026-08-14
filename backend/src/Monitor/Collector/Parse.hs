{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Parsers for the fixed read-only remote batch scripts.
--
-- Every parser is total: malformed or missing input yields empty results
-- (plus a section error), never an exception that could take down the
-- whole collection.
module Monitor.Collector.Parse
  ( Parsed (..)
  , emptyParsed
  , parseBatch
  , parseMetricsTick
  , parseDouble
  , parseSize
  ) where

import qualified Data.Aeson as Aeson
import Data.Aeson (FromJSON (..), withObject, (.:), (.:?), (.!=))
import Data.Char (isDigit)
import Data.List (find, foldl')
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Read as TR
import Data.Time
  ( UTCTime
  , defaultTimeLocale
  , diffUTCTime
  , formatTime
  , parseTimeM
  , zonedTimeToUTC
  )
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Monitor.Core.Types

-- | Everything a full batch can produce. Missing data is empty, not fatal.
data Parsed = Parsed
  { pMetrics      :: Maybe Metrics
  , pDisks        :: [DiskMount]
  , pDockerUsage  :: Maybe DockerUsage
  , pApt          :: Maybe AptUpgrades
  , pTlsCerts     :: [TlsCert]
  , pPorts        :: [TcpPort]
  , pSshLogins    :: [SshLogin]
  , pFirewall     :: Maybe Firewall
  , pVnstatDays   :: [VnstatDay]
  , pMonthRx      :: Integer
  , pMonthTx      :: Integer
  , pNetIfaces    :: [NetIface]
  , pFingerprints :: [Fingerprint]
  , pM3u8         :: Maybe M3u8Queue
  , pGitea        :: Maybe GiteaInfo
  , pCaddy        :: Maybe CaddyLogs
  , pContainers   :: [Container]
  , pServices     :: [Service]
  , pFail2ban     :: [Fail2banJail]
  , pBackup       :: Maybe BackupInfo
  , pHealth       :: [HealthCheck]
  , pErrors       :: Map Text Text
  }
  deriving (Show)

emptyParsed :: Parsed
emptyParsed = Parsed
  { pMetrics = Nothing
  , pDisks = []
  , pDockerUsage = Nothing
  , pApt = Nothing
  , pTlsCerts = []
  , pPorts = []
  , pSshLogins = []
  , pFirewall = Nothing
  , pVnstatDays = []
  , pMonthRx = 0
  , pMonthTx = 0
  , pNetIfaces = []
  , pFingerprints = []
  , pM3u8 = Nothing
  , pGitea = Nothing
  , pCaddy = Nothing
  , pContainers = []
  , pServices = []
  , pFail2ban = []
  , pBackup = Nothing
  , pHealth = []
  , pErrors = Map.empty
  }

-- ---------------------------------------------------------------------------
-- Generic helpers
-- ---------------------------------------------------------------------------

-- | Parse a double, tolerating suffixes like %, GiB, /s etc.
parseDouble :: Text -> Maybe Double
parseDouble t =
  let num = T.takeWhile (\c -> isDigit c || c `elem` (".-" :: String)) (T.strip t)
  in case TR.double num of
       Right (v, _) -> Just v
       _ -> Nothing

-- | Parse an integer prefix, ignoring any trailing unit or punctuation.
parseInt :: Text -> Maybe Int
parseInt t =
  let num = T.takeWhile isDigit (T.strip t)
  in case TR.decimal num of
       Right (v, _) -> Just v
       _ -> Nothing

-- | Parse an HTTP status code line, keeping only real 1xx-5xx responses.
parseHttpStatus :: Text -> Maybe Text
parseHttpStatus t = do
  n <- parseInt t
  if n >= 100 && n < 600
    then Just (T.pack (show n))
    else Nothing

-- | Parse a human size ("1.24 GiB") into bytes. Missing unit means bytes.
parseSize :: Text -> Integer
parseSize t = round (fromMaybe 0 (parseDouble t) * mult)
  where
    suf = T.toLower (T.dropWhile (\c -> isDigit c || c `elem` (".-" :: String)) t)
    s = T.strip suf
    mult
      | "gib" `T.isPrefixOf` s || "gb" `T.isPrefixOf` s = 1024 ^ (3 :: Int)
      | "mib" `T.isPrefixOf` s || "mb" `T.isPrefixOf` s = 1024 ^ (2 :: Int)
      | "kib" `T.isPrefixOf` s || "kb" `T.isPrefixOf` s = 1024
      | "tib" `T.isPrefixOf` s || "tb" `T.isPrefixOf` s = 1024 ^ (4 :: Int)
      | otherwise = 1

-- | Is the stripped token a supported traffic-size unit?
isSizeUnit :: Text -> Bool
isSizeUnit u = T.toLower u `elem`
  [ "b", "kb", "kib", "mb", "mib", "gb", "gib", "tb", "tib"
  , "bit", "kbit", "mbit", "gbit", "kibit", "mibit", "gibit"
  ]

-- | Section-based split of a remote batch output. Every section starts
-- with a line '===NAME==='. Lines starting with @ERR:@ inside a section
-- are peeled off into the error map.
sections :: Text -> (Map Text Text, Map Text Text)
sections raw =
  let out = T.filter (/= '\r') raw
      go acc errs curName curBody rest = case rest of
        [] -> finish acc errs curName curBody
        (l : ls')
          | Just name <- sectionName l ->
              let (acc', errs') = finish acc errs curName curBody
              in go acc' errs' name [] ls'
          | otherwise -> go acc errs curName (l : curBody) ls'
      finish acc errs curName curBody
        | T.null curName = (acc, errs)
        | otherwise =
            let (errLines, bodyLines) = partitionErr (reverse curBody)
                acc' = Map.insert curName (T.unlines bodyLines) acc
                errs' = case errLines of
                  [] -> errs
                  (e : _) -> Map.insert curName (T.strip (T.drop 4 e)) errs
            in (acc', errs')
      sectionName l =
        let t = T.strip l
        in if "===" `T.isPrefixOf` t && "===" `T.isSuffixOf` t
             then Just (T.strip (T.dropAround (== '=') t))
             else Nothing
      partitionErr = foldr step ([], [])
        where
          step l (es, bs)
            | "ERR:" `T.isPrefixOf` T.strip l = (T.strip l : es, bs)
            | otherwise = (es, l : bs)
  in go Map.empty Map.empty "" [] (T.lines out)

-- | Lookup helper on the section split result.
getSec :: Map Text Text -> Text -> Text
getSec secs k = Map.findWithDefault "" k secs

-- | (rx, tx) of the "today" row of vnstat -d. Falls back to the last
-- daily row when its date matches today (vnstat omits the literal
-- "today" row until the database has a fresh sample).
vnstatToday :: UTCTime -> Text -> (Integer, Integer)
vnstatToday now t =
  let rows = mapMaybe vnstatRow (T.lines t)
      todayStr = T.pack (formatTime defaultTimeLocale "%Y-%m-%d" now)
      literal = [ (rx, tx) | (d, rx, tx) <- rows, T.toLower d == "today" ]
  in case literal of
       ((rx, tx) : _) -> (rx, tx)
       [] -> case reverse rows of
         ((d, rx, tx) : _) | d == todayStr -> (rx, tx)
         _ -> (0, 0)

-- | One vnstat data row ("date rx | tx | total | rate"). Handles both the
-- daily format ("today"/"2026-08-14") and the monthly format ("Aug '26").
vnstatRow :: Text -> Maybe (Text, Integer, Integer)
vnstatRow l = do
  let parts = map T.strip (T.splitOn "|" (T.strip l))
      ws0 = T.words (headOr "" parts)
      ws1 = T.words (headOr "" (drop 1 parts))
      rateCol = headOr "" (drop 3 parts)
  if null parts || length ws0 < 2 || length ws1 < 2 || not ("/s" `T.isInfixOf` rateCol)
    then Nothing
    else
      let date = T.unwords (take (length ws0 - 2) ws0)
          rxTok = ws0 !! (length ws0 - 2)
          rxUnit = ws0 !! (length ws0 - 1)
          txTok = head ws1
          txUnit = ws1 !! 1
      in if T.any isDigit date && isSizeUnit rxUnit && isSizeUnit txUnit
           then Just (date, parseSize (rxTok <> rxUnit), parseSize (txTok <> txUnit))
           else Nothing

-- | Last month row of vnstat -m.
vnstatMonth :: Text -> (Integer, Integer)
vnstatMonth t =
  case reverse (mapMaybe vnstatRow (T.lines t)) of
    ((_, rx, tx) : _) -> (rx, tx)
    [] -> (0, 0)

-- | First list element, or a default for the empty list.
headOr :: Text -> [Text] -> Text
headOr d [] = d
headOr _ (x : _) = x

-- ---------------------------------------------------------------------------
-- Section parsers
-- ---------------------------------------------------------------------------

parseNetIfaces :: Text -> [NetIface]
parseNetIfaces t =
  [ NetIface name (fromIntegral rx) (fromIntegral tx)
  | l <- T.lines t
  , let parts = T.splitOn "|" (T.strip l)
  , length parts >= 3
  , let name = T.strip (head parts)
  , not (T.null name)
  , Just rx <- [parseInt (parts !! 1)]
  , Just tx <- [parseInt (parts !! 2)]
  ]

parseDisks :: Text -> [DiskMount]
parseDisks t =
  [ DiskMount fs size used avail pct mount
  | l <- T.lines t
  , let parts = T.splitOn "|" (T.strip l)
  , length parts >= 6
  , let fs = head parts
  , let size = parts !! 1
  , let used = parts !! 2
  , let avail = parts !! 3
  , let mount = T.intercalate "|" (drop 5 parts)
  , Just pct <- [parseDouble (parts !! 4)]
  ]

parseTls :: Text -> UTCTime -> (Map Text Text, [TlsCert])
parseTls t now =
  foldr step (Map.empty, []) (tlsBlocks (T.lines t))
  where
    tlsBlocks = reverse . map reverse . foldl' stepBlock [[]]
      where
        stepBlock acc l
          | Just h <- T.stripPrefix "HOST:" (T.strip l) = [T.strip h] : acc
          | otherwise = case acc of
              (b : bs) -> (l : b) : bs
              [] -> [[l]]
    step block (errs, certs) = case block of
      (h : body)
        | T.null h -> (errs, certs)
        | any ("ERR:" `T.isPrefixOf`) body || null body ->
            (Map.insert ("tls:" <> h) "probe failed" errs, certs)
        | otherwise ->
            case mkCert h body now of
              Just c -> (errs, c : certs)
              Nothing -> (Map.insert ("tls:" <> h) "certificate parse failed" errs, certs)
      [] -> (errs, certs)

mkCert :: Text -> [Text] -> UTCTime -> Maybe TlsCert
mkCert h ls now = do
  subject <- field "subject="
  issuer <- field "issuer="
  notAfterRaw <- field "notAfter="
  fp <- field "SHA256 Fingerprint="
  na <- parseNotAfter notAfterRaw
  pure TlsCert
    { tcHost = h
    , tcSubject = subject
    , tcIssuer = issuer
    , tcNotAfter = na
    , tcDaysLeft = floor (diffUTCTime na now / 86400)
    , tcFingerprint = fp
    }
  where
    field prefix =
      listToMaybe
        [ T.strip (T.drop (T.length prefix) l)
        | l <- ls
        , T.toLower prefix `T.isPrefixOf` T.toLower (T.strip l)
        ]

-- | "notAfter=Aug 14 12:00:00 2026 GMT" -> UTC time.
parseNotAfter :: Text -> Maybe UTCTime
parseNotAfter raw = do
  let t0 = fromMaybe raw (T.stripPrefix "notAfter=" raw)
      t1 = T.strip t0
      t2 = fromMaybe t1 (T.stripSuffix " GMT" t1)
  zt <- parseTimeM True defaultTimeLocale "%b %e %H:%M:%S %Y" (T.unpack t2)
  pure (zonedTimeToUTC zt)

parseFingerprints :: Text -> [Fingerprint]
parseFingerprints t =
  [ Fingerprint file algo algoTok
  | l <- T.lines t
  , let ws = T.words (T.strip l)
  , length ws >= 3
  , let algoTok = ws !! 1
  , ":" `T.isInfixOf` algoTok
  , let algo = T.takeWhile (/= ':') algoTok
  , let file = T.intercalate " " (drop 2 ws)
  , not (T.null file)
  ]

parsePorts :: Text -> [TcpPort]
parsePorts t =
  [ TcpPort port proto local proc exposed
  | l <- T.lines t
  , let ws = T.words (T.strip l)
  , length ws >= 5
  , let proto = head ws
  , proto `elem` ["tcp", "udp"]
  , let local = ws !! 4
  , let hostPart = localHost local
  , let exposed = hostPart `elem` ["0.0.0.0", "*", "::"]
  , let proc = parseProcess ws
  , Just port <- [parseInt (last (T.splitOn ":" local))]
  ]
  where
    localHost l
      | "[" `T.isPrefixOf` l = T.takeWhile (/= ']') (T.drop 1 l)
      | otherwise = T.takeWhile (/= ':') l
    parseProcess ws =
      case [w | w <- ws, "users:(" `T.isInfixOf` w] of
        (w : _) ->
          let inner = T.drop 1 (T.dropWhile (/= '(') (T.drop 1 (T.dropWhile (/= '(') w)))
              name = T.filter (/= '"') (T.takeWhile (/= ',') inner)
          in if T.null (T.strip name) then Nothing else Just (T.strip name)
        [] -> Nothing

parseSshLogins :: Text -> [SshLogin]
parseSshLogins t = mapMaybe mkLogin (T.lines t)
  where
    mkLogin l =
      let ws = T.words (T.strip l)
          time = if length ws >= 3 then T.unwords (take 3 ws) else ""
          isOk = "Accepted" `T.isInfixOf` l
          user = between "for " " from " l
          from = between "from " " port " l
      in if T.null user && T.null from
           then Nothing
           else Just (SshLogin time isOk user from)
    between a b s =
      let afterA = snd (T.breakOn a s)
          uptoB = fst (T.breakOn b afterA)
      in T.strip (T.drop (T.length a) uptoB)

parseFirewall :: Text -> Maybe Firewall
parseFirewall t =
  let ufwBlock = block "--UFW--" "--IPTABLES--" t
      iptBlock = block "--IPTABLES--" "--UFWREJECT--" t
      rejectBlock = block "--UFWREJECT--" "--" t
      active = "Status: active" `T.isInfixOf` ufwBlock
      rules = mapMaybe ufwRule (T.lines ufwBlock)
      ipt = mapMaybe iptRule (T.lines iptBlock ++ T.lines rejectBlock)
  in if T.null ufwBlock && T.null iptBlock && T.null rejectBlock
       then Nothing
       else Just (Firewall active rules ipt)
  where
    block from to s =
      let after = snd (T.breakOn from s)
          linesAfter = T.lines after
      in if T.null after
           then ""
           else T.unlines (takeWhile (not . T.isPrefixOf to . T.strip) linesAfter)
    ufwRule l =
      let cols = map T.strip (filter (not . T.null) (T.splitOn "  " (T.strip l)))
          norm a = case T.words a of
            (w : _) -> w
            [] -> a
      in case cols of
           (to : action : from : _)
             | norm action `elem` ["ALLOW", "DENY", "REJECT", "LIMIT"] ->
                 Just (UfwRule to (norm action) from)
           _ -> Nothing
    iptRule l =
      let ws = T.words (T.strip l)
      in case ws of
           (num : pkts : bytes : target : prot : _ : _ : _ : src : dst : _)
             | T.all isDigit num ->
                 Just (IptablesRule (parseSize pkts) (parseSize bytes) target prot src dst)
           _ -> Nothing

parseDockerDf :: Text -> Maybe DockerUsage
parseDockerDf t =
  case (row "Images", row "Containers", row "Local Volumes", row "Build Cache") of
    (Just a, Just b, Just c, Just d) ->
      Just (DockerUsage (mk a) (mk b) (mk c) (mk d))
    _ -> Nothing
  where
    row kw =
      case [T.words (T.strip l) | l <- T.lines t, kw `T.isPrefixOf` T.strip l] of
        (ws : _) ->
          let vals = drop (length (T.words kw)) ws
          in if length vals >= 3
               then Just (head vals, vals !! 2)   -- (total count, size)
               else Nothing
        [] -> Nothing
    mk (cnt, size) = DockerRow (fromMaybe 0 (parseInt cnt)) size

parseApt :: Text -> Maybe AptUpgrades
parseApt t =
  case T.lines t of
    [] -> Nothing
    (countLine : rest) ->
      let names = filter (not . T.null) (map T.strip rest)
      in Just (AptUpgrades (fromMaybe 0 (parseInt countLine)) names)

-- | Raw JSON shapes of the m3u8 queue probe.
data RawM3u8 = RawM3u8
  { rmCounts :: Map Text Int
  , rmRecent :: [RawM3u8Job]
  }
  deriving (Show)

instance FromJSON RawM3u8 where
  parseJSON = withObject "M3u8Queue" $ \o ->
    RawM3u8
      <$> o .: "counts"
      <*> o .: "recent"

data RawM3u8Job = RawM3u8Job
  { rjTitle    :: Text
  , rjStatus   :: Text
  , rjProgress :: Int
  , rjTotal    :: Int
  , rjUpdated  :: Text
  }
  deriving (Show)

instance FromJSON RawM3u8Job where
  parseJSON = withObject "M3u8Job" $ \o ->
    RawM3u8Job
      <$> o .: "t"
      <*> o .: "s"
      <*> o .:? "p" .!= 0
      <*> o .:? "n" .!= 0
      <*> o .: "u"

parseM3u8 :: Text -> Maybe M3u8Queue
parseM3u8 t =
  case [T.strip l | l <- T.lines t, not (T.null (T.strip l))] of
    (codeLine : jsonLine : _) ->
      let health = parseHttpStatus codeLine
          decoded = Aeson.eitherDecodeStrict' (TE.encodeUtf8 jsonLine) :: Either String RawM3u8
      in case (decoded, health) of
           (Right raw, _) -> Just M3u8Queue
             { mqHealth = health
             , mqCounts = rmCounts raw
             , mqRecent =
                 [ M3u8Job (rjTitle j) (rjStatus j) (rjProgress j) (rjTotal j) (rjUpdated j)
                 | j <- rmRecent raw
                 ]
             }
           (Left _, Just h) -> Just M3u8Queue { mqHealth = Just h, mqCounts = Map.empty, mqRecent = [] }
           (Left _, Nothing) -> Nothing
    (codeLine : _) ->
      case parseHttpStatus codeLine of
        Just h -> Just M3u8Queue { mqHealth = Just h, mqCounts = Map.empty, mqRecent = [] }
        Nothing -> Nothing
    [] -> Nothing

parseGitea :: Text -> Maybe GiteaInfo
parseGitea t =
  case [T.strip l | l <- T.lines t, not (T.null (T.strip l))] of
    [] -> Nothing
    (codeLine : rest) ->
      let health = parseHttpStatus codeLine
          stats = case rest of
            (dbLine : _) ->
              let ints = map parseInt (T.splitOn "|" dbLine)
              in if length ints >= 4 && all isJust ints
                   then (head ints, ints !! 1, ints !! 2, ints !! 3)
                   else (Nothing, Nothing, Nothing, Nothing)
            [] -> (Nothing, Nothing, Nothing, Nothing)
          (repos, users, activeWeek, lastPush) = stats
      in if isNothing health && all isNothing [repos, users, activeWeek, lastPush]
           then Nothing
           else Just GiteaInfo
             { giHealth = health
             , giRepos = repos
             , giUsers = users
             , giActiveWeek = activeWeek
             , giLastPush = lastPush
             }

parseCaddy :: Text -> Maybe CaddyLogs
parseCaddy t =
  case [T.strip l | l <- T.lines t, not (T.null (T.strip l))] of
    [] -> Nothing
    (statLine : rest) ->
      let parts = T.splitOn "|" statLine
      in case (parseInt (headOr "" parts), parseInt (headOr "" (drop 1 parts))) of
           (Just size, Just epoch) ->
             let linesCount = case rest of
                   (l : _) -> parseInt l
                   [] -> Nothing
             in Just CaddyLogs
               { clSizeBytes = fromIntegral size
               , clLines = linesCount
               , clMtime = posixSecondsToUTCTime (fromIntegral epoch)
               , clGrowthBps = 0
               }
           _ -> Nothing

parseBackup :: Text -> Maybe BackupInfo
parseBackup t =
  let ls = [T.strip l | l <- T.lines t, not (T.null (T.strip l))]
      count = listToMaybe ls >>= parseInt
      epoch = listToMaybe (drop 1 ls) >>= parseInt
      rest = drop 2 ls
      lastLine = listToMaybe
        [ T.strip (T.drop (T.length "LastTriggerUSec=") l)
        | l <- rest
        , "LastTriggerUSec=" `T.isPrefixOf` l
        , not (T.null (T.strip (T.drop (T.length "LastTriggerUSec=") l)))
        ]
      nextLine = listToMaybe
        [ T.strip (T.drop (T.length "NextElapseUSecRealtime=") l)
        | l <- rest
        , "NextElapseUSecRealtime=" `T.isPrefixOf` l
        , "n/a" `T.isInfixOf` l || not (T.null (T.strip (T.drop (T.length "NextElapseUSecRealtime=") l)))
        ]
      failedLine = find (`elem` ["failed", "active", "inactive", "unknown"]) rest
      failed = fmap (== "failed") failedLine
  in if T.null t || (isNothing count && isNothing epoch)
       then Nothing
       else Just BackupInfo
         { bkLastRun = lastLine
         , bkNextRun = nextLine
         , bkCount = fromMaybe 0 count
         , bkLatest = Nothing
         , bkNewestEpoch = epoch
         , bkFailed = failed
         }

parseContainers :: Text -> Text -> [Container]
parseContainers ps stats =
  let rows = map (T.splitOn "|") (T.lines ps)
      statsMap = [(T.strip (T.dropWhile (== '/') (T.takeWhile (/= '|') s)), s) | s <- T.lines stats]
      mk r = case r of
        (name : image : status : _) ->
          let srow = lookup (T.strip name) statsMap
              cpu = srow >>= (parseDouble . T.strip . headOr "" . drop 1 . T.splitOn "|")
              mem = srow >>= (parseDouble . T.strip . headOr "" . drop 2 . T.splitOn "|")
          in Just Container
               { cName = T.strip name
               , cImage = T.strip image
               , cStatus = T.strip status
               , cCpuPct = cpu
               , cMemPct = mem
               }
        _ -> Nothing
  in mapMaybe mk rows

parseServices :: Text -> [Service]
parseServices t =
  [ Service name (state == "active")
  | l <- T.lines t
  , let (name, rest) = T.breakOn ":" (T.strip l)
  , not (T.null rest)
  , let state = T.strip (T.drop 1 rest)
  , not (T.null state)
  ]

parseFail2ban :: Text -> [Fail2banJail]
parseFail2ban t =
  let ls = T.lines t
      jailLine = fromMaybe "" (find ("Jail list:" `T.isInfixOf`) ls)
      jailNames = filter (not . T.null) (map (T.strip . T.dropWhile (== ':')) (T.splitOn "," (T.dropWhile (/= ':') jailLine)))
      isHeader n l = ("== " <> n <> " ==") `T.isInfixOf` l
      seg n = dropWhile (not . isHeader n) ls
      getVal key seg' =
        let body = takeWhile (\x -> not (any (`isHeader` x) jailNames)) (drop 1 seg')
        in case [l | l <- body, key `T.isInfixOf` l] of
             (l : _) -> fromMaybe 0 (parseInt (T.strip (T.drop 1 (T.dropWhile (/= ':') l))))
             [] -> 0
  in [ Fail2banJail n (getVal "Currently banned:" (seg n)) (getVal "Total banned:" (seg n))
     | n <- jailNames
     ]

parseHealth :: Text -> [HealthCheck]
parseHealth t =
  [ HealthCheck url (code == "200") ms code
  | l <- T.lines t
  , let ws = T.words l
  , length ws >= 3
  , let url = head ws
  , not (T.null url)
  , let code = ws !! 1
  , T.length code == 3
  , let ms = round (fromMaybe 0 (parseDouble (ws !! 2)) * 1000)
  ]

-- ---------------------------------------------------------------------------
-- Batch assembly
-- ---------------------------------------------------------------------------

-- | Parse the output of the full batch script.
parseBatch :: ServerConfig -> UTCTime -> Text -> Parsed
parseBatch _cfg now out =
  let (secs, errs) = sections out
      (todayRx, todayTx) = vnstatToday now (getSec secs "VNSTATD")
      (monthRx, monthTx) = vnstatMonth (getSec secs "VNSTATM")
      (l1, l5, l15) = loads (getSec secs "LOAD")
      (tlsErrs, tlsCerts) = parseTls (getSec secs "TLS") now
      metrics =
        if T.null (getSec secs "UPTIME") && T.null (getSec secs "CPU") && T.null (getSec secs "MEM")
          then Nothing
          else Just Metrics
            { mCpu = fromMaybe 0 (parseDouble (headOr "0" (T.lines (getSec secs "CPU"))))
            , mMemUsedPct = fromMaybe 0 (parseDouble (headOr "0" (T.lines (getSec secs "MEM"))))
            , mLoad1 = l1
            , mLoad5 = l5
            , mLoad15 = l15
            , mUptimeSec = fromMaybe 0 (parseInt (getSec secs "UPTIME"))
            , mDiskUsedPct = fromMaybe 0 (parseDouble (headOr "0" (T.lines (getSec secs "DISK"))))
            , mRxBytes = todayRx
            , mTxBytes = todayTx
            , mRxRate = 0
            , mTxRate = 0
            , mTimestamp = now
            }
  in emptyParsed
    { pMetrics = metrics
    , pDisks = parseDisks (getSec secs "DISKMOUNTS")
    , pDockerUsage = parseDockerDf (getSec secs "DOCKERDF")
    , pApt = parseApt (getSec secs "APT")
    , pTlsCerts = tlsCerts
    , pPorts = parsePorts (getSec secs "PORTS")
    , pSshLogins = parseSshLogins (getSec secs "SSHAUTH")
    , pFirewall = parseFirewall (getSec secs "FIREWALL")
    , pVnstatDays = parseVnstatDays (getSec secs "VNSTATD")
    , pMonthRx = monthRx
    , pMonthTx = monthTx
    , pNetIfaces = parseNetIfaces (getSec secs "NETDEV")
    , pFingerprints = parseFingerprints (getSec secs "FINGERPRINTS")
    , pM3u8 = parseM3u8 (getSec secs "M3U8")
    , pGitea = parseGitea (getSec secs "GITEA")
    , pCaddy = parseCaddy (getSec secs "CADDY")
    , pContainers = parseContainers (getSec secs "CONTAINERS") (getSec secs "STATS")
    , pServices = parseServices (getSec secs "SERVICES")
    , pFail2ban = parseFail2ban (getSec secs "F2B")
    , pBackup = parseBackup (getSec secs "BACKUP")
    , pHealth = parseHealth (getSec secs "HEALTH")
    , pErrors = Map.union tlsErrs errs
    }

parseVnstatDays :: Text -> [VnstatDay]
parseVnstatDays t =
  [ VnstatDay d rx tx
  | (d, rx, tx) <- mapMaybe vnstatRow (T.lines t)
  ]

-- | Parse the output of the light metrics script.
parseMetricsTick :: UTCTime -> Text -> (Maybe Metrics, [NetIface], [VnstatDay], Maybe CaddyLogs, Map Text Text)
parseMetricsTick now out =
  let (secs, errs) = sections out
      (todayRx, todayTx) = vnstatToday now (getSec secs "VNSTATD")
      (l1, l5, l15) = loads (getSec secs "LOAD")
      ifaces = parseNetIfaces (getSec secs "NETDEV")
      metrics =
        if T.null (getSec secs "UPTIME")
          then Nothing
          else Just Metrics
            { mCpu = fromMaybe 0 (parseDouble (headOr "0" (T.lines (getSec secs "CPU"))))
            , mMemUsedPct = fromMaybe 0 (parseDouble (headOr "0" (T.lines (getSec secs "MEM"))))
            , mLoad1 = l1
            , mLoad5 = l5
            , mLoad15 = l15
            , mUptimeSec = fromMaybe 0 (parseInt (getSec secs "UPTIME"))
            , mDiskUsedPct = fromMaybe 0 (parseDouble (headOr "0" (T.lines (getSec secs "DISK"))))
            , mRxBytes = todayRx
            , mTxBytes = todayTx
            , mRxRate = 0
            , mTxRate = 0
            , mTimestamp = now
            }
  in ( metrics
     , ifaces
     , parseVnstatDays (getSec secs "VNSTATD")
     , parseCaddy (getSec secs "CADDY")
     , errs
     )

-- | Load averages from 'uptime' output ("0.10, 0.05, 0.01").
loads :: Text -> (Double, Double, Double)
loads t =
  let ws = T.words t
      nums = map parseLoad ws
  in case nums of
       (a : b : c : _) -> (a, b, c)
       _ -> (0, 0, 0)
  where
    parseLoad w = if T.any isDigit w then fromMaybe 0 (parseDouble w) else 0
