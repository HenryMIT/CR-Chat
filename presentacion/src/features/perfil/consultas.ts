import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { api, ok } from '@/api/cliente'
import { claves } from '@/api/claves'
import type { Me } from '@/api/tipos'
import { actualizarUsuario, cerrarSesionLocal, useAuth } from '@/auth/sesion'
import { subirArchivo } from '@/features/subidas'

export function useYo() {
  const usuario = useAuth((s) => s.usuario)
  return useQuery({
    queryKey: claves.yo(),
    queryFn: async ({ signal }) => {
      const me = await ok(api.GET('/me', { signal }))
      actualizarUsuario(me)
      return me
    },
    ...(usuario ? { initialData: usuario } : {}),
    staleTime: 60_000,
  })
}

function useGuardarYo() {
  const qc = useQueryClient()
  return (me: Me) => {
    qc.setQueryData(claves.yo(), me)
    actualizarUsuario(me)
  }
}

export function useActualizarPerfil() {
  const guardar = useGuardarYo()
  return useMutation({
    mutationFn: (cambios: { display_name?: string; about?: string | null }) => ok(api.PATCH('/me', { body: cambios })),
    onSuccess: guardar,
  })
}

/** Sube la foto (URL prefirmada) y la referencia con PATCH /me. `null` la quita. */
export function useCambiarAvatar() {
  const guardar = useGuardarYo()
  return useMutation({
    mutationFn: async (archivo: File | null) => {
      const mediaId = archivo ? await subirArchivo(archivo, 'avatar') : null
      return ok(api.PATCH('/me', { body: { avatar_media_id: mediaId } }))
    },
    onSuccess: guardar,
  })
}

export function useCambiarPassword() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (datos: { current_password: string; new_password: string }) => {
      await ok(api.PUT('/me/password', { body: datos }))
    },
    // El servidor revoca las demás sesiones.
    onSuccess: () => qc.invalidateQueries({ queryKey: claves.sesiones() }),
  })
}

export function useCambiarTelefono() {
  const guardar = useGuardarYo()
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (datos: { current_password: string; phone: string }) => ok(api.PUT('/me/phone', { body: datos })),
    onSuccess: (me) => {
      guardar(me)
      void qc.invalidateQueries({ queryKey: claves.sesiones() })
    },
  })
}

export function useDesactivarCuenta() {
  return useMutation({
    mutationFn: async (password: string) => {
      await ok(api.DELETE('/me', { body: { password } }))
    },
    onSuccess: () => {
      cerrarSesionLocal('manual')
    },
  })
}

export function useSesiones() {
  return useQuery({
    queryKey: claves.sesiones(),
    queryFn: ({ signal }) => ok(api.GET('/me/sessions', { signal })).then((r) => r.items),
  })
}

export function useRevocarSesion() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: string) => {
      await ok(api.DELETE('/me/sessions/{sessionId}', { params: { path: { sessionId: id } } }))
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: claves.sesiones() }),
  })
}

export function useRevocarOtras() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async () => {
      await ok(api.DELETE('/me/sessions'))
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: claves.sesiones() }),
  })
}
