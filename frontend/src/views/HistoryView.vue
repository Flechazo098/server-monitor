<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { apiGet } from '../api/client'
import { useServersStore } from '../stores/servers'
import { CHART } from '../lib/chartTheme'
import { fmtBytes } from '../lib/format'
import { MetricsSchema, type Metrics } from '../types'
import LineChart from '../components/LineChart.vue'
import BarsChart from '../components/BarsChart.vue'
import Panel from '../components/Panel.vue'
import EmptyState from '../components/EmptyState.vue'

const store = useServersStore()
const serverId = ref('')
const hours = ref(24)
const metric = ref<'cpu' | 'mem' | 'disk' | 'load' | 'net' | 'rx' | 'tx'>('cpu')
const rows = ref<Metrics[]>([])
const error = ref<string | null>(null)
const loading = ref(false)

async function load() {
  if (!serverId.value) return
  loading.value = true
  try {
    rows.value = await apiGet(
      '/api/history?server=' + encodeURIComponent(serverId.value) + '&hours=' + hours.value,
      MetricsSchema.array(),
    )
    error.value = null
  } catch (e) {
    error.value = String(e)
  } finally {
    loading.value = false
  }
}

watch([serverId, hours], load)

const series = computed(() => {
  switch (metric.value) {
    case 'cpu':
      return [
        { name: 'total', data: rows.value.map((m) => [m.timestamp, m.cpu] as [string, number]), color: CHART.cpu, area: true, unit: '%' as const },
        { name: 'user', data: rows.value.map((m) => [m.timestamp, m.cpuUser] as [string, number]), color: CHART.cpuUser, unit: '%' as const },
        { name: 'system', data: rows.value.map((m) => [m.timestamp, m.cpuSystem] as [string, number]), color: CHART.cpuSystem, unit: '%' as const },
        { name: 'iowait', data: rows.value.map((m) => [m.timestamp, m.cpuIowait] as [string, number]), color: CHART.cpuIowait, unit: '%' as const },
      ]
    case 'mem':
      return [{ name: 'memory used', data: rows.value.map((m) => [m.timestamp, m.mem] as [string, number]), color: CHART.mem, area: true, unit: '%' as const }]
    case 'disk':
      return [{ name: 'disk /', data: rows.value.map((m) => [m.timestamp, m.disk] as [string, number]), color: CHART.disk, area: true, unit: '%' as const }]
    case 'load':
      return [
        { name: 'load1', data: rows.value.map((m) => [m.timestamp, m.load1] as [string, number]), color: CHART.load },
        { name: 'load5', data: rows.value.map((m) => [m.timestamp, m.load5] as [string, number]), color: CHART.mem },
        { name: 'load15', data: rows.value.map((m) => [m.timestamp, m.load15] as [string, number]), color: CHART.tx },
      ]
    case 'net':
      return [
        { name: 'rx', data: rows.value.map((m) => [m.timestamp, m.rxRate] as [string, number]), color: CHART.rx, area: true, unit: 'B/s' as const },
        { name: 'tx', data: rows.value.map((m) => [m.timestamp, m.txRate] as [string, number]), color: CHART.tx, area: true, unit: 'B/s' as const },
      ]
    case 'rx':
      return [{ name: 'rx cumulative', data: rows.value.map((m) => [m.timestamp, m.rxBytes] as [string, number]), color: CHART.rx, area: true, unit: 'bytes' as const }]
    case 'tx':
      return [{ name: 'tx cumulative', data: rows.value.map((m) => [m.timestamp, m.txBytes] as [string, number]), color: CHART.tx, area: true, unit: 'bytes' as const }]
  }
})

const vnstatCats = computed(() => (store.servers.find((s) => s.id === serverId.value)?.vnstatDays ?? []).slice(-30).map((d) => d.date))
const vnstatRx = computed(() => (store.servers.find((s) => s.id === serverId.value)?.vnstatDays ?? []).slice(-30).map((d) => d.rx))
const vnstatTx = computed(() => (store.servers.find((s) => s.id === serverId.value)?.vnstatDays ?? []).slice(-30).map((d) => d.tx))

watch(
  () => store.servers.map((server) => server.id),
  (ids) => {
    if (!serverId.value && ids.length) serverId.value = ids[0]
  },
  { immediate: true },
)
</script>

<template>
  <div>
    <div class="page-head">
      <div>
        <h1 class="page-title">History</h1>
        <p class="page-sub">{{ hours }}h window · {{ rows.length }} persisted samples</p>
      </div>
      <div class="page-side mono">{{ rows.length }} samples</div>
    </div>

    <div class="filter-bar">
      <select v-model="serverId">
        <option v-for="s in store.servers" :key="s.id" :value="s.id">{{ s.name }}</option>
      </select>
      <select v-model.number="hours">
        <option :value="1">Last hour</option>
        <option :value="6">Last 6 hours</option>
        <option :value="24">Last 24 hours</option>
        <option :value="168">Last 7 days</option>
      </select>
      <select v-model="metric">
        <option value="cpu">CPU %</option>
        <option value="mem">Memory %</option>
        <option value="disk">Disk / %</option>
        <option value="load">Load average</option>
        <option value="net">Net throughput</option>
        <option value="rx">Traffic rx (today)</option>
        <option value="tx">Traffic tx (today)</option>
      </select>
      <button class="btn" @click="load"><UiIcon name="refresh" :size="13" /> Refresh</button>
    </div>

    <div v-if="error" class="error-box">{{ error }}</div>

    <div class="stack">
      <Panel title="Metric history" flush>
        <div v-if="loading && rows.length === 0" class="loading"><span class="spinner" /> loading…</div>
        <template v-else-if="rows.length">
          <div class="panel-body"><LineChart :series="series" height="260px" :min="['cpu', 'mem', 'disk', 'net'].includes(metric) ? 0 : null" :max="['cpu', 'mem', 'disk'].includes(metric) ? 100 : null" /></div>
        </template>
        <EmptyState v-else icon="clock" message="No samples in this window" />
      </Panel>

      <Panel title="Traffic per day · vnStat (30 days)" flush>
        <template v-if="vnstatCats.length">
          <div class="panel-body">
            <BarsChart
              :categories="vnstatCats"
              :series="[
                { name: 'rx', data: vnstatRx, color: CHART.vnstatRx },
                { name: 'tx', data: vnstatTx, color: CHART.vnstatTx },
              ]"
              height="220px"
            />
          </div>
          <div class="panel-side" style="padding: 0 14px 12px; justify-content: flex-end">
            <span class="mono faint">↓ {{ fmtBytes(vnstatRx.reduce((a, b) => a + b, 0)) }} · ↑ {{ fmtBytes(vnstatTx.reduce((a, b) => a + b, 0)) }} (30d)</span>
          </div>
        </template>
        <EmptyState v-else icon="net" message="vnStat daily data unavailable" />
      </Panel>
    </div>
  </div>
</template>
