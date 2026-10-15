import { nativeHost, hostRequest } from './host'
export async function api<T>(path: string, signal?: AbortSignal): Promise<T> {
  if (nativeHost()) { signal?.throwIfAborted(); const value = await hostRequest<T>('GET', path); signal?.throwIfAborted(); return value }
  const response = await fetch(`/api/${path}`, { signal, credentials: 'same-origin' })
  if (!response.ok) {
    const json = await response.json().catch(() => ({}))
    throw new Error(json.error ?? `Local API returned ${response.status}`)
  }
  return response.json() as Promise<T>
}
export async function post<T>(path: string, body?: unknown): Promise<T> {
  if (nativeHost()) return hostRequest<T>('POST', path, body)
  const response = await fetch(`/api/${path}`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-AgentBarBar': '1' }, body: body == null ? undefined : JSON.stringify(body), credentials: 'same-origin' })
  const data = await response.json()
  if (!response.ok) throw new Error(data.error ?? `Local API returned ${response.status}`)
  return data as T
}
