<script setup lang="ts">
defineProps<{ icon?: string; message: string }>()
</script>

<template>
  <div class="empty">
    <span v-if="icon" class="empty-ic"><UiIcon :name="icon" :size="22" /></span>
    <span>{{ message }}</span>
  </div>
</template>
