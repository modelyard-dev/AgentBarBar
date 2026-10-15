import { useState } from 'react'
import { t } from './i18n'
import { themes, saveAppearance, useAppearance, type Theme, type Appearance } from './appearance'
import type { Settings } from './schema'

export function AppearanceSettings({ saved }: { saved: (settings: Settings) => void }) {
  const preferences = useAppearance()
  const [error, setError] = useState('')
  const dark = preferences.appearance === 'dark' || (preferences.appearance === 'system' && preferences.systemDark)
  async function choose(theme: Theme, appearance: Appearance) {
    setError('')
    try { saved(await saveAppearance({ theme, appearance })) } catch { setError('Could not save appearance. Please try again.') }
  }
  return <section className="panel appearance-panel" aria-labelledby="appearance-title">
    <div className="panel-title"><div><h2 id="appearance-title">{t('Appearance')}</h2><p>{t('Choose a look that feels at home.')}</p></div></div>
    <div className="appearance-body">
      <div className="theme-grid" role="group" aria-label={t('Theme')}>
        {themes.map(theme => <button key={theme.id} className="theme-card" aria-pressed={preferences.theme === theme.id} aria-label={t(theme.name)} disabled={preferences.saving} onClick={() => choose(theme.id, preferences.appearance)}>
          <div className="theme-preview" data-theme={theme.id} data-mode={dark ? 'dark' : 'light'} aria-hidden="true">
            <div className="preview-heading"><i /><span /><b /></div>
            <div className="preview-number">128.4K</div>
            <div className="preview-bottom"><svg viewBox="0 0 120 40"><path className="preview-area" d="M0 34L20 28L40 31L60 13L80 18L100 8L120 3V40H0Z" /><path className="preview-line" d="M0 34L20 28L40 31L60 13L80 18L100 8L120 3" /></svg><div className="preview-bars"><i /><i /><i /></div></div>
          </div>
          <div className="theme-label"><strong>{t(theme.name)}</strong><span className="theme-selected" aria-hidden="true">{preferences.theme === theme.id ? '✓' : ''}</span></div>
          <p>{t(theme.description)}</p>
        </button>)}
      </div>
      <div className="appearance-mode"><span>{t('Color mode')}</span><div role="group" aria-label={t('Color mode')}>{(['system', 'light', 'dark'] as const).map(mode => <button key={mode} aria-pressed={preferences.appearance === mode} disabled={preferences.saving} onClick={() => choose(preferences.theme, mode)}>{t(mode === 'system' ? 'Follow system' : mode === 'light' ? 'Light' : 'Dark')}</button>)}</div></div>
      {error && <p role="alert" className="appearance-error">{t(error)}</p>}
    </div>
  </section>
}
