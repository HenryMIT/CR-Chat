import { useInfiniteQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { api, ok } from '@/api/cliente'
import { claves } from '@/api/claves'
import type { Contacto } from '@/api/tipos'

const TAMANO_PAGINA = 30

export function useContactos(q: string) {
  const busqueda = q.trim()
  return useInfiniteQuery({
    queryKey: claves.contactos(busqueda),
    queryFn: ({ pageParam, signal }) =>
      ok(
        api.GET('/contacts', {
          params: {
            query: { limit: TAMANO_PAGINA, ...(busqueda ? { q: busqueda.slice(0, 50) } : {}), ...(pageParam ? { cursor: pageParam } : {}) },
          },
          signal,
        }),
      ),
    initialPageParam: null as string | null,
    getNextPageParam: (p) => p.next_cursor,
    placeholderData: (previo) => previo,
  })
}

export function useBloqueos() {
  return useInfiniteQuery({
    queryKey: claves.bloqueos(),
    queryFn: ({ pageParam, signal }) =>
      ok(api.GET('/blocks', { params: { query: { limit: 50, ...(pageParam ? { cursor: pageParam } : {}) } }, signal })),
    initialPageParam: null as string | null,
    getNextPageParam: (p) => p.next_cursor,
  })
}

function useInvalidarRelaciones() {
  const qc = useQueryClient()
  return () => {
    void qc.invalidateQueries({ queryKey: claves.todosLosContactos() })
    void qc.invalidateQueries({ queryKey: claves.bloqueos() })
    void qc.invalidateQueries({ queryKey: claves.conversaciones() })
  }
}

/** Alta idempotente por teléfono. `creado` distingue 201 de 200 (ya existía). */
export function useCrearContacto() {
  const invalidar = useInvalidarRelaciones()
  return useMutation({
    mutationFn: async (datos: { phone: string; alias?: string }): Promise<{ contacto: Contacto; creado: boolean }> => {
      const r = await api.POST('/contacts', { body: datos })
      const contacto = await ok(Promise.resolve(r))
      return { contacto, creado: r.response.status === 201 }
    },
    onSuccess: invalidar,
  })
}

export function useEditarAlias() {
  const invalidar = useInvalidarRelaciones()
  return useMutation({
    mutationFn: ({ id, alias }: { id: string; alias: string | null }) =>
      ok(api.PATCH('/contacts/{contactId}', { params: { path: { contactId: id } }, body: { alias } })),
    onSuccess: invalidar,
  })
}

export function useBorrarContacto() {
  const invalidar = useInvalidarRelaciones()
  return useMutation({
    mutationFn: async (id: string) => {
      await ok(api.DELETE('/contacts/{contactId}', { params: { path: { contactId: id } } }))
    },
    onSuccess: invalidar,
  })
}

export function useBloquear() {
  const invalidar = useInvalidarRelaciones()
  return useMutation({
    mutationFn: async ({ usuarioId, bloquear }: { usuarioId: string; bloquear: boolean }) => {
      const opciones = { params: { path: { userId: usuarioId } } }
      await ok(bloquear ? api.PUT('/blocks/{userId}', opciones) : api.DELETE('/blocks/{userId}', opciones))
    },
    onSuccess: invalidar,
  })
}
