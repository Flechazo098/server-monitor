import { createApp } from 'vue'
import { createPinia } from 'pinia'
import App from './App.vue'
import router from './router'
import UiIcon from './components/UiIcon.vue'
import './style.css'

createApp(App)
  .use(createPinia())
  .use(router)
  .component('UiIcon', UiIcon)
  .mount('#app')
