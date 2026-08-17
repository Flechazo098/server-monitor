<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { apiGet, getBackendInfo } from '../api/client'
import { useServersStore } from '../stores/servers'
import Panel from '../components/Panel.vue'
import { HealthInfoSchema, type HealthInfo } from '../types'

const store = useServersStore()
const port = ref<number | null>(null)
const mode = ref<'tauri' | 'browser'>('browser')
const health = ref<HealthInfo | null>(null)

onMounted(async () => {
  mode.value = window.__TAURI_INTERNALS__ ? 'tauri' : 'browser'
  try {
    const info = await getBackendInfo()
    port.value = info.port
    health.value = await apiGet('/api/health', HealthInfoSchema)
  } catch {
    health.value = null
  }
})
</script>

<template>
  <div>
    <div class="page-head">
      <div>
        <h1 class="page-title">Settings</h1>
        <p class="page-sub">Backend connection, sampling policy and alert thresholds (read-only)</p>
      </div>
    </div>

    <div class="grid-2">
      <Panel title="Backend connection">
        <div class="kv">
          <div class="kv-row"><span class="k">Mode</span><span class="v">{{ mode }}</span></div>
          <div class="kv-row"><span class="k">Address</span><span class="v">{{ port != null ? '127.0.0.1:' + port : '—' }}</span></div>
          <div class="kv-row"><span class="k">API health</span><span class="v">{{ health ? 'ok (' + health.online + '/' + health.servers + ' online)' : 'unreachable' }}</span></div>
        </div>
        <div class="policy-note kv">
          <div class="kv-row"><span class="k">Bind scope</span><span class="v ok-text">loopback only</span></div>
          <div class="kv-row"><span class="k">REST auth</span><span class="v">Bearer token</span></div>
          <div class="kv-row"><span class="k">WebSocket auth</span><span class="v">session token</span></div>
        </div>
      </Panel>

      <Panel title="Monitoring policy">
        <div class="kv">
          <div class="kv-row"><span class="k">Servers monitored</span><span class="v">{{ store.servers.length }}</span></div>
          <div class="kv-row"><span class="k">Backend connected</span><span class="v" :class="store.connected ? 'ok-text' : 'crit-text'">{{ store.connected ? 'yes' : 'no' }}</span></div>
          <div class="kv-row"><span class="k">Live events buffered</span><span class="v">{{ store.liveEvents.length }}</span></div>
        </div>
      </Panel>
    </div>

    <div class="grid-2" style="margin-top: 12px">
      <Panel title="Alert thresholds · active configuration">
        <div v-if="health" class="kv">
          <div class="kv-row"><span class="k">Disk usage</span><span class="v">≥ {{ health.alerts.diskPct }}% · critical</span></div>
          <div class="kv-row"><span class="k">Memory</span><span class="v">≥ {{ health.alerts.memPct }}% · critical</span></div>
          <div class="kv-row"><span class="k">CPU sustained</span><span class="v">≥ {{ health.alerts.cpuPct }}% for {{ health.alerts.cpuSustainSec }}s · warning</span></div>
          <div class="kv-row"><span class="k">TLS expiry</span><span class="v">&lt; {{ health.alerts.tlsMinDays }} days · warning</span></div>
          <div class="kv-row"><span class="k">Health check</span><span class="v">{{ health.alerts.healthMaxFails }} consecutive failures · critical</span></div>
          <div class="kv-row"><span class="k">Backup age</span><span class="v">≥ {{ health.alerts.backupMaxAgeHours }}h · critical</span></div>
          <div class="kv-row"><span class="k">Re-alert cooldown</span><span class="v">{{ health.alerts.cooldownSec }}s</span></div>
        </div>
        <div v-else class="loading"><span class="spinner" /> loading policy…</div>
      </Panel>

      <Panel title="Collection policy · active configuration">
        <div v-if="health" class="kv">
          <div class="kv-row"><span class="k">Inventory sample</span><span class="v">{{ health.collection.fullIntervalSec }}s</span></div>
          <div class="kv-row"><span class="k">SSH timeout</span><span class="v">{{ health.collection.timeoutSec }}s</span></div>
          <div class="kv-row"><span class="k">Failure backoff cap</span><span class="v">{{ health.collection.backoffMaxSec }}s</span></div>
          <div class="kv-row"><span class="k">History retention</span><span class="v">{{ health.collection.retentionDays }} days</span></div>
        </div>
        <div class="policy-note kv">
          <div class="kv-row"><span class="k">API surface</span><span class="v ok-text">GET only</span></div>
          <div class="kv-row"><span class="k">Remote mutation</span><span class="v ok-text">disabled</span></div>
          <div class="kv-row"><span class="k">Credential logging</span><span class="v ok-text">disabled</span></div>
        </div>
      </Panel>
    </div>
  </div>
</template>
