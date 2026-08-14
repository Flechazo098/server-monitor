// TypeScript mirrors of the Haskell backend JSON payloads.
// Keep field names in sync with Monitor.Core.Types.

export type ServerStatus = 'online' | 'offline'
export type Severity = 'info' | 'warning' | 'critical'

export interface Metrics {
  cpu: number
  mem: number
  load1: number
  load5: number
  load15: number
  uptimeSec: number
  disk: number
  rxBytes: number
  txBytes: number
  rxRate: number
  txRate: number
  timestamp: string
}

export interface Container {
  name: string
  image: string
  status: string
  cpuPct: number | null
  memPct: number | null
}

export interface Service {
  name: string
  active: boolean
}

export interface Fail2banJail {
  name: string
  banned: number
  total: number
}

export interface BackupInfo {
  lastRun: string | null
  nextRun: string | null
  count: number
  latest: string | null
  newestEpoch: number | null
  failed: boolean | null
}

export interface HealthCheck {
  url: string
  ok: boolean
  latencyMs: number
  status: string
}

export interface DiskMount {
  fs: string
  size: string
  used: string
  avail: string
  pct: number
  mount: string
}

export interface DockerRow {
  count: number
  size: string
}

export interface DockerUsage {
  images: DockerRow
  containers: DockerRow
  volumes: DockerRow
  buildCache: DockerRow
}

export interface AptUpgrades {
  count: number
  packages: string[]
}

export interface TlsCert {
  host: string
  subject: string
  issuer: string
  notAfter: string
  daysLeft: number
  fingerprint: string
}

export interface TcpPort {
  port: number
  proto: string
  local: string
  process: string | null
  exposed: boolean
}

export interface SshLogin {
  time: string
  ok: boolean
  user: string
  from: string
}

export interface UfwRule {
  to: string
  action: string
  from: string
}

export interface IptablesRule {
  pkts: number
  bytes: number
  target: string
  proto: string
  source: string
  dest: string
}

export interface Firewall {
  active: boolean
  rules: UfwRule[]
  iptables: IptablesRule[]
}

export interface VnstatDay {
  date: string
  rx: number
  tx: number
}

export interface NetIface {
  name: string
  rx: number
  tx: number
}

export interface Fingerprint {
  file: string
  algo: string
  hash: string
}

export interface M3u8Job {
  title: string
  status: string
  progress: number
  total: number
  updated: string
}

export interface M3u8Queue {
  health: string | null
  counts: Record<string, number>
  recent: M3u8Job[]
}

export interface GiteaInfo {
  health: string | null
  repos: number | null
  users: number | null
  activeWeek: number | null
  lastPush: number | null
}

export interface CaddyLogs {
  sizeBytes: number
  lines: number | null
  mtime: string
  growthBps: number
}

export interface Alert {
  key: string
  severity: Severity
  message: string
  since: string
}

export interface AlertPayload extends Alert {
  state: 'fired' | 'resolved'
}

export interface ServerState {
  id: string
  name: string
  status: ServerStatus
  metrics: Metrics | null
  containers: Container[]
  services: Service[]
  fail2ban: Fail2banJail[]
  backup: BackupInfo | null
  health: HealthCheck[]
  disks: DiskMount[]
  dockerUsage: DockerUsage | null
  apt: AptUpgrades | null
  tlsCerts: TlsCert[]
  ports: TcpPort[]
  sshLogins: SshLogin[]
  firewall: Firewall | null
  vnstatDays: VnstatDay[]
  netIfaces: NetIface[]
  fingerprints: Fingerprint[]
  m3u8: M3u8Queue | null
  gitea: GiteaInfo | null
  caddy: CaddyLogs | null
  alerts: Alert[]
  sectionErrors: Record<string, string>
  lastError: string | null
  updatedAt: string
}

export interface HealthInfo {
  status: string
  servers: number
  online: number
}

export interface EventRow {
  ts: string
  server: string
  type: string
  severity: Severity
  state: string
  message: string
}

export interface CaddySample {
  ts: string
  size: number
  lines: number | null
}

export type WsMessage =
  | { type: 'snapshot'; servers: ServerState[] }
  | { type: 'metrics'; server: string; data: Metrics }
  | { type: 'status'; server: string; data: ServerStatus }
  | { type: 'alert'; server: string; data: AlertPayload }
