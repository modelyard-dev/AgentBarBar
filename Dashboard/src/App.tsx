import { hostAction, nativeHost } from './host'
import { t, diagnostic, locale, setLanguagePreference, useLanguage, getLanguagePreference, type LanguagePreference } from './i18n'
import { useCallback, useEffect, useRef, useState } from 'react'
import { Area, AreaChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts'
import { api, post } from './api'
import { compact, defaults, exact, metricLabel, query, rangeName, relative, time, type Filters } from './format'
import type { Agent, EventPage, FilterOptions, Group, Metric, MetricName, Overview, Settings, Status, Summary, UsageEvent } from './schema'
import { TokenSurveyButton } from './TokenSurveyButton'
import { SourceCoverageView } from './SourceCoverageView'
import { SettingsView } from './SettingsView'
import { syncAppearance, appearanceRevision } from './appearance'
import { timelineValue } from './timeline'
import { useLoad, bootLanguage } from './cache'

type Page = 'overview' | 'usage' | 'agents' | 'models' | 'projects' | 'sessions' | 'settings'
const pages: Page[] = ['overview', 'usage', 'agents', 'models', 'projects', 'sessions', 'settings']
const titles: Record<Page, string> = { overview: 'Overview', usage: 'Usage', agents: 'Agents', models: 'Models', projects: 'Projects', sessions: 'Sessions', settings: 'Settings' }
const labels: Record<MetricName, string> = { input: 'Input (including cache)', output: 'Output', cacheRead: 'Cache reads', cacheWrite: 'Cache writes', cachedOutput: 'Cached output', reasoning: 'Reasoning', total: 'Total tokens' }
const paths: Record<string, string> = {
  overview: 'M3 3h6v6H3zM15 3h6v6h-6zM3 15h6v6H3zM15 15h6v6h-6z',
  usage: 'M2 13h4l3-8 5 14 3-8h5', agents: 'M12 3 3 8l9 5 9-5-9-5ZM3 12l9 5 9-5M3 16l9 5 9-5',
  models: 'M4 4h16v16H4zM4 10h16M10 4v16', projects: 'M3 7h7l2 2h9v11H3zM3 7V4h7l2 3',
  sessions: 'M12 8v5l3 2M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z',
  settings: 'M5 3v18M12 3v18M19 3v18M2 7h6M9 15h6M16 9h6', refresh: 'M20 7V3l-4 4M20 7a9 9 0 1 0 1 9',
  arrow: 'M5 12h14M14 7l5 5-5 5', close: 'm5 5 14 14M19 5 5 19', check: 'm5 12 4 4L19 6',
}
export function Icon({ name, size = 18 }: { name: string; size?: number }) { return <svg aria-hidden="true" width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><path d={paths[name] ?? paths.agents} /></svg> }
function AgentGlyph({ id, name }: { id: string; name: string }) {
  const [failed, setFailed] = useState(false)
  return <span className="generic-icon" aria-hidden="true">{failed ? name[0] : <img src={`/agent-icons/${id}.png`} onError={() => setFailed(true)} alt="" width="22" height="22" />}</span>
}
if (bootLanguage === 'en' || bootLanguage === 'zh-Hans' || bootLanguage === 'system') setLanguagePreference(bootLanguage)
function initialFilters(): Filters {
  const params = new URLSearchParams(location.search)
  return Object.fromEntries(Object.entries(defaults).map(([key, value]) => [key, params.get(key) ?? (key === 'range' && (location.pathname === '/' || location.pathname === '/overview') ? '1' : value)])) as unknown as Filters
}
export function App() {
  const [page, setPage] = useState<Page>(() => pages.find(p => location.pathname.includes(p)) ?? 'overview')
  const [filters, setFilters] = useState(initialFilters)
  const [revision, setRevision] = useState(0)
  const [notice, setNotice] = useState('')
  const utility = useRef<HTMLDetailsElement>(null)
  useEffect(() => {
    function outside(event: PointerEvent) {
      if (utility.current?.open && event.target instanceof Node && !utility.current.contains(event.target)) utility.current.open = false
    }
    function escape(event: KeyboardEvent) {
      if (event.key === 'Escape' && utility.current?.open) {
        utility.current.open = false
        utility.current.querySelector('summary')?.focus()
      }
    }
    document.addEventListener('pointerdown', outside, true)
    document.addEventListener('keydown', escape)
    return () => { document.removeEventListener('pointerdown', outside, true); document.removeEventListener('keydown', escape) }
  }, [])
  const preference = useLanguage()
  const preferences = useLoad<Settings>('settings', revision)
  useEffect(() => { if (preferences.data) setLanguagePreference(preferences.data.language ?? 'system') }, [preferences.data])
  const options = useLoad<FilterOptions>('filters', revision)
  const [statusRevision, setStatusRevision] = useState(0)
  const wasCollecting = useRef(false)
  const status = useLoad<Status>('status', `${revision}:${statusRevision}`)
  const q = query(filters)
  const refresh = useCallback(() => setRevision(v => v + 1), [])
  useEffect(() => {
    if (wasCollecting.current && !status.loading && status.data && !status.data.collecting) { setNotice(n => n === 'Sync started' ? 'Sync completed' : n); if (!nativeHost() && !document.hidden) refresh() }
    wasCollecting.current = status.data?.collecting ?? false
    if (!status.data?.collecting || document.hidden || nativeHost()) return
    const timer = setTimeout(() => setStatusRevision(v => v + 1), 1000)
    return () => clearTimeout(timer)
  }, [status.data, refresh])
  useEffect(() => {
    let active = true
    let timer: ReturnType<typeof setInterval> | undefined
    async function readPreference() {
      try {
        const appearanceAtRequest = appearanceRevision()
        const settings = await api<Settings>('settings')
        if (active) { if (settings.language !== getLanguagePreference()) setLanguagePreference(settings.language); if (appearanceRevision() === appearanceAtRequest) syncAppearance(settings) }
      } catch { /* Connection state is exposed by the status request. */ }
    }
    function visibility() {
      if (timer) clearInterval(timer)
      if (!document.hidden) { void readPreference(); if (!nativeHost()) timer = setInterval(readPreference, 5000) }
    }
    visibility(); document.addEventListener('visibilitychange', visibility); window.addEventListener('agentbar:settings_changed', readPreference)
    return () => { active = false; if (timer) clearInterval(timer); document.removeEventListener('visibilitychange', visibility); window.removeEventListener('agentbar:settings_changed', readPreference) }
  }, [])
  useEffect(() => {
    let timer: ReturnType<typeof setInterval> | undefined
    function visibility() { if (timer) clearInterval(timer); if (!document.hidden) { refresh(); if (!nativeHost()) timer = setInterval(refresh, 30000) } }
    visibility(); document.addEventListener('visibilitychange', visibility)
    return () => { if (timer) clearInterval(timer); document.removeEventListener('visibilitychange', visibility) }
  }, [refresh])
  useEffect(() => {
    const params = new URLSearchParams()
    for (const [key, value] of Object.entries(filters)) if (value) params.set(key, value)
    history.replaceState(null, '', `/${page}?${params}`)
  }, [filters, page])
  useEffect(() => { const listener = (e: KeyboardEvent) => { if (e.metaKey && e.key === ',') { e.preventDefault(); setPage('settings') } }; window.addEventListener('keydown', listener); return () => window.removeEventListener('keydown', listener) }, [])
  useEffect(() => {
    if (!nativeHost()) return
    let timer: ReturnType<typeof setTimeout> | undefined
    const updated = () => { if (timer) clearTimeout(timer); if (!document.hidden) timer = setTimeout(refresh, 400) }
    const navigate = (e: Event) => { if ((e as CustomEvent).detail === 'settings') setPage('settings') }
    const statusUpdated = () => { if (!document.hidden) setStatusRevision(v => v + 1) }
    const completed = () => setNotice(n => n === 'Sync started' ? 'Sync completed' : n)
    window.addEventListener('agentbar:collector_status_changed', statusUpdated)
    for (const e of ['data_updated','import_completed','settings_changed']) window.addEventListener(`agentbar:${e}`, updated)
    window.addEventListener('agentbar:import_completed', completed)
    window.addEventListener('agentbar:navigate', navigate)
    return () => { if(timer) clearTimeout(timer); window.removeEventListener('agentbar:collector_status_changed', statusUpdated); for(const e of ['data_updated','import_completed','settings_changed']) window.removeEventListener(`agentbar:${e}`, updated); window.removeEventListener('agentbar:import_completed', completed); window.removeEventListener('agentbar:navigate', navigate) }
  }, [refresh])
  function select(key: keyof Filters, value: string) { setFilters(v => ({ ...v, [key]: value })) }
  function drill(key: 'agent' | 'model' | 'project' | 'session', value: string, target: Page = 'usage') { select(key, value); setPage(target) }
  async function sync() { try { setNotice('Sync started'); await post('sync'); refresh(); setTimeout(refresh, 2000) } catch (e) { setNotice((e as Error).message) } }
  async function changeLanguage(language: LanguagePreference) {
    try {
      const latest = await api<Settings>('settings')
      const saved = await post<Settings>('settings', { ...latest, language })
      setLanguagePreference(saved.language); refresh()
    } catch (e) { setNotice((e as Error).message) }
  }
  useEffect(() => { document.title = `${t(titles[page])} · AgentBarBar` }, [page, preference])
  const activeCount = Object.entries(filters).filter(([k, v]) => ['agent', 'model', 'project', 'provider', 'session'].includes(k) && v).length
  return <div className="app-shell">
    <main>
      <header className="simple-header">
        <a className="simple-brand" href="/" onClick={e => { e.preventDefault(); setPage('overview') }}><img src="/mark.svg" alt="" />AgentBarBar</a>
        <nav aria-label={t("Main navigation")}>{(['overview', 'usage', 'settings'] as Page[]).map(p => <button className={page === p ? 'selected' : ''} key={p} onClick={() => { setPage(p); utility.current?.removeAttribute('open') }}>{t(titles[p])}</button>)}</nav>
        <details className="utility-menu" ref={utility}><summary aria-label={t('More')}>···</summary><div className="utility-content">{(['agents', 'models', 'projects', 'sessions'] as Page[]).map(p => <button key={p} onClick={() => { setPage(p); utility.current?.removeAttribute('open') }}>{t(titles[p])}</button>)}<select aria-label={t('Language')} value={preference} onChange={e => changeLanguage(e.target.value as LanguagePreference)}><option value="system">{t('Follow system')}</option><option value="zh-Hans">简体中文</option><option value="en">English</option></select><button onClick={sync} disabled={status.data?.collecting}>{t(status.data?.collecting ? 'Collecting…' : 'Sync now')}</button></div></details>
      </header>
      <div className="content">
        {page !== 'overview' && <div className="page-title"><h1>{t(titles[page])}</h1></div>}
        {page !== 'settings' && <details className="filter-disclosure"><summary>{t('Filter')}{activeCount > 0 && ` · ${activeCount}`}</summary><div className="filter-bar">
          <label>{t("Date")}<select aria-label={t("Date filter")} value={filters.range} onChange={e => select('range', e.target.value)}><option value="1">{t("Today")}</option><option value="yesterday">{t("Yesterday")}</option><option value="7">{t("Last 7 days")}</option><option value="30">{t("Last 30 days")}</option><option value="all">{t("All collected time")}</option><option value="custom">{t("Custom range")}</option></select></label>
          {(['agent', 'model', 'project', 'provider'] as const).map((key, i) => <label key={key}>{t(key[0].toUpperCase() + key.slice(1))}<select aria-label={t(`${key} filter`)} value={filters[key]} onChange={e => select(key, e.target.value)}><option value="">{t(`All ${key === 'agent' ? 'agents' : `${key}s`}`)}</option>{(options.data?.[(['agents', 'models', 'projects', 'providers'] as const)[i]] ?? []).map(o => <option value={o.id} key={o.id}>{o.name}</option>)}{key !== 'agent' && <option value="unknown">{t("Unknown")}</option>}</select></label>)}
          <button className="reset-button" disabled={activeCount === 0 && filters.range === '7'} onClick={() => setFilters(defaults)}>{t('Reset')}{activeCount > 0 && <span>{activeCount}</span>}</button>
          {filters.range === 'custom' && <div className="date-inputs"><input aria-label={t("Start date")} type="date" value={filters.start} onChange={e => select('start', e.target.value)} /><span>{t("through")}</span><input aria-label={t("End date")} type="date" value={filters.end} onChange={e => select('end', e.target.value)} /></div>}
          {filters.session && <button className="session-chip" onClick={() => select('session', '')}>{t('Session: {id}', { id: filters.session.slice(0, 20) })} <Icon name="close" size={12} /></button>}
        </div></details>}
        {(notice || status.error) && <div className="notice" role="status">{diagnostic(t(status.error || notice))}<button aria-label={t("Dismiss notification")} onClick={() => setNotice('')}><Icon name="close" size={14} /></button></div>}
        {page === 'overview' && <OverviewView range={filters.range} q={q} revision={revision} onUsage={() => setPage('usage')} onPeriod={range => select('range', range)} drill={drill} />}
        {page === 'usage' && <><UsageView q={q} revision={revision} /><UsageBreakdown q={q} revision={revision} /></>}
        {page === 'agents' && <AgentsView q={q} revision={revision} filters={filters} select={select} drill={drill} />}
        {(['models', 'projects', 'sessions'] as Page[]).includes(page) && <GroupsView dimension={page as 'models' | 'projects' | 'sessions'} q={q} revision={revision} drill={drill} />}
        {page === 'settings' && <SettingsView revision={revision} refresh={refresh} collecting={status.data?.collecting ?? false} status={status.data} />}
        <footer className="page-foot"><div className="footer-resource"><a href="https://tibo.modelyard.dev/" target="_blank" rel="noopener noreferrer" onClick={e => { if (nativeHost()) { e.preventDefault(); void hostAction('open-tibo').catch(error => setNotice(error.message)) } }}>Tibo Codex Monitor <span aria-hidden="true">↗</span></a><span>{t('Track Codex limit resets and policy updates.')}</span></div><span>{t("Private on your Mac")}</span></footer>
      </div>
    </main>
  </div>
}
function Loading({ error, loading }: { error: string; loading: boolean }) { return error ? <div className="error-box" role="alert">{diagnostic(error)}</div> : loading ? <div className="loading-state">{t("Reading local usage\u2026")}</div> : null }
function CacheStatus({ loading, savedAt }: { loading: boolean; savedAt?: number }) { return savedAt && loading ? <div className="cache-status" role="status">{t(loading ? 'Showing saved snapshot · Updating in background · {time}' : 'Updated {time}', { time: new Date(savedAt).toLocaleTimeString(locale()) })}</div> : null }
function Empty({ children = t('No usage records match these filters.') }: { children?: React.ReactNode }) { return <div className="empty-state"><Icon name="usage" size={26} /><h3>{t("No usage to show")}</h3><p>{children}</p></div> }
export function MetricValue({ metric, small = false }: { metric?: Metric; small?: boolean }) { return <span className={small ? 'metric-inline' : 'metric-value'} title={metric?.value != null ? `${exact(metric.value)} · ${metricLabel(metric)}` : metricLabel(metric)}>{compact(metric?.value)}{metric?.state === 'partial' && <sup aria-label={t('Partial')} title={t('Available records only')}>*</sup>}{metric?.value == null && <small>{metricLabel(metric)}</small>}</span> }
function SummaryStrip({ summary, onClick }: { summary: Summary; onClick: () => void }) {
  const rawInput = summary.uncachedInput?.state === 'known' ? summary.uncachedInput : undefined
  return <div className="breakdown-strip">{(['input', 'output', 'cacheRead', 'cacheWrite', 'reasoning'] as MetricName[]).map(key => <button key={key} onClick={onClick}>
    <span>{t(key === 'input' ? (rawInput ? 'Input (uncached)' : 'Input (including cache)') : labels[key])}</span>
    <MetricValue metric={key === 'input' && rawInput ? rawInput : summary.metrics[key]} small />
    {key === 'input' && rawInput && <small>{t('Including cache')}: {summary.metrics.input.value == null ? t("Unknown") : compact(summary.metrics.input.value)}</small>}
    {key === 'reasoning' && summary.metrics.reasoning.value != null && <small>{t('Included in output')}</small>}
    {summary.metrics[key].state === 'partial' && <small>{t('{count}/{total} records', { count: summary.metrics[key].knownEvents, total: summary.events })}</small>}
  </button>)}<div><span>{t("Estimated cost")}</span><strong>{summary.cost == null ? t('Not available') : `${summary.currency} ${summary.cost.toFixed(2)}`}</strong><small>{summary.cost == null ? t('No verified pricing data') : t('{count}/{total} records priced', { count: summary.costKnownEvents, total: summary.events })}</small></div></div>
}

function Timeline({ data, simple = false }: { data: Overview; simple?: boolean }) {
  const [metric, setMetric] = useState<MetricName>('total')
  const now = Date.now()
  const values = data.timeline.map(p => ({ timestamp: p.timestamp, ...Object.fromEntries((['total', 'input', 'output', 'cacheRead', 'reasoning'] as MetricName[]).map(key => [key, timelineValue(p, key, now)])) }))
  const hourly = data.timeline.length > 1 && new Date(data.timeline[1].timestamp).getTime() - new Date(data.timeline[0].timestamp).getTime() < 86400000
  const tick = (value: string) => new Date(value).toLocaleString(locale(), hourly ? { hour: 'numeric' } : { month: 'short', day: 'numeric' })
  return <section className="panel timeline-panel"><div className="panel-title"><div><h2>{t(simple ? "Usage trend" : "Token usage timeline")}</h2></div>{!simple && <select aria-label={t("Timeline metric")} value={metric} onChange={e => setMetric(e.target.value as MetricName)}>{(['total', 'input', 'output', 'cacheRead', 'reasoning'] as MetricName[]).map(key => <option value={key} key={key}>{t(labels[key])}</option>)}</select>}</div>
    {data.selected.events === 0 ? <Empty /> : <div className="chart-wrap"><ResponsiveContainer width="100%" height={228}><AreaChart data={values} margin={{ top: 14, left: 0, right: 18, bottom: 0 }}><CartesianGrid stroke="var(--line)" vertical={false} strokeDasharray="3 4" /><XAxis dataKey="timestamp" tickFormatter={tick} axisLine={false} tickLine={false} minTickGap={35} tick={{ fill: 'var(--muted)', fontSize: 11 }} /><YAxis tickFormatter={compact} axisLine={false} tickLine={false} tick={{ fill: 'var(--muted)', fontSize: 11 }} width={55} /><Tooltip contentStyle={{ background: 'var(--surface)', border: '1px solid var(--line)', borderRadius: 6, fontSize: 12 }} labelFormatter={v => time(String(v))} formatter={v => [exact(v == null ? undefined : Number(v)), t(labels[metric])]} /><Area type="monotone" dataKey={metric} stroke="var(--accent)" fill="var(--accent-fill)" strokeWidth={2} dot={{ r: 3, strokeWidth: 0, fill: 'var(--accent)' }} isAnimationActive={false} connectNulls={false} /></AreaChart></ResponsiveContainer></div>}
  </section>
}
function Distribution({ title, groups, click, kind }: { kind: 'agent' | 'model'; title: string; groups: Group[]; click: (id: string) => void }) {
  const total = groups.reduce((sum, g) => sum + (g.summary.metrics.total.value ?? 0), 0)
  return <section className="panel"><div className="panel-title"><h2>{t(title)}</h2></div><div className="distribution-list">{groups.length === 0 ? <p className="muted">{t("No reported usage in this period.")}</p> : groups.slice(0, 7).map((g, i) => <button key={g.id} onClick={() => click(g.id)} className="distribution-row"><span aria-hidden="true">{kind === 'agent' ? <AgentGlyph id={g.id} name={g.name} /> : <span className="generic-icon"><Icon name="models" size={13} /></span>}</span><span className="distribution-main"><span className="distribution-name">{g.name === 'unknown' ? t('Unknown') : g.name}</span><span className="meter-track"><span style={{ width: `${total > 0 ? (g.summary.metrics.total.value ?? 0) / total * 100 : 0}%`, opacity: Math.max(.4, 1 - i * .08) }} /></span></span><span className="distribution-count"><MetricValue metric={g.summary.metrics.total} small /><small>{total > 0 && g.summary.metrics.total.value != null ? `${(g.summary.metrics.total.value / total * 100).toFixed(1)}%` : t('No total')}</small></span></button>)}</div></section>
}
function OverviewView({ range, q, revision, onUsage, onPeriod, drill }: { range: string; q: string; revision: number; onUsage: () => void; onPeriod: (range: string) => void; drill: (key: 'agent' | 'model' | 'project' | 'session', id: string, page?: Page) => void }) {
  const { data, error, loading, savedAt } = useLoad<Overview>(`overview?${q}`, revision)
  if (!data) return <Loading error={error} loading={loading} />
  return <><Loading error={error} loading={false} /><CacheStatus loading={loading} savedAt={savedAt} />
    <div className="overview-heading"><span>{t('Your AI usage')}</span><div className="range-switch" aria-label={t('Period')}>{[['1', 'Today'], ['7', '7 days'], ['30', '30 days'], ['all', 'All time']].map(([value, label]) => <button key={value} aria-pressed={range === value} onClick={() => onPeriod(value)}>{t(label)}</button>)}</div></div>
    <button className="primary-stat simple-hero" onClick={onUsage}><span className="eyebrow">{rangeName(range)}</span><div className="hero-amount"><MetricValue metric={data.selected.metrics.total} /><span className="hero-unit">{t('Tokens')}</span></div>{data.changePercent != null && <span className="sub-stat">{t('{arrow} {percent}% today vs yesterday', { arrow: data.changePercent >= 0 ? '↑' : '↓', percent: Math.abs(data.changePercent).toFixed(1) })}</span>}</button>
    <div className="overview-grid"><Timeline data={data} simple /><Distribution kind="agent" title="By Agent" groups={data.agentDistribution} click={id => drill('agent', id, 'agents')} /></div>
    <button className="view-details" onClick={onUsage}>{t('View usage details')} <Icon name="arrow" size={15} /></button>
  </>
}

function UsageBreakdown({ q, revision }: { q: string; revision: number }) {
  const { data } = useLoad<Overview>(`overview?${q}`, revision)
  return data ? <details className="overview-details"><summary>{t('Token breakdown & data details')}</summary><SummaryStrip summary={data.selected} onClick={() => document.querySelector('.table-panel')?.scrollIntoView({ behavior: 'smooth' })} /><p className="coverage-disclaimer">{t('Statistics cover collected records; healthy collectors do not guarantee complete history.')}</p></details> : null
}
function detectionEvidence(value: string) {
  const labels: Record<string, string> = { application: 'Application', executable: 'Executable', editor_extension: 'Editor extension', running_process: 'Running process', configuration_directory: 'Configuration directory', known_directory: 'Configuration directory', usage_directory: 'Usage directory', npm_package: 'npm package' }
  const split = value.indexOf(':')
  return split < 0 ? value : `${t(labels[value.slice(0, split)] ?? value.slice(0, split))}: ${value.slice(split + 1).trim()}`
}
function hasUsageCollector(agent: Agent) { return !!agent.collector && agent.collector.descriptor.mode !== 'inspection' }
function AgentStatus({ agent }: { agent: Agent }) { const state = agent.collector?.health.status ?? 'unsupported'; return <span><span className={`health-tag ${state}`}><span className="status-dot" />{t(agent.collector ? state : 'No token collector yet')}</span>{agent.collector?.coverage && <small>{t(agent.collector.coverage.status)}</small>}</span> }
function agentSourceStatus(agent: Agent) {
  if (!agent.collector) return 'Token source not yet verified'
  if (agent.collector.descriptor.mode === 'inspection') return agent.collector.health.status === 'candidate_source' ? 'Candidate source needs validation' : 'Local sources checked; Token counts unavailable'
  if (!agent.collector.enabled) return 'Collection disabled'
  if (!agent.detection.sourceAvailable) return 'Configured source not found'
  if (agent.collector.health.status === 'waiting') return 'Awaiting source validation'
  return 'Usage source found'
}
function AgentsView({ q, revision, filters, select, drill }: { q: string; revision: number; filters: Filters; select: (key: keyof Filters, value: string) => void; drill: (key: 'agent' | 'model' | 'project' | 'session', id: string, page?: Page) => void }) {
  const { data, error, loading, savedAt } = useLoad<Agent[]>(`agents?${q}`, revision)
  const [detail, setDetail] = useState<string>()
  const selected = data?.find(a => a.id === (filters.agent || detail))
  return <><Loading error={error} loading={loading && !data} /><CacheStatus loading={loading} savedAt={savedAt} />{selected && <section className="panel agent-detail"><div className="panel-title"><div><h2>{selected.name}</h2><p>{t(agentSourceStatus(selected))}</p></div><button className="quiet-button" onClick={() => { setDetail(undefined); select('agent', '') }}>{t("All agents")}</button></div><div className="period-tabs">{['1', '7', '30', 'all'].map(r => <button key={r} className={filters.range === r ? 'active' : ''} onClick={() => select('range', r)}>{rangeName(r)}</button>)}<button onClick={() => drill('agent', selected.id, 'models')}>{t("Models")}</button><button onClick={() => drill('agent', selected.id, 'projects')}>{t("Projects")}</button><button onClick={() => drill('agent', selected.id, 'sessions')}>{t("Sessions")}</button><button onClick={() => drill('agent', selected.id)}>{t("View requests")}<Icon name="arrow" size={14} /></button></div><SummaryStrip summary={selected.summary} onClick={() => drill('agent', selected.id)} /><div className="detail-metadata"><span>{t('Models: {models}', { models: selected.models.join(', ') || t('Unknown') })}</span><span>{t('Projects: {projects} · Sessions: {sessions}', { projects: hasUsageCollector(selected) && selected.collector?.descriptor.capabilities.project !== 'unsupported' ? selected.summary.projects : t('Unknown'), sessions: hasUsageCollector(selected) ? selected.summary.sessions : '—' })}</span><span>{t('Last seen: {time}', { time: time(selected.lastSeen) })}</span></div></section>}
    {selected && <details className="panel agent-technical"><summary>{t("Connection details")}</summary><div className="survey-panel"><TokenSurveyButton agentID={selected.id} /><SourceCoverageView coverage={selected.collector?.coverage} /></div></details>}
    {selected && <details className="panel discovery-details"><summary>{t("Detection evidence")}</summary><div className="panel-title"><h2>{t('Detection evidence')}</h2><span className="muted">{t('Application version')}: {selected.detection.version ?? t('Unknown')}</span></div><ul>{selected.detection.evidence.map(evidence => <li key={evidence}>{detectionEvidence(evidence)}</li>)}</ul></details>}
    {selected && <AgentTimeline q={q} revision={revision} agent={selected.id} />}
    <section className="panel table-panel"><div className="panel-title"><h2>{t("Discovered agents")}</h2><span className="muted">{t('{count} total', { count: data?.length ?? 0 })}</span></div><div className="table-scroll"><table><thead><tr><th>{t("Agent")}</th><th>{t("Collector")}</th><th className="number">{t("Today")}</th><th className="number">{t("Selected period")}</th><th className="number">{t("All collected time")}</th><th className="number">{t("Sessions")}</th><th>{t("Models / Projects")}</th><th>{t("Last seen")}</th></tr></thead><tbody>{data?.map(a => <tr key={a.id} className="clickable-row" onClick={() => { setDetail(a.id); select('agent', a.id) }}><td><button className="name-button"><AgentGlyph id={a.id} name={a.name} /><span>{a.name}<small>{t(a.detection.installed ? 'Installed' : a.detection.evidence.length ? 'Configuration found' : 'No current installation found')} · {t(agentSourceStatus(a))}</small></span></button></td><td><AgentStatus agent={a} /></td><td className="number"><MetricValue metric={a.today.metrics.total} small /></td><td className="number"><MetricValue metric={a.summary.metrics.total} small /></td><td className="number"><MetricValue metric={a.allTime.metrics.total} small /></td><td className="number">{hasUsageCollector(a) ? a.summary.sessions : '—'}</td><td><span className="cell-models">{a.models.slice(0, 2).join(', ') || t('Unknown')}{a.models.length > 2 && ` +${a.models.length - 2}`}<small>{hasUsageCollector(a) && a.collector?.descriptor.capabilities.project !== 'unsupported' ? t('{count} projects', { count: a.summary.projects }) : t('Unknown')}</small></span></td><td className="muted nowrap">{relative(a.lastSeen)}</td></tr>)}</tbody></table></div></section>
    {data?.length === 0 && <Empty>{t("No discovered agents match this filter.")}</Empty>}
  </>
}
function AgentTimeline({ q, revision, agent }: { q: string; revision: number; agent: string }) { const scope = new URLSearchParams(q); scope.set('agent', agent); const { data } = useLoad<Overview>(`overview?${scope}`, revision); return data ? <Timeline data={data} /> : null }
function GroupsView({ dimension, q, revision, drill }: { dimension: 'models' | 'projects' | 'sessions'; q: string; revision: number; drill: (key: 'agent' | 'model' | 'project' | 'session', id: string) => void }) {
  const { data, error, loading } = useLoad<Group[]>(`${dimension}?${q}`, revision)
  const key = ({ models: 'model', projects: 'project', sessions: 'session' } as const)[dimension]
  return <><Loading error={error} loading={loading && !data} /><section className="panel table-panel"><div className="panel-title"><h2>{t('{dimension} by reported usage', { dimension: t(titles[dimension]) })}</h2></div><div className="table-scroll"><table><thead><tr><th>{dimension === 'models' ? t('Raw model identifier') : dimension === 'projects' ? t('Project') : t('Session')}</th><th className="number">{t("Tokens")}</th><th className="number">{t("Input (including cache)")}</th><th className="number">{t("Output")}</th><th className="number">{t("Cache read")}</th><th className="number">{t("Reasoning")}</th><th className="number">{t("Sessions")}</th><th>{t("Agents / Projects")}</th><th>{t("Last activity")}</th></tr></thead><tbody>{data?.map(g => <tr key={g.id} className="clickable-row" onClick={() => drill(key, g.id)}><td><button className="name-button"><Icon name={dimension} /><span className={dimension === 'sessions' ? 'mono truncate-session' : ''}>{g.name === 'unknown' ? t('Unknown') : g.name}<small>{g.path}</small></span></button></td>{(['total', 'input', 'output', 'cacheRead', 'reasoning'] as MetricName[]).map(m => <td key={m} className="number"><MetricValue metric={g.summary.metrics[m]} small /></td>)}<td className="number">{g.summary.sessions}</td><td><span className="cell-models">{g.agentIDs.join(', ')}<small>{t('{count} projects', { count: g.summary.projects })}</small></span></td><td className="muted nowrap">{relative(g.lastActivity)}</td></tr>)}</tbody></table></div>{data?.length === 0 && <Empty />}</section></>
}
function UsageView({ q, revision }: { q: string; revision: number }) {
  const [offset, setOffset] = useState(0)
  const [selected, setSelected] = useState<UsageEvent>()
  const { data, error, loading } = useLoad<EventPage>(`events?${q}&limit=50&offset=${offset}`, revision)
  useEffect(() => { setOffset(0); setSelected(undefined) }, [q])
  function exportPage() {
    if (!data) return
    const fields = ['timestamp', 'agentName', 'rawModelName', 'sessionID', 'total', 'input', 'output', 'cacheRead', 'cacheWrite', 'reasoning', 'sourcePath', 'sourceLine', 'quality']
    const escape = (v: unknown) => { const text = v == null ? '' : String(v); return `"${text.replaceAll('"', '""')}"` }
    const lines = data.events.map(e => [e.timestamp, e.agentName, e.rawModelName, e.sessionID, ...(['total', 'input', 'output', 'cacheRead', 'cacheWrite', 'reasoning'] as MetricName[]).map(k => e.metrics[k].value), e.sourcePath, e.sourceLine, e.quality].map(escape).join(','))
    const url = URL.createObjectURL(new Blob([fields.join(',') + '\n' + lines.join('\n')], { type: 'text/csv' }))
    const link = document.createElement('a'); link.href = url; link.download = 'AgentBarBar-usage-page.csv'; link.click(); URL.revokeObjectURL(url)
  }
  return <><Loading error={error} loading={loading && !data} /><section className="panel table-panel"><div className="panel-title"><div><h2>{t("Usage events")}</h2><p>{data ? t('{count} recorded requests', { count: exact(data.total) }) : t('Source provenance for every count')}</p></div><button className="quiet-button" onClick={exportPage} disabled={!data?.events.length}>{t("Export page CSV")}</button></div><div className="table-scroll"><table><thead><tr><th>{t("Time")}</th><th>{t("Agent / Model")}</th><th>{t("Project")}</th><th className="number">{t("Total")}</th></tr></thead><tbody>{data?.events.map(e => <tr key={e.id} className="clickable-row" onClick={() => setSelected(e)}><td className="nowrap"><button className="text-button">{time(e.timestamp)}</button></td><td><span className="cell-models">{e.agentName}<small>{e.rawModelName ?? t('Unknown model')}</small></span></td><td>{e.project?.name ?? t('Unknown')}</td><td className="number"><MetricValue metric={e.metrics.total} small /></td></tr>)}</tbody></table></div>{data?.events.length === 0 && <Empty />}<div className="pagination"><span>{data && data.total > 0 ? t('{start}–{end} of {total}', { start: offset + 1, end: Math.min(offset + 50, data.total), total: exact(data.total) }) : t('0 records')} · {t('Click for details')}</span><div><button onClick={() => setOffset(v => Math.max(0, v - 50))} disabled={offset === 0}>{t("Previous")}</button><button onClick={() => setOffset(v => v + 50)} disabled={!data || offset + 50 >= data.total}>{t("Next")}</button></div></div></section>{selected && <SourceDrawer event={selected} close={() => setSelected(undefined)} />}</>
}
function SourceDrawer({ event: e, close }: { event: UsageEvent; close: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null)
  useEffect(() => { dialog.current?.showModal() }, [])
  return <dialog className="source-dialog" ref={dialog} onCancel={close}><div className="drawer-head"><div><span className="eyebrow">{t("WHERE DID THIS NUMBER COME FROM?")}</span><h2>{e.agentName}</h2></div><button className="icon-button" aria-label={t("Close source details")} onClick={close}><Icon name="close" /></button></div><div className="drawer-body"><div className="source-total"><MetricValue metric={e.metrics.total} /><span>{t('tokens')} · {e.isEstimated ? t('Estimated') : e.quality === 'exact' ? t('Exact as reported by source') : t('Partial source coverage')}</span></div><dl>{Object.entries({ Time: time(e.timestamp), Agent: e.agentName, 'Raw model': e.rawModelName ?? t('Unknown'), Provider: e.provider ?? t('Unknown'), Session: e.sessionID ?? t('Unknown'), Project: e.project?.name ?? t('Unknown'), 'Working directory': e.workingDirectory ?? t('Unknown'), 'Project detection': e.project ? `${e.project.detectionMethod} · ${t('confidence')} ${e.project.confidence}` : t('Not available'), Source: e.sourcePath, Location: e.sourceType === 'local_sqlite' ? t('SQLite message · {id}', { id: e.sourceMetadata.source_row_id ?? e.sourceEventID }) : t('Line {line} · byte {byte}', { line: e.sourceLine, byte: e.sourceOffset }), Collector: `${e.collectorID} · ${e.collectorVersion}`, Parser: e.parserVersion, 'Source event ID': e.sourceEventID, Fingerprint: e.fingerprint }).map(([label, value]) => <div key={label}><dt>{t(label)}</dt><dd>{value}</dd></div>)}</dl><h3>{t("Reported token breakdown")}</h3><div className="source-metrics">{(Object.keys(labels) as MetricName[]).map(k => <div key={k}><span>{t(labels[k])}</span><MetricValue metric={e.metrics[k]} small /></div>)}</div><p className="muted">{t("Input includes cache reads and writes. Output includes reasoning. These components overlap; total does not add them twice.")}</p><h3>{t("Source metadata")}</h3><pre>{JSON.stringify(e.sourceMetadata, null, 2)}</pre><p className="muted">{t("Only metadata is stored. Prompt, response and tool content are excluded.")}</p></div></dialog>
}
