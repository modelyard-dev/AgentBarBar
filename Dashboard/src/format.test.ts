import { beforeEach, describe, expect, it } from 'vitest'
import { setLanguagePreference } from './i18n'
import { compact, defaults, metricLabel, query } from './format'
beforeEach(() => setLanguagePreference('en'))

describe('source-aware numbers', () => {
  it('distinguishes known zero, unsupported, unknown and unavailable', () => {
    expect(compact(0)).toBe('0')
    expect(compact(undefined)).toBe('—')
    expect(metricLabel({ state: 'unsupported' })).toBe('Unsupported')
    expect(metricLabel({ state: 'unknown' })).toBe('Unknown')
    expect(metricLabel({ state: 'not_available' })).toBe('Not available')
    expect(metricLabel({ value: 0, state: 'known' })).toBe('Source reported')
  })
  it('retains partial coverage instead of labeling the known sum complete', () => {
    expect(metricLabel({ value: 124, state: 'partial' })).toBe('Partial coverage')
  })
})
describe('global filters', () => {
  it('encodes original model/project strings and excludes the all-time date window', () => {
    const result = new URLSearchParams(query({ ...defaults, range: 'all', agent: 'pi', model: 'deepseek/deepseek-v4.1-flash', project: 'project-id', provider: 'scnet' }))
    expect(result.get('model')).toBe('deepseek/deepseek-v4.1-flash')
    expect(result.get('agent')).toBe('pi')
    expect(result.has('start')).toBe(false)
    expect(result.has('end')).toBe(false)
  })
  it('uses half-open calendar dates for today', () => {
    const now = new Date(2026, 9, 4, 17)
    const result = new URLSearchParams(query({ ...defaults, range: '1' }, now))
    expect(new Date(result.get('start')!).getDate()).toBe(4)
    expect(new Date(result.get('end')!).getDate()).toBe(5)
  })
})
