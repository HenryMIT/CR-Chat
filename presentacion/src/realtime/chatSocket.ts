/**
 * Conexión WebSocket con el servicio `ws` (ver docs/contratos/ws-eventos.md §3).
 *
 * Independiente de React para poder probarla con temporizadores falsos:
 * - Autenticación con el primer mensaje `auth` (el token nunca va en la URL).
 * - Reautenticación sobre la misma conexión (`auth.expiring` o token renovado por REST).
 * - Heartbeat: `ping` cada `heartbeat_interval` (25 s); sin `pong` en 10 s se da por muerta.
 * - Reconexión con backoff exponencial y jitter: 1 s, 2 s, 4 s… hasta 30 s.
 * - Códigos de cierre: 1000/1008 no reintentan; 4401 renueva el token (o sale si la sesión
 *   fue revocada); 4029 espera 30 s; el resto reintenta con backoff.
 * - Tras cada `auth.ok` que sigue a una reconexión se pide resincronizar por REST.
 */
import { nuevoUuid } from '@/lib/uuid'
import { analizarEvento, type EventoServidor, type EventosCliente } from './eventos'

export type EstadoSocket = 'inactivo' | 'conectando' | 'autenticando' | 'conectado' | 'reconectando' | 'cerrado'

/** Subconjunto de WebSocket que usamos (permite inyectar un doble en pruebas). */
export interface SocketBasico {
  readonly readyState: number
  onopen: ((ev: Event) => void) | null
  onmessage: ((ev: MessageEvent) => void) | null
  onclose: ((ev: CloseEvent) => void) | null
  onerror: ((ev: Event) => void) | null
  send(datos: string): void
  close(codigo?: number, motivo?: string): void
}

export interface OpcionesChatSocket {
  url: string
  /** Devuelve un access token; con `forzar` debe renovarlo por REST. null = sin sesión. */
  obtenerToken: (forzar: boolean) => Promise<string | null>
  alEvento: (evento: EventoServidor) => void
  alEstado?: (estado: EstadoSocket) => void
  /** Se llama tras `auth.ok` cuando no es la primera conexión (resincronizar por REST). */
  alResincronizar?: () => void
  /** Primera autenticación correcta de esta instancia. */
  alConectar?: () => void
  /** La sesión fue revocada (cierre 4401 `session_revoked`): volver al login. */
  alSesionRevocada?: () => void
  crearSocket?: (url: string) => SocketBasico
  aleatorio?: () => number
  backoffBaseMs?: number
  backoffMaxMs?: number
  esperaPongMs?: number
}

const ABIERTO = 1
const SUBPROTOCOLO = 'cr-chat.v1'

export class ChatSocket {
  private readonly o: Required<Omit<OpcionesChatSocket, 'alEstado' | 'alResincronizar' | 'alConectar' | 'alSesionRevocada'>> &
    OpcionesChatSocket
  private socket: SocketBasico | null = null
  private estadoActual: EstadoSocket = 'inactivo'
  private intentos = 0
  private yaAutenticado = false
  private cierreManual = false
  private forzarRefresco = false
  private reconexion: ReturnType<typeof setTimeout> | undefined
  private latido: ReturnType<typeof setInterval> | undefined
  private esperaPong: ReturnType<typeof setTimeout> | undefined

  constructor(opciones: OpcionesChatSocket) {
    this.o = {
      crearSocket: (url) => new WebSocket(url, SUBPROTOCOLO),
      aleatorio: Math.random,
      backoffBaseMs: 1000,
      backoffMaxMs: 30_000,
      esperaPongMs: 10_000,
      ...opciones,
    }
  }

  get estado(): EstadoSocket {
    return this.estadoActual
  }

  conectar(): void {
    this.cierreManual = false
    clearTimeout(this.reconexion)
    this.abrir()
  }

  /** Cierre definitivo (logout o desmontaje): no reintenta. */
  desconectar(): void {
    this.cierreManual = true
    clearTimeout(this.reconexion)
    this.detenerLatido()
    const s = this.socket
    this.socket = null
    if (s) {
      this.soltar(s)
      s.close(1000, 'cliente')
    }
    this.cambiarEstado('cerrado')
  }

  /** Si está esperando para reconectar, lo intenta ya (p. ej. al recuperar la red). */
  reconectarAhora(): void {
    if (this.estadoActual !== 'reconectando') return
    clearTimeout(this.reconexion)
    this.abrir()
  }

  /** Envía un evento del cliente. Devuelve false si no hay una conexión autenticada. */
  enviar<T extends keyof EventosCliente>(tipo: T, datos: EventosCliente[T]): boolean {
    if (this.estadoActual !== 'conectado' && tipo !== 'auth') return false
    return this.enviarCrudo(tipo, datos)
  }

  /** Reenvía `auth` con el token vigente sobre la conexión abierta. */
  async reautenticar(forzar = false): Promise<void> {
    if (!this.socket || this.socket.readyState !== ABIERTO) return
    const token = await this.o.obtenerToken(forzar)
    if (!token) {
      this.desconectar()
      return
    }
    this.enviarCrudo('auth', { access_token: token })
  }

