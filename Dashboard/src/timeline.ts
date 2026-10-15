import type { MetricName, TimelinePoint } from './schema'

/** Chart-only zeros represent elapsed buckets with no recorded requests. */
export function timelineValue(point: TimelinePoint, metric: MetricName, now: number): number | null {
  if (Date.parse(point.timestamp) > now) return null
  const counter = point.summary.metrics[metric]
  if (counter.value != null) return counter.value
  return point.summary.events === 0 && counter.state === 'not_available' ? 0 : null
}
