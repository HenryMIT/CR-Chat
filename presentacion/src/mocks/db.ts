/**
 * Base de datos simulada para MSW. Reproduce el comportamiento descrito en
 * docs/contratos/openapi.yaml y ws-eventos.md (propiedad → 404, idempotencia,
 * rotación de refresh con detección de reutilización, recibos monótonos, bloqueos…)
 * con los usuarios de demo de docs/db/README.md.
 *
 * SOLO PARA DESARROLLO Y PRUEBAS: las contraseñas de demo son públicas.
 */
import type {
  Bloqueo,
  Contacto,
  Conversacion,
  Media,
  Me,
  Mensaje,
  Sesion,
  UsuarioPublico,
  UsuarioResumen,
} from '@/api/tipos'
import type { EventoServidor } from '@/realtime/eventos'
import { nuevoUuid } from '@/lib/uuid'

export interface UsuarioDb {
  id: string
  email: string
  phone: string
  display_name: string
  about: string | null
  avatar_media_id: string | null
  password: string
  created_at: string
}

interface ContactoDb {
  id: string
  owner_id: string
  contact_user_id: string
  alias: string | null
  created_at: string
}

interface BloqueoDb {
  blocker_id: string
  blocked_id: string
  created_at: string
}

interface ConversacionDb {
  id: string
  participantes: [string, string]
  created_at: string
}

interface MensajeDb {
  id: string
  conversation_id: string
  sender_id: string
  client_id: string | null
  text: string | null
  media_id: string | null
  created_at: string
  edited_at: string | null
  deleted_at: string | null
}

interface MarcadorDb {
  delivered: string | null
  seen: string | null
}

interface SesionDb {
  id: string
  user_id: string
  device_name: string
  ip_hint: string | null
  created_at: string
  last_used_at: string
  refresh: string
  refreshRotados: string[]
  access: string
  accessExpira: number
  revocada: boolean
}

interface MediaDb {
  id: string
  owner_id: string
  purpose: 'avatar' | 'message'
  content_type: string
  size_bytes: number
  url: string | null
  subido: boolean
}

interface Datos {
  usuarios: UsuarioDb[]
  contactos: ContactoDb[]
  bloqueos: BloqueoDb[]
  conversaciones: ConversacionDb[]
  mensajes: MensajeDb[]
  marcadores: Record<string, MarcadorDb>
  sesiones: SesionDb[]
  media: MediaDb[]
}

export const IDS = {
  ana: '0192d590-0a0a-7a00-8a00-00000000a001',
  bruno: '0192d590-0b0b-7b00-8b00-00000000b002',
  carla: '0192d590-0c0c-7c00-8c00-00000000c003',
  convAnaBruno: '0192d59f-11aa-7b2c-8d3e-00000000ab01',
  convAnaCarla: '0192d59f-11aa-7b2c-8d3e-00000000ac02',
} as const

const ACCESS_SEGUNDOS = 900
const REFRESH_SEGUNDOS = 2_592_000
export const VENTANA_EDICION_MS = 15 * 60_000

