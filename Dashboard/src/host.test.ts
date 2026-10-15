import { afterEach, expect, test, vi } from 'vitest'
import { api, post } from './api'
import { nativeHost } from './host'
afterEach(() => vi.unstubAllGlobals())
test('native bridge preserves business route/body and does not open HTTP', async () => {
 const invoke=vi.fn().mockResolvedValue({events:2});const fetch=vi.fn()
 vi.stubGlobal('window',{__TAURI__:{core:{invoke}}});vi.stubGlobal('fetch',fetch)
 expect(await api('summary?agent=codex')).toEqual({events:2})
 expect(invoke).toHaveBeenCalledWith('business_request',{method:'GET',path:'summary?agent=codex',body:null})
 await post('settings',{language:'en'})
 expect(invoke).toHaveBeenLastCalledWith('business_request',{method:'POST',path:'settings',body:{language:'en'}})
 expect(fetch).not.toHaveBeenCalled()
})
test('structured recoverable error stays safe and Node has no native host', async () => {
 expect(nativeHost()).toBe(false)
 vi.stubGlobal('window',{__TAURI__:{core:{invoke:vi.fn().mockRejectedValue({code:'INVALID_SETTINGS',message:'Invalid or unsupported settings',recoverable:true})}}})
 await expect(post('settings',{})).rejects.toThrow('Invalid or unsupported settings')
})
