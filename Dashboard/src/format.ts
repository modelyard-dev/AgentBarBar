import { locale, t } from './i18n'
import type { Metric } from './schema'

export function compact(value: number | null | undefined): string {
  if (value == null) return '—'
  if (Math.abs(value) >= 1e9) return `${(value / 1e9).toFixed(2)}B`
  if (Math.abs(value) >= 1e6) return `${(value / 1e6).toFixed(2)}M`
  if (Math.abs(value) >= 1e3) return `${(value / 1e3).toFixed(1)}K`
  return value.toLocaleString(locale())
}
export function exact(value: number | null | undefined): string { return value == null ? t('Not available') : value.toLocaleString(locale()) }
export function metricLabel(metric?: Metric): string {
  if (!metric) return t('Unknown')
  if (metric.value != null) return t(metric.state === 'partial' ? 'Partial coverage' : 'Source reported')
  return t(({ known: 'Not available', unknown: 'Unknown', unsupported: 'Unsupported', not_available: 'Not available', partial: 'Partial coverage' })[metric.state])
}
export function time(value?: string): string { return value ? new Date(value).toLocaleString(locale()) : t('Not available') }
export function relative(value?: string): string {
  if (!value) return t('Never')
  const seconds = Math.max(0, Math.floor((Date.now() - new Date(value).getTime()) / 1000))
  const formatter = new Intl.RelativeTimeFormat(locale(), { numeric: 'always', style: 'short' })
  if (seconds < 60) return formatter.format(-seconds, 'second')
  if (seconds < 3600) return formatter.format(-Math.floor(seconds / 60), 'minute')
  if (seconds < 86400) return formatter.format(-Math.floor(seconds / 3600), 'hour')
  return formatter.format(-Math.floor(seconds / 86400), 'day')
}
export interface Filters { range: string; agent: string; model: string; project: string; provider: string; start: string; end: string; session: string }
export const defaults: Filters = { range: '7', agent: '', model: '', project: '', provider: '', start: '', end: '', session: '' }
export function query(filters: Filters, now = new Date()): string {
  const params = new URLSearchParams()
  const end = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1)
  const start = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  if (filters.range === 'yesterday') { end.setDate(end.getDate() - 1); start.setDate(start.getDate() - 1) }
  else if (filters.range === 'custom') {
    if (filters.start) start.setTime(new Date(`${filters.start}T00:00:00`).getTime())
    if (filters.end) { end.setTime(new Date(`${filters.end}T00:00:00`).getTime()); end.setDate(end.getDate() + 1) }
  } else if (filters.range !== 'all') start.setDate(start.getDate() - (Number(filters.range) || 1) + 1)
  if (filters.range !== 'all') {
    if (!Number.isNaN(start.getTime())) params.set('start', start.toISOString())
    if (!Number.isNaN(end.getTime())) params.set('end', end.toISOString())
  }
  for (const key of ['agent', 'model', 'project', 'provider', 'session'] as const) if (filters[key]) params.set(key, filters[key])
  params.set('tz', Intl.DateTimeFormat().resolvedOptions().timeZone)
  return params.toString()
}
export function rangeName(range: string): string { return t(({ '1': 'Today', '7': 'Last 7 days', '30': 'Last 30 days', all: 'All collected time', yesterday: 'Yesterday', custom: 'Custom range' } as Record<string, string>)[range] ?? 'Selected period') }
