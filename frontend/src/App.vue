<script setup lang="ts">
import { onMounted } from 'vue'
import { useServersStore } from './stores/servers'
import UpdatePrompt from './components/UpdatePrompt.vue'

const store = useServersStore()
onMounted(() => {
  store.connect()
  store.refresh()
})

const nav = [
  { to: '/', icon: 'grid', label: 'Overview' },
  { to: '/servers', icon: 'server', label: 'Servers' },
  { to: '/events', icon: 'bell', label: 'Events' },
  { to: '/history', icon: 'clock', label: 'History' },
  { to: '/settings', icon: 'gear', label: 'Settings' },
]
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
          <div class="brand-sub">Read-only ops</div>
        </div>
      </div>
      <nav>
        <RouterLink v-for="item in nav" :key="item.to" :to="item.to" :class="{ active: $route.path === item.to || (item.to === '/servers' && $route.path.startsWith('/servers')) }">
          <span class="nav-ic"><UiIcon :name="item.icon" /></span>
          {{ item.label }}
        </RouterLink>
      </nav>
      <div class="conn">
        <span class="dot" :class="store.connected ? 'ok' : 'crit'" />
        <div>
          <div>{{ store.connected ? 'Backend connected' : 'Backend disconnected' }}</div>
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
