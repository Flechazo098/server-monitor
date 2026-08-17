<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useRoute } from 'vue-router'
import { apiGet } from '../api/client'
import { useServersStore } from '../stores/servers'
import { CHART } from '../lib/chartTheme'
import {
  fmtBytes,
  fmtClock,
  fmtEpoch,
  fmtPct,
  fmtRate,
  fmtDateTime,
  healthState,
  levelFor,
  tlsLevel,
} from '../lib/format'
import {
  CaddySampleSchema,
  MetricsSchema,
  type CaddySample,
  type ServerState,
} from '../types'
import LineChart from '../components/LineChart.vue'
import MeterBar from '../components/MeterBar.vue'
import StatusChip from '../components/StatusChip.vue'
import Panel from '../components/Panel.vue'
import EmptyState from '../components/EmptyState.vue'

const route = useRoute()
const store = useServersStore()
const thresholds = computed(() => store.healthInfo?.alerts)
const tab = ref('overview')

const server = computed<ServerState | null>(
  () => store.servers.find((s) => s.id === route.params.id) ?? null,
)
const metrics = computed(() => server.value?.metrics ?? null)

// Live chart buffers fed by WS metric updates.
const MAX_POINTS = 240
const point = (timestamp: string, value: number): [string, number] => [timestamp, value]
const cpuHist = ref<[string, number][]>([])
const cpuUserHist = ref<[string, number][]>([])
const cpuSystemHist = ref<[string, number][]>([])
const cpuIowaitHist = ref<[string, number][]>([])
const netHist = ref<{ rx: [string, number][]; tx: [string, number][] }>({ rx: [], tx: [] })
watch(
  () => server.value?.id,
  (id) => {
    cpuHist.value = []
    cpuUserHist.value = []
    cpuSystemHist.value = []
    cpuIowaitHist.value = []
    netHist.value = { rx: [], tx: [] }
    if (id) loadTelemetry(id)
  },
)

async function loadTelemetry(serverId: string) {
  try {
    const rows = await apiGet(
      '/api/history?server=' + encodeURIComponent(serverId) + '&hours=1',
      MetricsSchema.array(),
    )
    if (server.value?.id !== serverId) return
    const recent = rows.slice(-MAX_POINTS)
    cpuHist.value = recent.map((m) => point(m.timestamp, m.cpu))
    cpuUserHist.value = recent.map((m) => point(m.timestamp, m.cpuUser))
    cpuSystemHist.value = recent.map((m) => point(m.timestamp, m.cpuSystem))
    cpuIowaitHist.value = recent.map((m) => point(m.timestamp, m.cpuIowait))
    netHist.value = {
      rx: recent.map((m) => point(m.timestamp, m.rxRate)),
      tx: recent.map((m) => point(m.timestamp, m.txRate)),
    }
  } catch {
    // Live samples still populate the charts when history is unavailable.
  }
}
watch(
  metrics,
  (m) => {
    if (!m) return
    cpuHist.value = [...cpuHist.value, point(m.timestamp, m.cpu)].slice(-MAX_POINTS)
    cpuUserHist.value = [...cpuUserHist.value, point(m.timestamp, m.cpuUser)].slice(-MAX_POINTS)
    cpuSystemHist.value = [...cpuSystemHist.value, point(m.timestamp, m.cpuSystem)].slice(-MAX_POINTS)
    cpuIowaitHist.value = [...cpuIowaitHist.value, point(m.timestamp, m.cpuIowait)].slice(-MAX_POINTS)
    netHist.value = {
      rx: [...netHist.value.rx, point(m.timestamp, m.rxRate)].slice(-MAX_POINTS),
      tx: [...netHist.value.tx, point(m.timestamp, m.txRate)].slice(-MAX_POINTS),
    }
  },
  { immediate: true },
)

