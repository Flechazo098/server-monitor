<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { relaunch } from '@tauri-apps/plugin-process'
import { useI18n } from 'vue-i18n'
import { apiGet, getBackendInfo, getMonitorConfig, saveMonitorConfig } from '../api/client'
import { useServersStore } from '../stores/servers'
import Panel from '../components/Panel.vue'
import { HealthInfoSchema, MonitorConfigSchema, type HealthInfo, type MonitorConfig } from '../types'
import { useUiText } from '../i18n'

interface ServerDraft extends Omit<MonitorConfig['servers'][number], 'publicUrls' | 'certHosts'> {
  publicUrlsText: string
  certHostsText: string
}

interface ConfigDraft extends Omit<MonitorConfig, 'servers'> {
  servers: ServerDraft[]
}

const store = useServersStore()
const { t } = useI18n()
const tr = useUiText()
const port = ref<number | null>(null)
const mode = ref<'tauri' | 'browser'>('browser')
const health = ref<HealthInfo | null>(null)
const draft = ref<ConfigDraft | null>(null)
const loading = ref(true)
const saving = ref(false)
const loadError = ref<string | null>(null)
const saveError = ref<string | null>(null)
const saved = ref(false)

function toDraft(config: MonitorConfig): ConfigDraft {
  return {
    ...config,
    servers: config.servers.map((server) => ({
      ...server,
      publicUrlsText: server.publicUrls.join('\n'),
      certHostsText: server.certHosts.join('\n'),
    })),
  }
}

function lines(value: string): string[] {
  return value.split(/\r?\n/).map((item) => item.trim()).filter(Boolean)
}

function fromDraft(value: ConfigDraft): MonitorConfig {
  const candidate = {
    ...value,
    servers: value.servers.map(({ publicUrlsText, certHostsText, ...server }) => ({
      ...server,
      publicUrls: lines(publicUrlsText),
      certHosts: lines(certHostsText),
    })),
  }
  return MonitorConfigSchema.parse(candidate)
}

function addServer() {
  draft.value?.servers.push({
    id: `server-${(draft.value.servers.length ?? 0) + 1}`,
    name: '',
    sshHost: '',
    sshPort: 22,
    sshUser: '',
    sshKey: '',
    intervalSec: 20,
    publicUrlsText: '',
    certHostsText: '',
  })
}

async function save() {
  if (!draft.value || saving.value) return
  saving.value = true
  saveError.value = null
  saved.value = false
  try {
    await saveMonitorConfig(fromDraft(draft.value))
    saved.value = true
  } catch (error) {
    saveError.value = error instanceof Error ? error.message : String(error)
  } finally {
    saving.value = false
  }
}

