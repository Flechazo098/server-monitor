import { createRouter, createWebHashHistory } from 'vue-router'

const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: '/', name: 'overview', component: () => import('../views/OverviewView.vue') },
    { path: '/servers', name: 'servers', component: () => import('../views/ServersView.vue') },
    { path: '/servers/:id', name: 'server-detail', component: () => import('../views/ServerDetailView.vue'), props: true },
    { path: '/events', name: 'events', component: () => import('../views/EventsView.vue') },
    { path: '/history', name: 'history', component: () => import('../views/HistoryView.vue') },
    { path: '/settings', name: 'settings', component: () => import('../views/SettingsView.vue') },
  ],
})

export default router
