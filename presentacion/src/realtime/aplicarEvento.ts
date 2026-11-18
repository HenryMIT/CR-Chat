/** Integra los eventos del servidor WebSocket en la caché de TanStack Query. */
import type { QueryClient } from '@tanstack/react-query'
import { claves } from '@/api/claves'
import {
  aplicarRecibo,
  compararMensajes,
  estadoMaximo,
  existeMensaje,
  marcarBorrado,
  mensajesOrdenados,
  upsertMensaje,
  type CacheMensajes,
} from '@/cache/mensajes'
import {
  actualizarConversacion,
  actualizarUltimoMensaje,
  buscarConversacion,
  registrarMensajeEnLista,
  subirConversacion,
  type CacheConversaciones,
} from '@/cache/conversaciones'
import { fijarPresencia, marcarEscribiendo, useEfimero } from './estadoEfimero'
import type { EventoServidor } from './eventos'

export interface ContextoEvento {
  miId: string
}

function conversacionVisible(id: string): boolean {
  const visible = typeof document === 'undefined' || document.visibilityState === 'visible'
  return visible && useEfimero.getState().conversacionActiva === id
}

export function aplicarEventoServidor(qc: QueryClient, evento: EventoServidor, ctx: ContextoEvento): void {
  switch (evento.type) {
    case 'message.new': {
      const m = evento.data.message
      const claveM = claves.mensajes(m.conversation_id)
      if (qc.getQueryData(claveM)) qc.setQueryData<CacheMensajes>(claveM, (c) => upsertMensaje(c, m))

      const deOtro = m.sender_id !== ctx.miId
      const lista = qc.getQueryData<CacheConversaciones>(claves.conversaciones())
      const nueva = registrarMensajeEnLista(lista, m, { sumarNoLeido: deOtro && !conversacionVisible(m.conversation_id) })
      if (nueva) qc.setQueryData(claves.conversaciones(), nueva)
      else void qc.invalidateQueries({ queryKey: claves.conversaciones() })

      if (deOtro) marcarEscribiendo(m.conversation_id, m.sender_id, false)
      return
    }

    case 'message.edited': {
      const m = evento.data.message
      const claveM = claves.mensajes(m.conversation_id)
      const cache = qc.getQueryData<CacheMensajes>(claveM)
      if (cache) {
        // Edición de un mensaje que no conocemos: se pide por REST (contrato §6).
        if (existeMensaje(cache, m.id)) qc.setQueryData<CacheMensajes>(claveM, (c) => upsertMensaje(c, m))
        else void qc.invalidateQueries({ queryKey: claveM })
      }
      qc.setQueryData<CacheConversaciones>(claves.conversaciones(), (c) =>
        actualizarUltimoMensaje(c, m.conversation_id, m.id, (previo) => ({ ...m, status: estadoMaximo(previo.status, m.status) })),
      )
      return
    }

    case 'message.deleted': {
      const { conversation_id, message_id, deleted_at } = evento.data
      qc.setQueryData<CacheMensajes>(claves.mensajes(conversation_id), (c) => marcarBorrado(c, message_id, deleted_at))
      qc.setQueryData<CacheConversaciones>(claves.conversaciones(), (c) =>
        actualizarUltimoMensaje(c, conversation_id, message_id, (m) => ({ ...m, text: null, media: null, deleted_at })),
      )
      return
    }

    case 'receipt.delivered':
    case 'receipt.seen': {
      const { conversation_id, user_id, up_to_message_id } = evento.data
      const estado = evento.type === 'receipt.seen' ? 'seen' : 'delivered'
      if (user_id === ctx.miId) {
        // Lo leí desde otro dispositivo: ya no hay pendientes en esta conversación.
        if (estado === 'seen') {
          qc.setQueryData<CacheConversaciones>(claves.conversaciones(), (c) =>
            actualizarConversacion(c, conversation_id, (conv) => ({ ...conv, unread_count: 0 })),
          )
        }
        return
      }
      const claveM = claves.mensajes(conversation_id)
      const cache = qc.getQueryData<CacheMensajes>(claveM)
      const actualizada = aplicarRecibo(cache, up_to_message_id, estado, ctx.miId)
      if (actualizada) qc.setQueryData(claveM, actualizada)
      else if (cache) void qc.invalidateQueries({ queryKey: claveM })

      const objetivo = mensajesOrdenados(actualizada ?? cache).find((m) => m.id === up_to_message_id)
      qc.setQueryData<CacheConversaciones>(claves.conversaciones(), (c) =>
        actualizarConversacion(c, conversation_id, (conv) => {
          const ultimo = conv.last_message
          if (!ultimo || ultimo.sender_id !== ctx.miId) return conv
          const alcanza = ultimo.id === up_to_message_id || (objetivo !== undefined && compararMensajes(ultimo, objetivo) <= 0)
          if (!alcanza) return conv
          return { ...conv, last_message: { ...ultimo, status: estadoMaximo(ultimo.status, estado) ?? estado } }
        }),
      )
      return
    }

    case 'conversation.new': {
      const conv = evento.data.conversation
      const lista = qc.getQueryData<CacheConversaciones>(claves.conversaciones())
      if (!lista) {
        void qc.invalidateQueries({ queryKey: claves.conversaciones() })
        return
      }
      if (!buscarConversacion(lista, conv.id)) qc.setQueryData(claves.conversaciones(), subirConversacion(lista, conv))
      return
    }

    case 'typing': {
      const { conversation_id, user_id, state } = evento.data
      if (user_id !== ctx.miId) marcarEscribiendo(conversation_id, user_id, state === 'start')
      return
    }

    case 'presence':
      fijarPresencia(evento.data.user_id, evento.data.status, evento.data.last_seen_at)
      return

    case 'error':
      if (import.meta.env.DEV) console.warn('[ws] error del servidor:', evento.data.code, evento.data.detail ?? '')
      return

    default:
      return
  }
}
