import { nativeHost } from './host'
import { useSyncExternalStore } from 'react'
import { api, post } from './api'
import type { Settings } from './schema'

export const themes = [
  { id: 'forest', name: 'Forest', description: 'Calm greens and soft contrast' },
  { id: 'paper', name: 'Paper', description: 'Warm tones with a notebook feel' },
  { id: 'ocean', name: 'Ocean', description: 'Cool blues and clear layers' },
  { id: 'mono', name: 'Mono', description: 'Black, white and precise numbers' },
] as const
export type Theme = typeof themes[number]['id']
export type Appearance = 'system' | 'light' | 'dark'
const listeners = new Set<() => void>()
let revision = 0
export function appearanceRevision() { return revision }
const media = typeof window !== 'undefined' ? window.matchMedia('(prefers-color-scheme: dark)') : undefined
function theme(value?: string): Theme { return themes.some(t => t.id === value) ? value as Theme : 'forest' }
function appearance(value?: string): Appearance { return value === 'light' || value === 'dark' ? value : 'system' }
let state = {
  theme: theme(typeof document !== 'undefined' ? document.documentElement.dataset.theme : undefined),
  appearance: appearance(typeof document !== 'undefined' ? document.documentElement.dataset.appearance : undefined),
  systemDark: media?.matches ?? false,
  saving: false,
}
function publish() {
  if (typeof document !== 'undefined') {
    document.documentElement.dataset.theme = state.theme
    document.documentElement.dataset.appearance = nativeHost() && state.appearance === 'system' ? (state.systemDark ? 'dark' : 'light') : state.appearance
  }
  listeners.forEach(listener => listener())
}
publish()
media?.addEventListener('change', event => { state = { ...state, systemDark: event.matches }; publish() })
window.addEventListener('agentbar:system_theme_changed', event => { state = { ...state, systemDark: Boolean((event as CustomEvent).detail?.dark) }; publish() })
export function useAppearance() {
  return useSyncExternalStore(callback => { listeners.add(callback); return () => listeners.delete(callback) }, () => state)
}
export function syncAppearance(settings: Settings) {
  if (state.saving) return
  const nextTheme = theme(settings.dashboardTheme), nextAppearance = appearance(settings.dashboardAppearance)
  if (state.theme !== nextTheme || state.appearance !== nextAppearance) {
    state = { ...state, theme: nextTheme, appearance: nextAppearance }; publish()
  }
}
export async function saveAppearance(next: { theme: Theme; appearance: Appearance }): Promise<Settings> {
  if (state.saving) throw new Error('Appearance is being saved')
  const previous = state
  revision += 1
  state = { ...state, ...next, saving: true }; publish()
  try {
    // Preserve unrelated preferences, including any source changes from another window.
    const latest = await api<Settings>('settings')
    const saved = await post<Settings>('settings', { ...latest, dashboardTheme: next.theme, dashboardAppearance: next.appearance })
    state = { ...state, theme: theme(saved.dashboardTheme), appearance: appearance(saved.dashboardAppearance), saving: false }; publish()
    return saved
  } catch (error) {
    state = { ...previous, systemDark: state.systemDark, saving: false }; publish()
    throw error
  }
}
