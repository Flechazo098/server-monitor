<script setup lang="ts">
import { useUiText } from '../i18n'

defineProps<{ kind: 'ok' | 'warn' | 'crit' | 'off' | 'info' | 'online' | 'offline'; label: string; dot?: boolean }>()
const tr = useUiText()
</script>

<template>
  <span class="chip" :class="kind">
    <span v-if="dot" class="dot" :class="kind" />
    {{ tr(label) }}
  </span>
</template>
