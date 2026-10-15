import { expect, test } from '@playwright/test'

test('appearance persists across reloads and respects system versus explicit modes', async ({ page }) => {
  test.setTimeout(60000)
  await page.goto('/settings')
  const original = await (await page.request.get('/api/settings')).json()
  const headers = { 'X-AgentBarBar': '1', Origin: new URL(page.url()).origin }
  try {
    await page.request.post('/api/settings', { headers, data: { ...original, language: 'en', dashboardTheme: 'forest', dashboardAppearance: 'system' } })
    await page.reload()
    await expect(page.getByRole('heading', { name: 'Appearance', exact: true })).toBeVisible()
    await expect(page.locator('.theme-card')).toHaveCount(4)
    for (const [id, name] of [['forest', 'Forest'], ['paper', 'Paper'], ['ocean', 'Ocean'], ['mono', 'Mono']]) {
      await page.getByRole('button', { name, exact: true }).click()
      await expect(page.getByRole('button', { name, exact: true })).toBeEnabled()
      for (const [mode, label] of [['light', 'Light'], ['dark', 'Dark']]) {
        await page.locator('.appearance-mode').getByRole('button', { name: label, exact: true }).click()
        await expect(page.getByRole('button', { name, exact: true })).toBeEnabled()
        const saved = await (await page.request.get('/api/settings')).json()
        expect(saved.dashboardTheme).toBe(id); expect(saved.dashboardAppearance).toBe(mode)
        expect(saved.disabledCollectors).toEqual(original.disabledCollectors)
        expect(saved.sourceOverrides).toEqual(original.sourceOverrides)
        expect(saved.customAgents).toEqual(original.customAgents)
        await page.goto('/overview?range=7')
        await expect(page.locator('.primary-stat')).toBeVisible()
        await expect(page.locator('html')).toHaveAttribute('data-theme', id)
        await expect(page.locator('html')).toHaveAttribute('data-appearance', mode)
        await page.screenshot({ path: `../local-validation/theme-${id}-${mode}.png`, fullPage: true })
        await page.goto('/settings')
        await expect(page.getByRole('button', { name, exact: true })).toHaveAttribute('aria-pressed', 'true')
      }
    }
    const background = () => page.evaluate(() => getComputedStyle(document.body).backgroundColor)
    await page.emulateMedia({ colorScheme: 'dark' })
    await page.locator('.appearance-mode').getByRole('button', { name: 'Light', exact: true }).click()
    await expect(page.getByRole('button', { name: 'Mono', exact: true })).toBeEnabled()
    expect(await background()).toBe('rgb(250, 250, 250)')
    await page.locator('.appearance-mode').getByRole('button', { name: 'Follow system', exact: true }).click()
    await expect(page.getByRole('button', { name: 'Mono', exact: true })).toBeEnabled()
    expect(await background()).toBe('rgb(22, 22, 22)')
    await page.emulateMedia({ colorScheme: 'light' })
    await expect.poll(background).toBe('rgb(250, 250, 250)')
    await page.getByRole('button', { name: 'Paper', exact: true }).click()
    await expect(page.getByRole('button', { name: 'Paper', exact: true })).toBeEnabled()
    await page.screenshot({ path: '../local-validation/theme-settings.png', fullPage: true })
    await page.setViewportSize({ width: 375, height: 812 })
    await page.screenshot({ path: '../local-validation/theme-settings-mobile.png', fullPage: true })
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
  } finally {
    await page.request.post('/api/settings', { headers, data: original })
  }
})

test('failed appearance saves restore the previous theme', async ({ page }) => {
  await page.goto('/settings')
  const original = await (await page.request.get('/api/settings')).json()
  const headers = { 'X-AgentBarBar': '1', Origin: new URL(page.url()).origin }
  try {
    await page.request.post('/api/settings', { headers, data: { ...original, language: 'en', dashboardTheme: 'forest', dashboardAppearance: 'light' } })
    await page.reload()
    await expect(page.getByRole('button', { name: 'Forest', exact: true })).toHaveAttribute('aria-pressed', 'true')
    await page.route('**/api/settings', route => route.request().method() === 'POST'
      ? route.fulfill({ status: 503, json: { error: 'Fixture write failure' } }) : route.continue())
    await page.getByRole('button', { name: 'Ocean', exact: true }).click()
    await expect(page.getByRole('alert')).toContainText('Could not save appearance')
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'forest')
    await expect(page.getByRole('button', { name: 'Forest', exact: true })).toHaveAttribute('aria-pressed', 'true')
    expect((await (await page.request.get('/api/settings')).json()).dashboardTheme).toBe('forest')
  } finally {
    await page.unrouteAll()
    await page.request.post('/api/settings', { headers, data: original })
  }
})

