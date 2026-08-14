// API client for the Haskell monitor backend.
//
// In the Tauri shell, the backend port + token are handed over by Rust via
// the get_backend_info invoke command. In plain-browser dev mode we fall
// back to VITE_BACKEND_URL (default http://127.0.0.1:8787) with an optional
// VITE_BACKEND_TOKEN.

export interface BackendInfo {
  port: number
  token: string
}

let cached: BackendInfo | null = null

declare global {
  interface Window {
    __TAURI_INTERNALS__?: unknown
  }
}

async function invokeTauri(cmd: string): Promise<unknown> {
  const { invoke } = await import('@tauri-apps/api/core')
  return invoke(cmd)
}

export async function getBackendInfo(): Promise<BackendInfo> {
  if (cached) return cached
  if (window.__TAURI_INTERNALS__) {
    const info = (await invokeTauri('get_backend_info')) as BackendInfo
    cached = info
    return info
  }
  const port = Number(import.meta.env.VITE_BACKEND_PORT ?? 8787)
  const token = (import.meta.env.VITE_BACKEND_TOKEN as string | undefined) ?? ''
  cached = { port, token }
  return cached
}

export async function apiGet<T>(path: string): Promise<T> {
  const info = await getBackendInfo()
  const res = await fetch('http://127.0.0.1:' + info.port + path, {
    headers: info.token ? { Authorization: 'Bearer ' + info.token } : undefined,
  })
  if (!res.ok) throw new Error('GET ' + path + ' -> ' + res.status)
  return (await res.json()) as T
}

export async function openWebSocket(path: string): Promise<WebSocket> {
  const info = await getBackendInfo()
  const url = 'ws://127.0.0.1:' + info.port + path
  return new WebSocket(url)
}