onMounted(async () => {
  mode.value = window.__TAURI_INTERNALS__ ? 'tauri' : 'browser'
  try {
    draft.value = toDraft(await getMonitorConfig())
  } catch (error) {
    loadError.value = error instanceof Error ? error.message : String(error)
  } finally {
    loading.value = false
  }
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
        <h1 class="page-title">{{ t('settings.title') }}</h1>
        <p class="page-sub">{{ t('settings.subtitle') }}</p>
      </div>
      <div class="page-side"><span class="security-badge"><UiIcon name="lock" :size="12" /> {{ t('settings.encrypted') }}</span></div>
    </div>

    <div v-if="loadError" class="error-box"><strong>{{ t('settings.loadFailed') }}</strong><br>{{ loadError }}</div>
    <div v-if="loading" class="loading"><span class="spinner" /> {{ tr('loading…') }}</div>

    <template v-if="draft">
      <div class="settings-summary">
        <Panel :title="t('settings.security')">
          <p class="security-copy">{{ t('settings.securityBody') }}</p>
        </Panel>
        <Panel :title="t('settings.connection')">
          <div class="kv">
            <div class="kv-row"><span class="k">{{ tr('Mode') }}</span><span class="v">{{ mode }}</span></div>
            <div class="kv-row"><span class="k">{{ tr('Address') }}</span><span class="v">{{ port != null ? '127.0.0.1:' + port : '—' }}</span></div>
            <div class="kv-row"><span class="k">{{ tr('Status') }}</span><span class="v" :class="store.connected ? 'ok-text' : 'crit-text'">{{ store.connected ? tr('Online') : tr('Offline') }}</span></div>
          </div>
        </Panel>
        <Panel :title="t('settings.policy')">
          <div class="kv">
            <div class="kv-row"><span class="k">{{ tr('Servers') }}</span><span class="v">{{ store.servers.length }}</span></div>
            <div class="kv-row"><span class="k">{{ tr('Live events') }}</span><span class="v">{{ store.liveEvents.length }}</span></div>
            <div class="kv-row"><span class="k">{{ tr('API health') }}</span><span class="v">{{ health ? health.online + '/' + health.servers : '—' }}</span></div>
          </div>
        </Panel>
      </div>

      <form class="config-form" @submit.prevent="save">
        <div class="grid-2">
          <Panel :title="t('settings.alerts')">
            <div class="form-grid">
              <label><span>{{ tr('Disk usage threshold') }}</span><input v-model.number="draft.alerts.diskPct" type="number" min="1" max="100" step="0.1"><small>%</small></label>
              <label><span>{{ tr('Memory threshold') }}</span><input v-model.number="draft.alerts.memPct" type="number" min="1" max="100" step="0.1"><small>%</small></label>
              <label><span>{{ tr('CPU threshold') }}</span><input v-model.number="draft.alerts.cpuPct" type="number" min="1" max="100" step="0.1"><small>%</small></label>
              <label><span>{{ tr('CPU sustain time') }}</span><input v-model.number="draft.alerts.cpuSustainSec" type="number" min="0"><small>s</small></label>
              <label><span>{{ tr('TLS minimum validity') }}</span><input v-model.number="draft.alerts.tlsMinDays" type="number" min="0"><small>{{ tr('days') }}</small></label>
              <label><span>{{ tr('Health failure count') }}</span><input v-model.number="draft.alerts.healthMaxFails" type="number" min="1"><small>{{ tr('times') }}</small></label>
              <label><span>{{ tr('Backup maximum age') }}</span><input v-model.number="draft.alerts.backupMaxAgeHours" type="number" min="1"><small>h</small></label>
              <label><span>{{ tr('Re-alert cooldown') }}</span><input v-model.number="draft.alerts.cooldownSec" type="number" min="0"><small>s</small></label>
            </div>
          </Panel>

          <Panel :title="t('settings.collection')">
            <div class="form-grid">
              <label><span>{{ tr('Full inventory interval') }}</span><input v-model.number="draft.collection.fullIntervalSec" type="number" min="10" max="86400"><small>s</small></label>
              <label><span>{{ tr('SSH collection timeout') }}</span><input v-model.number="draft.collection.timeoutSec" type="number" min="5" max="300"><small>s</small></label>
              <label><span>{{ tr('History retention') }}</span><input v-model.number="draft.collection.retentionDays" type="number" min="1" max="3650"><small>{{ tr('days') }}</small></label>
              <label><span>{{ tr('Failure backoff cap') }}</span><input v-model.number="draft.collection.backoffMaxSec" type="number" min="5" max="3600"><small>s</small></label>
              <label class="wide"><span>{{ tr('Database path') }}</span><input v-model.trim="draft.dbPath" type="text"></label>
            </div>
          </Panel>
        </div>

        <div class="section-heading">
          <div><h2>{{ t('settings.servers') }}</h2><span>{{ draft.servers.length }}</span></div>
          <button class="btn" type="button" @click="addServer"><UiIcon name="plus" :size="13" /> {{ t('settings.addServer') }}</button>
        </div>

        <div class="server-editor-list">
          <Panel v-for="(server, index) in draft.servers" :key="index" :title="t('settings.server', { index: index + 1 })">
            <template #side>
              <button class="btn danger" type="button" :disabled="draft.servers.length === 1" @click="draft.servers.splice(index, 1)">{{ t('settings.removeServer') }}</button>
            </template>
            <div class="server-form-grid">
              <label><span>ID</span><input v-model.trim="server.id" type="text"></label>
              <label><span>{{ tr('Display name') }}</span><input v-model.trim="server.name" type="text"></label>
              <label><span>{{ tr('SSH host') }}</span><input v-model.trim="server.sshHost" type="text" spellcheck="false"></label>
              <label><span>{{ tr('SSH port') }}</span><input v-model.number="server.sshPort" type="number" min="1" max="65535"></label>
              <label><span>{{ tr('SSH user') }}</span><input v-model.trim="server.sshUser" type="text" spellcheck="false"></label>
              <label class="span-2"><span>{{ tr('SSH private key path') }}</span><input v-model.trim="server.sshKey" type="text" spellcheck="false"></label>
              <label><span>{{ tr('Fast sample interval') }}</span><input v-model.number="server.intervalSec" type="number" min="5" max="3600"><small>s</small></label>
              <label class="span-2"><span>{{ tr('Public URLs') }}</span><textarea v-model="server.publicUrlsText" rows="3" :placeholder="t('settings.urlsHint')" spellcheck="false" /></label>
              <label class="span-2"><span>{{ tr('TLS certificate hosts') }}</span><textarea v-model="server.certHostsText" rows="3" :placeholder="t('settings.hostsHint')" spellcheck="false" /></label>
            </div>
          </Panel>
        </div>

        <div v-if="saveError" class="error-box"><strong>{{ t('settings.saveFailed') }}</strong><br>{{ saveError }}</div>
        <div v-if="saved" class="success-box"><UiIcon name="check" :size="14" /> {{ t('settings.saved') }} <button class="btn" type="button" @click="relaunch">{{ t('settings.restart') }}</button></div>
        <div class="form-actions">
          <span>{{ tr('Changes affect only local monitoring and never mutate a server.') }}</span>
          <button class="btn primary" type="submit" :disabled="saving"><UiIcon name="lock" :size="13" /> {{ saving ? t('settings.saving') : t('settings.save') }}</button>
        </div>
      </form>
    </template>
  </div>
</template>
