// Shared ECharts styling: one visual language for every chart in the app.
import type { EChartsOption } from 'echarts'

export const CHART = {
  cpu: '#697254',
  cpuUser: '#3f7764',
  cpuSystem: '#59758a',
  cpuIowait: '#aa4e41',
  mem: '#a86d24',
  disk: '#aa4e41',
  load: '#637f7a',
  rx: '#3f7764',
  tx: '#7b668b',
  caddy: '#697254',
  vnstatRx: '#3f7764',
  vnstatTx: '#7b668b',
} as const

export interface SeriesSpec {
  name: string
  data: [string, number][]
  color?: string
  area?: boolean
  unit?: '%' | 'B/s' | 'bytes' | 'count'
}

const AXIS = {
  axisLine: { lineStyle: { color: '#c9bca5' } },
  axisTick: { show: false },
  axisLabel: { color: '#887e6d', fontSize: 10.5, fontFamily: "'Cascadia Code', Consolas, monospace" },
  splitLine: { lineStyle: { color: '#e2d7c4' } },
}

export function lineOption(series: SeriesSpec[]): EChartsOption {
  return {
    animation: true,
    animationDuration: 320,
    animationDurationUpdate: 240,
    animationEasing: 'cubicOut',
    animationEasingUpdate: 'cubicOut',
    tooltip: {
      trigger: 'axis',
      backgroundColor: '#fffaf0',
      borderColor: '#bdae91',
      textStyle: { color: '#2f2b23', fontSize: 11.5, fontFamily: "'Cascadia Code', Consolas, monospace" },
      axisPointer: { lineStyle: { color: '#8f856f' } },
      confine: true,
      valueFormatter: undefined,
    },
    legend: series.length > 1 ? {
      top: 0,
      right: 4,
      itemWidth: 12,
      itemHeight: 2,
      textStyle: { color: '#6f6759', fontSize: 10.5 },
    } : undefined,
    grid: { left: 48, right: 14, top: series.length > 1 ? 30 : 14, bottom: 24, containLabel: false },
    xAxis: {
      type: 'time',
      ...AXIS,
      axisLabel: { ...AXIS.axisLabel, hideOverlap: true },
    },
    yAxis: {
      type: 'value',
      ...AXIS,
      scale: true,
      splitNumber: 4,
      axisLabel: { ...AXIS.axisLabel, formatter: (value: number) => formatAxis(value, series[0]?.unit) },
    },
    series: series.map((s) => ({
      name: s.name,
      type: 'line',
      showSymbol: s.data.length < 2,
      symbolSize: 5,
      smooth: 0.12,
      lineStyle: { width: 1.6, color: s.color ?? CHART.cpu },
      itemStyle: { color: s.color ?? CHART.cpu },
      tooltip: { valueFormatter: (value) => formatValue(Number(Array.isArray(value) ? value[0] : value), s.unit) },
      areaStyle: s.area
        ? { color: hexA(s.color ?? CHART.cpu, 0.08) }
        : undefined,
      data: s.data,
    })),
  }
}

export function barOption(
  categories: string[],
  series: { name: string; data: number[]; color: string }[],
): EChartsOption {
  return {
    animation: true,
    animationDuration: 360,
    animationDurationUpdate: 260,
    tooltip: {
      trigger: 'axis',
      backgroundColor: '#fffaf0',
      borderColor: '#bdae91',
      textStyle: { color: '#2f2b23', fontSize: 11.5, fontFamily: "'Cascadia Code', Consolas, monospace" },
      axisPointer: { type: 'shadow', shadowStyle: { color: 'rgba(105,114,84,0.08)' } },
    },
    grid: { left: 46, right: 14, top: 14, bottom: 22 },
    xAxis: {
      type: 'category',
      data: categories,
      ...AXIS,
      axisLabel: { ...AXIS.axisLabel, hideOverlap: true },
    },
    yAxis: {
      type: 'value',
      ...AXIS,
      scale: true,
      axisLabel: { ...AXIS.axisLabel, formatter: (value: number) => compactBytes(value) },
    },
    legend: {
      top: 0,
      right: 4,
      itemWidth: 10,
      itemHeight: 10,
      icon: 'roundRect',
      textStyle: { color: '#6f6759', fontSize: 11 },
    },
    series: series.map((s) => ({
      name: s.name,
      type: 'bar',
      barMaxWidth: 14,
      itemStyle: { color: s.color, borderRadius: [2, 2, 0, 0] },
      tooltip: { valueFormatter: (value) => compactBytes(Number(Array.isArray(value) ? value[0] : value)) },
      data: s.data,
    })),
  }
}

function formatAxis(value: number, unit?: SeriesSpec['unit']): string {
  if (unit === '%') return value + '%'
  if (unit === 'B/s' || unit === 'bytes') return compactBytes(value)
  return Number.isInteger(value) ? String(value) : value.toFixed(1)
}

function formatValue(value: number, unit?: SeriesSpec['unit']): string {
  if (unit === '%') return value.toFixed(1) + '%'
  if (unit === 'B/s') return compactBytes(value) + '/s'
  if (unit === 'bytes') return compactBytes(value)
  return value.toLocaleString()
}

function compactBytes(value: number): string {
  if (!Number.isFinite(value) || value <= 0) return '0 B'
  const units = ['B', 'KB', 'MB', 'GB', 'TB']
  const index = Math.min(units.length - 1, Math.floor(Math.log(value) / Math.log(1024)))
  const scaled = value / 1024 ** index
  return (scaled >= 100 ? scaled.toFixed(0) : scaled.toFixed(1)) + ' ' + units[index]
}

// "#rrggbb" -> "rgba(...)" for gradient stops.
function hexA(hex: string, alpha: number): string {
  const h = hex.replace('#', '')
  const r = parseInt(h.slice(0, 2), 16)
  const g = parseInt(h.slice(2, 4), 16)
  const b = parseInt(h.slice(4, 6), 16)
  return `rgba(${r},${g},${b},${alpha})`
}
