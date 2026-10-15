import { expect, test } from '@playwright/test'

test('public theme gallery uses bilingual anonymous demo data', async ({ page }) => {
  test.setTimeout(60000)
  await page.route('**/api/overview?**', async route => {
    const response = await route.fetch()
    const demo = await response.json()
    demo.agentDistribution = demo.agentDistribution.filter((group: { name: string }) => group.name !== 'Custom Fixture')
    const totals = [15400, 18300, 22600, 12700, 19400, 15800, 22700]
    demo.timeline.forEach((point: { summary: { metrics: { total: { value: number; state: string } } } }, index: number) => {
      point.summary.metrics.total = { value: totals[index] ?? 0, state: 'known' }
    })
    demo.selected.metrics.total.value = 126900
    await route.fulfill({ response, json: demo })
  })
  await page.goto('/settings?range=7')
  const original = await (await page.request.get('/api/settings')).json()
  const headers = { 'X-AgentBarBar': '1', Origin: new URL(page.url()).origin }
  try {
    await page.emulateMedia({ colorScheme: 'dark', reducedMotion: 'reduce' })
    for (const [language, suffix] of [['en', 'en'], ['zh-Hans', 'zh']]) {
      await page.request.post('/api/settings', { headers, data: { ...original, language, dashboardTheme: 'forest', dashboardAppearance: 'dark' } })
      await page.goto('/settings?range=7')
      await expect(page.locator('html')).toHaveAttribute('lang', language)
      await page.screenshot({ path: `../local-validation/public-appearance-${suffix}.png`, fullPage: true })
      for (const [id, english, chinese, mode] of [
        ['forest', 'Forest', '松绿', 'dark'], ['paper', 'Paper', '纸感', 'light'],
        ['ocean', 'Ocean', '深海', 'dark'], ['mono', 'Mono', '极简', 'light'],
      ]) {
        const name = language === 'en' ? english : chinese
        await page.getByRole('button', { name, exact: true }).click()
        await expect(page.getByRole('button', { name, exact: true })).toBeEnabled()
        const modeLabel = language === 'en' ? (mode === 'dark' ? 'Dark' : 'Light') : (mode === 'dark' ? '深色' : '浅色')
        await page.locator('.appearance-mode').getByRole('button', { name: modeLabel, exact: true }).click()
        await expect(page.getByRole('button', { name, exact: true })).toBeEnabled()
        await page.goto('/overview?range=7')
        await expect(page.locator('.primary-stat')).toContainText('126.9K')
        await expect(page.locator('.distribution-list')).not.toContainText('Custom Fixture')
        await expect(page.locator('html')).toHaveAttribute('data-theme', id)
        await expect(page.locator('html')).toHaveAttribute('data-appearance', mode)
        await page.screenshot({ path: `../local-validation/public-theme-${id}-${suffix}.png`, fullPage: true })
        await page.goto('/settings?range=7')
      }
    }
  } finally {
    await page.request.post('/api/settings', { headers, data: original })
  }
})
