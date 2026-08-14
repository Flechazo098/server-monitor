<script setup lang="ts">
import { computed } from 'vue'
import { iconPaths } from './icons'

const props = defineProps<{ name: string; size?: number }>()
const paths = computed(() => iconPaths(props.name))
</script>

<template>
  <svg
    :width="size ?? 16"
    :height="size ?? 16"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    stroke-width="1.6"
    stroke-linecap="round"
    stroke-linejoin="round"
    aria-hidden="true"
  >
    <path v-for="(d, i) in paths" :key="i" :d="d" />
  </svg>
</template>
