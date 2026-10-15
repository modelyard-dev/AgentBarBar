import { afterEach, expect, test } from 'vitest'
import { diagnostic, locale, setLanguagePreference, t } from './i18n'
import { metricLabel, rangeName, relative, time } from './format'
import chinese from './locales/zh-Hans.json'
afterEach(() => setLanguagePreference('en'))
test('Chinese covers metric states, dates, errors and interpolation without translating identifiers', () => {
  setLanguagePreference('zh-Hans')
  expect(t('Overview')).toBe('概览')
  expect(t('{requests} requests · {sessions} sessions', { requests: 4, sessions: 2 })).toBe('4 次请求 · 2 个会话')
  expect(rangeName('30')).toBe('最近 30 天')
  expect(metricLabel({ state: 'unsupported' })).toBe('暂不支持')
  expect(metricLabel({ state: 'unknown' })).toBe('未知')
  expect(metricLabel({ state: 'not_available' })).toBe('不可用')
  expect(metricLabel({ state: 'known', value: 0 })).toBe('数据源报告')
  expect(relative()).toBe('暂无记录')
  expect(time()).toBe('不可用')
  expect(locale()).toBe('zh-CN')
  expect(diagnostic('Parser incompatible: usage schema')).toBe('解析器不兼容： usage schema')
  expect(t('provider/raw-model')).toBe('provider/raw-model')
})
test('English round trip and every catalog interpolation retains the same fields', () => {
  setLanguagePreference('en')
  expect(t('Collectors')).toBe('Collectors')
  expect(metricLabel({ state: 'unsupported' })).toBe('Unsupported')
  for (const [english, translation] of Object.entries(chinese)) {
    const fields = (text: string) => [...text.matchAll(/\{([a-zA-Z]+)\}/g)].map(m => m[1]).sort()
    expect(fields(translation), english).toEqual(fields(english))
  }
})
