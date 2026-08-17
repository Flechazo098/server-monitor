<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref, watch } from 'vue'
import * as echarts from 'echarts/core'
import { LineChart as ELineChart } from 'echarts/charts'
import { GridComponent, LegendComponent, TooltipComponent } from 'echarts/components'
import { CanvasRenderer } from 'echarts/renderers'
import { lineOption, type SeriesSpec } from '../lib/chartTheme'

echarts.use([ELineChart, GridComponent, LegendComponent, TooltipComponent, CanvasRenderer])

const props = withDefaults(
  defineProps<{
    series: SeriesSpec[]
    height?: string
    min?: number | null
    max?: number | null
  }>(),
  { height: '200px', min: null, max: null },
)

const el = ref<HTMLDivElement | null>(null)
let chart: echarts.ECharts | null = null
let ro: ResizeObserver | null = null

function render() {
  if (!chart) return
  const opt = lineOption(props.series)
  if (props.min != null || props.max != null) {
    Object.assign(opt.yAxis as object, { min: props.min ?? undefined, max: props.max ?? undefined })
  }
  chart.setOption(opt, { notMerge: true, lazyUpdate: true })
}

onMounted(() => {
  if (!el.value) return
  chart = echarts.init(el.value)
  render()
  ro = new ResizeObserver(() => chart?.resize())
  ro.observe(el.value)
})

watch(() => props.series, render, { deep: true })
onBeforeUnmount(() => {
  ro?.disconnect()
  chart?.dispose()
  chart = null
})
</script>

<template>
  <div ref="el" :style="{ height, width: '100%' }"></div>
</template>
