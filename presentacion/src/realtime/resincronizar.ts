/**
 * Resincronización por REST tras reconectar (contrato WS §6): Redis pub/sub es
 * at-most-once, así que lo publicado durante la desconexión se recupera con `after`.
 */
import type { QueryClient } from '@tanstack/react-query'
import { api, ok } from '@/api/cliente'
import { claves } from '@/api/claves'
import type { PaginaMensajes } from '@/api/tipos'
import { cacheVacia, ultimoConfirmado, upsertMensaje, type CacheMensajes } from '@/cache/mensajes'

/** Máximo de páginas `after` antes de rendirse y recargar la conversación completa. */
const MAX_PAGINAS = 10

export async function resincronizar(qc: QueryClient): Promise<void> {
  const lista = qc.invalidateQueries({ queryKey: claves.conversaciones() })
  const activas = qc.getQueryCache().findAll({ queryKey: claves.todosLosMensajes(), type: 'active' })

  await Promise.all([
    lista,
    ...activas.map(async (consulta) => {
      const conversacionId = String(consulta.queryKey[1])
      const ultimo = ultimoConfirmado(consulta.state.data as CacheMensajes | undefined)
      if (!ultimo) {
        await qc.invalidateQueries({ queryKey: consulta.queryKey })
        return
      }
      let cursor: string | null = ultimo.cursor
      for (let i = 0; i < MAX_PAGINAS && cursor; i++) {
        const pagina: PaginaMensajes = await ok(
          api.GET('/conversations/{conversationId}/messages', {
            params: { path: { conversationId: conversacionId }, query: { after: cursor, limit: 100 } },
          }),
        )
        qc.setQueryData<CacheMensajes>(consulta.queryKey, (c) =>
          pagina.items.reduce<CacheMensajes>((acc, m) => upsertMensaje(acc, m), c ?? cacheVacia()),
        )
        cursor = pagina.next_cursor
      }
      if (cursor) await qc.invalidateQueries({ queryKey: consulta.queryKey })
    }),
  ])
}
