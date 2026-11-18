import { describe, expect, it, vi } from 'vitest'
import { http, HttpResponse } from 'msw'
import { api, ok } from '@/api/cliente'
import { ApiError } from '@/api/errores'
import { API, db, servidor } from '@/test/servidor'
import { entrarComoAna } from '@/test/utilidades'
import {
  CANAL_AUTH,
  CLAVE_REFRESH,
  alCerrarSesion,
  arrancarSesion,
  cerrarSesion,
  iniciarSesion,
  iniciarSincronizacionPestanas,
  nombreDispositivo,
  refrescarSesion,
  useAuth,
} from './sesion'

describe('sesión', () => {
  it('normaliza un teléfono local a E.164 antes de enviarlo (la API exige E.164)', async () => {
    let cuerpo: Record<string, unknown> = {}
    servidor.events.on('request:start', ({ request }) => {
      if (request.url.endsWith('/auth/login')) void request.clone().json().then((b) => (cuerpo = b as Record<string, unknown>))
    })
    await expect(iniciarSesion(' 7000 0001 ', 'Demo-Ana-2026!')).resolves.toMatchObject({ display_name: 'Ana Demo' })
    expect(cuerpo.identifier).toBe('+50670000001')
    servidor.events.removeAllListeners()
  })

  it('inicia sesión con teléfono en `identifier` y guarda el access solo en memoria', async () => {
    let cuerpo: Record<string, unknown> = {}
    servidor.events.on('request:start', ({ request }) => {
      if (request.url.endsWith('/auth/login')) void request.clone().json().then((b) => (cuerpo = b as Record<string, unknown>))
    })
    const yo = await entrarComoAna()
    expect(yo.display_name).toBe('Ana Demo')
    expect(cuerpo.identifier).toBe('+50670000001')
    expect(cuerpo.device_name).toEqual(expect.any(String))
    const estado = useAuth.getState()
    expect(estado.estado).toBe('autenticado')
    expect(estado.accessToken).toMatch(/^mock\./)
    // El access token nunca se persiste; el refresh sí.
    const guardado = Array.from({ length: localStorage.length }, (_, i) => localStorage.getItem(localStorage.key(i) ?? '') ?? '').join('|')
    expect(guardado).not.toContain(estado.accessToken)
    expect(localStorage.getItem(CLAVE_REFRESH)).toBeTruthy()
    servidor.events.removeAllListeners()
  })

  it('acepta correo como identificador y responde 401 genérico con credenciales malas', async () => {
    await expect(iniciarSesion('ANA@demo.crchat.local', 'Demo-Ana-2026!')).resolves.toMatchObject({ display_name: 'Ana Demo' })
    await expect(iniciarSesion('ana@demo.crchat.local', 'mala')).rejects.toMatchObject({ status: 401 })
  })

  it('renueva el token de forma silenciosa ante un 401 y repite la petición', async () => {
    await entrarComoAna()
    const { sesionId, accessToken } = useAuth.getState()
    db.caducarAccess(sesionId ?? '')
    const yo = await ok(api.GET('/me'))
    expect(yo.display_name).toBe('Ana Demo')
    expect(useAuth.getState().accessToken).not.toBe(accessToken)
  })

  it('el refresco es single-flight: varias llamadas simultáneas rotan una sola vez', async () => {
    await entrarComoAna()
    let llamadas = 0
    servidor.events.on('request:start', ({ request }) => {
      if (request.url.endsWith('/auth/refresh')) llamadas++
    })
    const [a, b, c] = await Promise.all([refrescarSesion(), refrescarSesion(), refrescarSesion()])
    expect(a).toBeTruthy()
    expect(a).toBe(b)
    expect(b).toBe(c)
    expect(llamadas).toBe(1)
    servidor.events.removeAllListeners()
  })

  it('si el refresh ya no vale, cierra la sesión local con motivo "expirada"', async () => {
    await entrarComoAna()
    const oyente = vi.fn()
    alCerrarSesion(oyente)
    servidor.use(http.post(`${API}/auth/refresh`, () => HttpResponse.json({ type: 'x', title: 'No', status: 401 }, { status: 401 })))
    await expect(refrescarSesion()).resolves.toBeNull()
    expect(useAuth.getState()).toMatchObject({ estado: 'anonimo', accessToken: null, motivoSalida: 'expirada' })
    expect(localStorage.getItem(CLAVE_REFRESH)).toBeNull()
    expect(oyente).toHaveBeenCalledWith('expirada')
  })

  it('arranca recuperando la sesión con el refresh guardado', async () => {
    await entrarComoAna()
    useAuth.setState({ estado: 'iniciando', accessToken: null, usuario: null })
    await arrancarSesion()
    expect(useAuth.getState()).toMatchObject({ estado: 'autenticado', usuario: { display_name: 'Ana Demo' } })
  })

  it('sin refresh guardado arranca como anónimo', async () => {
    await arrancarSesion()
    expect(useAuth.getState().estado).toBe('anonimo')
  })

  it('logout revoca la sesión en el servidor: el token deja de valer', async () => {
    await entrarComoAna()
    const token = useAuth.getState().accessToken
    await cerrarSesion()
    expect(useAuth.getState().estado).toBe('anonimo')
    expect(() => db.autenticar(token)).toThrow()
  })

  it('un logout en otra pestaña (BroadcastChannel) cierra esta', async () => {
    const dejar = iniciarSincronizacionPestanas()
    await entrarComoAna()
    const otraPestana = new BroadcastChannel(CANAL_AUTH)
    otraPestana.postMessage({ tipo: 'salida' })
    await vi.waitFor(() => {
      expect(useAuth.getState()).toMatchObject({ estado: 'anonimo', motivoSalida: 'otra-pestana' })
    })
    otraPestana.close()
    dejar()
  })

  it('los errores llevan el problema RFC 9457', async () => {
    await entrarComoAna()
    const r = ok(api.GET('/conversations/{conversationId}', { params: { path: { conversationId: '00000000-0000-7000-8000-000000000000' } } }))
    await expect(r).rejects.toBeInstanceOf(ApiError)
    await expect(r).rejects.toMatchObject({ status: 404, message: 'Conversación no encontrada.' })
  })

  it('deriva un nombre de dispositivo legible', () => {
    expect(nombreDispositivo('Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0')).toBe('Firefox en Linux')
    expect(nombreDispositivo('Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit Safari/604.1')).toBe('Safari en iOS')
  })
})
