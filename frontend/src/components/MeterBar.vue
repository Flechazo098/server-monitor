<script setup lang="ts">
import { computed } from 'vue'
import type { Level } from '../lib/format'

const props = defineProps<{
  value: number
  level?: Level
  threshold?: number // draw a tick at this percent
  max?: number
}>()

const pct = computed(() => {
  const m = props.max ?? 100
  return Math.max(0, Math.min(100, (props.value / m) * 100))
})
</script>

<template>
  <div class="meter">
    <div
      class="meter-fill"
      :class="level ?? 'ok'"
      :style="{ width: pct + '%' }"
    />
    <div v-if="threshold != null" class="meter-mark" :style="{ left: threshold + '%' }" />
  </div>
</template>
