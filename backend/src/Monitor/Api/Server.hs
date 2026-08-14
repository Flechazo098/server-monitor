{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

-- | HTTP API: type-level description of every read-only endpoint.
--
-- There are no mutating endpoints by design: no POST /exec, no restart,
-- no config writes. The only push channel is the WebSocket stream.
module Monitor.Api.Server
  ( app
  , runBackend
  , authMiddleware
  , corsMiddleware
  ) where

import Control.Concurrent.STM
import Control.Exception (SomeException, finally, try)
import Control.Monad (forever, void)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (ToJSON (..), object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Char8 as BC
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Tagged ()
import Data.Text (Text)
import qualified Data.Text as T
import Monitor.Core.Types
import Monitor.Storage.SQLite
  ( CaddySample
  , EventRow
  , loadCaddyStats
  , loadHistory
  , loadRecentEvents
  )
import Network.HTTP.Types (status204, status401, status403, status404)
import Network.Socket
import Network.Wai (Request, mapResponseHeaders, pathInfo, requestHeaders, requestMethod, responseLBS)
import Network.Wai.Handler.Warp
  ( defaultSettings
  , runSettingsSocket
  , setBeforeMainLoop
  , setTimeout
  )
import Network.Wai.Handler.WebSockets (websocketsOr)
import Network.WebSockets
  ( PendingConnection
  , acceptRequest
  , defaultConnectionOptions
  , sendClose
  , sendTextData
  , withPingThread
  )
import Servant
import System.IO (hFlush, stdout)

-- ---------------------------------------------------------------------------
-- API type
-- ---------------------------------------------------------------------------

type MonitorAPI =
       "api" :> "health"   :> Get '[JSON] HealthInfo
  :<|> "api" :> "servers"  :> Get '[JSON] [ServerState]
  :<|> "api" :> "servers"  :> Capture "id" Text :> "containers" :> Get '[JSON] [Container]
  :<|> "api" :> "servers"  :> Capture "id" Text :> "services"   :> Get '[JSON] [Service]
  :<|> "api" :> "servers"  :> Capture "id" Text :> "fail2ban"   :> Get '[JSON] [Fail2banJail]
  :<|> "api" :> "servers"  :> Capture "id" Text :> "backup"     :> Get '[JSON] (Maybe BackupInfo)
  :<|> "api" :> "history"  :> QueryParam "server" Text :> QueryParam "hours" Int :> Get '[JSON] [Metrics]
  :<|> "api" :> "caddy"    :> QueryParam "server" Text :> QueryParam "hours" Int :> Get '[JSON] [CaddySample]
  :<|> "api" :> "events"   :> QueryParam "limit" Int :> Get '[JSON] [EventRow]
  :<|> "ws" :> Raw

-- | Response body for @GET /api/health@.
data HealthInfo = HealthInfo
  { hiStatus  :: Text
  , hiServers :: Int
  , hiOnline  :: Int
  }
  deriving (Show)

instance ToJSON HealthInfo where
  toJSON h = object
    [ "status" .= hiStatus h
    , "servers" .= hiServers h
    , "online" .= hiOnline h
    ]

-- ---------------------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------------------

apiServer :: AppState -> Server MonitorAPI
apiServer st =
  healthH :<|> serversH :<|> containersH :<|> servicesH :<|> fail2banH
    :<|> backupH :<|> historyH :<|> caddyH :<|> eventsH :<|> wsRawH
  where
    healthH :: Handler HealthInfo
    healthH = do
      states <- liftIO (readTVarIO (serverStates st))
      let servers = Map.size states
          online = length (filter ((== Online) . ssStatus) (Map.elems states))
      pure HealthInfo { hiStatus = "ok", hiServers = servers, hiOnline = online }

    serversH :: Handler [ServerState]
    serversH = liftIO (Map.elems <$> readTVarIO (serverStates st))

    getState :: Text -> Handler ServerState
    getState sid = do
      states <- liftIO (readTVarIO (serverStates st))
      case Map.lookup (ServerId sid) states of
        Just s -> pure s
        Nothing -> throwError err404 { errBody = "unknown server" }

    containersH :: Text -> Handler [Container]
    containersH sid = ssContainers <$> getState sid

    servicesH :: Text -> Handler [Service]
    servicesH sid = ssServices <$> getState sid

    fail2banH :: Text -> Handler [Fail2banJail]
    fail2banH sid = ssFail2ban <$> getState sid

    backupH :: Text -> Handler (Maybe BackupInfo)
    backupH sid = ssBackup <$> getState sid

    historyH :: Maybe Text -> Maybe Int -> Handler [Metrics]
    historyH mSid mHours =
      let sid = fromMaybe "" mSid
          hours = fromMaybe 24 mHours
      in liftIO (loadHistory (dbPath st) (ServerId sid) hours)

    caddyH :: Maybe Text -> Maybe Int -> Handler [CaddySample]
    caddyH mSid mHours =
      let sid = fromMaybe "" mSid
          hours = fromMaybe 24 mHours
      in liftIO (loadCaddyStats (dbPath st) (ServerId sid) hours)

    eventsH :: Maybe Int -> Handler [EventRow]
    eventsH mLimit = liftIO (loadRecentEvents (dbPath st) (fromMaybe 50 mLimit))

    wsRawH :: Tagged Handler Application
    wsRawH = Tagged (websocketsOr defaultConnectionOptions (wsHandler st) notFoundWs)

-- | WebSocket handler: subscribes, sends the current snapshot, then streams
-- events. A ping thread reaps dead connections instead of leaking them.
wsHandler :: AppState -> PendingConnection -> IO ()
wsHandler st pending = do
  conn <- acceptRequest pending
  chan <- atomically (cloneTChan (events st))
  states <- readTVarIO (serverStates st)
  let snapshot = object
        [ "type" .= ("snapshot" :: Text)
        , "servers" .= Map.elems states
        ]
  finally
    ( withPingThread conn 30 (pure ()) $ do
        sendTextData conn (Aeson.encode snapshot)
        forever $ do
          ev <- atomically (readTChan chan)
          sendTextData conn (Aeson.encode ev)
    )
    (void (try (sendClose conn ("bye" :: BC.ByteString)) :: IO (Either SomeException ())))

notFoundWs :: Application
notFoundWs _ respond = respond (responseLBS status404 [] "websocket upgrade required")

-- | WAI application combining the Servant API with the WS raw endpoint.
app :: AppState -> Application
app st = serve api (apiServer st)
  where
    api :: Proxy MonitorAPI
    api = Proxy

-- ---------------------------------------------------------------------------
-- CORS middleware (local development / Tauri webview)
-- ---------------------------------------------------------------------------

-- | Origins allowed to read the local read-only API. Everything else gets
-- no CORS headers (or a 403 on preflight). The API is bound to loopback
-- and token-protected, so this only exists to make the Vite dev server and
-- the packaged Tauri webview work; it never widens the trust boundary.
allowedOrigins :: [BC.ByteString]
allowedOrigins =
  [ "http://localhost:5173"     -- Vite dev server (browser + tauri dev)
  , "http://127.0.0.1:5173"
  , "http://localhost:1420"     -- tauri default dev port
  , "http://tauri.localhost"    -- Tauri 2 on Windows
  , "https://tauri.localhost"
  , "tauri://localhost"         -- Tauri 2 on macOS / Linux
  ]

originOf :: Request -> Maybe BC.ByteString
originOf req = lookup "origin" (requestHeaders req)

-- | CORS for the local read-only API.
--   * OPTIONS (preflight): answered directly, no auth required;
--   * other requests: allowed origins get the response headers attached.
corsMiddleware :: Application -> Application
corsMiddleware inner req respond =
  case requestMethod req of
    "OPTIONS" ->
      case originOf req of
        Just o | o `elem` allowedOrigins ->
          respond (responseLBS status204
            [ ("Access-Control-Allow-Origin", o)
            , ("Access-Control-Allow-Methods", "GET, OPTIONS")
            , ("Access-Control-Allow-Headers", "Authorization, Content-Type")
            , ("Access-Control-Max-Age", "86400")
            , ("Vary", "Origin")
            ] "")
        _ -> respond (responseLBS status403 [] "origin not allowed")
    _ ->
      inner req (respond . mapResponseHeaders (\hs -> corsResponseHeaders req ++ hs))
  where
    corsResponseHeaders req' = case originOf req' of
      Just o | o `elem` allowedOrigins ->
        [ ("Access-Control-Allow-Origin", o), ("Vary", "Origin") ]
      _ -> []

-- ---------------------------------------------------------------------------
-- Token auth middleware
-- ---------------------------------------------------------------------------

-- | Rejects requests without a matching @Authorization: Bearer <token>@.
-- The WebSocket endpoint is exempt: browsers cannot set WS headers, and the
-- stream only carries read-only metrics.
authMiddleware :: Text -> Application -> Application
authMiddleware token inner req respond =
  case pathInfo req of
    ("ws" : _) -> inner req respond
    _ ->
      case lookup "authorization" (requestHeaders req) of
        Just hdr | BC.unpack hdr == ("Bearer " <> T.unpack token) -> inner req respond
        _ -> respond (responseLBS status401 [] "unauthorized")

-- ---------------------------------------------------------------------------
-- Server bootstrap (bind 127.0.0.1:0, print READY port token)
-- ---------------------------------------------------------------------------

-- | Bind an ephemeral localhost port and serve until killed.
-- Prints @READY <port> <token>@ to stdout so the Tauri shell can discover it.
runBackend :: AppState -> Text -> IO ()
runBackend st token = do
  sock <- socket AF_INET Stream defaultProtocol
  setSocketOption sock ReuseAddr 1
  bind sock (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
  listen sock 512
  port <- socketPort sock
  putStrLn ("READY " <> show port <> " " <> T.unpack token)
  hFlush stdout
  let settings = setBeforeMainLoop (pure ()) (setTimeout 30 defaultSettings)
      handlers = corsMiddleware (authMiddleware token (app st))
  runSettingsSocket settings sock handlers
  close sock
