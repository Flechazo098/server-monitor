<script setup lang="ts">
import { computed } from 'vue'
import { useServersStore } from '../stores/servers'
import { fmtClock, fmtDuration, fmtPct, fmtRate, healthState, levelFor } from '../lib/format'
import MeterBar from '../components/MeterBar.vue'
import StatusChip from '../components/StatusChip.vue'
import Panel from '../components/Panel.vue'
import EmptyState from '../components/EmptyState.vue'
import type { ServerState } from '../types'
import { useUiText } from '../i18n'

const store = useServersStore()
const tr = useUiText()
const thresholds = computed(() => store.healthInfo?.alerts)

function exposedCount(s: ServerState): number {
  return s.ports.filter((p) => p.exposed).length
}
function sshFailed(s: ServerState): number {
  return s.sshLogins.filter((l) => !l.ok).length
}
function sectionErrorCount(s: ServerState): number {
  return Object.keys(s.sectionErrors).length
}
const totalAlerts = computed(() => store.servers.reduce((acc, s) => acc + s.alerts.length, 0))
const healthyServers = computed(() => store.servers.filter((s) => healthState(s.status, s.alerts).kind === 'ok').length)
</script>

<template>
  <div>
    <div class="page-head">
      <div>
        <h1 class="page-title">{{ tr('Servers') }}</h1>
        <p class="page-sub">{{ healthyServers }}/{{ store.servers.length }} {{ tr('healthy') }} · {{ totalAlerts }} {{ tr('active alerts') }}</p>
      </div>
      <div class="page-side">
        {{ store.servers.filter((s) => s.status === 'online').length }}/{{ store.servers.length }} {{ tr('online') }} ·
        {{ totalAlerts }} {{ tr('active alerts') }}
      </div>
    </div>

    <Panel title="Inventory" flush>
      <table class="tbl">
        <thead>
          <tr>
            <th>{{ tr('Server') }}</th>
            <th>{{ tr('Status') }}</th>
            <th>CPU</th>
            <th>{{ tr('MEM') }}</th>
            <th class="num">DISK /</th>
            <th class="num">{{ tr('Load') }}</th>
            <th class="num">{{ tr('NET rate') }}</th>
            <th class="num">{{ tr('Uptime') }}</th>
            <th class="num">{{ tr('Containers') }}</th>
            <th class="num">{{ tr('Listen ports') }}</th>
            <th class="num">{{ tr('Wildcard binds') }}</th>
            <th class="num">{{ tr('SSH fails 24h') }}</th>
            <th class="num">{{ tr('apt updates') }}</th>
            <th class="num">{{ tr('Failed sections') }}</th>
            <th class="num">{{ tr('Updated') }}</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="s in store.servers" :key="s.id" class="clickable-row" @click="$router.push('/servers/' + s.id)">
            <td class="cell-main">{{ s.name }}</td>
            <td><StatusChip :kind="healthState(s.status, s.alerts).kind" :label="healthState(s.status, s.alerts).label" dot /></td>
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
              <td class="num">{{ fmtPct(s.metrics.disk) }}</td>
              <td class="num">{{ s.metrics.load1.toFixed(2) }}</td>
              <td class="num">{{ fmtRate(s.metrics.rxRate) }} ↓ / {{ fmtRate(s.metrics.txRate) }} ↑</td>
              <td class="num">{{ fmtDuration(s.metrics.uptimeSec) }}</td>
            </template>
            <template v-else>
              <td colspan="6" class="faint">{{ tr('no metrics yet') }}</td>
            </template>
            <td class="num">{{ s.containers.length }}</td>
            <td class="num">{{ s.ports.length }}</td>
            <td class="num" :class="exposedCount(s) > 0 ? 'warn-text' : ''">{{ exposedCount(s) }}</td>
            <td class="num" :class="sshFailed(s) > 0 ? 'warn-text' : ''">{{ sshFailed(s) }}</td>
            <td class="num" :class="s.apt && s.apt.count > 0 ? 'warn-text' : ''">{{ s.apt ? s.apt.count : '—' }}</td>
            <td class="num" :class="sectionErrorCount(s) > 0 ? 'crit-text' : ''">{{ sectionErrorCount(s) }}</td>
            <td class="num faint">{{ fmtClock(s.updatedAt) }}</td>
          </tr>
        </tbody>
      </table>
      <EmptyState v-if="store.servers.length === 0" icon="server" message="No servers — check protected configuration" />
    </Panel>
  </div>
</template>
