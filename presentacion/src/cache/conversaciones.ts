/** Operaciones puras sobre la caché de la lista de conversaciones (orden por actividad). */
import type { InfiniteData } from '@tanstack/react-query'
import type { Conversacion, Mensaje, PaginaConversaciones } from '@/api/tipos'

export type CacheConversaciones = InfiniteData<PaginaConversaciones>

export function todasLasConversaciones(cache: CacheConversaciones | undefined): Conversacion[] {
  return cache?.pages.flatMap((p) => p.items) ?? []
}

export function buscarConversacion(cache: CacheConversaciones | undefined, id: string): Conversacion | undefined {
  return todasLasConversaciones(cache).find((c) => c.id === id)
}

export function actualizarConversacion(
  cache: CacheConversaciones | undefined,
  id: string,
  cambio: (c: Conversacion) => Conversacion,
): CacheConversaciones | undefined {
  if (!cache) return cache
  return {
    ...cache,
    pages: cache.pages.map((p) => ({ ...p, items: p.items.map((c) => (c.id === id ? cambio(c) : c)) })),
  }
}

/** Coloca la conversación al principio (actividad más reciente), quitándola de donde estuviera. */
export function subirConversacion(cache: CacheConversaciones | undefined, conversacion: Conversacion): CacheConversaciones | undefined {
  if (!cache) return cache
  const pages = cache.pages.map((p) => ({ ...p, items: p.items.filter((c) => c.id !== conversacion.id) }))
  const [primera, ...resto] = pages
  return {
    ...cache,
    pages: [{ next_cursor: primera?.next_cursor ?? null, items: [conversacion, ...(primera?.items ?? [])] }, ...resto],
  }
}

/**
 * Refleja un mensaje nuevo en la lista: último mensaje, posición y no leídos.
 * Devuelve undefined si la conversación no está en caché (hay que pedirla por REST).
 */
export function registrarMensajeEnLista(
  cache: CacheConversaciones | undefined,
  mensaje: Mensaje,
  opciones: { sumarNoLeido: boolean },
): CacheConversaciones | undefined {
  const actual = buscarConversacion(cache, mensaje.conversation_id)
  if (!cache || !actual) return undefined
  const esMasReciente = !actual.last_message || actual.last_message.created_at <= mensaje.created_at
  if (!esMasReciente) return cache
  const yaContado = actual.last_message?.id === mensaje.id
  return subirConversacion(cache, {
    ...actual,
    last_message: mensaje,
    unread_count: actual.unread_count + (opciones.sumarNoLeido && !yaContado ? 1 : 0),
  })
}

export function actualizarUltimoMensaje(
  cache: CacheConversaciones | undefined,
  conversacionId: string,
  mensajeId: string,
  cambio: (m: Mensaje) => Mensaje,
): CacheConversaciones | undefined {
  return actualizarConversacion(cache, conversacionId, (c) =>
    c.last_message?.id === mensajeId ? { ...c, last_message: cambio(c.last_message) } : c,
  )
}