const caddyHist = ref<CaddySample[]>([])
const caddyLoading = ref(false)
watch(() => server.value?.id, () => { caddyHist.value = [] })
async function loadCaddy() {
  if (!server.value) return
  caddyLoading.value = true
  try {
    caddyHist.value = await apiGet(
      '/api/caddy?server=' + encodeURIComponent(server.value.id) + '&hours=168',
      CaddySampleSchema.array(),
    )
  } catch {
    caddyHist.value = []
  } finally {
    caddyLoading.value = false
  }
}
watch(
  () => [tab.value, server.value?.id],
  ([t]) => {
    if (t === 'backups') loadCaddy()
  },
)

const caddyGrowthPerDay = computed(() => {
  const c = server.value?.caddy
  return c && c.growthBps > 0 ? c.growthBps * 86400 : 0
})

const iptablesBlocked = computed(() => {
  const rules = server.value?.firewall?.iptables ?? []
  const blocked = rules.filter((r) =>
    /^(drop|reject)/i.test(r.target),
  )
  return {
    pkts: blocked.reduce((a, r) => a + r.pkts, 0),
    bytes: blocked.reduce((a, r) => a + r.bytes, 0),
  }
})

const m3u8Counts = computed(() => {
  const q = server.value?.m3u8
  return q ? Object.entries(q.counts).sort((a, b) => b[1] - a[1]) : []
})

function m3u8JobKind(status: string): 'ok' | 'warn' | 'crit' | 'off' | 'info' {
  if (status === 'done' || status === 'completed') return 'ok'
  if (status === 'running' || status === 'queued' || status === 'pending') return 'info'
  if (status === 'failed' || status === 'error' || status === 'interrupted') return 'crit'
  return 'off'
}

const sectionErrors = computed(() => Object.entries(server.value?.sectionErrors ?? {}))
const loadRow = computed(() => metrics.value ? metrics.value.load1.toFixed(2) + ' / ' + metrics.value.load5.toFixed(2) + ' / ' + metrics.value.load15.toFixed(2) : '—')
const swapPct = computed(() => {
  const m = metrics.value
  return m && m.swapTotalBytes > 0 ? (m.swapUsedBytes / m.swapTotalBytes) * 100 : 0
})
</script>

