<script setup lang="ts">
import { computed } from 'vue'
import { useServersStore } from '../stores/servers'
import { fmtBytes, fmtClock, fmtDuration, fmtPct, fmtRate, healthState, levelFor, tlsLevel } from '../lib/format'
import { CHART } from '../lib/chartTheme'
import type { Alert, HealthCheck, ServerState, TlsCert } from '../types'
import BarsChart from '../components/BarsChart.vue'
import MeterBar from '../components/MeterBar.vue'
import StatusChip from '../components/StatusChip.vue'
import Panel from '../components/Panel.vue'
import EmptyState from '../components/EmptyState.vue'

const store = useServersStore()
const thresholds = computed(() => store.healthInfo?.alerts)

const online = computed(() => store.servers.filter((s) => s.status === 'online').length)
const healthy = computed(() => store.servers.filter((s) => healthState(s.status, s.alerts).kind === 'ok').length)
const avgCpu = computed(() => {
  const vals = store.servers.flatMap((s) => (s.metrics ? [s.metrics.cpu] : []))
  return vals.length ? vals.reduce((a, b) => a + b, 0) / vals.length : null
})
const avgMem = computed(() => {
  const vals = store.servers.flatMap((s) => (s.metrics ? [s.metrics.mem] : []))
  return vals.length ? vals.reduce((a, b) => a + b, 0) / vals.length : null
})
const trafficToday = computed(() =>
  store.servers.reduce(
    (acc, s) => acc + (s.metrics?.rxBytes ?? 0) + (s.metrics?.txBytes ?? 0),
    0,
  ),
)

interface AlertRow extends Alert {
  server: string
  serverName: string
}
const activeAlerts = computed<AlertRow[]>(() =>
  store.servers
    .flatMap((s) => s.alerts.map((a) => ({ ...a, server: s.id, serverName: s.name })))
    .sort((a, b) => b.since.localeCompare(a.since)),
)
const alertCount = computed(() => activeAlerts.value.length)
const critCount = computed(() => activeAlerts.value.filter((a) => a.severity === 'critical').length)

const healthRows = computed<{ server: ServerState; h: HealthCheck }[]>(() =>
  store.servers.flatMap((s) => s.health.map((h) => ({ server: s, h }))),
)
const tlsRows = computed<{ server: ServerState; c: TlsCert }[]>(() =>
  store.servers.flatMap((s) => s.tlsCerts.map((c) => ({ server: s, c }))),
)

