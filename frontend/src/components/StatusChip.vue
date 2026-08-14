<script setup lang="ts">
defineProps<{ kind: 'ok' | 'warn' | 'crit' | 'off' | 'info' | 'online' | 'offline'; label: string; dot?: boolean }>()
</script>

<template>
  <span class="chip" :class="kind">
    <span v-if="dot" class="dot" :class="kind" />
    {{ label }}
  </span>
</template>
