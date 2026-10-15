import { expect, test } from '@playwright/test'

test('native sync completion replaces the start notice even if it precedes the POST reply', async ({ page }) => {
  await page.addInitScript(() => {
    const handlers = new Map<string, Set<(event: { payload: unknown }) => void>>()
    Object.defineProperty(window, '__TAURI__', { value: {
      event: { listen: async (name: string, handler: (event: { payload: unknown }) => void) => {
        const set = handlers.get(name) ?? new Set(); set.add(handler); handlers.set(name, set)
        return () => set.delete(handler)
      } },
      core: { invoke: async (command: string, args?: { method: string; path: string; body?: unknown }) => {
        if (command !== 'business_request') return null
        if (args?.method === 'POST' && args.path === 'sync') {
          for (const handler of handlers.get('import_completed') ?? []) handler({ payload: { collector: 'running' } })
          return { accepted: true }
        }
        const response = await fetch(`/api/${args?.path}`, { method: args?.method, headers: { 'Content-Type': 'application/json', 'X-AgentBarBar': '1' }, body: args?.method === 'POST' ? JSON.stringify(args.body) : undefined })
        return response.json()
      } },
    } })
  })
  await page.goto('/')
  await page.locator('.utility-menu > summary').click()
  await page.getByRole('button', { name: /^(Sync now|立即同步)$/, exact: true }).click()
  await expect(page.getByRole('status').filter({ hasText: /Sync completed|同步已完成/ })).toBeVisible()
  await expect(page.getByRole('status').filter({ hasText: /Sync started|正在同步/ })).toHaveCount(0)
})
