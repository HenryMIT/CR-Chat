/** Tipos del contrato WebSocket (docs/contratos/ws-eventos.md). */
import type { Conversacion, Id, Mensaje } from '@/api/tipos'

export interface Sobre<T extends string = string, D = unknown> {
  type: T
  id: string
  ts: string
  data: D
}

export interface DatosRecibo {
  conversation_id: Id
  user_id: Id
  up_to_message_id: Id
  at: string
}

export type EventoServidor =
  | Sobre<'auth.ok', { reply_to?: string; user_id: Id; session_id: Id; expires_at: string; heartbeat_interval?: number }>
  | Sobre<'auth.expiring', { expires_at: string }>
  | Sobre<'pong', { reply_to?: string }>
  | Sobre<'message.new', { message: Mensaje }>
  | Sobre<'message.edited', { message: Mensaje }>
  | Sobre<'message.deleted', { conversation_id: Id; message_id: Id; deleted_at: string }>
  | Sobre<'receipt.delivered', DatosRecibo>
  | Sobre<'receipt.seen', DatosRecibo>
  | Sobre<'conversation.new', { conversation: Conversacion }>
  | Sobre<'typing', { conversation_id: Id; user_id: Id; state: 'start' | 'stop' }>
  | Sobre<'presence', { user_id: Id; status: 'online' | 'offline'; last_seen_at: string | null }>
  | Sobre<'error', { reply_to?: string; code: string; detail?: string; retry_after?: number }>

export type TipoEventoServidor = EventoServidor['type']

export interface EventosCliente {
  auth: { access_token: string }
  ping: Record<string, never>
  typing: { conversation_id: Id; state: 'start' | 'stop' }
  seen: { conversation_id: Id; up_to_message_id: Id }
  'presence.query': { user_ids: Id[] }
}

const TIPOS_CONOCIDOS = new Set<string>([
  'auth.ok',
  'auth.expiring',
  'pong',
  'message.new',
  'message.edited',
  'message.deleted',
  'receipt.delivered',
  'receipt.seen',
  'conversation.new',
  'typing',
  'presence',
  'error',
])

/** Valida la forma mínima del sobre. Un `type` desconocido se ignora (contrato §2). */
export function analizarEvento(texto: unknown): EventoServidor | null {
  if (typeof texto !== 'string') return null
  let valor: unknown
  try {
    valor = JSON.parse(texto)
  } catch {
    return null
  }
  if (typeof valor !== 'object' || valor === null) return null
  const sobre = valor as Partial<Sobre>
  if (typeof sobre.type !== 'string' || !TIPOS_CONOCIDOS.has(sobre.type)) return null
  if (typeof sobre.data !== 'object' || sobre.data === null) return null
  return valor as EventoServidor
}
