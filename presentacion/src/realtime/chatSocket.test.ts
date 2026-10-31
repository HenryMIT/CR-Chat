import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ChatSocket, type OpcionesChatSocket, type SocketBasico } from './chatSocket'

/** Doble de WebSocket controlable desde la prueba. */
class SocketFalso implements SocketBasico {
  readyState = 0
  enviados: { type: string; id: string; data: unknown }[] = []
  onopen: ((ev: Event) => void) | null = null
  onmessage: ((ev: MessageEvent) => void) | null = null
  onclose: ((ev: CloseEvent) => void) | null = null
  onerror: ((ev: Event) => void) | null = null
  cerradoCon: number | undefined

  send(datos: string) {
    this.enviados.push(JSON.parse(datos) as { type: string; id: string; data: unknown })
  }
  close(codigo?: number) {
    this.cerradoCon = codigo
    this.readyState = 3
  }
  abrir() {
    this.readyState = 1
    this.onopen?.(new Event('open'))
  }
  recibir(type: string, data: unknown = {}) {
    this.onmessage?.(new MessageEvent('message', { data: JSON.stringify({ type, id: 'x', ts: '', data }) }))
  }
  cerrarDesdeServidor(code: number, reason = '') {
    this.readyState = 3
    this.onclose?.({ code, reason } as CloseEvent)
  }
  tipos() {
    return this.enviados.map((e) => e.type)
  }
}

function crear(extra: Partial<OpcionesChatSocket> = {}) {
  const sockets: SocketFalso[] = []
  const obtenerToken = vi.fn((forzar: boolean) => Promise.resolve(forzar ? 'renovado' : 'token'))
  const opciones = {
    url: 'ws://x/ws',
    obtenerToken,
    alEvento: vi.fn(),
    alEstado: vi.fn(),
    alResincronizar: vi.fn(),
    alConectar: vi.fn(),
    alSesionRevocada: vi.fn(),
    aleatorio: () => 0.5, // jitter neutro: retardo = base
    crearSocket: () => {
      const s = new SocketFalso()
      sockets.push(s)
      return s
    },
    ...extra,
  }
  const cs = new ChatSocket(opciones)
  const ultimo = () => {
    const s = sockets[sockets.length - 1]
    if (!s) throw new Error('sin socket')
    return s
  }
  return { cs, sockets, ultimo, opciones, obtenerToken }
}

async function autenticar(s: SocketFalso) {
  s.abrir()
  await vi.waitFor(() => {
    expect(s.tipos()).toContain('auth')
  })
  s.recibir('auth.ok', { user_id: 'u', session_id: 's', expires_at: '', heartbeat_interval: 25 })
}

