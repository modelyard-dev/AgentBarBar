import { defineConfig } from '@playwright/test'
export default defineConfig({
  testDir: './windows-e2e', workers: 1,
  use: { baseURL: 'http://127.0.0.1:48766', locale: 'en-US', viewport: { width: 1440, height: 980 } },
  webServer: { command: 'node node_modules/vite/bin/vite.js preview --host 127.0.0.1 --port 48766 --strictPort', url: 'http://127.0.0.1:48766', reuseExistingServer: false },
})
