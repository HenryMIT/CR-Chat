import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { api, ok } from '@/api/cliente'
import { claves } from '@/api/claves'
import type { Conversacion } from '@/api/tipos'
import { buscarConversacion, subirConversacion, type CacheConversaciones } from '@/cache/conversaciones'
import { useAuth } from '@/auth/sesion'

const TAMANO_PAGINA = 30

export function useConversaciones() {
  const autenticado = useAuth((s) => s.estado === 'autenticado')
  return useInfiniteQuery({
    queryKey: claves.conversaciones(),
    queryFn: ({ pageParam, signal }) =>
      ok(api.GET('/conversations', { params: { query: { limit: TAMANO_PAGINA, ...(pageParam ? { cursor: pageParam } : {}) } }, signal })),
    initialPageParam: null as string | null,
    getNextPageParam: (ultima) => ultima.next_cursor,
    enabled: autenticado,
  })
}

/** Conversación por id: la de la lista (viva por WS) o, si no está cargada, por REST. */
export function useConversacion(id: string) {
  const qc = useQueryClient()
  const lista = useConversaciones()
  const deLista = buscarConversacion(lista.data, id)
  const detalle = useQuery({
    queryKey: claves.conversacion(id),
    queryFn: ({ signal }) => ok(api.GET('/conversations/{conversationId}', { params: { path: { conversationId: id } }, signal })),
    enabled: !deLista && !lista.isPending,
    initialData: () => buscarConversacion(qc.getQueryData<CacheConversaciones>(claves.conversaciones()), id),
  })
  return { conversacion: deLista ?? detalle.data, cargando: !deLista && (lista.isPending || detalle.isPending), error: deLista ? null : detalle.error }
}

/** Crea u obtiene la conversación 1:1 con un contacto (idempotente). */
export function useIniciarConversacion() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (contactoId: string) => ok(api.POST('/conversations', { body: { contact_id: contactoId } })),
    onSuccess: (conv: Conversacion) => {
      qc.setQueryData<CacheConversaciones>(claves.conversaciones(), (c) => (buscarConversacion(c, conv.id) ? c : subirConversacion(c, conv)))
      qc.setQueryData(claves.conversacion(conv.id), conv)
      void qc.invalidateQueries({ queryKey: claves.todosLosContactos() })
    },
  })
}
