import { defineConfig } from '@playwright/test'

export default defineConfig({
  testDir: './e2e',
  fullyParallel: false,
  workers: 1,
  timeout: 30000,
  use: { baseURL: 'http://127.0.0.1:48765', viewport: { width: 1440, height: 980 }, trace: 'retain-on-failure' },
  projects: [{ name: 'chromium', use: { browserName: 'chromium' } }],
  webServer: {
    command: 'python3 ../scripts/prepare_e2e.py && ../.build/debug/agentbarbar-cli --db ../.build/e2e/usage.sqlite --home ../.build/e2e/home --collect --serve --dashboard dist --port 48765',
    url: 'http://127.0.0.1:48765/health',
    reuseExistingServer: false,
    timeout: 60000,
  },
})
