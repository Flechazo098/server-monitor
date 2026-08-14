<script setup lang="ts">
import { computed } from 'vue'
import { useServersStore } from '../stores/servers'
import { fmtClock, fmtDuration, fmtPct, fmtRate, levelFor } from '../lib/format'
import MeterBar from '../components/MeterBar.vue'
import StatusChip from '../components/StatusChip.vue'
import Panel from '../components/Panel.vue'
import EmptyState from '../components/EmptyState.vue'
import type { ServerState } from '../types'

const store = useServersStore()

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
</script>

<template>
  <div>
    <div class="page-head">
      <div>
        <h1 class="page-title">Servers</h1>
        <p class="page-sub">Live state and operational detail of every monitored host</p>
      </div>
      <div class="page-side">
        {{ store.servers.filter((s) => s.status === 'online').length }}/{{ store.servers.length }} online ·
        {{ totalAlerts }} active alerts
      </div>
    </div>

    <Panel title="Inventory" flush>
      <table class="tbl">
        <thead>
          <tr>
            <th>Server</th>
            <th>Status</th>
            <th>CPU</th>
            <th>MEM</th>
            <th class="num">DISK /</th>
            <th class="num">Load</th>
            <th class="num">NET rate</th>
            <th class="num">Uptime</th>
            <th class="num">Containers</th>
            <th class="num">Listen ports</th>
            <th class="num">Exposed</th>
            <th class="num">SSH fails 24h</th>
            <th class="num">apt updates</th>
            <th class="num">Failed sections</th>
            <th class="num">Updated</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="s in store.servers" :key="s.id" class="clickable-row" @click="$router.push('/servers/' + s.id)">
            <td class="cell-main">{{ s.name }}</td>
            <td><StatusChip :kind="s.status" :label="s.status" dot /></td>
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
              <td class="num">{{ fmtPct(s.metrics.disk) }}</td>
              <td class="num">{{ s.metrics.load1.toFixed(2) }}</td>
              <td class="num">{{ fmtRate(s.metrics.rxRate) }} ↓ / {{ fmtRate(s.metrics.txRate) }} ↑</td>
              <td class="num">{{ fmtDuration(s.metrics.uptimeSec) }}</td>
            </template>
            <template v-else>
              <td colspan="6" class="faint">no metrics yet</td>
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
      <EmptyState v-if="store.servers.length === 0" icon="server" message="No servers — check backend config.json" />
    </Panel>
  </div>
</template>
