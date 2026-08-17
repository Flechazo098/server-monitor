// API client for the Haskell monitor backend. Every payload is decoded at
// the language boundary; TypeScript types alone are not treated as proof.
//
// In the Tauri shell, the backend port + token are handed over by Rust via
// the get_backend_info invoke command. In plain-browser dev mode we fall
// back to VITE_BACKEND_URL (default http://127.0.0.1:8787) with an optional
// VITE_BACKEND_TOKEN.

import { z, type ZodType } from 'zod'
import { invoke } from '@tauri-apps/api/core'

const BackendInfoSchema = z.strictObject({
  port: z.number().int().min(1).max(65535),
  token: z.string().min(1),
})
export type BackendInfo = z.infer<typeof BackendInfoSchema>

export class ContractError extends Error {
  constructor(source: string, issues: z.core.$ZodIssue[]) {
    const detail = issues
      .slice(0, 3)
      .map((issue) => `${issue.path.join('.') || '<root>'}: ${issue.message}`)
      .join('; ')
    super(`Backend contract mismatch at ${source}: ${detail}`)
    this.name = 'ContractError'
  }
}

export function decode<T>(source: string, schema: ZodType<T>, value: unknown): T {
  const parsed = schema.safeParse(value)
  if (!parsed.success) throw new ContractError(source, parsed.error.issues)
  return parsed.data
}

let cached: BackendInfo | null = null

declare global {
  interface Window {
    __TAURI_INTERNALS__?: unknown
  }
}

export async function getBackendInfo(): Promise<BackendInfo> {
  if (cached) return cached
  if (window.__TAURI_INTERNALS__) {
    const info = decode('get_backend_info', BackendInfoSchema, await invoke('get_backend_info'))
    cached = info
    return info
  }
  const port = Number(import.meta.env.VITE_BACKEND_PORT ?? 8787)
  const token = (import.meta.env.VITE_BACKEND_TOKEN as string | undefined) ?? ''
  cached = { port, token }
  return cached
}

export async function apiGet<T>(path: string, schema: ZodType<T>): Promise<T> {
  const info = await getBackendInfo()
  const res = await fetch('http://127.0.0.1:' + info.port + path, {
    headers: info.token ? { Authorization: 'Bearer ' + info.token } : undefined,
    signal: AbortSignal.timeout(10_000),
  })
  if (!res.ok) throw new Error('Request failed (' + res.status + ')')
  return decode(path, schema, await res.json())
}

export async function openWebSocket(path: string): Promise<WebSocket> {
  const info = await getBackendInfo()
  const separator = path.includes('?') ? '&' : '?'
  const url = 'ws://127.0.0.1:' + info.port + path + separator + 'token=' + encodeURIComponent(info.token)
  return new WebSocket(url)
}
