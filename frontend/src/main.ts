import { createApp } from 'vue'
import { createPinia } from 'pinia'
import App from './App.vue'
import router from './router'
import UiIcon from './components/UiIcon.vue'
import { i18n } from './i18n'
import './style.css'

createApp(App)
  .use(createPinia())
  .use(router)
  .use(i18n)
  .component('UiIcon', UiIcon)
  .mount('#app')
