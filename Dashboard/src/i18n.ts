import { nativeHost } from './host'
import { useSyncExternalStore } from 'react'
import chinese from './locales/zh-Hans.json'
export type LanguagePreference = 'system' | 'en' | 'zh-Hans'
let preference: LanguagePreference = 'system'
const listeners = new Set<() => void>()
export function language(): 'en' | 'zh-Hans' {
  return preference === 'system' ? (typeof navigator !== 'undefined' && navigator.language.startsWith('zh') ? 'zh-Hans' : 'en') : preference
}
export function locale(): string { return language() === 'zh-Hans' ? 'zh-CN' : 'en-US' }
export function setLanguagePreference(value: LanguagePreference) {
  if (!['system', 'en', 'zh-Hans'].includes(value)) return
  preference = value
  if (typeof document !== 'undefined') document.documentElement.lang = language()
  listeners.forEach(listener => listener())
}
export function getLanguagePreference(): LanguagePreference { return preference }
export function useLanguage(): LanguagePreference {
  useSyncExternalStore(callback => { listeners.add(callback); return () => { listeners.delete(callback) } }, () => `${preference}:${language()}`)
  return preference
}
export function t(key: string, values: Record<string, string | number> = {}): string {
  const platformKey = nativeHost() ? ({ 'Private on your Mac': 'Private on this PC', 'Menu bar display': 'Tray display', 'Icon + today tokens': 'Today tokens in tooltip', 'Icon + active agents': 'Active agents in tooltip', 'Icon + estimated cost': 'Estimated cost in tooltip', 'No Full Disk Access requested. Use the native directory picker to select an additional source when a collector needs one.': 'Runs with your user permissions. Additional source paths must be explicitly selected.' } as Record<string,string>)[key] ?? key : key
  const text = language() === 'zh-Hans' ? (chinese as Record<string,string>)[platformKey] ?? platformKey : platformKey
  return text.replace(/\{([a-zA-Z]+)\}/g, (match, field: string) => String(values[field] ?? match))
}
export function diagnostic(value: string): string {
  if (language() !== 'zh-Hans') return value
  if ((chinese as Record<string, string>)[value]) return t(value)
  const prefixes: Record<string, string> = { 'Parser incompatible:': '解析器不兼容：', 'Permission denied:': '无权读取：', 'Data source unavailable:': '数据源不可用：', 'Cannot inspect data directory:': '无法检查数据目录：', 'OpenCode database:': 'OpenCode 数据库：', 'Database error:': '数据库错误：', 'Invalid settings:': '设置无效：', 'Invalid source counters:': '来源计数异常：', '; these components are Unknown': '；这些分项标为未知', 'Local API failed:': '本机 API 失败：' }
  return Object.entries(prefixes).reduce((text, [from, to]) => text.replaceAll(from, to), value)
}
if (typeof window !== 'undefined') window.addEventListener('languagechange', () => setLanguagePreference(preference))
