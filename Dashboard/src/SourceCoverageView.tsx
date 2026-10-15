import { t } from './i18n'
import { compact, time } from './format'
import type { SourceCoverage, Metric } from './schema'
function amount(metric: Metric) { return metric.value == null ? t(metric.state) : compact(metric.value) }
export function SourceCoverageView({ coverage }: { coverage?: SourceCoverage }) {
  if (!coverage) return null
  return <details className="source-coverage"><summary>{t('History coverage')}: {t(coverage.status)}</summary>
    <p>{t(coverage.scope)}</p>
    <p>{t('Observed records')}: {coverage.records} · {time(coverage.earliest)} — {time(coverage.latest)}</p>
    {coverage.reconciliation && <p>{t('Reconciliation')}: {t(coverage.reconciliation.status)} · {time(coverage.reconciliation.checkedAt)}<br />{t(coverage.reconciliation.scope)} · {t('Source records')}: {coverage.reconciliation.sourceCount} · {t('Collected records')}: {coverage.reconciliation.collectedCount}</p>}
    {coverage.notes.map(note => <p key={note}>{t(note)}</p>)}
    {coverage.errors.map(error => <p className="diagnostic-error" key={error}>{t(error)}</p>)}
    {coverage.traceEvidence && <section className="historical-evidence"><h3>{t('Trace evidence (not merged)')}</h3><p>{t('Inspected files')}: {coverage.traceEvidence.inspectedFiles} · {time(coverage.traceEvidence.checkedAt)}</p><p>{t('Trace samples are workflow aggregates; request overlap has not been verified.')}</p>{coverage.traceEvidence.limited && <p>{t('Bounded sample; not a complete trace inventory.')}</p>}{coverage.traceEvidence.samples.map(sample => <p key={sample.traceID}><code>{sample.traceID}</code> · {compact(sample.totalTokens)} {t('Source reported tokens')} · {sample.models.join(', ') || t('Unknown')}</p>)}</section>}
    {coverage.historical && <section className="historical-evidence">
      <h3>{t('Historical cache evidence (not merged)')}</h3>
      <p>{coverage.historical.startDate ?? t('Unknown')} — {coverage.historical.endDate ?? t('Unknown')} · {t('Reported sessions')}: {coverage.historical.reportedSessions ?? t('Unknown')}</p>
      <p>{t('Last computed')}: {coverage.historical.lastComputedDate ?? t('Unknown')}</p>
      <p className="mono">{coverage.historical.sourcePath}</p>
      <div className="table-scroll"><table><thead><tr><th>{t('Raw model identifier')}</th><th>{t('Input (uncached)')}</th><th>{t('Output')}</th><th>{t('Cache reads')}</th><th>{t('Cache writes')}</th></tr></thead>
      <tbody>{coverage.historical.models.map(model => <tr key={model.model}><td>{model.model}</td><td>{amount(model.input)}</td><td>{amount(model.output)}</td><td>{amount(model.cacheRead)}</td><td>{amount(model.cacheWrite)}</td></tr>)}</tbody></table></div>
    </section>}
  </details>
}
