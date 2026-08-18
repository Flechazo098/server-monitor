<script setup lang="ts">
import { useUiText } from '../i18n'

defineProps<{ icon?: string; message: string }>()
const tr = useUiText()
</script>

<template>
  <div class="empty">
    <span v-if="icon" class="empty-ic"><UiIcon :name="icon" :size="22" /></span>
    <span>{{ tr(message) }}</span>
  </div>
</template>
