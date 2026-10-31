/**
 * Operaciones puras sobre la caché de mensajes de una conversación.
 *
 * Forma: InfiniteData<PaginaMensajes>. pages[0] es la página MÁS RECIENTE; cada página
 * siguiente es historial más antiguo (scroll hacia arriba con `before`). Dentro de cada
 * página los mensajes están en orden cronológico ascendente, como los entrega la API.
 * Todas las operaciones son idempotentes (upsert por `id` o `client_id`), porque un mismo
 * mensaje puede llegar por la respuesta REST y por `message.new` en cualquier orden.
 */
import type { InfiniteData } from '@tanstack/react-query'
import type { EstadoMensaje, Mensaje, MensajeChat, PaginaMensajes } from '@/api/tipos'

export interface PaginaChat extends Omit<PaginaMensajes, 'items'> {
  items: MensajeChat[]
}

export type CacheMensajes = InfiniteData<PaginaChat>

const RANGO_ESTADO: Record<EstadoMensaje, number> = { sent: 0, delivered: 1, seen: 2 }

export function compararMensajes(a: Mensaje, b: Mensaje): number {
  if (a.created_at < b.created_at) return -1
  if (a.created_at > b.created_at) return 1
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0
}

/** El estado de recibo nunca retrocede (marcador monótono). */
export function estadoMaximo(a?: EstadoMensaje, b?: EstadoMensaje): EstadoMensaje | undefined {
  if (!a) return b
  if (!b) return a
  return RANGO_ESTADO[a] >= RANGO_ESTADO[b] ? a : b
}

function coincide(a: MensajeChat, b: MensajeChat): boolean {
  return a.id === b.id || (a.client_id !== null && a.client_id === b.client_id)
}

function fusionar(previo: MensajeChat, nuevo: MensajeChat): MensajeChat {
  const status = estadoMaximo(previo.status, nuevo.status)
  const fusion: MensajeChat = { ...previo, ...nuevo }
  if (status) fusion.status = status
  // Una versión confirmada por el servidor quita la marca local.
  if (!nuevo.local) delete fusion.local
  return fusion
}

export function cacheVacia(): CacheMensajes {
  return { pages: [{ items: [], next_cursor: null }], pageParams: [null] }
}

/** Inserta o actualiza un mensaje. Si es nuevo va a la página más reciente, ordenado. */
export function upsertMensaje(cache: CacheMensajes | undefined, mensaje: MensajeChat): CacheMensajes {
  const base = cache ?? cacheVacia()
  const pIdx = base.pages.findIndex((p) => p.items.some((m) => coincide(m, mensaje)))
  if (pIdx !== -1) {
    const pages = base.pages.map((p, n) => {
      if (n !== pIdx) return p
      const items = p.items.map((m) => (coincide(m, mensaje) ? fusionar(m, mensaje) : m))
      // La hora del servidor puede diferir de la optimista: se reordena la página.
      items.sort(compararMensajes)
      return { ...p, items }
    })
    return { ...base, pages }
  }
  const [primera, ...resto] = base.pages
  const items = [...(primera?.items ?? []), mensaje].sort(compararMensajes)
  return { ...base, pages: [{ next_cursor: primera?.next_cursor ?? null, items }, ...resto] }
}

export function actualizarMensaje(
  cache: CacheMensajes | undefined,
  id: string,
  cambio: (m: MensajeChat) => MensajeChat,
): CacheMensajes | undefined {
  if (!cache) return cache
  return {
    ...cache,
    pages: cache.pages.map((p) => (p.items.some((m) => m.id === id) ? { ...p, items: p.items.map((m) => (m.id === id ? cambio(m) : m)) } : p)),
  }
}

export function quitarMensaje(cache: CacheMensajes | undefined, id: string): CacheMensajes | undefined {
  if (!cache) return cache
  return { ...cache, pages: cache.pages.map((p) => ({ ...p, items: p.items.filter((m) => m.id !== id) })) }
}

export function marcarBorrado(cache: CacheMensajes | undefined, id: string, borradoEn: string): CacheMensajes | undefined {
  return actualizarMensaje(cache, id, (m) => ({ ...m, text: null, media: null, deleted_at: borradoEn }))
}

/** Lista plana en orden cronológico ascendente (lo que se pinta en pantalla). */
export function mensajesOrdenados(cache: CacheMensajes | undefined): MensajeChat[] {
  if (!cache) return []
  const lista: MensajeChat[] = []
  for (let i = cache.pages.length - 1; i >= 0; i--) lista.push(...(cache.pages[i]?.items ?? []))
  return lista
}

export function existeMensaje(cache: CacheMensajes | undefined, id: string): boolean {
  return cache?.pages.some((p) => p.items.some((m) => m.id === id)) ?? false
}

/**
 * Aplica un recibo `delivered`/`seen` del otro participante: todos MIS mensajes hasta
 * `hastaId` inclusive suben a ese estado (nunca bajan). Devuelve null si no se conoce
 * el mensaje de referencia (el llamador puede resincronizar).
 */
export function aplicarRecibo(
  cache: CacheMensajes | undefined,
  hastaId: string,
  estado: 'delivered' | 'seen',
  miId: string,
): CacheMensajes | null {
  if (!cache) return null
  const todos = mensajesOrdenados(cache)
  const objetivo = todos.find((m) => m.id === hastaId)
  if (!objetivo) return null
  const afectar = (m: MensajeChat): MensajeChat =>
    m.sender_id === miId && !m.local && compararMensajes(m, objetivo) <= 0
      ? { ...m, status: estadoMaximo(m.status, estado) ?? estado }
      : m
  return { ...cache, pages: cache.pages.map((p) => ({ ...p, items: p.items.map(afectar) })) }
}

/** Último mensaje confirmado por el servidor (para resincronizar con `after`). */
export function ultimoConfirmado(cache: CacheMensajes | undefined): MensajeChat | undefined {
  const lista = mensajesOrdenados(cache)
  for (let i = lista.length - 1; i >= 0; i--) {
    const m = lista[i]
    if (m && !m.local) return m
  }
  return undefined
}
