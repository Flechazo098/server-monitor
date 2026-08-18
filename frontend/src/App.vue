<script setup lang="ts">
import { computed, onMounted } from 'vue'
import { useI18n } from 'vue-i18n'
import { useServersStore } from './stores/servers'
import UpdatePrompt from './components/UpdatePrompt.vue'
import { useAppLocale } from './i18n'

const store = useServersStore()
const { t } = useI18n()
const { locale } = useAppLocale()
onMounted(() => {
  store.connect()
  store.refresh()
})

const nav = computed(() => [
  { to: '/', icon: 'grid', label: t('nav.overview') },
  { to: '/servers', icon: 'server', label: t('nav.servers') },
  { to: '/events', icon: 'bell', label: t('nav.events') },
  { to: '/history', icon: 'clock', label: t('nav.history') },
  { to: '/settings', icon: 'gear', label: t('nav.settings') },
])
</script>

<template>
  <div class="layout">
    <aside class="sidebar">
      <div class="brand">
        <div class="brand-mark">
          <UiIcon name="activity" :size="14" />
        </div>
        <div>
          <div class="brand-name">Server Monitor</div>
          <div class="brand-sub">{{ t('app.subtitle') }}</div>
        </div>
      </div>
      <nav>
        <RouterLink v-for="item in nav" :key="item.to" :to="item.to" :class="{ active: $route.path === item.to || (item.to === '/servers' && $route.path.startsWith('/servers')) }">
          <span class="nav-ic"><UiIcon :name="item.icon" /></span>
          {{ item.label }}
        </RouterLink>
      </nav>
      <label class="locale-switch">
        <UiIcon name="globe" :size="13" />
        <select v-model="locale" :aria-label="t('app.language')">
          <option value="zh-CN">{{ t('app.chinese') }}</option>
          <option value="en">{{ t('app.english') }}</option>
        </select>
      </label>
      <div class="conn">
        <span class="dot" :class="store.connected ? 'ok' : 'crit'" />
        <div>
          <div>{{ store.connected ? t('app.connected') : t('app.disconnected') }}</div>
          <div v-if="store.lastError" class="conn-err">{{ store.lastError }}</div>
        </div>
      </div>
    </aside>
    <main class="content">
      <RouterView />
    </main>
    <UpdatePrompt />
  </div>
</template>
