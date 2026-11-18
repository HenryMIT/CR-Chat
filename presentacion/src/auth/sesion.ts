/**
 * Sesión del cliente.
 *
 * - El access token vive SOLO en memoria (store de Zustand), nunca en storage.
 * - El refresh token (opaco, rotado en cada uso) se guarda en localStorage para sobrevivir
 *   a recargas y compartirse entre pestañas. Riesgo conocido ante XSS: el requerimiento A-15
 *   (cookie HttpOnly) lo eliminaría; ver README.
 * - El refresco es "single-flight" dentro de la pestaña y se serializa entre pestañas con
 *   Web Locks: como el servidor detecta la reutilización de un refresh rotado y revoca la
 *   sesión, dos pestañas no deben rotar el mismo token a la vez.
 * - Logout sincronizado entre pestañas con BroadcastChannel.
 */
import { create } from 'zustand'
import { env } from '@/lib/env'
import { normalizarTelefono, pareceCorreo } from '@/lib/formato'
import { ErrorDeRed, errorDesdeRespuesta } from '@/api/errores'
import type { LoginPeticion, Me, ParTokens } from '@/api/tipos'

export type EstadoAuth = 'iniciando' | 'autenticado' | 'anonimo'
export type MotivoSalida = 'manual' | 'expirada' | 'revocada' | 'otra-pestana'

interface AuthState {
  estado: EstadoAuth
  accessToken: string | null
  /** Momento (epoch ms) en que caduca el access token. */
  expiraEn: number | null
  sesionId: string | null
  usuario: Me | null
  motivoSalida: MotivoSalida | null
  /** Error al arrancar (p. ej. sin red): la app ofrece reintentar en vez de pedir login. */
  errorArranque: string | null
}

const estadoInicial: AuthState = {
  estado: 'iniciando',
  accessToken: null,
  expiraEn: null,
  sesionId: null,
  usuario: null,
  motivoSalida: null,
  errorArranque: null,
}

export const useAuth = create<AuthState>()(() => ({ ...estadoInicial }))

export const CLAVE_REFRESH = 'crchat.rt'
export const CANAL_AUTH = 'crchat-auth'
/** Margen antes del vencimiento a partir del cual se renueva el access token. */
const MARGEN_MS = 30_000

type MensajeCanal = { tipo: 'salida' } | { tipo: 'entrada' }

let temporizador: ReturnType<typeof setTimeout> | undefined
let refrescoEnCurso: Promise<string | null> | null = null
let canal: BroadcastChannel | null = null
const oyentesSalida = new Set<(motivo: MotivoSalida) => void>()

// ---------------------------------------------------------------- almacenamiento

function leerRefresh(): string | null {
  try {
    return localStorage.getItem(CLAVE_REFRESH)
  } catch {
    return null
  }
}

function guardarRefresh(token: string): void {
  try {
    localStorage.setItem(CLAVE_REFRESH, token)
  } catch {
    /* almacenamiento no disponible (modo privado estricto): la sesión dura lo que la pestaña */
  }
}

function borrarRefresh(): void {
  try {
    localStorage.removeItem(CLAVE_REFRESH)
  } catch {
    /* sin almacenamiento */
  }
}

// ---------------------------------------------------------------- utilidades

/** "Firefox en Linux", etc. Se envía como `device_name` para la lista de sesiones. */
export function nombreDispositivo(ua = typeof navigator === 'undefined' ? '' : navigator.userAgent): string {
  const navegador = /Edg\//.test(ua)
    ? 'Edge'
    : /OPR\//.test(ua)
      ? 'Opera'
      : /Firefox\//.test(ua)
        ? 'Firefox'
        : /Chrome\//.test(ua)
          ? 'Chrome'
          : /Safari\//.test(ua)
            ? 'Safari'
            : 'Navegador'
  const sistema = /Android/.test(ua)
    ? 'Android'
    : /iPhone|iPad|iPod/.test(ua)
      ? 'iOS'
      : /Windows/.test(ua)
        ? 'Windows'
        : /Mac OS X|Macintosh/.test(ua)
          ? 'macOS'
          : /Linux/.test(ua)
            ? 'Linux'
            : 'dispositivo desconocido'
  return `${navegador} en ${sistema}`
}

function difundir(mensaje: MensajeCanal): void {
  canal?.postMessage(mensaje)
}

async function conBloqueoEntrePestanas<T>(fn: () => Promise<T>): Promise<T> {
  const locks = typeof navigator !== 'undefined' ? navigator.locks : undefined
  if (typeof locks?.request === 'function') {
    return locks.request('crchat-refresh', fn)
  }
  return fn()
}

