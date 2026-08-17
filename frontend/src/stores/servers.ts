import { defineStore } from 'pinia'
import { ref, shallowRef } from 'vue'
import { apiGet, openWebSocket } from '../api/client'
import {
  HealthInfoSchema,
  ServerStateSchema,
  WsMessageSchema,
  type EventRow,
  type HealthInfo,
  type ServerState,
  type WsMessage,
} from '../types'

const MAX_LIVE_EVENTS = 250

export const useServersStore = defineStore('servers', () => {
  const servers = shallowRef<ServerState[]>([])
  const byId = new Map<string, ServerState>()
  const connected = ref(false)
  const healthInfo = shallowRef<HealthInfo | null>(null)
  const lastError = ref<string | null>(null)
  // Live events assembled from WS messages (status transitions + alerts).
  const liveEvents = ref<EventRow[]>([])
  let ws: WebSocket | null = null
  let reconnectTimer: number | undefined
  let reconnectAttempts = 0

  function pushEvent(row: EventRow) {
    liveEvents.value = [row, ...liveEvents.value].slice(0, MAX_LIVE_EVENTS)
  }

  function apply(msg: WsMessage) {
    if (msg.type === 'snapshot') {
      byId.clear()
      for (const s of msg.servers) byId.set(s.id, s)
      servers.value = [...byId.values()]
    } else if (msg.type === 'server') {
      byId.set(msg.server, msg.data)
      servers.value = [...byId.values()]
    } else if (msg.type === 'status') {
      const s = byId.get(msg.server)
      if (s) {
        s.status = msg.data
        servers.value = [...byId.values()]
      }
      pushEvent({
        ts: new Date().toISOString(),
        server: msg.server,
        type: 'status',
        severity: msg.data === 'offline' ? 'critical' : 'info',
        state: msg.data === 'offline' ? 'fired' : 'resolved',
        message: 'server went ' + msg.data,
      })
    } else if (msg.type === 'alert') {
      const d = msg.data
      // Keep per-server active alerts in sync with the stream.
      const s = byId.get(msg.server)
      if (s) {
        if (d.state === 'fired') {
          if (!s.alerts.some((a) => a.key === d.key)) s.alerts = [...s.alerts, d]
        } else {
          s.alerts = s.alerts.filter((a) => a.key !== d.key)
        }
        servers.value = [...byId.values()]
      }
      pushEvent({
        ts: d.timestamp,
        server: msg.server,
        type: 'alert',
        severity: d.severity,
        state: d.state,
        message: d.message,
      })
    }
  }

  function scheduleReconnect() {
    if (reconnectTimer) return
    const delay = Math.min(30_000, 1_000 * 2 ** Math.min(reconnectAttempts, 5))
    reconnectAttempts += 1
    reconnectTimer = window.setTimeout(() => {
      reconnectTimer = undefined
      connect()
    }, delay)
  }

  function connect() {
    if (ws) {
      ws.onclose = null
      ws.close()
      ws = null
    }
    connected.value = false
    openWebSocket('/ws')
      .then((socket) => {
        ws = socket
        socket.onopen = () => {
          if (ws !== socket) return
          connected.value = true
          lastError.value = null
          reconnectAttempts = 0
        }
        socket.onmessage = (e) => {
          try {
            apply(WsMessageSchema.parse(JSON.parse(e.data as string)))
          } catch (err) {
            lastError.value = err instanceof Error ? err.message : 'Malformed live payload'
          }
        }
        socket.onclose = () => {
          if (ws !== socket) return
          ws = null
          connected.value = false
          scheduleReconnect()
        }
        socket.onerror = () => {
          lastError.value = 'Live connection interrupted'
          socket.close()
        }
      })
      .catch((err) => {
        lastError.value = String(err)
        scheduleReconnect()
      })
  }

  async function refresh() {
    try {
      const list = await apiGet('/api/servers', ServerStateSchema.array())
      byId.clear()
      for (const s of list) byId.set(s.id, s)
      servers.value = list
      healthInfo.value = await apiGet('/api/health', HealthInfoSchema)
      lastError.value = null
    } catch (err) {
      lastError.value = String(err)
    }
  }

  return { servers, connected, healthInfo, lastError, liveEvents, connect, refresh }
})
