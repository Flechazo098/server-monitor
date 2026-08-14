// Shared formatting helpers for the whole frontend.

const UNITS = ['B', 'KB', 'MB', 'GB', 'TB', 'PB']

export function fmtBytes(n: number): string {
  if (!Number.isFinite(n) || n < 0) return '—'
  if (n < 1024) return Math.round(n) + ' B'
  const i = Math.min(UNITS.length - 1, Math.floor(Math.log(n) / Math.log(1024)))
  const v = n / 1024 ** i
  return (v >= 100 ? v.toFixed(0) : v >= 10 ? v.toFixed(1) : v.toFixed(2)) + ' ' + UNITS[i]
}

export function fmtRate(bytesPerSec: number): string {
  if (!Number.isFinite(bytesPerSec) || bytesPerSec <= 0) return '0 B/s'
  return fmtBytes(bytesPerSec) + '/s'
}

export function fmtPct(v: number | null | undefined, digits = 1): string {
  if (v == null || !Number.isFinite(v)) return '—'
  return v.toFixed(digits) + '%'
}

export function fmtDuration(sec: number): string {
  if (!Number.isFinite(sec) || sec < 0) return '—'
  const d = Math.floor(sec / 86400)
  const h = Math.floor((sec % 86400) / 3600)
  const m = Math.floor((sec % 3600) / 60)
  if (d > 0) return d + 'd ' + h + 'h'
  if (h > 0) return h + 'h ' + m + 'm'
  return m + 'm'
}

export function fmtClock(iso: string): string {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return '—'
  return d.toLocaleTimeString([], { hour12: false })
}

export function fmtDateTime(iso: string): string {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return '—'
  return d.toLocaleString([], { hour12: false })
}

export function fmtAgo(iso: string): string {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return '—'
  const s = Math.max(0, (Date.now() - d.getTime()) / 1000)
  if (s < 60) return Math.round(s) + 's ago'
  if (s < 3600) return Math.round(s / 60) + 'm ago'
  if (s < 86400) return Math.round(s / 3600) + 'h ago'
  return Math.round(s / 86400) + 'd ago'
}

export function fmtEpoch(epoch: number | null | undefined): string {
  if (epoch == null) return '—'
  return fmtAgo(new Date(epoch * 1000).toISOString())
}

// Semantic level for a percentage metric, with per-metric thresholds.
export type Level = 'ok' | 'warn' | 'crit'

export function levelFor(kind: 'cpu' | 'mem' | 'disk', v: number): Level {
  switch (kind) {
    case 'cpu':
      return v >= 85 ? 'crit' : v >= 70 ? 'warn' : 'ok'
    case 'mem':
      return v >= 90 ? 'crit' : v >= 70 ? 'warn' : 'ok'
    case 'disk':
      return v >= 80 ? 'crit' : v >= 60 ? 'warn' : 'ok'
  }
}

export function tlsLevel(daysLeft: number): Level {
  if (daysLeft < 0) return 'crit'
  if (daysLeft < 15) return 'crit'
  if (daysLeft < 30) return 'warn'
  return 'ok'
}

export function severityToLevel(sev: string): Level {
  return sev === 'critical' ? 'crit' : sev === 'warning' ? 'warn' : 'ok'
}