  // ---------------------------------------------------------------- interno

  private cambiarEstado(estado: EstadoSocket): void {
    if (this.estadoActual === estado) return
    this.estadoActual = estado
    this.o.alEstado?.(estado)
  }

  private enviarCrudo(tipo: string, datos: unknown): boolean {
    const s = this.socket
    if (!s || s.readyState !== ABIERTO) return false
    s.send(JSON.stringify({ type: tipo, id: nuevoUuid(), ts: new Date().toISOString(), data: datos }))
    return true
  }

  private abrir(): void {
    this.cambiarEstado(this.yaAutenticado || this.intentos > 0 ? 'reconectando' : 'conectando')
    let s: SocketBasico
    try {
      s = this.o.crearSocket(this.o.url)
    } catch {
      this.programarReconexion()
      return
    }
    this.socket = s
    s.onopen = () => {
      this.cambiarEstado('autenticando')
      const forzar = this.forzarRefresco
      this.forzarRefresco = false
      this.o
        .obtenerToken(forzar)
        .then((token) => {
          if (this.socket !== s) return
          if (!token) {
            this.desconectar()
            return
          }
          this.enviarCrudo('auth', { access_token: token })
        })
        .catch(() => {
          // Sin red para renovar: se cierra y se reintenta con backoff.
          if (this.socket === s) s.close(4000, 'sin-token')
        })
    }
    s.onmessage = (ev: MessageEvent) => {
      this.alMensaje(ev.data)
    }
    s.onclose = (ev: CloseEvent) => {
      if (this.socket !== s) return
      this.alCerrar(ev.code, ev.reason)
    }
    s.onerror = () => {
      /* el navegador dispara también `close`; ahí se decide la reconexión */
    }
  }

  private soltar(s: SocketBasico): void {
    s.onopen = null
    s.onmessage = null
    s.onclose = null
    s.onerror = null
  }

  private alMensaje(datos: unknown): void {
    const evento = analizarEvento(datos)
    if (!evento) return
    switch (evento.type) {
      case 'auth.ok': {
        const reconexion = this.yaAutenticado
        this.yaAutenticado = true
        this.intentos = 0
        this.cambiarEstado('conectado')
        this.iniciarLatido((evento.data.heartbeat_interval ?? 25) * 1000)
        if (reconexion) this.o.alResincronizar?.()
        else this.o.alConectar?.()
        return
      }
      case 'auth.expiring':
        void this.reautenticar(true)
        return
      case 'pong':
        clearTimeout(this.esperaPong)
        this.esperaPong = undefined
        return
      default:
        this.o.alEvento(evento)
    }
  }

  private alCerrar(codigo: number, motivo: string): void {
    this.detenerLatido()
    if (this.socket) this.soltar(this.socket)
    this.socket = null
    if (this.cierreManual) {
      this.cambiarEstado('cerrado')
      return
    }
    if (codigo === 1000 || codigo === 1008) {
      this.cambiarEstado('cerrado')
      return
    }
    if (codigo === 4401) {
      if (motivo.includes('session_revoked')) {
        this.cambiarEstado('cerrado')
        this.o.alSesionRevocada?.()
        return
      }
      // Token inválido o expirado: se renueva antes de volver a autenticar.
      this.forzarRefresco = true
    }
    this.programarReconexion(codigo === 4029 ? 30_000 : undefined)
  }

  /** Retardo exponencial con jitter (±25 %) acotado a backoffMaxMs. */
  calcularRetardo(intento: number): number {
    const base = Math.min(this.o.backoffMaxMs, this.o.backoffBaseMs * 2 ** intento)
    const conJitter = base * (0.75 + this.o.aleatorio() * 0.5)
    return Math.round(Math.min(this.o.backoffMaxMs, conJitter))
  }

  private programarReconexion(retardoFijo?: number): void {
    this.cambiarEstado('reconectando')
    const retardo = retardoFijo ?? this.calcularRetardo(this.intentos)
    this.intentos += 1
    clearTimeout(this.reconexion)
    this.reconexion = setTimeout(() => {
      this.abrir()
    }, retardo)
  }

  private iniciarLatido(cadaMs: number): void {
    this.detenerLatido()
    this.latido = setInterval(() => {
      if (!this.enviarCrudo('ping', {})) return
      if (this.esperaPong !== undefined) return
      this.esperaPong = setTimeout(() => {
        this.conexionMuerta()
      }, this.o.esperaPongMs)
    }, cadaMs)
  }

  private detenerLatido(): void {
    clearInterval(this.latido)
    clearTimeout(this.esperaPong)
    this.latido = undefined
    this.esperaPong = undefined
  }

  /** Sin pong a tiempo: se abandona la conexión sin esperar su `close` y se reconecta. */
  private conexionMuerta(): void {
    const s = this.socket
    if (!s) return
    this.soltar(s)
    this.socket = null
    try {
      s.close(4000, 'heartbeat')
    } catch {
      /* ya cerrada */
    }
    this.detenerLatido()
    this.programarReconexion()
  }
}
