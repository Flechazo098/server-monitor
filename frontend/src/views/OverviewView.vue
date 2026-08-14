<script setup lang="ts">
import { computed } from 'vue'
import { useServersStore } from '../stores/servers'
import { fmtBytes, fmtClock, fmtDuration, fmtPct, fmtRate, levelFor, tlsLevel } from '../lib/format'
import { CHART } from '../lib/chartTheme'
import type { Alert, HealthCheck, ServerState, TlsCert } from '../types'
import BarsChart from '../components/BarsChart.vue'
import MeterBar from '../components/MeterBar.vue'
import StatusChip from '../components/StatusChip.vue'
import Panel from '../components/Panel.vue'
import EmptyState from '../components/EmptyState.vue'

const store = useServersStore()

const online = computed(() => store.servers.filter((s) => s.status === 'online').length)
const avgCpu = computed(() => {
  const vals = store.servers.flatMap((s) => (s.metrics ? [s.metrics.cpu] : []))
  return vals.length ? vals.reduce((a, b) => a + b, 0) / vals.length : 0
})
const avgMem = computed(() => {
  const vals = store.servers.flatMap((s) => (s.metrics ? [s.metrics.mem] : []))
  return vals.length ? vals.reduce((a, b) => a + b, 0) / vals.length : 0
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

const vnstatCats = computed(() => {
  const days = store.servers[0]?.vnstatDays ?? []
  return days.slice(-14).map((d) => d.date)
})
const vnstatRx = computed(() => {
  const days = store.servers[0]?.vnstatDays ?? []
  return days.slice(-14).map((d) => d.rx)
})
const vnstatTx = computed(() => {
  const days = store.servers[0]?.vnstatDays ?? []
  return days.slice(-14).map((d) => d.tx)
})
</script>

<template>
  <div>
    <div class="page-head">
      <div>
        <h1 class="page-title">Overview</h1>
        <p class="page-sub">Health and traffic of all monitored hosts</p>
      </div>
      <div class="page-side">
        <span v-if="store.servers[0]">updated {{ fmtClock(store.servers[0].updatedAt) }}</span>
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
        <div class="stat-value">{{ avgCpu.toFixed(1) }}<small>%</small></div>
      </div>
      <div class="stat">
        <div class="stat-label">Avg MEM</div>
        <div class="stat-value">{{ avgMem.toFixed(1) }}<small>%</small></div>
      </div>
      <div class="stat">
        <div class="stat-label">Traffic today</div>
        <div class="stat-value">{{ fmtBytes(trafficToday) }}</div>
      </div>
      <div class="stat">
        <div class="stat-label">Cert expiring soonest</div>
        <div class="stat-value" v-if="tlsRows.length">
          {{ Math.min(...tlsRows.map((t) => t.c.daysLeft)) }}<small>days · {{ tlsRows.find((t) => t.c.daysLeft === Math.min(...tlsRows.map((x) => x.c.daysLeft)))?.c.host }}</small>
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
              <StatusChip :kind="s.status" :label="s.status" dot />
            </td>
            <template v-if="s.metrics">
              <td>
                <div class="meter-cell">
                  <MeterBar :value="s.metrics.cpu" :level="levelFor('cpu', s.metrics.cpu)" :threshold="85" />
                  <span class="num">{{ fmtPct(s.metrics.cpu) }}</span>
                </div>
              </td>
              <td>
                <div class="meter-cell">
                  <MeterBar :value="s.metrics.mem" :level="levelFor('mem', s.metrics.mem)" :threshold="90" />
                  <span class="num">{{ fmtPct(s.metrics.mem) }}</span>
                </div>
              </td>
              <td>
                <div class="meter-cell">
                  <MeterBar :value="s.metrics.disk" :level="levelFor('disk', s.metrics.disk)" :threshold="80" />
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
            <table class="tbl">
              <tbody>
                <tr v-for="({ h }, i) in healthRows" :key="i">
                  <td style="width: 24px"><span class="dot" :class="h.ok ? 'ok' : 'crit'" /></td>
                  <td class="mono">{{ h.url }}</td>
                  <td class="num">{{ h.ok ? h.status : h.status + ' ✕' }}</td>
                  <td class="num">{{ h.latencyMs }}ms</td>
                </tr>
              </tbody>
            </table>
          </template>
          <EmptyState v-else icon="globe" message="No public URLs configured" />
        </Panel>

        <Panel title="TLS certificates" flush>
          <template v-if="tlsRows.length">
            <table class="tbl">
              <tbody>
                <tr v-for="({ c }, i) in tlsRows" :key="i">
                  <td style="width: 24px"><span class="dot" :class="tlsLevel(c.daysLeft)" /></td>
                  <td class="cell-main">{{ c.host }}</td>
                  <td class="num">
                    <StatusChip
                      :kind="tlsLevel(c.daysLeft)"
                      :label="c.daysLeft + 'd'"
                    />
                  </td>
                  <td class="mono faint">{{ c.fingerprint.slice(7, 24) }}…</td>
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
