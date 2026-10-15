import { useEffect, useState } from 'react'
import { api, post } from './api'
import { t, diagnostic } from './i18n'
import { time } from './format'
interface Survey {
  agentID: string; checkedAt: string; roots: string[]; filesChecked: number; bytesRead: number; limited: boolean
  findings: { path: string; format: string; fields: string[]; status: string }[]
  verifiedParser?: string; knownEvents?: number
  errors: string[]; collectionStatus: string
}
export function TokenSurveyButton({ agentID }: { agentID: string }) {
  const [report, setReport] = useState<Survey | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  useEffect(() => {
    const controller = new AbortController()
    setReport(null)
    api<Survey | null>(`token-survey?agent=${encodeURIComponent(agentID)}`, controller.signal).then(setReport).catch(() => {})
    return () => controller.abort()
  }, [agentID])
  async function inspect() {
    setBusy(true); setError('')
    try { setReport(await post<Survey>('token-survey', { agentID })) }
    catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setBusy(false) }
  }
  return <div className="token-survey" onClick={e => e.stopPropagation()}>
    <button className="quiet-button" disabled={busy} onClick={inspect}>{t(busy ? 'Surveying Token sources…' : 'Find Token sources')}</button>
    {error && <p className="diagnostic-error">{diagnostic(error)}</p>}
    {report && <details open><summary>{t('Survey results')} · {time(report.checkedAt)}</summary>
      <p>{t('Checked {files} files · {count} candidates', { files: report.filesChecked, count: report.findings.length })}</p>
      {report.verifiedParser && <p>{t('Verified parser')}: {report.verifiedParser} · {t('Stored usage events')}: {report.knownEvents ?? t("Unknown")}</p>}
      <p>{t('Collection result')}: {t(report.collectionStatus)}</p>
      <p>{t('Candidate fields need a verified parser before they can count as usage.')}</p>
      {report.limited && <p>{t('Bounded search reached a limit; absence of findings is not proof that no Token records exist.')}</p>}
      {report.findings.map(f => <div key={f.path} className="survey-finding"><code>{f.path}</code><small>{f.format} · {t(f.status)}</small><small>{f.fields.join(', ')}</small></div>)}
      <details><summary>{t('Checked directories')}</summary>{report.roots.map(root => <p className="mono" key={root}>{root}</p>)}</details>
      {report.errors.map(message => <p className="diagnostic-error" key={message}>{diagnostic(message)}</p>)}
    </details>}
  </div>
}
