import { useEffect, useState } from 'react'
import { api } from './api'

interface Entry<T = unknown> { data: T; savedAt: number }
interface Bootstrap { namespace: string; language?: string; entries: { key: string; body: string; savedAt: number }[] }
const memory = new Map<string, Entry>()
const pending = new Map<string, Promise<Entry>>()
const storage = 'agentbarbar.snapshots.v1'
const persistent = /^(overview|summary|agents|models|projects|sessions|filters|collectors|events)(\?|$)/
let namespace = ''
export let bootLanguage: string | undefined
export function cacheKey(path: string): string {
  const [route, search = ''] = path.split('?'); const params = new URLSearchParams(search); params.sort()
  return params.size ? `${route}?${params}` : route
}
function freshEnough(entry: Entry): boolean { return Number.isFinite(entry.savedAt) && Date.now() - entry.savedAt < 7 * 86400000 }
if (typeof document !== 'undefined') {
  try {
    const boot = JSON.parse(document.getElementById('agentbarbar-cache')?.textContent ?? '{}') as Bootstrap
    namespace = boot.namespace ?? ''; bootLanguage = boot.language
    const stored = JSON.parse(localStorage.getItem(storage) ?? '{}')
    if (namespace && stored.namespace === namespace) for (const [key, entry] of stored.entries ?? []) if (persistent.test(key) && freshEnough(entry)) memory.set(key, entry)
    for (const row of boot.entries ?? []) {
      const entry = { data: JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(row.body), c => c.charCodeAt(0)))), savedAt: row.savedAt * 1000 }
      const key = cacheKey(row.key)
      if (freshEnough(entry) && entry.savedAt > (memory.get(key)?.savedAt ?? 0)) memory.set(key, entry)
    }
  } catch { /* Damaged/unavailable cache never prevents a live request. */ }
}
function save() {
  if (memory.size > 64) for (const [key] of [...memory].sort((a, b) => a[1].savedAt - b[1].savedAt).slice(0, memory.size - 64)) memory.delete(key)
  if (!namespace) return
  const entries = [...memory].filter(([key]) => persistent.test(key)).sort((a, b) => b[1].savedAt - a[1].savedAt).slice(0, 24)
  while (entries.length && JSON.stringify(entries).length > 2_000_000) entries.pop()
  try { localStorage.setItem(storage, JSON.stringify({ namespace, entries })) } catch { /* Private browsing/quota: retain memory cache. */ }
}
export function cached<T>(path: string): Entry<T> | undefined { return memory.get(cacheKey(path)) as Entry<T> | undefined }
function revalidate<T>(path: string): Promise<Entry<T>> {
  const key = cacheKey(path)
  let request = pending.get(key)
  if (!request) {
    request = api<unknown>(path).then(data => { const entry = { data, savedAt: Date.now() }; memory.set(key, entry); save(); return entry }).finally(() => pending.delete(key))
    pending.set(key, request)
  }
  return request as Promise<Entry<T>>
}
export function useLoad<T>(path: string, revision: number | string) {
  const [state, setState] = useState<{ key: string; entry?: Entry<T>; error: string; loading: boolean }>(() => ({ key: cacheKey(path), entry: cached<T>(path), error: '', loading: true }))
  const key = cacheKey(path)
  const current = state.key === key ? state : { key, entry: cached<T>(path), error: '', loading: true }
  useEffect(() => {
    let active = true
    setState(old => ({ key, entry: cached<T>(path) ?? (old.key === key ? old.entry : undefined), error: '', loading: true }))
    revalidate<T>(path).then(entry => { if (active) setState({ key, entry, error: '', loading: false }) }).catch(error => { if (active) setState(old => ({ ...old, error: String(error.message), loading: false })) })
    return () => { active = false }
  }, [path, key, revision])
  return { data: current.entry?.data, savedAt: current.entry?.savedAt, error: current.error, loading: current.loading }
}
