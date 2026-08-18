<script setup lang="ts">
import { useUiText } from '../i18n'

defineProps<{ title?: string; flush?: boolean }>()
const tr = useUiText()
</script>

<template>
  <section class="panel">
    <div v-if="title || $slots.side" class="panel-head">
      <h3 class="panel-title">{{ title ? tr(title) : '' }}</h3>
      <div v-if="$slots.side" class="panel-side"><slot name="side" /></div>
    </div>
    <div class="panel-body" :class="{ flush }">
      <slot />
    </div>
  </section>
</template>
