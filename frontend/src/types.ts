import { z } from 'zod'

const finite = z.number().finite()
const integer = z.number().int().safe()
const nonNegativeInteger = integer.nonnegative()
const timestamp = z.string().min(1)

export const ServerStatusSchema = z.enum(['online', 'offline'])
export type ServerStatus = z.infer<typeof ServerStatusSchema>

export const SeveritySchema = z.enum(['info', 'warning', 'critical'])
export type Severity = z.infer<typeof SeveritySchema>

export const MetricsSchema = z.strictObject({
  cpu: finite,
  cpuUser: finite,
  cpuSystem: finite,
  cpuIowait: finite,
  mem: finite,
  memAvailableBytes: nonNegativeInteger,
  memCacheBytes: nonNegativeInteger,
  memBuffersBytes: nonNegativeInteger,
  swapUsedBytes: nonNegativeInteger,
  swapTotalBytes: nonNegativeInteger,
  load1: finite,
  load5: finite,
  load15: finite,
  uptimeSec: nonNegativeInteger,
  disk: finite,
  rxBytes: nonNegativeInteger,
  txBytes: nonNegativeInteger,
  rxRate: finite.nonnegative(),
  txRate: finite.nonnegative(),
  timestamp,
})
export type Metrics = z.infer<typeof MetricsSchema>

export const ContainerSchema = z.strictObject({
  name: z.string(),
  image: z.string(),
  status: z.string(),
  cpuPct: finite.nullable(),
  memPct: finite.nullable(),
})
export type Container = z.infer<typeof ContainerSchema>

export const ServiceSchema = z.strictObject({ name: z.string(), active: z.boolean() })
export type Service = z.infer<typeof ServiceSchema>

export const Fail2banJailSchema = z.strictObject({
  name: z.string(),
  banned: nonNegativeInteger,
  total: nonNegativeInteger,
  bannedIps: z.array(z.string()),
})
export type Fail2banJail = z.infer<typeof Fail2banJailSchema>

export const BackupInfoSchema = z.strictObject({
  lastRun: z.string().nullable(),
  nextRun: z.string().nullable(),
  count: nonNegativeInteger,
  latest: z.string().nullable(),
  newestEpoch: integer.nullable(),
  failed: z.boolean().nullable(),
})
export type BackupInfo = z.infer<typeof BackupInfoSchema>

export const HealthCheckSchema = z.strictObject({
  url: z.string(),
  ok: z.boolean(),
  latencyMs: nonNegativeInteger,
  status: z.string(),
})
export type HealthCheck = z.infer<typeof HealthCheckSchema>

export const DiskMountSchema = z.strictObject({
  fs: z.string(),
  type: z.string(),
  size: z.string(),
  used: z.string(),
  avail: z.string(),
  pct: finite,
  mount: z.string(),
})
export type DiskMount = z.infer<typeof DiskMountSchema>

export const DockerRowSchema = z.strictObject({ count: nonNegativeInteger, size: z.string() })
export type DockerRow = z.infer<typeof DockerRowSchema>

export const DockerUsageSchema = z.strictObject({
  images: DockerRowSchema,
  containers: DockerRowSchema,
  volumes: DockerRowSchema,
  buildCache: DockerRowSchema,
})
export type DockerUsage = z.infer<typeof DockerUsageSchema>

export const AptUpgradesSchema = z.strictObject({
  count: nonNegativeInteger,
  packages: z.array(z.string()),
})
export type AptUpgrades = z.infer<typeof AptUpgradesSchema>

export const TlsCertSchema = z.strictObject({
  host: z.string(),
  subject: z.string(),
  issuer: z.string(),
  notAfter: timestamp,
  daysLeft: integer,
  fingerprint: z.string(),
})
export type TlsCert = z.infer<typeof TlsCertSchema>

export const TcpPortSchema = z.strictObject({
  port: nonNegativeInteger,
  proto: z.string(),
  local: z.string(),
  process: z.string().nullable(),
  exposed: z.boolean(),
})
export type TcpPort = z.infer<typeof TcpPortSchema>

export const SshLoginSchema = z.strictObject({
  time: z.string(),
  ok: z.boolean(),
  user: z.string(),
  from: z.string(),
})
export type SshLogin = z.infer<typeof SshLoginSchema>

export const UfwRuleSchema = z.strictObject({
  to: z.string(),
  action: z.string(),
  from: z.string(),
})
export type UfwRule = z.infer<typeof UfwRuleSchema>

export const IptablesRuleSchema = z.strictObject({
  pkts: nonNegativeInteger,
  bytes: nonNegativeInteger,
  target: z.string(),
  proto: z.string(),
  source: z.string(),
  dest: z.string(),
})
export type IptablesRule = z.infer<typeof IptablesRuleSchema>

export const FirewallSchema = z.strictObject({
  active: z.boolean(),
  rules: z.array(UfwRuleSchema),
  iptables: z.array(IptablesRuleSchema),
})
export type Firewall = z.infer<typeof FirewallSchema>

export const VnstatDaySchema = z.strictObject({
  date: z.string(),
  rx: nonNegativeInteger,
  tx: nonNegativeInteger,
})
export type VnstatDay = z.infer<typeof VnstatDaySchema>

export const NetIfaceSchema = z.strictObject({
  name: z.string(),
  rx: nonNegativeInteger,
  tx: nonNegativeInteger,
})
export type NetIface = z.infer<typeof NetIfaceSchema>

export const FingerprintSchema = z.strictObject({
  file: z.string(),
  algo: z.string(),
  hash: z.string(),
})
export type Fingerprint = z.infer<typeof FingerprintSchema>

