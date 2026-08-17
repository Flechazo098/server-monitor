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
import Control.Concurrent.Async (async, race, wait, waitCatch)
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
runRemote cfg timeoutSec body = do
  let userHost = scSshUser cfg <> "@" <> scSshHost cfg
      cmd = wrapRemoteTimeout timeoutSec body
      args =
        [ "-i", T.pack (scSshKey cfg)
        , "-o", "BatchMode=yes"
        , "-o", "ConnectTimeout=10"
        , "-o", "StrictHostKeyChecking=yes"
        , "-o", "ServerAliveInterval=10"
        , "-o", "ServerAliveCountMax=3"
        , "-o", "NumberOfPasswordPrompts=0"
        , "-p", T.pack (show (scSshPort cfg))
        , userHost
        , cmd
        ]
  spawned <- try $ createProcess (proc "ssh" (map T.unpack args))
    { std_in = NoStream
    , std_out = CreatePipe
    , std_err = CreatePipe
    }
  (_, outH, errH, ph) <- case spawned of
    Left (_ :: SomeException) -> throwIO (CollectorError "unable to start the local SSH client")
    Right handles -> pure handles
  outA <- async (maybe (pure BS.empty) BS.hGetContents outH)
  errA <- async (maybe (pure BS.empty) BS.hGetContents errH)
  waitA <- async (waitForProcess ph)
  r <- race (threadDelay ((max 1 timeoutSec + 15) * 1000000)) (wait waitA)
  case r of
    Right code -> do
      outResult <- waitCatch outA
      errResult <- waitCatch errA
      case (code, outResult, errResult) of
        (ExitSuccess, Right out, Right _) -> pure (decode out)
        (ExitFailure n, Right out, Right err) ->
          throwIO (CollectorError (classifyFailure n (decode err <> " " <> decode out)))
        _ -> throwIO (CollectorError "failed while reading SSH output")
    Left () -> do
      terminateProcess ph
      void (waitCatch waitA)
      void (waitCatch outA)
      void (waitCatch errA)
      throwIO (CollectorError ("ssh timed out after " <> T.pack (show timeoutSec) <> "s"))
  where
    decode = TE.decodeUtf8With lenientDecode

    classifyFailure n raw =
      let lower = T.toLower raw
          reason
            | "permission denied" `T.isInfixOf` lower = "authentication rejected"
            | "host key verification failed" `T.isInfixOf` lower = "host key verification failed"
            | "connection timed out" `T.isInfixOf` lower = "connection timed out"
            | "connection refused" `T.isInfixOf` lower = "connection refused"
            | "no route to host" `T.isInfixOf` lower = "no route to host"
            | "could not resolve hostname" `T.isInfixOf` lower = "host resolution failed"
            | otherwise = "SSH transport failed"
      in reason <> " (exit " <> T.pack (show n) <> ")"

-- | A named section of a remote batch script.
sec :: Text -> Text -> Text
sec name body = "echo '===" <> name <> "==='\n" <> body

-- | Wrap a shell pipeline so failures degrade to a visible error line.
guarded :: Text -> Text -> Text
guarded errMsg body =
  "{\n" <> T.stripEnd body <> "\n} 2>/dev/null || echo 'ERR:" <> errMsg <> "'"

