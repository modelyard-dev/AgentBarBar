import { expect, it } from 'vitest'
import { timelineValue } from './timeline'
import type { TimelinePoint, Metric } from './schema'

const now = Date.parse('2026-10-05T03:15:00Z')
function point(timestamp: string, events: number, total: Metric): TimelinePoint {
  return { timestamp, end: timestamp, summary: { events, metrics: { total } } } as TimelinePoint
}
it('puts empty elapsed buckets on zero without altering their source metrics', () => {
  const empty = point('2026-10-05T00:00:00Z', 0, { state: 'not_available' })
  expect(timelineValue(empty, 'total', now)).toBe(0)
  expect(empty.summary.metrics.total).toEqual({ state: 'not_available' })
  expect(timelineValue(point('2026-10-05T03:00:00Z', 0, { state: 'not_available' }), 'total', now)).toBe(0)
})
it('leaves future buckets and missing or unsupported counters blank', () => {
  expect(timelineValue(point('2026-10-05T04:00:00Z', 0, { state: 'not_available' }), 'total', now)).toBeNull()
  for (const state of ['unknown', 'unsupported', 'not_available'] as const) {
    expect(timelineValue(point('2026-10-05T02:00:00Z', 2, { state }), 'total', now)).toBeNull()
  }
})
it('preserves reported partial totals and known zero', () => {
  expect(timelineValue(point('2026-10-05T02:00:00Z', 2, { value: 123, state: 'partial' }), 'total', now)).toBe(123)
  expect(timelineValue(point('2026-10-05T02:00:00Z', 2, { value: 0, state: 'known' }), 'total', now)).toBe(0)
})