describe('ChatSocket', () => {
  beforeEach(() => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('se autentica con el primer mensaje `auth` (el token no va en la URL)', async () => {
    const { cs, ultimo, opciones } = crear()
    cs.conectar()
    const s = ultimo()
    await autenticar(s)
    expect(s.enviados[0]).toMatchObject({ type: 'auth', data: { access_token: 'token' } })
    expect(cs.estado).toBe('conectado')
    expect(opciones.alConectar).toHaveBeenCalledOnce()
    expect(opciones.alResincronizar).not.toHaveBeenCalled()
  })

  it('reconecta con backoff exponencial 1 s, 2 s, 4 s… hasta 30 s', () => {
    const { cs } = crear()
    expect([0, 1, 2, 3, 4, 5, 6].map((i) => cs.calcularRetardo(i))).toEqual([1000, 2000, 4000, 8000, 16000, 30000, 30000])
    const conJitter = crear({ aleatorio: () => 1 }).cs
    expect(conJitter.calcularRetardo(0)).toBe(1250)
    expect(conJitter.calcularRetardo(10)).toBe(30000)
  })

  it('tras un corte reintenta y, al volver a autenticarse, pide resincronizar', async () => {
    const { cs, sockets, ultimo, opciones } = crear()
    cs.conectar()
    await autenticar(ultimo())
    ultimo().cerrarDesdeServidor(1006)
    expect(cs.estado).toBe('reconectando')

    vi.advanceTimersByTime(999)
    expect(sockets).toHaveLength(1)
    vi.advanceTimersByTime(1)
    expect(sockets).toHaveLength(2)

    // Segundo corte antes de autenticar: el siguiente intento espera 2 s.
    ultimo().cerrarDesdeServidor(1006)
    vi.advanceTimersByTime(1999)
    expect(sockets).toHaveLength(2)
    vi.advanceTimersByTime(1)
    expect(sockets).toHaveLength(3)

    await autenticar(ultimo())
    expect(opciones.alResincronizar).toHaveBeenCalledOnce()
    expect(cs.estado).toBe('conectado')
  })

  it('heartbeat: ping cada 25 s y sin pong en 10 s se reconecta', async () => {
    const { cs, sockets, ultimo } = crear()
    cs.conectar()
    const s = ultimo()
    await autenticar(s)
    vi.advanceTimersByTime(25_000)
    expect(s.tipos()).toContain('ping')
    s.recibir('pong')
    vi.advanceTimersByTime(10_000)
    expect(sockets).toHaveLength(1)

    vi.advanceTimersByTime(15_000) // segundo ping, sin respuesta
    vi.advanceTimersByTime(10_000)
    expect(s.cerradoCon).toBe(4000)
    expect(cs.estado).toBe('reconectando')
    vi.advanceTimersByTime(1000)
    expect(sockets).toHaveLength(2)
  })

  it('auth.expiring: renueva el token y reautentica sobre la misma conexión', async () => {
    const { cs, sockets, ultimo, obtenerToken } = crear()
    cs.conectar()
    const s = ultimo()
    await autenticar(s)
    s.recibir('auth.expiring', { expires_at: '' })
    await vi.waitFor(() => {
      expect(s.enviados.filter((e) => e.type === 'auth')).toHaveLength(2)
    })
    expect(obtenerToken).toHaveBeenLastCalledWith(true)
    expect(s.enviados.at(-1)).toMatchObject({ type: 'auth', data: { access_token: 'renovado' } })
    expect(sockets).toHaveLength(1)
  })

  it('4401 por token: reconecta forzando la renovación del token', async () => {
    const { cs, ultimo, obtenerToken } = crear()
    cs.conectar()
    await autenticar(ultimo())
    ultimo().cerrarDesdeServidor(4401, 'token_expired')
    vi.advanceTimersByTime(1000)
    ultimo().abrir()
    await vi.waitFor(() => {
      expect(obtenerToken).toHaveBeenLastCalledWith(true)
    })
  })

  it('4401 session_revoked: no reintenta y avisa para volver al login', async () => {
    const { cs, sockets, ultimo, opciones } = crear()
    cs.conectar()
    await autenticar(ultimo())
    ultimo().cerrarDesdeServidor(4401, 'session_revoked')
    vi.advanceTimersByTime(60_000)
    expect(sockets).toHaveLength(1)
    expect(cs.estado).toBe('cerrado')
    expect(opciones.alSesionRevocada).toHaveBeenCalledOnce()
  })

  it('4029 espera 30 s; 1000 y 1008 no reintentan', async () => {
    const a = crear()
    a.cs.conectar()
    await autenticar(a.ultimo())
    a.ultimo().cerrarDesdeServidor(4029)
    vi.advanceTimersByTime(29_999)
    expect(a.sockets).toHaveLength(1)
    vi.advanceTimersByTime(1)
    expect(a.sockets).toHaveLength(2)

    const b = crear()
    b.cs.conectar()
    await autenticar(b.ultimo())
    b.ultimo().cerrarDesdeServidor(1008)
    vi.advanceTimersByTime(60_000)
    expect(b.sockets).toHaveLength(1)
    expect(b.cs.estado).toBe('cerrado')
  })

  it('reenvía los eventos de negocio e ignora tipos desconocidos', async () => {
    const { cs, ultimo, opciones } = crear()
    cs.conectar()
    const s = ultimo()
    await autenticar(s)
    s.recibir('typing', { conversation_id: 'c', user_id: 'u2', state: 'start' })
    s.recibir('evento.inventado', {})
    expect(opciones.alEvento).toHaveBeenCalledOnce()
    expect(opciones.alEvento).toHaveBeenCalledWith(expect.objectContaining({ type: 'typing' }))
  })

  it('no envía eventos de cliente antes de autenticarse; desconectar no reintenta', async () => {
    const { cs, sockets, ultimo } = crear()
    cs.conectar()
    expect(cs.enviar('typing', { conversation_id: 'c', state: 'start' })).toBe(false)
    await autenticar(ultimo())
    expect(cs.enviar('typing', { conversation_id: 'c', state: 'start' })).toBe(true)
    cs.desconectar()
    vi.advanceTimersByTime(60_000)
    expect(sockets).toHaveLength(1)
    expect(cs.estado).toBe('cerrado')
  })
})