async function postJson(ruta: string, cuerpo: unknown): Promise<Response> {
  try {
    return await fetch(`${env.apiUrl}${ruta}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify(cuerpo),
    })
  } catch {
    throw new ErrorDeRed()
  }
}

// ---------------------------------------------------------------- API pública

/** Guarda un par de tokens recién emitido y programa el refresco proactivo. */
export function aplicarTokens(par: ParTokens): void {
  guardarRefresh(par.refresh_token)
  useAuth.setState({
    estado: 'autenticado',
    accessToken: par.access_token,
    expiraEn: Date.now() + par.expires_in * 1000,
    sesionId: par.session_id,
    usuario: par.user,
    motivoSalida: null,
    errorArranque: null,
  })
  clearTimeout(temporizador)
  // Se renueva 60 s antes de caducar (igual que el aviso auth.expiring del WebSocket).
  const enMs = Math.max(5, par.expires_in - 60) * 1000
  temporizador = setTimeout(() => {
    refrescarSesion().catch(() => {
      /* sin red: se reintentará en la próxima petición (401) o al reconectar */
    })
  }, enMs)
}

export function actualizarUsuario(usuario: Me): void {
  useAuth.setState({ usuario })
}

/** Renueva el access token. Devuelve null si la sesión ya no es válida (y la cierra). */
export function refrescarSesion(): Promise<string | null> {
  refrescoEnCurso ??= conBloqueoEntrePestanas(refrescarAhora).finally(() => {
    refrescoEnCurso = null
  })
  return refrescoEnCurso
}

async function refrescarAhora(): Promise<string | null> {
  // Se lee dentro del bloqueo: si otra pestaña acaba de rotarlo, aquí ya está el nuevo.
  const refresh = leerRefresh()
  if (!refresh) {
    if (useAuth.getState().estado === 'autenticado') cerrarSesionLocal('expirada')
    else useAuth.setState({ estado: 'anonimo' })
    return null
  }
  const res = await postJson('/auth/refresh', { refresh_token: refresh })
  if (res.ok) {
    const par = (await res.json()) as ParTokens
    aplicarTokens(par)
    return par.access_token
  }
  if (res.status === 400 || res.status === 401) {
    cerrarSesionLocal(useAuth.getState().estado === 'autenticado' ? 'expirada' : 'manual')
    return null
  }
  throw errorDesdeRespuesta(res, await res.json().catch(() => undefined))
}

/** Token listo para usar: el actual si le queda margen; si no, uno renovado. */
export async function obtenerTokenVigente(): Promise<string | null> {
  const { estado, accessToken, expiraEn } = useAuth.getState()
  if (estado === 'anonimo') return null
  if (accessToken && expiraEn !== null && expiraEn - Date.now() > MARGEN_MS) return accessToken
  return refrescarSesion()
}

/** Arranque de la app: intenta recuperar la sesión con el refresh guardado. */
export async function arrancarSesion(): Promise<void> {
  if (!leerRefresh()) {
    useAuth.setState({ estado: 'anonimo', errorArranque: null })
    return
  }
  useAuth.setState({ estado: 'iniciando', errorArranque: null })
  try {
    await refrescarSesion()
  } catch (e) {
    useAuth.setState({
      errorArranque: e instanceof Error ? e.message : 'No se pudo recuperar la sesión.',
    })
  }
}

export async function iniciarSesion(identifier: string, password: string): Promise<Me> {
  // La API exige email o teléfono E.164: «7000 0001» se envía como +50670000001.
  const id = identifier.trim()
  const cuerpo: LoginPeticion = { identifier: pareceCorreo(id) ? id : normalizarTelefono(id), password, device_name: nombreDispositivo() }
  const res = await postJson('/auth/login', cuerpo)
  if (!res.ok) throw errorDesdeRespuesta(res, await res.json().catch(() => undefined))
  const par = (await res.json()) as ParTokens
  aplicarTokens(par)
  difundir({ tipo: 'entrada' })
  return par.user
}

/** Limpia la sesión en esta pestaña (y, por defecto, avisa a las demás). */
export function cerrarSesionLocal(motivo: MotivoSalida, opciones: { difundir?: boolean } = {}): void {
  clearTimeout(temporizador)
  borrarRefresh()
  useAuth.setState({ ...estadoInicial, estado: 'anonimo', motivoSalida: motivo })
  for (const oyente of oyentesSalida) oyente(motivo)
  if (opciones.difundir ?? true) difundir({ tipo: 'salida' })
}

/** Logout explícito: revoca la sesión en el servidor (mejor esfuerzo) y limpia todo. */
export async function cerrarSesion(): Promise<void> {
  const token = useAuth.getState().accessToken
  if (token) {
    try {
      await fetch(`${env.apiUrl}/auth/logout`, { method: 'POST', headers: { Authorization: `Bearer ${token}` } })
    } catch {
      /* aunque falle la red, la sesión local se cierra igual */
    }
  }
  cerrarSesionLocal('manual')
}

/** Suscribe una acción al cierre de sesión (limpiar caché, cerrar el socket…). */
export function alCerrarSesion(oyente: (motivo: MotivoSalida) => void): () => void {
  oyentesSalida.add(oyente)
  return () => oyentesSalida.delete(oyente)
}

/** Escucha los avisos de otras pestañas. Devuelve la función de limpieza. */
export function iniciarSincronizacionPestanas(): () => void {
  if (typeof BroadcastChannel === 'undefined') return () => undefined
  const propio = new BroadcastChannel(CANAL_AUTH)
  canal = propio
  propio.onmessage = (evento: MessageEvent<MensajeCanal>) => {
    if (evento.data.tipo === 'salida' && useAuth.getState().estado !== 'anonimo') {
      cerrarSesionLocal('otra-pestana', { difundir: false })
    } else if (evento.data.tipo === 'entrada' && useAuth.getState().estado === 'anonimo') {
      // Otra pestaña inició sesión: esta recupera la suya con el refresh compartido.
      refrescarSesion().catch(() => undefined)
    }
  }
  return () => {
    propio.close()
    if (canal === propio) canal = null
  }
}

/** Solo para pruebas: vuelve al estado inicial. */
export function reiniciarSesionParaPruebas(): void {
  clearTimeout(temporizador)
  refrescoEnCurso = null
  oyentesSalida.clear()
  borrarRefresh()
  useAuth.setState({ ...estadoInicial })
}