-- | Full batch script: every read-only section, each independently guarded.
fullScript :: ServerConfig -> Text
fullScript cfg = T.unlines
  [ "export LANG=C LC_ALL=C"
  , "set -o pipefail"
  , sec "CPU" (guarded "procfs cpu counters unavailable" cpuProbe)
  , sec "MEM" (guarded "procfs memory counters unavailable" memProbe)
  , sec "LOAD" (guarded "uptime failed"
      "uptime | sed 's/.*load average: //'")
  , sec "UPTIME" (guarded "procfs missing"
      "awk '{printf \"%d\\n\", $1}' /proc/uptime")
  , sec "DISK" (guarded "df failed"
      "df -hP / | tail -n1 | awk '{gsub(/%/,\"\"); print $5}'")
  , sec "DISKMOUNTS" (guarded "df mounts failed"
      "df -hPT -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | tail -n +2 | awk '{p=$6; gsub(/%/,\"\",p); print $1\"|\"$2\"|\"$3\"|\"$4\"|\"$5\"|\"p\"|\"$7}'")
  , sec "NETDEV" (guarded "procfs missing"
      "awk 'NR>2 {gsub(/:/,\"\",$1); print $1\"|\"$2\"|\"$10}' /proc/net/dev")
  , sec "VNSTATD" (guarded "vnstat unavailable"
      "vnstat -d 2>/dev/null | tail -n 40")
  , sec "VNSTATM" (guarded "vnstat unavailable"
      "vnstat -m 2>/dev/null | tail -n 6")
  , sec "TLS" (tlsProbe (certHostsOf cfg))
  , sec "FINGERPRINTS" (guarded "host keys unreadable"
      "for f in /etc/ssh/ssh_host_*.pub; do printf '%s|' \"$f\"; ssh-keygen -lf \"$f\" 2>/dev/null | awk '{print $2\"|\"$NF}'; done")
  , sec "PORTS" (guarded "ss failed"
      "timeout 10 sudo -n ss -tulnpH 2>/dev/null || timeout 10 ss -tulnH 2>/dev/null")
  , sec "SSHAUTH" (guarded "journalctl unavailable"
      "timeout 15 sudo -n journalctl -u ssh -u sshd --since '24 hours ago' --no-pager -o short 2>/dev/null | awk '/Accepted |Failed /' | tail -n 40")
  , sec "FIREWALL" firewallProbe
  , sec "DOCKERDF" (guarded "docker unavailable"
      "timeout 20 sudo -n docker system df 2>/dev/null || timeout 20 docker system df 2>/dev/null")
  , sec "APT" (guarded "apt unavailable"
      "timeout 30 apt list --upgradable 2>/dev/null | awk -F/ 'NR>1 {n++; if(n<=10) names=names $1 \"\\n\"} END {print n+0; printf \"%s\", names}'")
  , sec "M3U8" m3u8Probe
  , sec "GITEA" giteaProbe
  , sec "CADDY" caddyProbe
  , sec "BACKUP" backupProbe
  , sec "SERVICES" (guarded "systemctl unavailable"
      "for s in docker caddy fail2ban vnstat; do echo -n \"$s:\"; systemctl is-active $s 2>/dev/null; done")
  , sec "CONTAINERS" (guarded "docker ps failed"
      "timeout 15 sudo -n docker ps --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null || timeout 15 docker ps --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null")
  , sec "STATS" (guarded "docker stats failed"
      "timeout 20 sudo -n docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemPerc}}' 2>/dev/null")
  , sec "F2B" f2bProbe
  , sec "HEALTH" (healthProbe (scPublicUrls cfg))
  , "true"
  ]

-- | Lighter script for high-frequency ticks (rates + core metrics only).
metricsScript :: ServerConfig -> Text
metricsScript cfg = T.unlines
  [ "export LANG=C LC_ALL=C"
  , "set -o pipefail"
  , sec "CPU" (guarded "procfs cpu counters unavailable" cpuProbe)
  , sec "MEM" (guarded "procfs memory counters unavailable" memProbe)
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
      "timeout 10 sudo -n stat -c '%s|%Y' /var/log/caddy/access.json 2>/dev/null || timeout 10 stat -c '%s|%Y' /var/log/caddy/access.json 2>/dev/null")
  , sec "HEALTH" (healthProbe (scPublicUrls cfg))
  , "true"
  ]

-- | Wrap the whole remote batch in a remote @timeout@ via a quoted
-- heredoc: a command that hangs cannot wedge the SSH session open, and
-- the output collected up to the hang is still delivered.
wrapRemoteTimeout :: Int -> Text -> Text
wrapRemoteTimeout timeoutSec body = T.unlines
  [ "exec timeout --kill-after=10 " <> T.pack (show (max 1 timeoutSec)) <> " /bin/bash <<'EOS'"
  , body
  , "EOS"
  ]

cpuProbe :: Text
cpuProbe = T.unlines
  [ "read -r _ u1 n1 s1 i1 w1 q1 sq1 st1 _ < /proc/stat"
  , "sleep 1"
  , "read -r _ u2 n2 s2 i2 w2 q2 sq2 st2 _ < /proc/stat"
  , "du=$((u2+n2-u1-n1)); ds=$((s2+q2+sq2-s1-q1-sq1)); dw=$((w2-w1)); dst=$((st2-st1))"
  , "dt=$((u2+n2+s2+i2+w2+q2+sq2+st2-u1-n1-s1-i1-w1-q1-sq1-st1))"
  , "awk -v dt=\"$dt\" -v u=\"$du\" -v s=\"$ds\" -v w=\"$dw\" -v st=\"$dst\" 'BEGIN {if(dt<=0) exit 1; printf \"%.1f|%.1f|%.1f|%.1f\\n\",100*(u+s+st)/dt,100*u/dt,100*(s+st)/dt,100*w/dt}'"
  ]

memProbe :: Text
memProbe =
  "awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}/^Buffers:/{b=$2}/^Cached:/{c=$2}/^SReclaimable:/{r=$2}/^Shmem:/{sh=$2}/^SwapTotal:/{st=$2}/^SwapFree:/{sf=$2} END {if(t<=0) exit 1; cache=c+r-sh; if(cache<0) cache=0; printf \"%.1f|%.0f|%.0f|%.0f|%.0f|%.0f\\n\",(t-a)*100/t,a*1024,cache*1024,b*1024,(st-sf)*1024,st*1024}' /proc/meminfo"

