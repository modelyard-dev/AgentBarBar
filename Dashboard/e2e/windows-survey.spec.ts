import { expect, test } from '@playwright/test'

test('Windows survey returns stored usage and restores its report after reload', async ({ page }) => {
  await page.addInitScript(() => {
    Object.defineProperty(window, '__TAURI__', { value: {
      event: { listen: async () => () => {} },
      core: { invoke: async (command: string, args?: { method: string; path: string; body?: { agentID?: string } }) => {
        if (command !== 'business_request') return null
        if (args?.path.startsWith('token-survey')) {
          if (args.method === 'GET') return JSON.parse(sessionStorage.getItem('survey-report') ?? 'null')
          const report = { agentID: args.body?.agentID, checkedAt: '2026-10-06T09:30:00Z', roots: ['C:\\anonymous\\sessions'], filesChecked: 1, bytesRead: 80, limited: false, findings: [{ path: 'C:\\anonymous\\sessions\\rollout.jsonl', format: 'JSONL', fields: ['input_tokens', 'output_tokens', 'total_tokens'], status: 'candidate_source' }], verifiedParser: 'codex-jsonl-v1.2.0', knownEvents: 1, errors: [], collectionStatus: 'healthy' }
          sessionStorage.setItem('survey-report', JSON.stringify(report)); return report
        }
        const response = await fetch(`/api/${args?.path}`, { method: args?.method }); const data = await response.json()
        if (args?.path === 'collectors') for (const c of data) if (c.descriptor.agentID === 'codex') {
          c.coverage = { status: 'observed', scope: 'Collected local usage records', records: 1, earliest: '2026-10-05T00:00:00Z', latest: '2026-10-05T00:00:00Z', completeHistoryVerified: false, notes: [], errors: [] }
          c.health.imported = 0; c.health.updated = 0
        }
        return data
      } },
    } })
  })
  await page.goto('/settings')
  await page.locator('.advanced-tools > summary').click()
  const row = page.locator('.collector-row').filter({ hasText: 'codex-local' })
  await row.locator('.connection-details > summary').click()
  await row.getByRole('button', { name: /Find Token sources|自动勘测 Token 来源/ }).click()
  await expect(row.locator('.token-survey')).toContainText('codex-jsonl-v1.2.0')
  await expect(row.locator('.token-survey')).toContainText('total_tokens')
  await expect(row.locator('.diagnostic-error')).toHaveCount(0)
  await row.locator('.source-coverage > summary').click()
  await expect(row.locator('.source-coverage')).toContainText(/Observed records: 1|已观测记录: 1/)
  await page.reload()
  await page.locator('.advanced-tools > summary').click()
  await row.locator('.connection-details > summary').click()
  await expect(row.locator('.token-survey')).toContainText('codex-jsonl-v1.2.0')
})
