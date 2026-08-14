// Shared ECharts styling: one visual language for every chart in the app.
import type { EChartsOption } from 'echarts'

export const CHART = {
  cpu: '#4c9aff',
  mem: '#f5b544',
  disk: '#f4685c',
  load: '#22d3ee',
  rx: '#34d399',
  tx: '#a78bfa',
  caddy: '#4c9aff',
  vnstatRx: '#34d399',
  vnstatTx: '#a78bfa',
} as const

export interface SeriesSpec {
  name: string
  data: [string, number][]
  color?: string
  area?: boolean
  unit?: string
}

const AXIS = {
  axisLine: { lineStyle: { color: '#232c3d' } },
  axisTick: { show: false },
  axisLabel: { color: '#5c6878', fontSize: 10.5, fontFamily: "'Cascadia Code', Consolas, monospace" },
  splitLine: { lineStyle: { color: '#161c27' } },
}

export function lineOption(series: SeriesSpec[]): EChartsOption {
  return {
    animation: false,
    tooltip: {
      trigger: 'axis',
      backgroundColor: '#10151f',
      borderColor: '#2b3649',
      textStyle: { color: '#d7dee8', fontSize: 11.5, fontFamily: "'Cascadia Code', Consolas, monospace" },
      axisPointer: { lineStyle: { color: '#3a465c' } },
      confine: true,
      valueFormatter: undefined,
    },
    grid: { left: 46, right: 14, top: 14, bottom: 22, containLabel: false },
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
    },
    series: series.map((s) => ({
      name: s.name,
      type: 'line',
      showSymbol: false,
      smooth: false,
      lineStyle: { width: 1.6, color: s.color ?? CHART.cpu },
      itemStyle: { color: s.color ?? CHART.cpu },
      areaStyle: s.area
        ? {
            color: {
              type: 'linear',
              x: 0, y: 0, x2: 0, y2: 1,
              colorStops: [
                { offset: 0, color: hexA(s.color ?? CHART.cpu, 0.16) },
                { offset: 1, color: hexA(s.color ?? CHART.cpu, 0) },
              ],
            },
          }
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
    animation: false,
    tooltip: {
      trigger: 'axis',
      backgroundColor: '#10151f',
      borderColor: '#2b3649',
      textStyle: { color: '#d7dee8', fontSize: 11.5, fontFamily: "'Cascadia Code', Consolas, monospace" },
      axisPointer: { type: 'shadow', shadowStyle: { color: 'rgba(76,154,255,0.06)' } },
    },
    grid: { left: 46, right: 14, top: 14, bottom: 22 },
    xAxis: {
      type: 'category',
      data: categories,
      ...AXIS,
      axisLabel: { ...AXIS.axisLabel, hideOverlap: true },
    },
    yAxis: { type: 'value', ...AXIS, scale: true },
    legend: {
      top: 0,
      right: 4,
      itemWidth: 10,
      itemHeight: 10,
      icon: 'roundRect',
      textStyle: { color: '#8b97a8', fontSize: 11 },
    },
    series: series.map((s) => ({
      name: s.name,
      type: 'bar',
      barMaxWidth: 14,
      itemStyle: { color: s.color, borderRadius: [2, 2, 0, 0] },
      data: s.data,
    })),
  }
}

// "#rrggbb" -> "rgba(...)" for gradient stops.
function hexA(hex: string, alpha: number): string {
  const h = hex.replace('#', '')
  const r = parseInt(h.slice(0, 2), 16)
  const g = parseInt(h.slice(2, 4), 16)
  const b = parseInt(h.slice(4, 6), 16)
  return `rgba(${r},${g},${b},${alpha})`
}
