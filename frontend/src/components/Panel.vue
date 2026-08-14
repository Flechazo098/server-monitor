<script setup lang="ts">
defineProps<{ title?: string; flush?: boolean }>()
</script>

<template>
  <section class="panel">
    <div v-if="title || $slots.side" class="panel-head">
      <h3 class="panel-title">{{ title }}</h3>
      <div v-if="$slots.side" class="panel-side"><slot name="side" /></div>
    </div>
    <div class="panel-body" :class="{ flush }">
      <slot />
    </div>
  </section>
</template>
