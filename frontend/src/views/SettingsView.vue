<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { apiGet, getBackendInfo } from '../api/client'
import { useServersStore } from '../stores/servers'
import Panel from '../components/Panel.vue'
import type { HealthInfo } from '../types'

const store = useServersStore()
const port = ref<number | null>(null)
const token = ref('')
const mode = ref<'tauri' | 'browser'>('browser')
const health = ref<HealthInfo | null>(null)

onMounted(async () => {
  const info = await getBackendInfo()
  port.value = info.port
  token.value = info.token
  mode.value = window.__TAURI_INTERNALS__ ? 'tauri' : 'browser'
  try {
    health.value = await apiGet<HealthInfo>('/api/health')
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
        <p class="faint" style="font-size: 11.5px; margin-top: 12px; line-height: 1.6">
          The backend binds only to loopback and is started/stopped by the Tauri
          shell. Every request carries an <code class="mono">Authorization: Bearer</code> header.
          WebSocket frames are read-only metric pushes.
        </p>
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
      <Panel title="Alert thresholds (config.json → alerts)">
        <div class="kv">
          <div class="kv-row"><span class="k">Disk usage</span><span class="v">> 80% (critical)</span></div>
          <div class="kv-row"><span class="k">Memory</span><span class="v">> 90% (critical)</span></div>
          <div class="kv-row"><span class="k">CPU sustained</span><span class="v">> 85% for 180s (warning)</span></div>
          <div class="kv-row"><span class="k">TLS expiry</span><span class="v">< 30 days (warning)</span></div>
          <div class="kv-row"><span class="k">Health check</span><span class="v">≥ 3 consecutive failures (critical)</span></div>
          <div class="kv-row"><span class="k">Backup age</span><span class="v">> 26h (critical)</span></div>
          <div class="kv-row"><span class="k">Re-alert cooldown</span><span class="v">3600s</span></div>
        </div>
      </Panel>

      <Panel title="Read-only by design">
        <p class="dim" style="font-size: 12.5px; line-height: 1.7">
          This monitor exposes GET endpoints only. There is no remote shell, no
          command execution endpoint, and no way to mutate the monitored servers
          from the UI. Every collection runs a fixed, embedded read-only script
          over SSH; credentials and secrets never leave the local config and are
          never written to the database or logs.
        </p>
      </Panel>
    </div>
  </div>
</template>
