/**
 * Servidor WebSocket simulado con `ws.link` de MSW (docs/contratos/ws-eventos.md):
 * auth en 5 s, ping/pong, typing, seen, presence.query, cierres 4001/4003/4401 y
 * reenvío de los eventos que "publica la API" (MockDb.publicar ≈ Redis pub/sub).
 */
import { ws } from 'msw'
import type { MockDb } from './db'
import { nuevoUuid } from '@/lib/uuid'

interface ClienteMock {
  send: (datos: string) => void
  close: (codigo?: number, motivo?: string) => void
}

interface Conexion {
  cliente: ClienteMock
  usuarioId: string | null
  sesionId: string | null
}

export interface OpcionesWsMock {
  wsUrl: string
  /** Tiempo para autenticarse antes del cierre 4001. */
  esperaAuthMs?: number
}

function sobre(type: string, data: unknown): string {
  return JSON.stringify({ type, id: nuevoUuid(), ts: new Date().toISOString(), data })
}

export function crearHandlersWs(db: MockDb, opciones: OpcionesWsMock) {
  const enlace = ws.link(opciones.wsUrl)
  const conexiones = new Set<Conexion>()

  // "Redis pub/sub": cada evento dirigido a un usuario llega a todas sus conexiones.
  db.alPublicar((usuarioId, evento) => {
    const texto = JSON.stringify(evento)
    for (const c of conexiones) if (c.usuarioId === usuarioId) c.cliente.send(texto)
  })
  db.alRevocarSesion((sesionId) => {
    for (const c of conexiones) if (c.sesionId === sesionId) c.cliente.close(4401, 'session_revoked')
  })

  const handler = enlace.addEventListener('connection', ({ client }) => {
    const conexion: Conexion = { cliente: client, usuarioId: null, sesionId: null }
    conexiones.add(conexion)
    const temporizador = setTimeout(() => {
      if (!conexion.usuarioId) client.close(4001, 'auth_timeout')
    }, opciones.esperaAuthMs ?? 5000)

    const responderError = (code: string, replyTo?: string, detail?: string) => {
      client.send(sobre('error', { code, ...(replyTo ? { reply_to: replyTo } : {}), ...(detail ? { detail } : {}) }))
    }

    client.addEventListener('message', (evento) => {
      if (typeof evento.data !== 'string') return
      let msg: { type?: unknown; id?: unknown; data?: Record<string, unknown> }
      try {
        msg = JSON.parse(evento.data) as typeof msg
      } catch {
        responderError('invalid_payload')
        return
      }
      const id = typeof msg.id === 'string' ? msg.id : undefined
      const datos = msg.data ?? {}

      if (msg.type === 'auth') {
        try {
          const { usuario, sesion } = db.autenticar(typeof datos.access_token === 'string' ? datos.access_token : null)
          if (conexion.usuarioId && conexion.usuarioId !== usuario.id) {
            client.close(4401, 'invalid_token')
            return
          }
          const primera = conexion.usuarioId === null
          conexion.usuarioId = usuario.id
          conexion.sesionId = sesion.id
          clearTimeout(temporizador)
          client.send(
            sobre('auth.ok', {
              reply_to: id,
              user_id: usuario.id,
              session_id: sesion.id,
              expires_at: new Date(sesion.accessExpira).toISOString(),
              heartbeat_interval: 25,
            }),
          )
          if (primera) db.conectar(usuario.id)
        } catch {
          responderError('invalid_token', id)
          client.close(4401, 'invalid_token')
        }
        return
      }

      if (!conexion.usuarioId) {
        client.close(4003, 'not_authenticated')
        return
      }
      const yo = conexion.usuarioId

      switch (msg.type) {
        case 'ping':
          client.send(sobre('pong', { reply_to: id }))
          return
        case 'typing': {
          const conv = db.esParticipante(yo, String(datos.conversation_id))
          if (!conv) {
            responderError('not_found', id)
            return
          }
          const otro = db.otroParticipante(conv, yo)
          if (db.hayBloqueo(yo, otro)) {
            responderError('blocked', id)
            return
          }
          db.publicar(otro, 'typing', { conversation_id: conv.id, user_id: yo, state: datos.state === 'stop' ? 'stop' : 'start' })
          return
        }
        case 'seen':
          try {
            db.marcarRecibo(yo, String(datos.conversation_id), 'seen', String(datos.up_to_message_id))
            db.guardar()
          } catch {
            responderError('not_found', id)
          }
          return
        case 'presence.query': {
          const ids = Array.isArray(datos.user_ids) ? datos.user_ids.slice(0, 100) : []
          const relacionados = new Set(db.relacionados(yo))
          for (const u of ids) {
            if (typeof u !== 'string' || !relacionados.has(u)) continue
            client.send(sobre('presence', { user_id: u, ...db.presencia(u) }))
          }
          return
        }
        default:
          responderError('unknown_type', id)
      }
    })

    client.addEventListener('close', () => {
      clearTimeout(temporizador)
      conexiones.delete(conexion)
      if (conexion.usuarioId) db.desconectar(conexion.usuarioId)
    })
  })

  return { handler, conexiones }
}
