import { useInfiniteQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { api, ok } from '@/api/cliente'
import { claves } from '@/api/claves'
import { esBloqueo, mensajeDeError } from '@/api/errores'
import type { EnviarMensajePeticion, Mensaje, MensajeChat } from '@/api/tipos'
import { useAuth } from '@/auth/sesion'
import {
  actualizarMensaje,
  marcarBorrado,
  mensajesOrdenados,
  upsertMensaje,
  type CacheMensajes,
} from '@/cache/mensajes'
import { actualizarConversacion, actualizarUltimoMensaje, registrarMensajeEnLista, type CacheConversaciones } from '@/cache/conversaciones'
import { avisar } from '@/components/ui/Avisos'
import { subirArchivo } from '@/features/subidas'
import { useTiempoReal } from '@/realtime/TiempoReal'
import { useCallback } from 'react'

export const TAMANO_PAGINA_MENSAJES = 30

/**
 * Al refrescar una conversación por REST se conservan los mensajes optimistas que el
 * servidor aún no devuelve (si no, desaparecerían de la pantalla mientras se envían).
 */
function conservarLocales(viejo: unknown, nuevo: unknown): unknown {
  const locales = mensajesOrdenados(viejo as CacheMensajes | undefined).filter((m) => m.local)
  if (locales.length === 0) return nuevo
  let resultado = nuevo as CacheMensajes
  const confirmados = new Set(mensajesOrdenados(resultado).map((m) => m.client_id))
  for (const m of locales) if (!confirmados.has(m.client_id)) resultado = upsertMensaje(resultado, m)
  return resultado
}

/** Historial con scroll infinito hacia arriba: cada página siguiente es más antigua (`before`). */
export function useMensajes(conversacionId: string, opciones: { sondeoMs?: number | false } = {}) {
  return useInfiniteQuery({
    queryKey: claves.mensajes(conversacionId),
    queryFn: ({ pageParam, signal }) =>
      ok(
        api.GET('/conversations/{conversationId}/messages', {
          params: {
            path: { conversationId: conversacionId },
            query: { limit: TAMANO_PAGINA_MENSAJES, ...(pageParam ? { before: pageParam } : {}) },
          },
          signal,
        }),
      ),
    initialPageParam: null as string | null,
    getNextPageParam: (pagina) => pagina.next_cursor,
    // Con WebSocket la caché se mantiene sola; sin él se sondea cada cierto tiempo.
    staleTime: Infinity,
    refetchInterval: opciones.sondeoMs ?? false,
    structuralSharing: conservarLocales,
  })
}

/** Archivos de envíos sin confirmar: permiten reintentar un adjunto que falló. */
const archivosPendientes = new Map<string, File>()

export function archivoPendiente(clientId: string): File | undefined {
  return archivosPendientes.get(clientId)
}

export function olvidarArchivo(clientId: string): void {
  archivosPendientes.delete(clientId)
}

interface VariablesEnvio {
  clientId: string
  texto?: string
  archivo?: File
}

function urlLocal(archivo: File): string {
  try {
    return URL.createObjectURL(archivo)
  } catch {
    return ''
  }
}

/** Envío optimista e idempotente (client_id = Idempotency-Key, reintento seguro). */
export function useEnviarMensaje(conversacionId: string) {
  const qc = useQueryClient()
  const miId = useAuth((s) => s.usuario?.id ?? '')
  const claveM = claves.mensajes(conversacionId)

  return useMutation({
    mutationFn: async ({ clientId, texto, archivo }: VariablesEnvio): Promise<Mensaje> => {
      const mediaId = archivo ? await subirArchivo(archivo, 'message') : undefined
      const cuerpo: EnviarMensajePeticion = {
        client_id: clientId,
        ...(texto ? { text: texto } : {}),
        ...(mediaId ? { media_id: mediaId } : {}),
      }
      return ok(
        api.POST('/conversations/{conversationId}/messages', {
          params: { path: { conversationId: conversacionId }, header: { 'Idempotency-Key': clientId } },
          body: cuerpo,
        }),
      )
    },
    onMutate: ({ clientId, texto, archivo }) => {
      if (archivo) archivosPendientes.set(clientId, archivo)
      const optimista: MensajeChat = {
        id: clientId,
        conversation_id: conversacionId,
        sender_id: miId,
        client_id: clientId,
        text: texto ?? null,
        media: archivo
          ? {
              id: clientId,
              content_type: archivo.type,
              size_bytes: archivo.size,
              url: urlLocal(archivo),
              url_expires_at: new Date(Date.now() + 3_600_000).toISOString(),
              width: null,
              height: null,
            }
          : null,
        created_at: new Date().toISOString(),
        edited_at: null,
        deleted_at: null,
        cursor: '',
        local: 'enviando',
      }
      qc.setQueryData<CacheMensajes>(claveM, (c) => upsertMensaje(c, optimista))
      qc.setQueryData<CacheConversaciones>(claves.conversaciones(), (c) => registrarMensajeEnLista(c, optimista, { sumarNoLeido: false }) ?? c)
    },
    onSuccess: (mensaje, { clientId }) => {
      archivosPendientes.delete(clientId)
      qc.setQueryData<CacheMensajes>(claveM, (c) => upsertMensaje(c, mensaje))
      qc.setQueryData<CacheConversaciones>(claves.conversaciones(), (c) => registrarMensajeEnLista(c, mensaje, { sumarNoLeido: false }) ?? c)
    },
    onError: (error, { clientId }) => {
      qc.setQueryData<CacheMensajes>(claveM, (c) => actualizarMensaje(c, clientId, (m) => ({ ...m, local: 'fallido' })))
      if (esBloqueo(error)) {
        avisar('No es posible enviar mensajes a este usuario.', 'error')
        void qc.invalidateQueries({ queryKey: claves.conversaciones() })
      } else {
        avisar(mensajeDeError(error), 'error')
      }
    },
  })
}

export function useEditarMensaje(conversacionId: string) {
  const qc = useQueryClient()
  const claveM = claves.mensajes(conversacionId)
  return useMutation({
    mutationFn: ({ id, texto }: { id: string; texto: string }) =>
      ok(api.PATCH('/messages/{messageId}', { params: { path: { messageId: id } }, body: { text: texto } })),
    onMutate: ({ id, texto }) => {
      const previo = qc.getQueryData<CacheMensajes>(claveM)
      qc.setQueryData<CacheMensajes>(claveM, (c) =>
        actualizarMensaje(c, id, (m) => ({ ...m, text: texto, edited_at: new Date().toISOString() })),
      )
      return { previo }
    },
    onSuccess: (mensaje) => {
      qc.setQueryData<CacheMensajes>(claveM, (c) => upsertMensaje(c, mensaje))
      qc.setQueryData<CacheConversaciones>(claves.conversaciones(), (c) =>
        actualizarUltimoMensaje(c, conversacionId, mensaje.id, (m) => ({ ...m, ...mensaje })),
      )
    },
    onError: (error, _v, contexto) => {
      if (contexto?.previo) qc.setQueryData(claveM, contexto.previo)
      avisar(mensajeDeError(error), 'error')
    },
  })
}

export function useBorrarMensaje(conversacionId: string) {
  const qc = useQueryClient()
  const claveM = claves.mensajes(conversacionId)
  return useMutation({
    mutationFn: async (id: string) => {
      await ok(api.DELETE('/messages/{messageId}', { params: { path: { messageId: id } } }))
    },
    onMutate: (id) => {
      const previo = qc.getQueryData<CacheMensajes>(claveM)
      const ahora = new Date().toISOString()
      qc.setQueryData<CacheMensajes>(claveM, (c) => marcarBorrado(c, id, ahora))
      qc.setQueryData<CacheConversaciones>(claves.conversaciones(), (c) =>
        actualizarUltimoMensaje(c, conversacionId, id, (m) => ({ ...m, text: null, media: null, deleted_at: ahora })),
      )
      return { previo }
    },
    onError: (error, _id, contexto) => {
      if (contexto?.previo) qc.setQueryData(claveM, contexto.previo)
      avisar(mensajeDeError(error), 'error')
    },
  })
}

/** Marca como visto hasta un mensaje: por WebSocket si hay conexión; si no, por REST. */
export function useMarcarVisto(conversacionId: string) {
  const qc = useQueryClient()
  const { enviarVisto } = useTiempoReal()
  return useCallback(
    (mensajeId: string) => {
      qc.setQueryData<CacheConversaciones>(claves.conversaciones(), (c) =>
        actualizarConversacion(c, conversacionId, (conv) => ({ ...conv, unread_count: 0 })),
      )
      if (enviarVisto(conversacionId, mensajeId)) return
      api
        .POST('/conversations/{conversationId}/receipts', {
          params: { path: { conversationId: conversacionId } },
          body: { status: 'seen', up_to_message_id: mensajeId },
        })
        .catch(() => {
          /* no crítico: se reintentará al volver a abrir la conversación */
        })
    },
    [qc, conversacionId, enviarVisto],
  )
}
