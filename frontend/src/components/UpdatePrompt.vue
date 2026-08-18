<script setup lang="ts">
import { computed, onMounted, shallowRef, ref } from 'vue'
import { check, type Update } from '@tauri-apps/plugin-updater'
import { relaunch } from '@tauri-apps/plugin-process'
import { useI18n } from 'vue-i18n'

const { t } = useI18n()

const update = shallowRef<Update | null>(null)
const dismissed = ref(false)
const installing = ref(false)
const downloaded = ref(0)
const total = ref<number | null>(null)
const error = ref<string | null>(null)

const visible = computed(() => Boolean(update.value) && !dismissed.value)
const progress = computed(() => {
  if (!total.value || total.value <= 0) return null
  return Math.min(100, Math.round(downloaded.value * 100 / total.value))
})

async function checkForUpdate() {
  if (!window.__TAURI_INTERNALS__) return
  try {
    update.value = await check()
  } catch {
    // Development builds intentionally have no updater endpoint.
  }
}

async function install() {
  if (!update.value || installing.value) return
  installing.value = true
  error.value = null
  downloaded.value = 0
  total.value = null
  try {
    await update.value.downloadAndInstall((event) => {
      if (event.event === 'Started') total.value = event.data.contentLength ?? null
      if (event.event === 'Progress') downloaded.value += event.data.chunkLength
    })
    await relaunch()
  } catch (reason) {
    error.value = reason instanceof Error ? reason.message : t('app.updateFailed')
    installing.value = false
  }
}

onMounted(() => window.setTimeout(checkForUpdate, 2500))
</script>

<template>
  <section v-if="visible" class="update-prompt" role="dialog" aria-live="polite" aria-label="Application update">
    <div class="update-mark"><UiIcon name="download" :size="17" /></div>
    <div class="update-copy">
      <div class="update-title">Server Monitor {{ update?.version }}</div>
      <div class="update-meta">{{ t('app.updateAvailable') }}</div>
      <div v-if="installing" class="update-progress">
        <span :style="{ width: (progress ?? 8) + '%' }" />
      </div>
      <div v-if="error" class="update-error">{{ error }}</div>
    </div>
    <div class="update-actions">
      <button class="btn" :disabled="installing" @click="dismissed = true">{{ t('app.later') }}</button>
      <button class="btn primary" :disabled="installing" @click="install">
        <UiIcon name="download" :size="14" />
        {{ installing ? (progress === null ? t('app.downloading') : progress + '%') : t('app.update') }}
      </button>
    </div>
  </section>
</template>