const trafficDays = computed(() => {
  const totals = new Map<string, { rx: number; tx: number }>()
  for (const server of store.servers) {
    for (const day of server.vnstatDays) {
      const current = totals.get(day.date) ?? { rx: 0, tx: 0 }
      current.rx += day.rx
      current.tx += day.tx
      totals.set(day.date, current)
    }
  }
  return [...totals.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .slice(-14)
    .map(([date, values]) => ({ date, ...values }))
})
const vnstatCats = computed(() => trafficDays.value.map((day) => day.date))
const vnstatRx = computed(() => trafficDays.value.map((day) => day.rx))
const vnstatTx = computed(() => trafficDays.value.map((day) => day.tx))
const latestUpdate = computed(() => store.servers.map((server) => server.updatedAt).sort().at(-1))
const soonestCert = computed(() => [...tlsRows.value].sort((a, b) => a.c.daysLeft - b.c.daysLeft)[0])
</script>

<template>
  <div>
    <div class="page-head">
      <div>
        <h1 class="page-title">Overview</h1>
        <p class="page-sub">{{ healthy }}/{{ store.servers.length }} healthy · {{ online }} reachable · {{ alertCount }} active alerts</p>
      </div>
      <div class="page-side">
        <span v-if="latestUpdate">updated {{ fmtClock(latestUpdate) }}</span>
      </div>
    </div>

    <div class="stat-strip">
      <div class="stat">
        <div class="stat-label">Servers</div>
        <div class="stat-value">{{ store.servers.length }}<small>online {{ online }}</small></div>
      </div>
      <div class="stat">
        <div class="stat-label">Active alerts</div>
        <div class="stat-value" :class="critCount > 0 ? 'crit-text' : alertCount > 0 ? 'warn-text' : 'ok-text'">
          {{ alertCount }}
        </div>
      </div>
      <div class="stat">
        <div class="stat-label">Avg CPU</div>
        <div class="stat-value">{{ fmtPct(avgCpu) }}</div>
      </div>
      <div class="stat">
        <div class="stat-label">Avg MEM</div>
        <div class="stat-value">{{ fmtPct(avgMem) }}</div>
      </div>
      <div class="stat">
        <div class="stat-label">Traffic today</div>
        <div class="stat-value">{{ fmtBytes(trafficToday) }}</div>
      </div>
      <div class="stat">
        <div class="stat-label">Cert expiring soonest</div>
        <div class="stat-value" v-if="soonestCert">
          {{ soonestCert.c.daysLeft }}<small>days · {{ soonestCert.c.host }}</small>
        </div>
        <div class="stat-value faint" v-else>—</div>
      </div>
    </div>

    <Panel title="Servers" flush>
      <table class="tbl">
        <thead>
          <tr>
            <th>Server</th>
            <th>Status</th>
            <th>CPU</th>
            <th>MEM</th>
            <th>DISK /</th>
            <th>Load 1m</th>
            <th class="num">NET (rx / tx)</th>
            <th class="num">Uptime</th>
            <th class="num">Updated</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="s in store.servers" :key="s.id">
            <td class="cell-main">
              <RouterLink :to="'/servers/' + s.id">{{ s.name }}</RouterLink>
            </td>
            <td>
              <StatusChip :kind="healthState(s.status, s.alerts).kind" :label="healthState(s.status, s.alerts).label" dot />
            </td>
            <template v-if="s.metrics">
              <td>
                <div class="meter-cell">
                  <MeterBar :value="s.metrics.cpu" :level="levelFor('cpu', s.metrics.cpu, thresholds?.cpuPct)" :threshold="thresholds?.cpuPct ?? 85" />
                  <span class="num">{{ fmtPct(s.metrics.cpu) }}</span>
                </div>
              </td>
              <td>
                <div class="meter-cell">
                  <MeterBar :value="s.metrics.mem" :level="levelFor('mem', s.metrics.mem, thresholds?.memPct)" :threshold="thresholds?.memPct ?? 90" />
                  <span class="num">{{ fmtPct(s.metrics.mem) }}</span>
                </div>
              </td>
              <td>
                <div class="meter-cell">
                  <MeterBar :value="s.metrics.disk" :level="levelFor('disk', s.metrics.disk, thresholds?.diskPct)" :threshold="thresholds?.diskPct ?? 80" />
                  <span class="num">{{ fmtPct(s.metrics.disk) }}</span>
                </div>
              </td>
              <td class="num">{{ s.metrics.load1.toFixed(2) }}</td>
              <td class="num">{{ fmtRate(s.metrics.rxRate) }} ↓ / {{ fmtRate(s.metrics.txRate) }} ↑</td>
              <td class="num">{{ fmtDuration(s.metrics.uptimeSec) }}</td>
              <td class="num faint">{{ fmtClock(s.updatedAt) }}</td>
            </template>
            <template v-else>
              <td colspan="6" class="faint">no metrics yet</td>
            </template>
          </tr>
        </tbody>
      </table>
      <EmptyState v-if="store.servers.length === 0" icon="server" message="No servers — check backend config.json" />
    </Panel>

    <div class="grid-2-1" style="margin-top: 12px">
      <Panel title="Traffic · vnStat daily" v-if="vnstatCats.length">
        <BarsChart
          :categories="vnstatCats"
          :series="[
            { name: 'rx', data: vnstatRx, color: CHART.vnstatRx },
            { name: 'tx', data: vnstatTx, color: CHART.vnstatTx },
          ]"
          height="240px"
        />
        <div class="panel-side" style="margin-top: 6px">
          <span class="faint">total 14d</span>
          <span class="mono">↓ {{ fmtBytes(vnstatRx.reduce((a, b) => a + b, 0)) }}</span>
          <span class="mono">↑ {{ fmtBytes(vnstatTx.reduce((a, b) => a + b, 0)) }}</span>
        </div>
      </Panel>

      <div class="stack">
        <Panel title="Active alerts" flush>
          <template v-if="activeAlerts.length">
            <table class="tbl">
              <tbody>
                <tr v-for="a in activeAlerts.slice(0, 8)" :key="a.server + a.key">
                  <td style="width: 24px"><span class="dot" :class="a.severity === 'critical' ? 'crit' : a.severity === 'warning' ? 'warn' : 'ok'" /></td>
                  <td class="cell-main">{{ a.message }}</td>
                  <td class="faint">{{ a.serverName }}</td>
                </tr>
              </tbody>
            </table>
          </template>
          <EmptyState v-else icon="check" message="No active alerts" />
        </Panel>

        <Panel title="Public entry points" flush>
          <template v-if="healthRows.length">
            <table class="tbl compact-table">
              <tbody>
                <tr v-for="({ h }, i) in healthRows" :key="i">
                  <td style="width: 24px"><span class="dot" :class="h.ok ? 'ok' : 'crit'" /></td>
                  <td class="mono compact-primary" :title="h.url">{{ h.url }}</td>
                  <td class="num compact-status" :class="h.ok ? 'ok-text' : 'crit-text'">{{ h.status }}</td>
                  <td class="num compact-latency">{{ h.latencyMs }}ms</td>
                </tr>
              </tbody>
            </table>
          </template>
          <EmptyState v-else icon="globe" message="No public URLs configured" />
        </Panel>

        <Panel title="TLS certificates" flush>
          <template v-if="tlsRows.length">
            <table class="tbl compact-table">
              <tbody>
                <tr v-for="({ c }, i) in tlsRows" :key="i">
                  <td style="width: 24px"><span class="dot" :class="tlsLevel(c.daysLeft, thresholds?.tlsMinDays)" /></td>
                  <td class="cell-main compact-primary" :title="c.fingerprint">{{ c.host }}</td>
                  <td class="num compact-status">
                    <StatusChip
                      :kind="tlsLevel(c.daysLeft, thresholds?.tlsMinDays)"
                      :label="c.daysLeft + 'd'"
                    />
                  </td>
                </tr>
              </tbody>
            </table>
          </template>
          <EmptyState v-else icon="lock" message="No certificates probed" />
        </Panel>
      </div>
    </div>
  </div>
</template>