function base64url(bytes: Uint8Array): string {
  let s = ''
  for (const b of bytes) s += String.fromCharCode(b)
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function tokenAleatorio(): string {
  return base64url(crypto.getRandomValues(new Uint8Array(32)))
}

function codificarCursor(valor: unknown): string {
  return base64url(new TextEncoder().encode(JSON.stringify(valor)))
}

export function decodificarCursor(cursor: string): unknown {
  try {
    const b64 = cursor.replace(/-/g, '+').replace(/_/g, '/')
    const bin = atob(b64 + '='.repeat((4 - (b64.length % 4)) % 4))
    return JSON.parse(new TextDecoder().decode(Uint8Array.from(bin, (c) => c.charCodeAt(0)))) as unknown
  } catch {
    return null
  }
}

function sinAcentos(t: string): string {
  return t.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
}

function hace(minutos: number, ahora = Date.now()): string {
  return new Date(ahora - minutos * 60_000).toISOString()
}

/** Datos semilla: equivalentes a Postgres/seed/demo.sql más mensajes de ejemplo. */
export function datosSemilla(ahora = Date.now()): Datos {
  const creado = hace(60 * 24 * 30, ahora)
  const usuarios: UsuarioDb[] = [
    { id: IDS.ana, email: 'ana@demo.crchat.local', phone: '+50670000001', display_name: 'Ana Demo', about: 'Diseñando cosas bonitas ✨', avatar_media_id: null, password: 'Demo-Ana-2026!', created_at: creado },
    { id: IDS.bruno, email: 'bruno@demo.crchat.local', phone: '+50670000002', display_name: 'Bruno Demo', about: 'En el café de siempre', avatar_media_id: null, password: 'Demo-Bruno-2026!', created_at: creado },
    { id: IDS.carla, email: 'carla@demo.crchat.local', phone: '+50670000003', display_name: 'Carla Demo', about: null, avatar_media_id: null, password: 'Demo-Carla-2026!', created_at: creado },
  ]
  const contactos: ContactoDb[] = [
    { id: '0192d591-0000-7000-8000-0000000c0001', owner_id: IDS.ana, contact_user_id: IDS.bruno, alias: 'Bruno', created_at: creado },
    { id: '0192d591-0000-7000-8000-0000000c0002', owner_id: IDS.ana, contact_user_id: IDS.carla, alias: 'Carla (trabajo)', created_at: creado },
    { id: '0192d591-0000-7000-8000-0000000c0003', owner_id: IDS.bruno, contact_user_id: IDS.ana, alias: 'Ana', created_at: creado },
    { id: '0192d591-0000-7000-8000-0000000c0004', owner_id: IDS.carla, contact_user_id: IDS.bruno, alias: 'Bruno', created_at: creado },
  ]
  const conversaciones: ConversacionDb[] = [
    { id: IDS.convAnaBruno, participantes: [IDS.ana, IDS.bruno], created_at: creado },
    { id: IDS.convAnaCarla, participantes: [IDS.ana, IDS.carla], created_at: creado },
  ]

  const guion: [string, string][] = [
    [IDS.bruno, '¡Hola Ana! ¿Cómo va el proyecto del portafolio?'],
    [IDS.ana, 'Bien, ya casi termino el diseño del chat 🙌'],
    [IDS.bruno, '¿Qué paleta usaste al final?'],
    [IDS.ana, 'Verde selva y un acento color guaria morada.'],
    [IDS.bruno, 'Suena muy tico, me gusta'],
    [IDS.ana, 'Esa era la idea jaja'],
    [IDS.bruno, '¿Y el modo oscuro?'],
    [IDS.ana, 'También, con contraste AA en todo.'],
    [IDS.bruno, 'Pura vida. ¿Lo vemos el viernes?'],
    [IDS.ana, 'Dale, en el café de siempre a las 10.'],
  ]
  const mensajes: MensajeDb[] = []
  // 49 mensajes repartidos en tres días: suficiente para probar el scroll infinito.
  const total = 49
  for (let i = 0; i < total; i++) {
    const [remitente, texto] = guion[i % guion.length] as [string, string]
    const minutosAtras = Math.round(((total - i) * 60 * 72) / total)
    mensajes.push({
      id: `0192d5a1-0000-7000-8000-${String(i + 1).padStart(12, '0')}`,
      conversation_id: IDS.convAnaBruno,
      sender_id: remitente,
      client_id: null,
      text: texto,
      media_id: null,
      created_at: hace(minutosAtras, ahora),
      edited_at: null,
      deleted_at: null,
    })
  }
  const ultimoAnaBruno = mensajes[mensajes.length - 1]
  mensajes.push(
    {
      id: '0192d5a2-0000-7000-8000-000000000001',
      conversation_id: IDS.convAnaCarla,
      sender_id: IDS.ana,
      client_id: null,
      text: 'Carla, ¿me pasas el informe cuando puedas?',
      media_id: null,
      created_at: hace(180, ahora),
      edited_at: null,
      deleted_at: null,
    },
    {
      id: '0192d5a2-0000-7000-8000-000000000002',
      conversation_id: IDS.convAnaCarla,
      sender_id: IDS.carla,
      client_id: null,
      text: 'Claro, te lo envío hoy en la tarde.',
      media_id: null,
      created_at: hace(170, ahora),
      edited_at: null,
      deleted_at: null,
    },
    {
      id: '0192d5a2-0000-7000-8000-000000000003',
      conversation_id: IDS.convAnaCarla,
      sender_id: IDS.carla,
      client_id: null,
      text: '¿Lo necesitas en PDF o en hoja de cálculo?',
      media_id: null,
      created_at: hace(25, ahora),
      edited_at: null,
      deleted_at: null,
    },
  )

  const marcadores: Record<string, MarcadorDb> = {
    // Bruno ya vio todo lo de Ana; Ana tiene 3 sin leer de Bruno.
    [`${IDS.convAnaBruno}:${IDS.bruno}`]: { delivered: ultimoAnaBruno?.id ?? null, seen: ultimoAnaBruno?.id ?? null },
    [`${IDS.convAnaBruno}:${IDS.ana}`]: {
      delivered: mensajes[total - 4]?.id ?? null,
      seen: mensajes[total - 4]?.id ?? null,
    },
    [`${IDS.convAnaCarla}:${IDS.carla}`]: { delivered: '0192d5a2-0000-7000-8000-000000000001', seen: '0192d5a2-0000-7000-8000-000000000001' },
    [`${IDS.convAnaCarla}:${IDS.ana}`]: { delivered: '0192d5a2-0000-7000-8000-000000000002', seen: '0192d5a2-0000-7000-8000-000000000002' },
  }
  return { usuarios, contactos, bloqueos: [], conversaciones, mensajes, marcadores, sesiones: [], media: [] }
}

export class ErrorMock extends Error {
  readonly status: number
  readonly tipo: string
  readonly titulo: string
  readonly detalle: string
  readonly errores: { field: string; detail: string }[] | undefined

  constructor(status: number, tipo: string, titulo: string, detalle: string, errores?: { field: string; detail: string }[]) {
    super(detalle)
    this.status = status
    this.tipo = tipo
    this.titulo = titulo
    this.detalle = detalle
    this.errores = errores
  }
}

export const noEncontrado = (detalle = 'No encontrado.') => new ErrorMock(404, 'no-encontrado', 'No encontrado', detalle)
const validacion = (errores: { field: string; detail: string }[]) =>
  new ErrorMock(422, 'validacion', 'Datos inválidos', 'Uno o más campos no son válidos.', errores)

type OyentePublicacion = (usuarioId: string, evento: EventoServidor) => void
type OyenteRevocacion = (sesionId: string) => void

export interface OpcionesDb {
  /** Clave de localStorage para conservar los datos entre recargas (solo navegador). */
  persistirEn?: string
}

export class MockDb {
  d: Datos
  private oyentes = new Set<OyentePublicacion>()
  private oyentesRevocacion = new Set<OyenteRevocacion>()
  private conexiones = new Map<string, number>()
  private ultimaConexion = new Map<string, string>()
  private readonly clave: string | undefined

  constructor(opciones: OpcionesDb = {}) {
    this.clave = opciones.persistirEn
    this.d = this.cargar() ?? datosSemilla()
    // Presencia inicial de la demo: Carla se conectó hace un rato.
    this.ultimaConexion.set(IDS.carla, hace(95))
    this.ultimaConexion.set(IDS.bruno, hace(12))
  }

  // ------------------------------------------------------------ persistencia y eventos

  private cargar(): Datos | null {
    if (!this.clave || typeof localStorage === 'undefined') return null
    try {
      const crudo = localStorage.getItem(this.clave)
      if (!crudo) return null
      const datos = JSON.parse(crudo) as Datos
      // Las URL blob: de los adjuntos no sobreviven a una recarga.
      for (const m of datos.media) m.url = null
      return datos
    } catch {
      return null
    }
  }

  guardar(): void {
    if (!this.clave || typeof localStorage === 'undefined') return
    try {
      localStorage.setItem(this.clave, JSON.stringify(this.d))
    } catch {
      /* cuota superada: la demo sigue en memoria */
    }
  }

  reiniciar(): void {
    this.d = datosSemilla()
    this.conexiones.clear()
    this.guardar()
  }

  alPublicar(oyente: OyentePublicacion): () => void {
    this.oyentes.add(oyente)
    return () => this.oyentes.delete(oyente)
  }

  alRevocarSesion(oyente: OyenteRevocacion): () => void {
    this.oyentesRevocacion.add(oyente)
    return () => this.oyentesRevocacion.delete(oyente)
  }

  publicar(usuarioId: string, type: EventoServidor['type'], data: unknown): void {
    const evento = { type, id: nuevoUuid(), ts: new Date().toISOString(), data } as EventoServidor
    for (const o of this.oyentes) o(usuarioId, evento)
  }

  // ------------------------------------------------------------ usuarios y sesiones

  usuario(id: string): UsuarioDb | undefined {
    return this.d.usuarios.find((u) => u.id === id)
  }

  media(id: string | null): Media | null {
    if (!id) return null
    const m = this.d.media.find((x) => x.id === id)
    if (!m?.url) return null
    return {
      id: m.id,
      content_type: m.content_type,
      size_bytes: m.size_bytes,
      width: null,
      height: null,
      url: m.url,
      url_expires_at: new Date(Date.now() + 10 * 60_000).toISOString(),
    }
  }

  me(u: UsuarioDb): Me {
    return {
      id: u.id,
      email: u.email,
      phone: u.phone,
      display_name: u.display_name,
      about: u.about,
      avatar: this.media(u.avatar_media_id),
      created_at: u.created_at,
    }
  }

  resumen(u: UsuarioDb): UsuarioResumen {
    return { id: u.id, display_name: u.display_name, avatar: this.media(u.avatar_media_id) }
  }

  registrar(datos: { email: string; phone: string; display_name: string; password: string }): Me {
    const errores: { field: string; detail: string }[] = []
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(datos.email)) errores.push({ field: 'email', detail: 'Correo no válido.' })
    if (!/^\+[1-9][0-9]{7,14}$/.test(datos.phone)) errores.push({ field: 'phone', detail: 'Debe estar en formato E.164, p. ej. +50688880001.' })
    if (!datos.display_name.trim() || datos.display_name.length > 50) errores.push({ field: 'display_name', detail: 'Entre 1 y 50 caracteres.' })
    if (datos.password.length < 10 || datos.password.length > 128) errores.push({ field: 'password', detail: 'Debe tener entre 10 y 128 caracteres.' })
    if (errores.length) throw validacion(errores)
    const existe = this.d.usuarios.some((u) => u.email.toLowerCase() === datos.email.toLowerCase() || u.phone === datos.phone)
    if (existe) throw new ErrorMock(409, 'registro-no-disponible', 'Registro no disponible', 'No se pudo completar el registro con esos datos.')
    const u: UsuarioDb = {
      id: nuevoUuid(),
      email: datos.email,
      phone: datos.phone,
      display_name: datos.display_name.trim(),
      about: null,
      avatar_media_id: null,
      password: datos.password,
      created_at: new Date().toISOString(),
    }
    this.d.usuarios.push(u)
    return this.me(u)
  }

  /** Login por teléfono o correo (`identifier`); acepta también `email` del contrato actual. */
  login(identificador: string, password: string, dispositivo: string | undefined) {
    const id = identificador.trim()
    const telefono = id.replace(/[\s\-().]/g, '')
    const u = this.d.usuarios.find((x) =>
      id.includes('@') ? x.email.toLowerCase() === id.toLowerCase() : x.phone === telefono || x.phone === `+506${telefono}`,
    )
    if (u?.password !== password) {
      throw new ErrorMock(401, 'no-autenticado', 'No autenticado', 'Credenciales incorrectas.')
    }
    const ahora = new Date().toISOString()
    const s: SesionDb = {
      id: nuevoUuid(),
      user_id: u.id,
      device_name: dispositivo?.slice(0, 100) || 'Navegador web',
      ip_hint: '192.0.2.0/24',
      created_at: ahora,
      last_used_at: ahora,
      refresh: tokenAleatorio(),
      refreshRotados: [],
      access: '',
      accessExpira: 0,
      revocada: false,
    }
    this.d.sesiones.push(s)
    return this.emitirTokens(s)
  }

  private emitirTokens(s: SesionDb) {
    s.access = `mock.${s.id}.${tokenAleatorio()}`
    s.accessExpira = Date.now() + ACCESS_SEGUNDOS * 1000
    s.last_used_at = new Date().toISOString()
    const u = this.usuario(s.user_id)
    if (!u) throw noEncontrado()
    return {
      access_token: s.access,
      token_type: 'Bearer' as const,
      expires_in: ACCESS_SEGUNDOS,
      refresh_token: s.refresh,
      refresh_expires_in: REFRESH_SEGUNDOS,
      session_id: s.id,
      user: this.me(u),
    }
  }

  refrescar(refresh: string) {
    const actual = this.d.sesiones.find((s) => s.refresh === refresh && !s.revocada)
    if (actual) {
      actual.refreshRotados.push(actual.refresh)
      actual.refresh = tokenAleatorio()
      return this.emitirTokens(actual)
    }
    // Reutilización de un refresh ya rotado: posible robo → se revoca la sesión entera.
    const robada = this.d.sesiones.find((s) => s.refreshRotados.includes(refresh))
    if (robada) this.revocar(robada)
    throw new ErrorMock(401, 'no-autenticado', 'No autenticado', 'La sesión ya no es válida.')
  }

  private revocar(s: SesionDb): void {
    if (s.revocada) return
    s.revocada = true
    for (const o of this.oyentesRevocacion) o(s.id)
  }

  /** Valida un access token (Authorization: Bearer). */
  autenticar(token: string | null): { usuario: UsuarioDb; sesion: SesionDb } {
    const s = token ? this.d.sesiones.find((x) => x.access === token) : undefined
    const u = s ? this.usuario(s.user_id) : undefined
    if (!s || !u || s.revocada || s.accessExpira < Date.now()) {
      throw new ErrorMock(401, 'no-autenticado', 'No autenticado', 'Token de acceso inválido o expirado.')
    }
    return { usuario: u, sesion: s }
  }

  /** Solo pruebas: hace caducar el access token de una sesión. */
  caducarAccess(sesionId: string): void {
    const s = this.d.sesiones.find((x) => x.id === sesionId)
    if (s) s.accessExpira = 0
  }

  cerrarSesion(sesion: SesionDb): void {
    this.revocar(sesion)
  }

  sesiones(usuarioId: string, actualId: string): Sesion[] {
    return this.d.sesiones
      .filter((s) => s.user_id === usuarioId && !s.revocada)
      .sort((a, b) => (a.last_used_at < b.last_used_at ? 1 : -1))
      .map((s) => ({
        id: s.id,
        device_name: s.device_name,
        ip_hint: s.ip_hint,
        created_at: s.created_at,
        last_used_at: s.last_used_at,
        current: s.id === actualId,
      }))
  }

  revocarSesion(usuarioId: string, sesionId: string): void {
    const s = this.d.sesiones.find((x) => x.id === sesionId && x.user_id === usuarioId && !x.revocada)
    if (!s) throw noEncontrado('Sesión no encontrada.')
    this.revocar(s)
  }

  revocarOtras(usuarioId: string, actualId: string): void {
    for (const s of this.d.sesiones) if (s.user_id === usuarioId && s.id !== actualId) this.revocar(s)
  }

  actualizarPerfil(u: UsuarioDb, cambios: { display_name?: string; about?: string | null; avatar_media_id?: string | null }): Me {
    if (cambios.display_name !== undefined) {
      const nombre = cambios.display_name.trim()
      if (!nombre || nombre.length > 50) throw validacion([{ field: 'display_name', detail: 'Entre 1 y 50 caracteres.' }])
      u.display_name = nombre
    }
    if (cambios.about !== undefined) {
      if (cambios.about && cambios.about.length > 140) throw validacion([{ field: 'about', detail: 'Máximo 140 caracteres.' }])
      u.about = cambios.about?.trim() || null
    }
    if (cambios.avatar_media_id !== undefined) {
      if (cambios.avatar_media_id !== null) {
        const m = this.d.media.find((x) => x.id === cambios.avatar_media_id && x.owner_id === u.id)
        if (!m?.subido || m.purpose !== 'avatar') throw validacion([{ field: 'avatar_media_id', detail: 'Archivo no válido.' }])
      }
      u.avatar_media_id = cambios.avatar_media_id
    }
    return this.me(u)
  }

  verificarPassword(u: UsuarioDb, password: string): void {
    if (u.password !== password) {
      throw new ErrorMock(403, 'contrasena-incorrecta', 'Contraseña incorrecta', 'La contraseña actual no es correcta.')
    }
  }

  // ------------------------------------------------------------ relaciones

  private bloqueado(a: string, b: string): boolean {
    return this.d.bloqueos.some((x) => (x.blocker_id === a && x.blocked_id === b) || (x.blocker_id === b && x.blocked_id === a))
  }

  private yoBloquee(yo: string, otro: string): boolean {
    return this.d.bloqueos.some((x) => x.blocker_id === yo && x.blocked_id === otro)
  }

  private conversacionEntre(a: string, b: string): ConversacionDb | undefined {
    return this.d.conversaciones.find((c) => c.participantes.includes(a) && c.participantes.includes(b))
  }

  hayRelacion(a: string, b: string): boolean {
    return (
      this.d.contactos.some(
        (c) => (c.owner_id === a && c.contact_user_id === b) || (c.owner_id === b && c.contact_user_id === a),
      ) || this.conversacionEntre(a, b) !== undefined
    )
  }

  /** Usuarios con relación y sin bloqueo (destinatarios de la presencia). */
  relacionados(usuarioId: string): string[] {
    return this.d.usuarios
      .map((u) => u.id)
      .filter((id) => id !== usuarioId && this.hayRelacion(usuarioId, id) && !this.bloqueado(usuarioId, id))
  }

  usuarioPublico(yo: string, otroId: string): UsuarioPublico {
    const otro = this.usuario(otroId)
    if (!otro || otroId === yo || !this.hayRelacion(yo, otroId) || this.bloqueado(yo, otroId)) throw noEncontrado('Usuario no encontrado.')
    const esContacto = this.d.contactos.some((c) => c.owner_id === yo && c.contact_user_id === otroId)
    return {
      id: otro.id,
      display_name: otro.display_name,
      about: otro.about,
      avatar: this.media(otro.avatar_media_id),
      ...(esContacto ? { phone: otro.phone } : {}),
    }
  }

  // ------------------------------------------------------------ contactos y bloqueos

  private contactoVista(c: ContactoDb): Contacto {
    const u = this.usuario(c.contact_user_id)
    if (!u) throw noEncontrado()
    return {
      id: c.id,
      alias: c.alias,
      phone: u.phone,
      user: this.resumen(u),
      conversation_id: this.conversacionEntre(c.owner_id, c.contact_user_id)?.id ?? null,
      blocked: this.yoBloquee(c.owner_id, c.contact_user_id),
      created_at: c.created_at,
    }
  }

  listarContactos(yo: string, q: string | null, cursor: string | null, limite: number) {
    const consulta = q ? sinAcentos(q.trim()) : ''
    const lista = this.d.contactos
      .filter((c) => c.owner_id === yo)
      .map((c) => this.contactoVista(c))
      .filter((c) => {
        if (!consulta) return true
        const nombre = sinAcentos(`${c.alias ?? ''} ${c.user.display_name}`)
        return nombre.includes(consulta) || c.phone.replace('+', '').startsWith(consulta.replace(/[\s+]/g, ''))
      })
      .sort((a, b) => {
        const na = sinAcentos(a.alias ?? a.user.display_name)
        const nb = sinAcentos(b.alias ?? b.user.display_name)
        return na < nb ? -1 : na > nb ? 1 : a.id < b.id ? -1 : 1
      })
    return this.paginar(lista, cursor, limite)
  }

  private paginar<T>(lista: T[], cursor: string | null, limite: number) {
    const desde = cursor ? ((decodificarCursor(cursor) as { o?: number } | null)?.o ?? 0) : 0
    const items = lista.slice(desde, desde + limite)
    const siguiente = desde + limite < lista.length ? codificarCursor({ o: desde + limite }) : null
    return { items, next_cursor: siguiente }
  }

  obtenerContacto(yo: string, id: string): Contacto {
    const c = this.d.contactos.find((x) => x.id === id && x.owner_id === yo)
    if (!c) throw noEncontrado('Contacto no encontrado.')
    return this.contactoVista(c)
  }

  /** Alta idempotente por teléfono: 404 genérico si no existe, soy yo o me bloqueó. */
  crearContacto(yo: string, telefono: string, alias: string | undefined): { contacto: Contacto; creado: boolean } {
    if (!/^\+[1-9][0-9]{7,14}$/.test(telefono)) throw validacion([{ field: 'phone', detail: 'Debe estar en formato E.164, p. ej. +50688880001.' }])
    const destino = this.d.usuarios.find((u) => u.phone === telefono)
    const meBloqueo = destino ? this.d.bloqueos.some((b) => b.blocker_id === destino.id && b.blocked_id === yo) : false
    if (!destino || destino.id === yo || meBloqueo) throw noEncontrado('No encontramos a nadie con ese número.')
    const existente = this.d.contactos.find((c) => c.owner_id === yo && c.contact_user_id === destino.id)
    if (existente) return { contacto: this.contactoVista(existente), creado: false }
    const c: ContactoDb = { id: nuevoUuid(), owner_id: yo, contact_user_id: destino.id, alias: alias?.trim() || null, created_at: new Date().toISOString() }
    this.d.contactos.push(c)
    return { contacto: this.contactoVista(c), creado: true }
  }

  editarAlias(yo: string, id: string, alias: string | null): Contacto {
    const c = this.d.contactos.find((x) => x.id === id && x.owner_id === yo)
    if (!c) throw noEncontrado('Contacto no encontrado.')
    if (alias !== null && (alias.trim().length === 0 || alias.length > 50)) throw validacion([{ field: 'alias', detail: 'Entre 1 y 50 caracteres.' }])
    c.alias = alias?.trim() ?? null
    return this.contactoVista(c)
  }

  borrarContacto(yo: string, id: string): void {
    const i = this.d.contactos.findIndex((x) => x.id === id && x.owner_id === yo)
    if (i === -1) throw noEncontrado('Contacto no encontrado.')
    this.d.contactos.splice(i, 1)
  }

  listarBloqueos(yo: string, cursor: string | null, limite: number) {
    const lista: Bloqueo[] = this.d.bloqueos
      .filter((b) => b.blocker_id === yo)
      .sort((a, b) => (a.created_at < b.created_at ? 1 : -1))
      .flatMap((b) => {
        const u = this.usuario(b.blocked_id)
        return u ? [{ user: this.resumen(u), created_at: b.created_at }] : []
      })
    return this.paginar(lista, cursor, limite)
  }

  bloquear(yo: string, otro: string): void {
    if (otro === yo || !this.usuario(otro) || !this.hayRelacion(yo, otro)) throw noEncontrado('Usuario no encontrado.')
    if (!this.yoBloquee(yo, otro)) this.d.bloqueos.push({ blocker_id: yo, blocked_id: otro, created_at: new Date().toISOString() })
  }

  desbloquear(yo: string, otro: string): void {
    this.d.bloqueos = this.d.bloqueos.filter((b) => !(b.blocker_id === yo && b.blocked_id === otro))
  }

  // ------------------------------------------------------------ conversaciones

  private marcador(convId: string, usuarioId: string): MarcadorDb {
    const clave = `${convId}:${usuarioId}`
    this.d.marcadores[clave] ??= { delivered: null, seen: null }
    return this.d.marcadores[clave]
  }

  private posicion(mensajeId: string | null): MensajeDb | undefined {
    return mensajeId ? this.d.mensajes.find((m) => m.id === mensajeId) : undefined
  }

  private menorOIgual(a: MensajeDb, b: MensajeDb | undefined): boolean {
    if (!b) return false
    return a.created_at < b.created_at || (a.created_at === b.created_at && a.id <= b.id)
  }

  private otro(c: ConversacionDb, yo: string): string {
    return c.participantes[0] === yo ? c.participantes[1] : c.participantes[0]
  }

  participante(yo: string, convId: string): ConversacionDb {
    const c = this.d.conversaciones.find((x) => x.id === convId && x.participantes.includes(yo))
    if (!c) throw noEncontrado('Conversación no encontrada.')
    return c
  }

  mensajeVista(m: MensajeDb, yo: string): Mensaje {
    const base: Mensaje = {
      id: m.id,
      conversation_id: m.conversation_id,
      sender_id: m.sender_id,
      client_id: m.client_id,
      text: m.deleted_at ? null : m.text,
      media: m.deleted_at ? null : this.media(m.media_id),
      created_at: m.created_at,
      edited_at: m.edited_at,
      deleted_at: m.deleted_at,
      cursor: codificarCursor({ t: m.created_at, i: m.id }),
    }
    if (m.sender_id !== yo) return base
    const c = this.d.conversaciones.find((x) => x.id === m.conversation_id)
    if (!c) return base
    const mk = this.marcador(c.id, this.otro(c, yo))
    const status = this.menorOIgual(m, this.posicion(mk.seen)) ? 'seen' : this.menorOIgual(m, this.posicion(mk.delivered)) ? 'delivered' : 'sent'
    return { ...base, status }
  }

  private mensajesDe(convId: string): MensajeDb[] {
    return this.d.mensajes
      .filter((m) => m.conversation_id === convId)
      .sort((a, b) => (a.created_at < b.created_at ? -1 : a.created_at > b.created_at ? 1 : a.id < b.id ? -1 : 1))
  }

  conversacionVista(c: ConversacionDb, yo: string): Conversacion {
    const otroId = this.otro(c, yo)
    const otro = this.usuario(otroId)
    if (!otro) throw noEncontrado()
    const contacto = this.d.contactos.find((x) => x.owner_id === yo && x.contact_user_id === otroId)
    const lista = this.mensajesDe(c.id)
    const ultimo = lista[lista.length - 1]
    const visto = this.posicion(this.marcador(c.id, yo).seen)
    const noLeidos = lista.filter((m) => m.sender_id !== yo && !m.deleted_at && !this.menorOIgual(m, visto)).length
    return {
      id: c.id,
      peer: this.resumen(otro),
      contact_id: contacto?.id ?? null,
      is_contact: contacto !== undefined,
      blocked: this.yoBloquee(yo, otroId),
      unread_count: noLeidos,
      last_message: ultimo ? this.mensajeVista(ultimo, yo) : null,
      created_at: c.created_at,
    }
  }

  listarConversaciones(yo: string, cursor: string | null, limite: number) {
    const lista = this.d.conversaciones
      .filter((c) => c.participantes.includes(yo))
      .map((c) => this.conversacionVista(c, yo))
      .sort((a, b) => {
        const ta = a.last_message?.created_at ?? a.created_at
        const tb = b.last_message?.created_at ?? b.created_at
        return ta < tb ? 1 : ta > tb ? -1 : a.id < b.id ? 1 : -1
      })
    return this.paginar(lista, cursor, limite)
  }

  crearConversacion(yo: string, contactoId: string): { conversacion: Conversacion; creada: boolean } {
    const contacto = this.d.contactos.find((c) => c.id === contactoId && c.owner_id === yo)
    if (!contacto) throw noEncontrado('Contacto no encontrado.')
    if (this.bloqueado(yo, contacto.contact_user_id)) {
      throw new ErrorMock(403, 'bloqueado', 'Acción bloqueada', 'No es posible enviar mensajes a este usuario.')
    }
    const existente = this.conversacionEntre(yo, contacto.contact_user_id)
    if (existente) return { conversacion: this.conversacionVista(existente, yo), creada: false }
    const c: ConversacionDb = { id: nuevoUuid(), participantes: [yo, contacto.contact_user_id], created_at: new Date().toISOString() }
    this.d.conversaciones.push(c)
    for (const p of c.participantes) this.publicar(p, 'conversation.new', { conversation: this.conversacionVista(c, p) })
    return { conversacion: this.conversacionVista(c, yo), creada: true }
  }

  // ------------------------------------------------------------ mensajes

  listarMensajes(yo: string, convId: string, opciones: { before: string | null; after: string | null; limite: number }) {
    const c = this.participante(yo, convId)
    const todos = this.mensajesDe(convId)
    let pagina: MensajeDb[]
    let hayMas: boolean
    if (opciones.before) {
      const ref = decodificarCursor(opciones.before) as { t: string; i: string } | null
      if (!ref) throw new ErrorMock(400, 'peticion-invalida', 'Petición inválida', 'Cursor inválido.')
      const previos = todos.filter((m) => m.created_at < ref.t || (m.created_at === ref.t && m.id < ref.i))
      pagina = previos.slice(-opciones.limite)
      hayMas = previos.length > opciones.limite
    } else if (opciones.after) {
      const ref = decodificarCursor(opciones.after) as { t: string; i: string } | null
      if (!ref) throw new ErrorMock(400, 'peticion-invalida', 'Petición inválida', 'Cursor inválido.')
      const posteriores = todos.filter((m) => m.created_at > ref.t || (m.created_at === ref.t && m.id > ref.i))
      pagina = posteriores.slice(0, opciones.limite)
      hayMas = posteriores.length > opciones.limite
    } else {
      pagina = todos.slice(-opciones.limite)
      hayMas = todos.length > opciones.limite
    }
    const items = pagina.map((m) => this.mensajeVista(m, yo))
    const extremo = opciones.after ? items[items.length - 1] : items[0]
    // Listar marca como entregados los mensajes recibidos devueltos.
    const recibidos = pagina.filter((m) => m.sender_id !== yo)
    const ultimoRecibido = recibidos[recibidos.length - 1]
    if (ultimoRecibido) this.marcarRecibo(yo, c.id, 'delivered', ultimoRecibido.id)
    return { items, next_cursor: hayMas && extremo ? extremo.cursor : null }
  }

  enviarMensaje(yo: string, convId: string, datos: { client_id?: string; text?: string; media_id?: string }): { mensaje: Mensaje; creado: boolean } {
    const c = this.participante(yo, convId)
    const otroId = this.otro(c, yo)
    if (this.bloqueado(yo, otroId)) throw new ErrorMock(403, 'bloqueado', 'Acción bloqueada', 'No es posible enviar mensajes a este usuario.')
    const texto = datos.text?.trim()
    if (!texto && !datos.media_id) throw validacion([{ field: 'text', detail: 'El mensaje no puede estar vacío.' }])
    if (texto && texto.length > 4000) throw validacion([{ field: 'text', detail: 'Máximo 4000 caracteres.' }])
    if (datos.client_id) {
      const repetido = this.d.mensajes.find((m) => m.sender_id === yo && m.client_id === datos.client_id)
      if (repetido) return { mensaje: this.mensajeVista(repetido, yo), creado: false }
    }
    if (datos.media_id) {
      const media = this.d.media.find((x) => x.id === datos.media_id && x.owner_id === yo)
      if (!media?.subido || media.purpose !== 'message') throw validacion([{ field: 'media_id', detail: 'Archivo no válido.' }])
    }
    const m: MensajeDb = {
      id: nuevoUuid(),
      conversation_id: convId,
      sender_id: yo,
      client_id: datos.client_id ?? null,
      text: texto ?? null,
      media_id: datos.media_id ?? null,
      created_at: new Date().toISOString(),
      edited_at: null,
      deleted_at: null,
    }
    this.d.mensajes.push(m)
    // Enviar implica haber leído todo lo anterior.
    this.marcador(convId, yo).seen = m.id
    this.marcador(convId, yo).delivered = m.id
    for (const p of c.participantes) this.publicar(p, 'message.new', { message: this.mensajeVista(m, p) })
    return { mensaje: this.mensajeVista(m, yo), creado: true }
  }

  private mensajePropio(yo: string, id: string): MensajeDb {
    const m = this.d.mensajes.find((x) => x.id === id)
    if (m?.sender_id !== yo) throw noEncontrado('Mensaje no encontrado.')
    return m
  }

  editarMensaje(yo: string, id: string, texto: string): Mensaje {
    const m = this.mensajePropio(yo, id)
    if (m.deleted_at) throw noEncontrado('Mensaje no encontrado.')
    if (Date.now() - new Date(m.created_at).getTime() > VENTANA_EDICION_MS) {
      throw new ErrorMock(422, 'edicion-expirada', 'Edición expirada', 'Solo se puede editar durante 15 minutos.')
    }
    const limpio = texto.trim()
    if (!limpio || limpio.length > 4000) throw validacion([{ field: 'text', detail: 'Entre 1 y 4000 caracteres.' }])
    m.text = limpio
    m.edited_at = new Date().toISOString()
    const c = this.participante(yo, m.conversation_id)
    for (const p of c.participantes) this.publicar(p, 'message.edited', { message: this.mensajeVista(m, p) })
    return this.mensajeVista(m, yo)
  }

  borrarMensaje(yo: string, id: string): void {
    const m = this.mensajePropio(yo, id)
    if (m.deleted_at) return
    m.deleted_at = new Date().toISOString()
    m.text = null
    m.media_id = null
    const c = this.participante(yo, m.conversation_id)
    for (const p of c.participantes) {
      this.publicar(p, 'message.deleted', { conversation_id: c.id, message_id: m.id, deleted_at: m.deleted_at })
    }
  }

  /** Marcador monótono de recibos; publica al emisor. Devuelve el ReceiptResult. */
  marcarRecibo(yo: string, convId: string, estado: 'delivered' | 'seen', hastaId: string) {
    const c = this.participante(yo, convId)
    const objetivo = this.d.mensajes.find((m) => m.id === hastaId && m.conversation_id === convId)
    if (!objetivo) throw noEncontrado('Mensaje no encontrado.')
    const mk = this.marcador(convId, yo)
    const otroId = this.otro(c, yo)
    let actualizados = 0
    const avanzar = (campo: 'delivered' | 'seen') => {
      const actual = this.posicion(mk[campo])
      if (actual && this.menorOIgual(objetivo, actual)) return false
      actualizados += this.mensajesDe(convId).filter(
        (m) => m.sender_id === otroId && this.menorOIgual(m, objetivo) && !this.menorOIgual(m, actual),
      ).length
      mk[campo] = objetivo.id
      return true
    }
    const cambioEntrega = avanzar('delivered')
    const cambioVisto = estado === 'seen' ? avanzar('seen') : false
    const datos = { conversation_id: convId, user_id: yo, up_to_message_id: objetivo.id, at: new Date().toISOString() }
    if (cambioVisto) {
      this.publicar(otroId, 'receipt.seen', datos)
      this.publicar(yo, 'receipt.seen', datos)
    } else if (cambioEntrega) {
      this.publicar(otroId, 'receipt.delivered', datos)
    }
    return {
      conversation_id: convId,
      status: estado,
      up_to_message_id: objetivo.id,
      updated_count: actualizados,
      unread_count: this.conversacionVista(c, yo).unread_count,
    }
  }

  esParticipante(yo: string, convId: string): ConversacionDb | null {
    return this.d.conversaciones.find((x) => x.id === convId && x.participantes.includes(yo)) ?? null
  }

  otroParticipante(c: ConversacionDb, yo: string): string {
    return this.otro(c, yo)
  }

  hayBloqueo(a: string, b: string): boolean {
    return this.bloqueado(a, b)
  }

  // ------------------------------------------------------------ subidas

  crearSubida(yo: string, datos: { purpose: 'avatar' | 'message'; content_type: string; size_bytes: number }) {
    const tiposAvatar = ['image/jpeg', 'image/png', 'image/webp']
    const tipos = [...tiposAvatar, 'image/gif', 'application/pdf', 'audio/ogg', 'audio/mpeg', 'video/mp4']
    const maximo = datos.purpose === 'avatar' ? 2 * 1024 * 1024 : 20 * 1024 * 1024
    if (!(datos.purpose === 'avatar' ? tiposAvatar : tipos).includes(datos.content_type)) {
      throw validacion([{ field: 'content_type', detail: 'Tipo de archivo no permitido.' }])
    }
    if (datos.size_bytes < 1 || datos.size_bytes > maximo) {
      throw validacion([{ field: 'size_bytes', detail: `El archivo supera el máximo de ${datos.purpose === 'avatar' ? '2' : '20'} MiB.` }])
    }
    const m: MediaDb = { id: nuevoUuid(), owner_id: yo, purpose: datos.purpose, content_type: datos.content_type, size_bytes: datos.size_bytes, url: null, subido: false }
    this.d.media.push(m)
    return m
  }

  completarSubida(mediaId: string, url: string): boolean {
    const m = this.d.media.find((x) => x.id === mediaId)
    if (!m) return false
    m.url = url
    m.subido = true
    return true
  }

  // ------------------------------------------------------------ presencia

  conectar(usuarioId: string): void {
    const n = (this.conexiones.get(usuarioId) ?? 0) + 1
    this.conexiones.set(usuarioId, n)
    if (n === 1) for (const r of this.relacionados(usuarioId)) this.publicar(r, 'presence', { user_id: usuarioId, status: 'online', last_seen_at: null })
  }

  desconectar(usuarioId: string): void {
    const n = Math.max(0, (this.conexiones.get(usuarioId) ?? 1) - 1)
    this.conexiones.set(usuarioId, n)
    if (n === 0) {
      const ahora = new Date().toISOString()
      this.ultimaConexion.set(usuarioId, ahora)
      for (const r of this.relacionados(usuarioId)) this.publicar(r, 'presence', { user_id: usuarioId, status: 'offline', last_seen_at: ahora })
    }
  }

  /** Marca a un usuario simulado (bot) como conectado o no, sin conexiones reales. */
  fijarEnLinea(usuarioId: string, enLinea: boolean): void {
    if (enLinea) this.conectar(usuarioId)
    else this.desconectar(usuarioId)
  }

  presencia(usuarioId: string): { status: 'online' | 'offline'; last_seen_at: string | null } {
    const enLinea = (this.conexiones.get(usuarioId) ?? 0) > 0
    return { status: enLinea ? 'online' : 'offline', last_seen_at: enLinea ? null : (this.ultimaConexion.get(usuarioId) ?? null) }
  }

  tieneSesionActiva(usuarioId: string): boolean {
    return this.d.sesiones.some((s) => s.user_id === usuarioId && !s.revocada)
  }

  conectado(usuarioId: string): boolean {
    return (this.conexiones.get(usuarioId) ?? 0) > 0
  }
}