test('external settings event refreshes appearance without window reload', async ({ page }) => {
  let theme = 'forest'
  await page.route('**/api/settings', async route => {
    const response = await route.fetch()
    const settings = await response.json()
    await route.fulfill({ response, json: { ...settings, dashboardTheme: theme, dashboardAppearance: 'dark', language: 'en' } })
  })
  await page.goto('/overview')
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'forest')
  theme = 'paper'
  await page.evaluate(() => window.dispatchEvent(new CustomEvent('agentbar:settings_changed')))
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'paper', { timeout: 1500 })
})

test('hidden native dashboard skips collector status and summary refreshes', async ({ page }) => {
  await page.addInitScript(() => {
    Object.assign(window, { __TAURI__: {
      event: { listen: async () => () => {} },
      core: { invoke: async (command: string, args?: { method: string; path: string }) => {
        if (command !== 'business_request') return { ready: true }
        return await (await fetch(`/api/${args!.path}`)).json()
      } },
    } })
  })
  let statusReads = 0, summaryReads = 0
  page.on('request', request => {
    if (new URL(request.url()).pathname === '/api/status') statusReads += 1
    if (new URL(request.url()).pathname === '/api/overview') summaryReads += 1
  })
  await page.goto('/overview')
  await expect(page.locator('.primary-stat')).toBeVisible()
  await page.evaluate(() => Object.defineProperty(document, 'hidden', { value: true, configurable: true }))
  const initial = { statusReads, summaryReads }
  await page.evaluate(() => {
    window.dispatchEvent(new CustomEvent('agentbar:collector_status_changed'))
    window.dispatchEvent(new CustomEvent('agentbar:data_updated'))
    window.dispatchEvent(new CustomEvent('agentbar:import_completed'))
  })
  await page.waitForTimeout(700)
  expect({ statusReads, summaryReads }).toEqual(initial)
  await page.evaluate(() => { Object.defineProperty(document, 'hidden', { value: false, configurable: true }); document.dispatchEvent(new Event('visibilitychange')) })
  await expect.poll(() => summaryReads).toBeGreaterThan(initial.summaryReads)
})

test('native no-data reconciliation updates status without overview scans', async ({ page }) => {
  await page.addInitScript(() => {
    Object.assign(window, { __agentbarTestCollecting: false, __TAURI__: {
      event: { listen: async () => () => {} },
      core: { invoke: async (command: string, args?: { path: string }) => {
        if (command !== 'business_request') return { ready: true }
        const value = await (await fetch(`/api/${args!.path}`)).json()
        if (args!.path === 'status') value.collecting = (window as unknown as { __agentbarTestCollecting: boolean }).__agentbarTestCollecting
        return value
      } },
    } })
  })
  let statusReads = 0, overviewReads = 0
  page.on('request', request => {
    if (new URL(request.url()).pathname === '/api/status') statusReads += 1
    if (new URL(request.url()).pathname === '/api/overview') overviewReads += 1
  })
  await page.goto('/overview')
  await expect(page.locator('.primary-stat')).toBeVisible()
  const initial = overviewReads
  for (const collecting of [true, false]) {
    const previous = statusReads
    await page.evaluate(value => { Object.assign(window, { __agentbarTestCollecting: value }); window.dispatchEvent(new CustomEvent('agentbar:collector_status_changed')) }, collecting)
    await expect.poll(() => statusReads).toBeGreaterThan(previous)
    await page.waitForTimeout(100)
  }
  await page.waitForTimeout(500)
  expect(overviewReads).toBe(initial)
  await page.evaluate(() => window.dispatchEvent(new CustomEvent('agentbar:data_updated')))
  await expect.poll(() => overviewReads).toBeGreaterThan(initial)
})