<template>
  <div>
    <div class="page-head">
      <div>
        <h1 class="page-title">
          <RouterLink to="/servers" class="dim"><UiIcon name="back" :size="15" /></RouterLink>
          {{ server?.name ?? 'Server' }}
          <StatusChip v-if="server" :kind="healthState(server.status, server.alerts).kind" :label="healthState(server.status, server.alerts).label" dot style="vertical-align: 2px; margin-left: 8px" />
        </h1>
        <p class="page-sub">
          <span v-if="server">last collection {{ fmtClock(server.updatedAt) }} · {{ Object.keys(server.sectionErrors).length }} failed section(s)</span>
          <span v-else>loading…</span>
        </p>
      </div>
      <div class="page-side" v-if="metrics">
        <div class="mono">load {{ loadRow }}</div>
        <div class="mono">↓ {{ fmtRate(metrics.rxRate) }} · ↑ {{ fmtRate(metrics.txRate) }}</div>
      </div>
    </div>

    <div v-if="server?.lastError" class="error-box">Last collection error: {{ server.lastError }}</div>

    <template v-if="server">
      <div class="tabbar">
        <button v-for="t in [
          { id: 'overview', label: 'Overview' },
          { id: 'storage', label: 'Storage' },
          { id: 'network', label: 'Network & Security' },
          { id: 'certs', label: 'Certificates' },
          { id: 'business', label: 'Business' },
          { id: 'backups', label: 'Logs & Backups' },
        ]" :key="t.id" :class="{ active: tab === t.id }" @click="tab = t.id">
          {{ t.label }}
        </button>
      </div>

      <!-- ============ OVERVIEW ============ -->
      <div v-if="tab === 'overview'" class="stack">
        <div v-if="metrics" class="resource-strip">
          <div><span>CPU total</span><strong>{{ fmtPct(metrics.cpu) }}</strong></div>
          <div><span>User / system / IO</span><strong>{{ fmtPct(metrics.cpuUser) }} / {{ fmtPct(metrics.cpuSystem) }} / {{ fmtPct(metrics.cpuIowait) }}</strong></div>
          <div><span>Memory used</span><strong>{{ fmtPct(metrics.mem) }}</strong></div>
          <div><span>Available / cache</span><strong>{{ fmtBytes(metrics.memAvailableBytes) }} / {{ fmtBytes(metrics.memCacheBytes) }}</strong></div>
          <div><span>Buffers</span><strong>{{ fmtBytes(metrics.memBuffersBytes) }}</strong></div>
          <div><span>Swap</span><strong :class="swapPct > 50 ? 'warn-text' : ''">{{ fmtBytes(metrics.swapUsedBytes) }} / {{ fmtBytes(metrics.swapTotalBytes) }}</strong></div>
        </div>
        <div class="grid-2-1">
          <Panel title="CPU composition · live">
            <LineChart
              :series="[
                { name: 'total', data: cpuHist, color: CHART.cpu, area: true, unit: '%' },
                { name: 'user', data: cpuUserHist, color: CHART.cpuUser, unit: '%' },
                { name: 'system', data: cpuSystemHist, color: CHART.cpuSystem, unit: '%' },
                { name: 'iowait', data: cpuIowaitHist, color: CHART.cpuIowait, unit: '%' },
              ]"
              height="220px"
              :min="0"
              :max="100"
            />
          </Panel>
          <Panel title="Network throughput (live)">
            <LineChart
              :series="[
                { name: 'rx', data: netHist.rx, color: CHART.rx, area: true, unit: 'B/s' },
                { name: 'tx', data: netHist.tx, color: CHART.tx, unit: 'B/s' },
              ]"
              height="220px"
            />
          </Panel>
        </div>

        <div class="grid-2">
          <Panel title="Listening ports" flush>
            <template v-if="server.ports.length">
              <table class="tbl">
                <thead>
                  <tr><th>Port</th><th>Proto</th><th>Bound to</th><th>Process</th><th>Bind scope</th></tr>
                </thead>
                <tbody>
                  <tr v-for="p in server.ports.slice(0, 30)" :key="p.proto + p.local">
                    <td class="num">{{ p.port }}</td>
                    <td class="mono">{{ p.proto }}</td>
                    <td class="mono">{{ p.local }}</td>
                    <td class="mono">{{ p.process ?? '—' }}</td>
                    <td>
                      <StatusChip v-if="p.exposed" kind="warn" label="All interfaces" />
                      <span v-else class="chip off">Restricted bind</span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </template>
            <EmptyState v-else icon="net" message="No listening socket data" />
          </Panel>

          <Panel title="Docker containers" flush>
            <template v-if="server.containers.length">
              <table class="tbl">
                <thead>
                  <tr><th>Name</th><th>Image</th><th>Status</th><th class="num">CPU</th><th class="num">MEM</th></tr>
                </thead>
                <tbody>
                  <tr v-for="c in server.containers" :key="c.name">
                    <td class="mono">{{ c.name }}</td>
                    <td class="mono dim">{{ c.image }}</td>
                    <td>{{ c.status }}</td>
                    <td class="num">{{ c.cpuPct != null ? c.cpuPct.toFixed(1) + '%' : '—' }}</td>
                    <td class="num">{{ c.memPct != null ? c.memPct.toFixed(1) + '%' : '—' }}</td>
                  </tr>
                </tbody>
              </table>
            </template>
            <EmptyState v-else icon="box" message="No container data" />
          </Panel>
        </div>

        <div class="grid-2">
          <Panel title="Public entry points" flush>
            <template v-if="server.health.length">
              <table class="tbl">
                <thead><tr><th>URL</th><th class="num">Status</th><th class="num">Latency</th></tr></thead>
                <tbody>
                  <tr v-for="h in server.health" :key="h.url">
                    <td class="mono">{{ h.url }}</td>
                    <td class="num" :class="h.ok ? 'ok-text' : 'crit-text'">{{ h.status }}</td>
                    <td class="num">{{ h.latencyMs }}ms</td>
                  </tr>
                </tbody>
              </table>
            </template>
            <EmptyState v-else icon="globe" message="No public URLs configured" />
          </Panel>

          <Panel title="Active alerts" flush>
            <template v-if="server.alerts.length">
              <table class="tbl">
                <tbody>
                  <tr v-for="a in server.alerts" :key="a.key">
                    <td style="width: 24px"><span class="dot" :class="a.severity === 'critical' ? 'crit' : a.severity === 'warning' ? 'warn' : 'ok'" /></td>
                    <td>{{ a.message }}</td>
                    <td class="num faint">{{ fmtEpoch(new Date(a.since).getTime() / 1000) }}</td>
                  </tr>
                </tbody>
              </table>
            </template>
            <EmptyState v-else icon="check" message="No active alerts" />
          </Panel>
        </div>
      </div>

      <!-- ============ STORAGE ============ -->
      <div v-if="tab === 'storage'" class="stack">
        <Panel title="Filesystem mounts" flush>
          <template v-if="server.disks.length">
            <table class="tbl">
              <thead>
                <tr><th>Mount</th><th>Source</th><th>Type</th><th class="num">Size</th><th class="num">Used</th><th class="num">Avail</th><th style="width: 24%">Usage</th></tr>
              </thead>
              <tbody>
                <tr v-for="d in server.disks" :key="d.mount">
                  <td class="mono cell-main">{{ d.mount }}</td>
                  <td class="mono dim">{{ d.fs }}</td>
                  <td class="mono dim">{{ d.type }}</td>
                  <td class="num">{{ d.size }}</td>
                  <td class="num">{{ d.used }}</td>
                  <td class="num">{{ d.avail }}</td>
                  <td>
                    <div class="meter-cell">
                      <MeterBar :value="d.pct" :level="levelFor('disk', d.pct, thresholds?.diskPct)" :threshold="thresholds?.diskPct ?? 80" />
                      <span class="num">{{ fmtPct(d.pct) }}</span>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </template>
          <EmptyState v-else icon="disk" message="No mount data" />
        </Panel>

        <div class="grid-2">
          <Panel title="Docker disk usage (system df)" flush>
            <template v-if="server.dockerUsage">
              <table class="tbl">
                <thead><tr><th>Category</th><th class="num">Count</th><th class="num">Size</th></tr></thead>
                <tbody>
                  <tr v-for="[name, row] in [
                    ['images', server.dockerUsage.images],
                    ['containers', server.dockerUsage.containers],
                    ['volumes', server.dockerUsage.volumes],
                    ['build cache', server.dockerUsage.buildCache],
                  ] as const" :key="name">
                    <td class="cell-main">{{ name }}</td>
                    <td class="num">{{ row.count }}</td>
                    <td class="num">{{ row.size }}</td>
                  </tr>
                </tbody>
              </table>
            </template>
            <EmptyState v-else icon="layers" message="Docker not available" />
          </Panel>

          <Panel title="Package updates (apt)" flush>
            <template v-if="server.apt">
              <div class="panel-body" style="padding-bottom: 8px">
                <div class="kv">
                  <div class="kv-row"><span class="k">Upgradable packages</span><span class="v" :class="server.apt.count > 0 ? 'warn-text' : 'ok-text'">{{ server.apt.count }}</span></div>
                </div>
                <div v-if="server.apt.packages.length" class="mono dim" style="margin-top: 8px; font-size: 11.5px; line-height: 1.7">
                  {{ server.apt.packages.join('  ') }}
                </div>
              </div>
            </template>
            <EmptyState v-else icon="pkg" message="apt unavailable" />
          </Panel>
        </div>
      </div>

      <!-- ============ NETWORK & SECURITY ============ -->
      <div v-if="tab === 'network'" class="stack">
        <div class="grid-2">
          <Panel title="Firewall (UFW)" flush>
            <template v-if="server.firewall">
              <div class="panel-body" style="padding-bottom: 8px">
                <div class="kv-row" style="margin-bottom: 6px">
                  <span class="k">Status</span>
                  <StatusChip :kind="server.firewall.active ? 'ok' : 'crit'" :label="server.firewall.active ? 'active' : 'inactive'" />
                </div>
              </div>
              <table class="tbl">
                <thead><tr><th>To</th><th>Action</th><th>From</th></tr></thead>
                <tbody>
                  <tr v-for="(r, i) in server.firewall.rules" :key="i">
                    <td class="mono">{{ r.to }}</td>
                    <td>
                      <span class="chip" :class="r.action === 'ALLOW' ? 'ok' : 'crit'">{{ r.action }}</span>
                    </td>
                    <td class="mono dim">{{ r.from }}</td>
                  </tr>
                </tbody>
              </table>
            </template>
            <EmptyState v-else icon="shield" message="UFW unavailable" />
          </Panel>

          <Panel title="Blocked traffic (iptables counters)" flush>
            <template v-if="iptablesBlocked.pkts > 0">
              <div class="panel-body" style="padding-bottom: 8px">
                <div class="kv">
                  <div class="kv-row"><span class="k">Dropped / rejected packets</span><span class="v warn-text">{{ iptablesBlocked.pkts.toLocaleString() }}</span></div>
                  <div class="kv-row"><span class="k">Blocked bytes</span><span class="v">{{ fmtBytes(iptablesBlocked.bytes) }}</span></div>
                </div>
              </div>
            </template>
            <template v-if="server.firewall && server.firewall.iptables.length">
              <table class="tbl">
                <thead><tr><th class="num">pkts</th><th class="num">bytes</th><th>target</th><th>proto</th><th>source</th><th>dest</th></tr></thead>
                <tbody>
                  <tr v-for="(r, i) in server.firewall.iptables.filter((x) => /^(drop|reject)/i.test(x.target)).slice(0, 12)" :key="i">
                    <td class="num">{{ r.pkts.toLocaleString() }}</td>
                    <td class="num">{{ fmtBytes(r.bytes) }}</td>
                    <td class="crit-text mono">{{ r.target }}</td>
                    <td class="mono">{{ r.proto }}</td>
                    <td class="mono dim">{{ r.source }}</td>
                    <td class="mono dim">{{ r.dest }}</td>
                  </tr>
                </tbody>
              </table>
            </template>
            <EmptyState v-if="!server.firewall" icon="shield" message="iptables unavailable" />
          </Panel>
        </div>

        <div class="grid-2">
          <Panel title="Fail2ban jails" flush>
            <template v-if="server.fail2ban.length">
              <table class="tbl">
                <thead><tr><th>Jail</th><th class="num">Current</th><th class="num">Total</th><th>Banned IPs</th></tr></thead>
                <tbody>
                  <tr v-for="j in server.fail2ban" :key="j.name">
                    <td class="mono">{{ j.name }}</td>
                    <td class="num" :class="j.banned > 0 ? 'warn-text' : ''">{{ j.banned }}</td>
                    <td class="num">{{ j.total }}</td>
                    <td>
                      <div v-if="j.bannedIps.length" class="token-list">
                        <span v-for="ip in j.bannedIps" :key="ip" class="token mono">{{ ip }}</span>
                      </div>
                      <span v-else class="faint">—</span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </template>
            <EmptyState v-else icon="shield" message="Fail2ban unavailable" />
          </Panel>

          <Panel title="SSH auth (last 24h)" flush>
            <template v-if="server.sshLogins.length">
              <table class="tbl">
                <thead><tr><th>Time</th><th>Result</th><th>User</th><th>From</th></tr></thead>
                <tbody>
                  <tr v-for="(l, i) in server.sshLogins.slice(-20).reverse()" :key="i">
                    <td class="mono dim">{{ l.time }}</td>
                    <td>
                      <StatusChip :kind="l.ok ? 'ok' : 'crit'" :label="l.ok ? 'accepted' : 'failed'" />
                    </td>
                    <td class="mono">{{ l.user }}</td>
                    <td class="mono dim">{{ l.from }}</td>
                  </tr>
                </tbody>
              </table>
            </template>
            <EmptyState v-else icon="key" message="journalctl unavailable or no logins" />
          </Panel>
        </div>
      </div>

      <!-- ============ CERTIFICATES ============ -->
      <div v-if="tab === 'certs'" class="stack">
        <Panel title="TLS certificates" flush>
          <template v-if="server.tlsCerts.length">
            <table class="tbl">
              <thead>
                <tr><th>Host</th><th>Subject</th><th>Issuer</th><th class="num">Expires</th><th class="num">Days left</th><th>SHA-256 fingerprint</th></tr>
              </thead>
              <tbody>
                <tr v-for="c in server.tlsCerts" :key="c.host">
                  <td class="mono cell-main">{{ c.host }}</td>
                  <td class="mono dim">{{ c.subject }}</td>
                  <td class="mono dim">{{ c.issuer }}</td>
                  <td class="num">{{ fmtDateTime(c.notAfter) }}</td>
                  <td class="num">
                    <StatusChip :kind="tlsLevel(c.daysLeft, thresholds?.tlsMinDays)" :label="c.daysLeft + ' days'" />
                  </td>
                  <td class="mono">{{ c.fingerprint }}</td>
                </tr>
              </tbody>
            </table>
          </template>
          <EmptyState v-else icon="lock" message="No certificate probes succeeded" />
        </Panel>

        <Panel title="SSH host key fingerprints" flush>
          <template v-if="server.fingerprints.length">
            <table class="tbl">
              <thead><tr><th>Key file</th><th>Algorithm</th><th>Fingerprint</th></tr></thead>
              <tbody>
                <tr v-for="f in server.fingerprints" :key="f.file">
                  <td class="mono">{{ f.file }}</td>
                  <td class="mono dim">{{ f.algo }}</td>
                  <td class="mono">{{ f.hash }}</td>
                </tr>
              </tbody>
            </table>
          </template>
          <EmptyState v-else icon="key" message="Host keys unreadable" />
        </Panel>
      </div>

      <!-- ============ BUSINESS ============ -->
      <div v-if="tab === 'business'" class="stack">
        <Panel title="m3u8 downloader queue" flush>
          <template v-if="server.m3u8">
            <div class="panel-body" style="padding-bottom: 8px">
              <div class="kv">
                <div class="kv-row">
                  <span class="k">Service health</span>
                  <StatusChip
                    :kind="server.m3u8.health === '200' ? 'ok' : 'crit'"
                    :label="server.m3u8.health ?? 'unreachable'"
                  />
                </div>
                <div class="kv-row">
                  <span class="k">Queue</span>
                  <span class="v">
                    <span v-for="[status, n] in m3u8Counts" :key="status" style="margin-left: 8px">
                      <span class="chip" :class="m3u8JobKind(status)">{{ status }} {{ n }}</span>
                    </span>
                    <span v-if="m3u8Counts.length === 0" class="faint">empty</span>
                  </span>
                </div>
              </div>
            </div>
            <template v-if="server.m3u8.recent.length">
              <table class="tbl">
                <thead><tr><th>Title</th><th>Status</th><th class="num">Progress</th><th class="num">Updated</th></tr></thead>
                <tbody>
                  <tr v-for="j in server.m3u8.recent" :key="j.title + j.updated">
                    <td class="mono">{{ j.title }}</td>
                    <td><StatusChip :kind="m3u8JobKind(j.status)" :label="j.status" /></td>
                    <td class="num">
                      {{ j.total > 0 ? Math.round((j.progress / j.total) * 100) + '%' : j.progress }}
                    </td>
                    <td class="num faint">{{ fmtDateTime(j.updated) }}</td>
                  </tr>
                </tbody>
              </table>
            </template>
          </template>
          <EmptyState v-else icon="download" message="Downloader unreachable" />
        </Panel>

        <Panel title="Gitea" flush>
          <template v-if="server.gitea">
            <div class="panel-body">
              <div class="kv">
                <div class="kv-row">
                  <span class="k">Health</span>
                  <StatusChip
                    :kind="server.gitea.health === '200' ? 'ok' : 'crit'"
                    :label="server.gitea.health ?? 'unreachable'"
                  />
                </div>
                <div class="kv-row"><span class="k">Repositories</span><span class="v">{{ server.gitea.repos ?? '—' }}</span></div>
                <div class="kv-row"><span class="k">Users</span><span class="v">{{ server.gitea.users ?? '—' }}</span></div>
                <div class="kv-row"><span class="k">Repos active (7d)</span><span class="v">{{ server.gitea.activeWeek ?? '—' }}</span></div>
                <div class="kv-row"><span class="k">Latest repository update</span><span class="v">{{ fmtEpoch(server.gitea.lastActivity) }}</span></div>
              </div>
            </div>
          </template>
          <EmptyState v-else icon="branch" message="Gitea unreachable" />
        </Panel>
      </div>

      <!-- ============ LOGS & BACKUPS ============ -->
      <div v-if="tab === 'backups'" class="stack">
        <Panel title="Caddy access log" flush>
          <template v-if="server.caddy">
            <div class="panel-body" style="padding-bottom: 8px">
              <div class="kv">
                <div class="kv-row"><span class="k">Log size</span><span class="v">{{ fmtBytes(server.caddy.sizeBytes) }}</span></div>
                <div class="kv-row">
                  <span class="k">Growth</span>
                  <span class="v" :class="caddyGrowthPerDay > 0 ? 'warn-text' : 'ok-text'">
                    ≈ {{ fmtBytes(caddyGrowthPerDay) }}/day
                  </span>
                </div>
              </div>
            </div>
            <template v-if="caddyHist.length">
              <div class="panel-body">
                <LineChart
                  :series="[{
                    name: 'size',
                    data: caddyHist.map((s) => [s.ts, s.size] as [string, number]),
                    color: CHART.caddy,
                    area: true,
                    unit: 'bytes',
                  }]"
                  height="200px"
                />
              </div>
            </template>
            <div v-if="caddyLoading" class="loading"><span class="spinner" /> loading history…</div>
          </template>
          <EmptyState v-else icon="log" message="Caddy log unavailable" />
        </Panel>

        <Panel title="Backups" flush>
          <template v-if="server.backup">
            <table class="tbl">
              <thead><tr><th>Last run</th><th>Next run</th><th class="num">Local copies</th><th class="num">Newest file</th><th>Service</th></tr></thead>
              <tbody>
                <tr>
                  <td class="mono" :class="server.backup.failed ? 'crit-text' : ''">{{ server.backup.lastRun ?? '—' }}</td>
                  <td class="mono">{{ server.backup.nextRun ?? '—' }}</td>
                  <td class="num">{{ server.backup.count }}</td>
                  <td class="num">{{ fmtEpoch(server.backup.newestEpoch) }}</td>
                  <td>
                    <StatusChip
                      :kind="server.backup.failed === true ? 'crit' : server.backup.failed === false ? 'ok' : 'off'"
                      :label="server.backup.failed === true ? 'failed' : server.backup.failed === false ? 'healthy' : 'unknown'"
                    />
                  </td>
                </tr>
              </tbody>
            </table>
          </template>
          <EmptyState v-else icon="clock" message="Backup info unavailable" />
        </Panel>

        <Panel v-if="sectionErrors.length" title="Unavailable sections" flush>
          <table class="tbl">
            <thead><tr><th>Section</th><th>Reason</th></tr></thead>
            <tbody>
              <tr v-for="[name, why] in sectionErrors" :key="name">
                <td class="mono">{{ name }}</td>
                <td class="dim">{{ why }}</td>
              </tr>
            </tbody>
          </table>
        </Panel>
      </div>
    </template>

    <div v-else class="panel">
      <div class="loading"><span class="spinner" /> loading server…</div>
    </div>
  </div>
</template>
