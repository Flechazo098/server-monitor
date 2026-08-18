<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { apiGet } from '../api/client'
import { useServersStore } from '../stores/servers'
import { fmtDateTime } from '../lib/format'
import StatusChip from '../components/StatusChip.vue'
import Panel from '../components/Panel.vue'
import EmptyState from '../components/EmptyState.vue'
import { EventRowSchema, type EventRow, type Severity } from '../types'
import { useUiText } from '../i18n'

const store = useServersStore()
const tr = useUiText()
const rows = ref<EventRow[]>([])
const error = ref<string | null>(null)
const loading = ref(false)

const serverFilter = ref('all')
const typeFilter = ref('all')
const severityFilter = ref<'all' | Severity>('all')

let timer: number | undefined

async function load() {
  if (loading.value) return
  loading.value = true
  try {
    rows.value = await apiGet('/api/events?limit=300', EventRowSchema.array())
    error.value = null
  } catch (e) {
    error.value = String(e)
  } finally {
    loading.value = false
  }
}

const merged = computed<EventRow[]>(() => {
  const live = store.liveEvents.filter(
    (event) => !rows.value.some((row) => isSameEvent(row, event)),
  )
  const all = [...live, ...rows.value].sort((a, b) => b.ts.localeCompare(a.ts))
  return all.slice(0, 300)
})

function isSameEvent(a: EventRow, b: EventRow): boolean {
  return a.server === b.server
    && a.type === b.type
    && a.state === b.state
    && a.message === b.message
    && Math.abs(new Date(a.ts).getTime() - new Date(b.ts).getTime()) < 2_000
}

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

function severityLabel(severity: Severity): string {
  return tr(severity === 'critical' ? 'Critical' : severity === 'warning' ? 'Warning' : 'Info')
}

onMounted(() => {
  load()
  timer = window.setInterval(load, 30000)
})
onBeforeUnmount(() => window.clearInterval(timer))
</script>

<template>
  <div>
    <div class="page-head">
      <div>
        <h1 class="page-title">{{ tr('Events') }}</h1>
        <p class="page-sub">{{ filtered.filter((event) => event.state === 'fired').length }} {{ tr('active transitions in current view') }}</p>
      </div>
      <div class="page-side">{{ filtered.length }} {{ tr('events shown') }}</div>
    </div>

    <div v-if="error" class="error-box">{{ error }}</div>

    <div class="filter-bar">
      <select v-model="serverFilter">
        <option value="all">{{ tr('All servers') }}</option>
        <option v-for="s in store.servers" :key="s.id" :value="s.id">{{ s.name }}</option>
      </select>
      <select v-model="typeFilter">
        <option value="all">{{ tr('All types') }}</option>
        <option value="alert">{{ tr('Alerts') }}</option>
        <option value="status">{{ tr('Status') }}</option>
      </select>
      <select v-model="severityFilter">
        <option value="all">{{ tr('All severities') }}</option>
        <option value="critical">{{ tr('Critical') }}</option>
        <option value="warning">{{ tr('Warning') }}</option>
        <option value="info">{{ tr('Info') }}</option>
      </select>
      <button class="btn" @click="load"><UiIcon name="refresh" :size="13" /> {{ tr('Refresh') }}</button>
    </div>

    <Panel title="Event log" flush>
      <table class="tbl">
        <thead>
          <tr>
            <th style="width: 170px">{{ tr('Time') }}</th>
            <th>{{ tr('Server') }}</th>
            <th>{{ tr('Type') }}</th>
            <th>{{ tr('Severity') }}</th>
            <th>{{ tr('State') }}</th>
            <th>{{ tr('Message') }}</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="e in filtered" :key="e.server + e.ts + e.type + e.state + e.message">
            <td class="mono dim">{{ fmtDateTime(e.ts) }}</td>
            <td class="mono">{{ e.server }}</td>
            <td class="mono">{{ e.type }}</td>
            <td><StatusChip :kind="chipKind(e)" :label="severityLabel(e.severity)" /></td>
            <td><span class="event-state" :class="e.state === 'resolved' ? 'resolved' : e.state === 'fired' ? 'fired' : ''">{{ e.state === 'resolved' ? tr('Recovered') : e.state === 'fired' ? tr('Active') : '—' }}</span></td>
            <td class="event-message">{{ e.message }}</td>
          </tr>
        </tbody>
      </table>
      <div v-if="loading" class="loading"><span class="spinner" /> {{ tr('refreshing…') }}</div>
      <EmptyState v-if="!loading && filtered.length === 0" icon="bell" message="No events match the filters" />
    </Panel>
  </div>
</template>