-- | TLS probes for every configured certificate host. Each host reports
-- its own result; a failed probe degrades that host only.
tlsProbe :: [Text] -> Text
tlsProbe hosts = T.unlines
  ( "for h in " <> T.unwords (map shellQuote hosts)
  : [ "do echo \"HOST:$h\"; { echo | timeout 8 openssl s_client -connect \"$h\":443 -servername \"$h\" 2>/dev/null | openssl x509 -noout -subject -issuer -enddate -fingerprint -sha256 2>/dev/null; } || echo 'ERR:probe failed'; done"
    ])

firewallProbe :: Text
firewallProbe = T.unlines
  [ "echo '--UFW--'"
  , "{ timeout 10 sudo -n ufw status verbose 2>/dev/null || timeout 10 ufw status verbose 2>/dev/null; } || echo 'ERR:ufw unavailable'"
  , "echo '--IPTABLES--'"
  , "{ timeout 10 sudo -n iptables -L INPUT -v -n --line-numbers 2>/dev/null; } || echo 'ERR:iptables unavailable'"
  , "echo '--UFWREJECT--'"
  , "{ timeout 10 sudo -n iptables -L ufw-reject-input -v -n --line-numbers 2>/dev/null; } || echo 'ERR:reject chain unavailable'"
  ]

m3u8Probe :: Text
m3u8Probe = T.unlines
  [ "{ curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8081/health; echo; } || echo 'ERR:health probe failed'"
  , "{ timeout 15 sudo -n docker exec m3u8-downloader-app-1 python3 -c 'import sqlite3,json;c=sqlite3.connect(\"file:/data/jobs.db?mode=ro\",uri=True);d={s:n for s,n in c.execute(\"SELECT status,COUNT(*) FROM jobs GROUP BY status\")};r=[{\"t\":x[0][:80],\"s\":x[1],\"p\":x[2],\"n\":x[3],\"u\":x[4]} for x in c.execute(\"SELECT title,status,progress,total,updated_at FROM jobs ORDER BY updated_at DESC LIMIT 8\")];print(json.dumps({\"counts\":d,\"recent\":r},ensure_ascii=False))' 2>/dev/null; } || echo 'ERR:jobs db unavailable'"
  ]

giteaProbe :: Text
giteaProbe = T.unlines
  [ "{ curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:3000/api/healthz || curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:3000/api/v1/healthz; echo; } || echo 'ERR:gitea health probe failed'"
  , "{ timeout 15 sudo -n docker exec gitea-db-1 psql -U gitea -d gitea -tA -F\\| -c 'SELECT (SELECT count(*) FROM repository)||chr(124)||(SELECT count(*) FROM \"user\")||chr(124)||(SELECT count(*) FROM repository WHERE updated_unix > (extract(epoch from now())-604800))||chr(124)||COALESCE((SELECT max(updated_unix) FROM repository),0)' 2>/dev/null; } || echo 'ERR:gitea db query failed'"
  ]

caddyProbe :: Text
caddyProbe =
  "{ timeout 10 sudo -n stat -c '%s|%Y' /var/log/caddy/access.json 2>/dev/null || timeout 10 stat -c '%s|%Y' /var/log/caddy/access.json 2>/dev/null; } || echo 'ERR:caddy log missing'"

backupProbe :: Text
backupProbe = T.unlines
  [ "printf 'count='; { find /var/backups/server-stack -mindepth 1 -maxdepth 1 -type f -printf '.' 2>/dev/null | wc -c; } || echo 0"
  , "printf 'newestEpoch='; { find /var/backups/server-stack -mindepth 1 -maxdepth 1 -type f -printf '%T@\\n' 2>/dev/null | sort -nr | head -n1 | cut -d. -f1; } || true; echo"
  , "systemctl show server-stack-backup.timer -p NextElapseUSecRealtime -p LastTriggerUSec --no-pager 2>/dev/null || echo 'ERR:timer unavailable'"
  , "printf 'serviceState='; systemctl is-failed server-stack-backup.service 2>/dev/null || echo inactive"
  ]

f2bProbe :: Text
f2bProbe = T.unlines
  [ "{ timeout 10 sudo -n fail2ban-client status 2>/dev/null; } || echo 'ERR:fail2ban unavailable'"
  , "for j in $(timeout 10 sudo -n fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' '); do echo \"== $j ==\"; timeout 10 sudo -n fail2ban-client status \"$j\" 2>/dev/null | grep -E 'Currently banned|Total banned|Banned IP list'; done"
  ]

healthProbe :: [Text] -> Text
healthProbe [] = "echo 'ERR:no public urls configured'"
healthProbe urls =
  "for u in " <> T.unwords (map shellQuote urls)
    <> "; do result=$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time 8 \"$u\" 2>/dev/null || true); set -- $result; echo \"$u ${1:-000} ${2:-0}\"; done"

shellQuote :: Text -> Text
shellQuote value = "'" <> T.replace "'" "'\"'\"'" value <> "'"
