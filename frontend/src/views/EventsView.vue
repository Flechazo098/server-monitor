<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { apiGet } from '../api/client'
import { useServersStore } from '../stores/servers'
import { fmtDateTime } from '../lib/format'
import StatusChip from '../components/StatusChip.vue'
import Panel from '../components/Panel.vue'
import EmptyState from '../components/EmptyState.vue'
import type { EventRow, Severity } from '../types'

const store = useServersStore()
const rows = ref<EventRow[]>([])
const error = ref<string | null>(null)
const loading = ref(false)

const serverFilter = ref('all')
const typeFilter = ref('all')
const severityFilter = ref<'all' | Severity>('all')

let timer: number | undefined

async function load() {
  loading.value = true
  try {
    rows.value = await apiGet<EventRow[]>('/api/events?limit=300')
    error.value = null
  } catch (e) {
    error.value = String(e)
  } finally {
    loading.value = false
  }
}

const merged = computed<EventRow[]>(() => {
  const live = store.liveEvents.filter(
    (e) => !rows.value.some((r) => r.ts === e.ts && r.message === e.message && r.server === e.server),
  )
  const all = [...live, ...rows.value].sort((a, b) => b.ts.localeCompare(a.ts))
  return all.slice(0, 300)
})

const filtered = computed(() =>
  merged.value.filter((e) => {
    if (serverFilter.value !== 'all' && e.server !== serverFilter.value) return false
    if (typeFilter.value !== 'all' && e.type !== typeFilter.value) return false
    if (severityFilter.value !== 'all' && e.severity !== severityFilter.value) return false
    return true
  }),
)

function chipKind(e: EventRow): 'ok' | 'warn' | 'crit' | 'info' {
  if (e.state === 'resolved') return 'ok'
  return e.severity === 'critical' ? 'crit' : e.severity === 'warning' ? 'warn' : 'info'
}

onMounted(() => {
  load()
  timer = window.setInterval(load, 15000)
})
onBeforeUnmount(() => window.clearInterval(timer))
</script>

<template>
  <div>
    <div class="page-head">
      <div>
        <h1 class="page-title">Events</h1>
        <p class="page-sub">Alert transitions and status changes, newest first</p>
      </div>
      <div class="page-side">{{ filtered.length }} events shown</div>
    </div>

    <div v-if="error" class="error-box">{{ error }}</div>

    <div class="filter-bar">
      <select v-model="serverFilter">
        <option value="all">All servers</option>
        <option v-for="s in store.servers" :key="s.id" :value="s.id">{{ s.name }}</option>
      </select>
      <select v-model="typeFilter">
        <option value="all">All types</option>
        <option value="alert">Alerts</option>
        <option value="status">Status</option>
      </select>
      <select v-model="severityFilter">
        <option value="all">All severities</option>
        <option value="critical">Critical</option>
        <option value="warning">Warning</option>
        <option value="info">Info</option>
      </select>
      <button class="btn" @click="load"><UiIcon name="refresh" :size="13" /> Refresh</button>
    </div>

    <Panel title="Event log" flush>
      <table class="tbl">
        <thead>
          <tr>
            <th style="width: 170px">Time</th>
            <th>Server</th>
            <th>Type</th>
            <th>Severity</th>
            <th>State</th>
            <th>Message</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="(e, i) in filtered" :key="i">
            <td class="mono dim">{{ fmtDateTime(e.ts) }}</td>
            <td class="mono">{{ e.server }}</td>
            <td class="mono">{{ e.type }}</td>
            <td><StatusChip :kind="chipKind(e)" :label="e.severity" /></td>
            <td><span class="mono" :class="e.state === 'resolved' ? 'ok-text' : e.state === 'fired' ? 'crit-text' : 'dim'">{{ e.state || '—' }}</span></td>
            <td class="mono" style="white-space: normal">{{ e.message }}</td>
          </tr>
        </tbody>
      </table>
      <div v-if="loading" class="loading"><span class="spinner" /> refreshing…</div>
      <EmptyState v-if="!loading && filtered.length === 0" icon="bell" message="No events match the filters" />
    </Panel>
  </div>
</template>
