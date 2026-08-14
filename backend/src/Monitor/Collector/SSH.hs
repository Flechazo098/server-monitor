{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Read-only remote collection over SSH.
--
-- We shell out to the system OpenSSH client (already provisioned on the
-- local machine, key + known_hosts verified). Every command is a fixed
-- literal string; the API never accepts arbitrary commands. Each remote
-- script is a batch of guarded sections: a failing section emits
-- @ERR:...@ and is reported as data, never as transport failure. The
-- script always ends with @true@, so the SSH exit status reflects the
-- transport (auth / connectivity) only.
module Monitor.Collector.SSH
  ( CollectorError (..)
  , runRemote
  , fullScript
  , metricsScript
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, race, wait)
import Control.Exception (Exception, SomeException, throwIO, try)
import Control.Monad (void)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Text.Encoding.Error (lenientDecode)
import Monitor.Core.Types
import System.Exit (ExitCode (..))
import System.Process
  ( CreateProcess (..)
  , StdStream (..)
  , createProcess
  , proc
  , terminateProcess
  , waitForProcess
  )

-- | Transport-level failure: ssh exit status or timeout.
newtype CollectorError = CollectorError Text
  deriving (Show)

instance Exception CollectorError

-- | Run a fixed remote command over SSH. Returns stdout on success;
-- throws 'CollectorError' on transport failure or timeout.
--
-- Implementation notes:
--   * stdout/stderr are read STRICTLY (Data.ByteString) before waiting for
--     the process. Lazy reads here deadlock once the pipe buffer fills:
--     ssh blocks writing, can never exit, and 'waitForProcess' never
--     returns.
--   * the wall-clock timeout runs on a separate 'race' thread and kills
--     the local ssh process, so it works even when the process wait is
--     not interruptible.
runRemote :: ServerConfig -> Int -> Text -> IO Text
runRemote cfg timeoutSec cmd = do
  let userHost = scSshUser cfg <> "@" <> scSshHost cfg
      args =
        [ "-i", T.pack (scSshKey cfg)
        , "-o", "BatchMode=yes"
        , "-o", "ConnectTimeout=10"
        , "-o", "StrictHostKeyChecking=accept-new"
        , "-o", "ServerAliveInterval=10"
        , "-o", "ServerAliveCountMax=3"
        , "-o", "NumberOfPasswordPrompts=0"
        , "-p", T.pack (show (scSshPort cfg))
        , userHost
        , cmd
        ]
  (_, Just outH, Just errH, ph) <-
    createProcess (proc "ssh" (map T.unpack args))
      { std_in = NoStream
      , std_out = CreatePipe
      , std_err = CreatePipe
      }
  let finish = do
        out <- BS.hGetContents outH
        err <- BS.hGetContents errH
        code <- waitForProcess ph
        pure ( code
             , TE.decodeUtf8With lenientDecode out
             , TE.decodeUtf8With lenientDecode err
             )
  a <- async finish
  r <- race (threadDelay (timeoutSec * 1000000)) (wait a)
  case r of
    Right (ExitSuccess, out, _) -> pure out
    Right (ExitFailure n, out, err) ->
      let detail = T.strip (err <> " " <> out)
          bounded = T.take 300 detail
      in throwIO (CollectorError (bounded <> " (exit " <> T.pack (show n) <> ")"))
    Left () -> do
      -- Timeout: kill the local ssh so the remote session and pipes are
      -- released, then reap everything we abandoned.
      terminateProcess ph
      void (try (waitForProcess ph) :: IO (Either SomeException ExitCode))
      void (try (wait a) :: IO (Either SomeException (ExitCode, Text, Text)))
      throwIO (CollectorError ("ssh timed out after " <> T.pack (show timeoutSec) <> "s"))

-- | A named section of a remote batch script.
sec :: Text -> Text -> Text
sec name body = "echo '===" <> name <> "==='\n" <> body

-- | Wrap a shell pipeline so failures degrade to a visible error line.
guarded :: Text -> Text -> Text
guarded errMsg body = "{ " <> body <> "; } 2>/dev/null || echo 'ERR:" <> errMsg <> "'"

-- | Full batch script: every read-only section, each independently guarded.
fullScript :: ServerConfig -> Text
fullScript cfg = wrapRemoteTimeout (T.unlines
  [ "export LANG=C LC_ALL=C"
  , sec "CPU" (guarded "top failed"
      "top -bn2 | grep 'Cpu(s)' | tail -1 | awk '{printf \"%.1f\\n\", $2+$4}'")
  , sec "MEM" (guarded "free failed"
      "free -m | awk '/Mem:/{printf \"%.1f\\n\", $3*100/$2}'")
  , sec "LOAD" (guarded "uptime failed"
      "uptime | sed 's/.*load average: //'")
  , sec "UPTIME" (guarded "procfs missing"
      "awk '{printf \"%d\\n\", $1}' /proc/uptime")
  , sec "DISK" (guarded "df failed"
      "df -hP / | tail -n1 | awk '{gsub(/%/,\"\"); print $5}'")
  , sec "DISKMOUNTS" (guarded "df mounts failed"
      "df -hP -t ext4 -t xfs -t btrfs -t zfs -t f2fs -t vfat 2>/dev/null | tail -n +2 | awk '{print $1\"|\"$2\"|\"$3\"|\"$4\"|\"$5\"|\"$6}'")
  , sec "NETDEV" (guarded "procfs missing"
      "awk 'NR>2 {gsub(/:/,\"\",$1); print $1\"|\"$2\"|\"$10}' /proc/net/dev")
  , sec "VNSTATD" (guarded "vnstat unavailable"
      "vnstat -d 2>/dev/null | tail -n 40")
  , sec "VNSTATM" (guarded "vnstat unavailable"
      "vnstat -m 2>/dev/null | tail -n 6")
  , sec "TLS" (tlsProbe (certHostsOf cfg))
  , sec "FINGERPRINTS" (guarded "host keys unreadable"
      "for f in /etc/ssh/ssh_host_*.pub; do ssh-keygen -lf \"$f\" 2>/dev/null; done")
  , sec "PORTS" (guarded "ss failed"
      "sudo -n ss -tulnpH 2>/dev/null || ss -tulnH 2>/dev/null")
  , sec "SSHAUTH" (guarded "journalctl unavailable"
      "sudo -n journalctl -u ssh -u sshd --since '24 hours ago' --no-pager -o short 2>/dev/null | grep -E 'Accepted |Failed ' | tail -n 40")
  , sec "FIREWALL" firewallProbe
  , sec "DOCKERDF" (guarded "docker unavailable"
      "sudo -n docker system df 2>/dev/null || docker system df 2>/dev/null")
  , sec "APT" (guarded "apt unavailable"
      "apt list --upgradable 2>/dev/null | grep -v '^Listing' | grep -c .; apt list --upgradable 2>/dev/null | grep -v '^Listing' | head -n 10 | awk -F/ '{print $1}' | tr '\\n' ' '; echo")
  , sec "M3U8" m3u8Probe
  , sec "GITEA" giteaProbe
  , sec "CADDY" caddyProbe
  , sec "BACKUP" backupProbe
  , sec "SERVICES" (guarded "systemctl unavailable"
      "for s in docker caddy fail2ban vnstat; do echo -n \"$s:\"; systemctl is-active $s 2>/dev/null; done")
  , sec "CONTAINERS" (guarded "docker ps failed"
      "sudo -n docker ps --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null || docker ps --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null")
  , sec "STATS" (guarded "docker stats failed"
      "sudo -n docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemPerc}}' 2>/dev/null")
  , sec "F2B" f2bProbe
  , sec "HEALTH" (healthProbe (scPublicUrls cfg))
  , "true"
  ])

-- | Lighter script for high-frequency ticks (rates + core metrics only).
metricsScript :: Text
metricsScript = wrapRemoteTimeout (T.unlines
  [ "export LANG=C LC_ALL=C"
  , sec "CPU" (guarded "top failed"
      "top -bn2 | grep 'Cpu(s)' | tail -1 | awk '{printf \"%.1f\\n\", $2+$4}'")
  , sec "MEM" (guarded "free failed"
      "free -m | awk '/Mem:/{printf \"%.1f\\n\", $3*100/$2}'")
  , sec "LOAD" (guarded "uptime failed"
      "uptime | sed 's/.*load average: //'")
  , sec "UPTIME" (guarded "procfs missing"
      "awk '{printf \"%d\\n\", $1}' /proc/uptime")
  , sec "DISK" (guarded "df failed"
      "df -hP / | tail -n1 | awk '{gsub(/%/,\"\"); print $5}'")
  , sec "NETDEV" (guarded "procfs missing"
      "awk 'NR>2 {gsub(/:/,\"\",$1); print $1\"|\"$2\"|\"$10}' /proc/net/dev")
  , sec "VNSTATD" (guarded "vnstat unavailable"
      "vnstat -d 2>/dev/null | tail -n 40")
  , sec "CADDY" (guarded "caddy log missing"
      "sudo -n stat -c '%s|%Y' /var/log/caddy/access.json 2>/dev/null || stat -c '%s|%Y' /var/log/caddy/access.json 2>/dev/null")
  , "true"
  ])

-- | Wrap the whole remote batch in a remote @timeout@ via a quoted
-- heredoc: a command that hangs cannot wedge the SSH session open, and
-- the output collected up to the hang is still delivered.
wrapRemoteTimeout :: Text -> Text
wrapRemoteTimeout body = T.unlines
  [ "exec timeout --kill-after=10 90 /bin/bash <<'EOS'"
  , body
  , "EOS"
  ]

-- | TLS probes for every configured certificate host. Each host reports
-- its own result; a failed probe degrades that host only.
tlsProbe :: [Text] -> Text
tlsProbe hosts = T.unlines
  ( "for h in " <> T.unwords hosts
  : [ "do echo \"HOST:$h\"; { echo | timeout 8 openssl s_client -connect \"$h\":443 -servername \"$h\" 2>/dev/null | openssl x509 -noout -subject -issuer -enddate -fingerprint -sha256 2>/dev/null; } || echo 'ERR:probe failed'; done"
    ])

firewallProbe :: Text
firewallProbe = T.unlines
  [ "echo '--UFW--'"
  , "{ sudo -n ufw status verbose 2>/dev/null || ufw status verbose 2>/dev/null; } || echo 'ERR:ufw unavailable'"
  , "echo '--IPTABLES--'"
  , "{ sudo -n iptables -L INPUT -v -n --line-numbers 2>/dev/null; } || echo 'ERR:iptables unavailable'"
  , "echo '--UFWREJECT--'"
  , "{ sudo -n iptables -L ufw-reject-input -v -n --line-numbers 2>/dev/null; } || echo 'ERR:reject chain unavailable'"
  ]

m3u8Probe :: Text
m3u8Probe = T.unlines
  [ "{ curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8081/health; echo; } || echo 'ERR:health probe failed'"
  , "{ sudo -n docker exec m3u8-downloader-app-1 python3 -c 'import sqlite3,json;c=sqlite3.connect(\"file:/data/jobs.db?mode=ro\",uri=True);d={s:n for s,n in c.execute(\"SELECT status,COUNT(*) FROM jobs GROUP BY status\")};r=[{\"t\":x[0][:80],\"s\":x[1],\"p\":x[2],\"n\":x[3],\"u\":x[4]} for x in c.execute(\"SELECT title,status,progress,total,updated_at FROM jobs ORDER BY updated_at DESC LIMIT 8\")];print(json.dumps({\"counts\":d,\"recent\":r},ensure_ascii=False))' 2>/dev/null; } || echo 'ERR:jobs db unavailable'"
  ]

giteaProbe :: Text
giteaProbe = T.unlines
  [ "{ curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:3000/api/healthz || curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:3000/api/v1/healthz; echo; } || echo 'ERR:gitea health probe failed'"
  , "{ sudo -n docker exec gitea-db-1 psql -U gitea -d gitea -tA -F\\| -c 'SELECT (SELECT count(*) FROM repository)||chr(124)||(SELECT count(*) FROM \"user\")||chr(124)||(SELECT count(*) FROM repository WHERE updated_unix > (extract(epoch from now())-604800))||chr(124)||COALESCE((SELECT max(updated_unix) FROM repository),0)' 2>/dev/null; } || echo 'ERR:gitea db query failed'"
  ]

caddyProbe :: Text
caddyProbe = T.unlines
  [ "{ sudo -n stat -c '%s|%Y' /var/log/caddy/access.json 2>/dev/null || stat -c '%s|%Y' /var/log/caddy/access.json 2>/dev/null; } || echo 'ERR:caddy log missing'"
  , "{ timeout 15 sudo -n wc -l /var/log/caddy/access.json 2>/dev/null | awk '{print $1}'; } || echo 'ERR:line count failed'"
  ]

backupProbe :: Text
backupProbe = T.unlines
  [ "{ ls /var/backups/server-stack/ 2>/dev/null | wc -l; } || echo 'ERR:backup dir missing'"
  , "{ stat -c '%Y' \"/var/backups/server-stack/$(ls -1t /var/backups/server-stack/ 2>/dev/null | head -n1)\" 2>/dev/null; } || echo 'ERR:no newest backup'"
  , "{ systemctl show server-stack-backup.timer -p NextElapseUSecRealtime -p LastTriggerUSec --no-pager 2>/dev/null; } || echo 'ERR:timer unavailable'"
  , "{ systemctl is-failed server-stack-backup.service 2>/dev/null || echo inactive; }"
  ]

f2bProbe :: Text
f2bProbe = T.unlines
  [ "{ sudo -n fail2ban-client status 2>/dev/null; } || echo 'ERR:fail2ban unavailable'"
  , "for j in $(sudo -n fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' '); do echo \"== $j ==\"; sudo -n fail2ban-client status $j 2>/dev/null | grep -E 'Currently banned|Total banned'; done"
  ]

healthProbe :: [Text] -> Text
healthProbe [] = "echo 'ERR:no public urls configured'"
healthProbe urls = T.unlines
  [ "{ " <> T.unwords
      [ "for u in"
      , T.unwords urls
      , "; do curl -s -o /dev/null -w \"$u %{http_code} %{time_total}\" --max-time 8 \"$u\"; echo; done"
      ] <> "; } || echo 'ERR:health probe failed'"
  ]