export const M3u8JobSchema = z.strictObject({
  title: z.string(),
  status: z.string(),
  progress: nonNegativeInteger,
  total: nonNegativeInteger,
  updated: z.string(),
})
export type M3u8Job = z.infer<typeof M3u8JobSchema>

export const M3u8QueueSchema = z.strictObject({
  health: z.string().nullable(),
  counts: z.record(z.string(), nonNegativeInteger),
  recent: z.array(M3u8JobSchema),
})
export type M3u8Queue = z.infer<typeof M3u8QueueSchema>

export const GiteaInfoSchema = z.strictObject({
  health: z.string().nullable(),
  repos: nonNegativeInteger.nullable(),
  users: nonNegativeInteger.nullable(),
  activeWeek: nonNegativeInteger.nullable(),
  lastActivity: integer.nullable(),
})
export type GiteaInfo = z.infer<typeof GiteaInfoSchema>

export const CaddyLogsSchema = z.strictObject({
  sizeBytes: nonNegativeInteger,
  mtime: timestamp,
  growthBps: finite.nonnegative(),
})
export type CaddyLogs = z.infer<typeof CaddyLogsSchema>

export const AlertSchema = z.strictObject({
  key: z.string(),
  severity: SeveritySchema,
  message: z.string(),
  since: timestamp,
})
export type Alert = z.infer<typeof AlertSchema>

export const AlertPayloadSchema = z.strictObject({
  ...AlertSchema.shape,
  timestamp,
  state: z.enum(['fired', 'resolved']),
})
export type AlertPayload = z.infer<typeof AlertPayloadSchema>

export const AlertConfigSchema = z.strictObject({
  diskPct: finite,
  memPct: finite,
  cpuPct: finite,
  cpuSustainSec: nonNegativeInteger,
  tlsMinDays: nonNegativeInteger,
  healthMaxFails: nonNegativeInteger,
  backupMaxAgeHours: nonNegativeInteger,
  cooldownSec: nonNegativeInteger,
})
export type AlertConfig = z.infer<typeof AlertConfigSchema>

export const CollectionConfigSchema = z.strictObject({
  fullIntervalSec: nonNegativeInteger,
  timeoutSec: nonNegativeInteger,
  retentionDays: nonNegativeInteger,
  backoffMaxSec: nonNegativeInteger,
})
export type CollectionConfig = z.infer<typeof CollectionConfigSchema>

export const ServerStateSchema = z.strictObject({
  id: z.string(),
  name: z.string(),
  status: ServerStatusSchema,
  metrics: MetricsSchema.nullable(),
  containers: z.array(ContainerSchema),
  services: z.array(ServiceSchema),
  fail2ban: z.array(Fail2banJailSchema),
  backup: BackupInfoSchema.nullable(),
  health: z.array(HealthCheckSchema),
  disks: z.array(DiskMountSchema),
  dockerUsage: DockerUsageSchema.nullable(),
  apt: AptUpgradesSchema.nullable(),
  tlsCerts: z.array(TlsCertSchema),
  ports: z.array(TcpPortSchema),
  sshLogins: z.array(SshLoginSchema),
  firewall: FirewallSchema.nullable(),
  vnstatDays: z.array(VnstatDaySchema),
  netIfaces: z.array(NetIfaceSchema),
  fingerprints: z.array(FingerprintSchema),
  m3u8: M3u8QueueSchema.nullable(),
  gitea: GiteaInfoSchema.nullable(),
  caddy: CaddyLogsSchema.nullable(),
  alerts: z.array(AlertSchema),
  sectionErrors: z.record(z.string(), z.string()),
  lastError: z.string().nullable(),
  updatedAt: timestamp,
})
export type ServerState = z.infer<typeof ServerStateSchema>

export const HealthInfoSchema = z.strictObject({
  status: z.string(),
  servers: nonNegativeInteger,
  online: nonNegativeInteger,
  alerts: AlertConfigSchema,
  collection: CollectionConfigSchema,
})
export type HealthInfo = z.infer<typeof HealthInfoSchema>

export const EventRowSchema = z.strictObject({
  ts: timestamp,
  server: z.string(),
  type: z.string(),
  severity: SeveritySchema,
  state: z.string(),
  message: z.string(),
})
export type EventRow = z.infer<typeof EventRowSchema>

export const CaddySampleSchema = z.strictObject({ ts: timestamp, size: nonNegativeInteger })
export type CaddySample = z.infer<typeof CaddySampleSchema>

export const WsMessageSchema = z.discriminatedUnion('type', [
  z.strictObject({ type: z.literal('snapshot'), servers: z.array(ServerStateSchema) }),
  z.strictObject({ type: z.literal('server'), server: z.string(), data: ServerStateSchema }),
  z.strictObject({ type: z.literal('status'), server: z.string(), data: ServerStatusSchema }),
  z.strictObject({ type: z.literal('alert'), server: z.string(), data: AlertPayloadSchema }),
])
export type WsMessage = z.infer<typeof WsMessageSchema>

export const ContractBundleSchema = z.strictObject({
  health: HealthInfoSchema,
  servers: z.array(ServerStateSchema),
  containers: z.array(ContainerSchema),
  services: z.array(ServiceSchema),
  fail2ban: z.array(Fail2banJailSchema),
  backup: BackupInfoSchema.nullable(),
  history: z.array(MetricsSchema),
  caddy: z.array(CaddySampleSchema),
  events: z.array(EventRowSchema),
  ws: z.array(WsMessageSchema),
})
export type ContractBundle = z.infer<typeof ContractBundleSchema>
