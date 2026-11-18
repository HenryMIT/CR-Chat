/**
 * Hook que mantiene la conexión WebSocket mientras hay sesión e integra sus eventos en
 * la caché de TanStack Query. Debe montarse una sola vez (lo hace TiempoRealProvider);
 * los componentes consumen la API con `useTiempoReal()`.
 */
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { claves } from '@/api/claves'
import { cerrarSesionLocal, obtenerTokenVigente, refrescarSesion, useAuth } from '@/auth/sesion'
import { todasLasConversaciones, type CacheConversaciones } from '@/cache/conversaciones'
import { env } from '@/lib/env'
import { aplicarEventoServidor } from './aplicarEvento'
import { ChatSocket, type EstadoSocket, type SocketBasico } from './chatSocket'
import { resincronizar } from './resincronizar'

export interface ApiTiempoReal {
  estado: EstadoSocket
  enviarEscribiendo: (conversacionId: string, activo: boolean) => boolean
  /** false si no hay socket; el llamador usa entonces POST /receipts. */
  enviarVisto: (conversacionId: string, mensajeId: string) => boolean
  consultarPresencia: (usuarioIds: string[]) => boolean
}

export interface OpcionesUseChatSocket {
  url?: string
  crearSocket?: (url: string) => SocketBasico
}

export function useChatSocket(opciones: OpcionesUseChatSocket = {}): ApiTiempoReal {
  const qc = useQueryClient()
  const autenticado = useAuth((s) => s.estado === 'autenticado')
  const miId = useAuth((s) => s.usuario?.id)
  const [estado, setEstado] = useState<EstadoSocket>('inactivo')
  const socketRef = useRef<ChatSocket | null>(null)
  const consultados = useRef(new Set<string>())
  const { url = env.wsUrl, crearSocket } = opciones

  useEffect(() => {
    if (!autenticado || !miId) return

    const consultarPresenciaPendiente = () => {
      const s = socketRef.current
      if (s?.estado !== 'conectado') return
      const pares = todasLasConversaciones(qc.getQueryData<CacheConversaciones>(claves.conversaciones()))
        .map((c) => c.peer.id)
        .filter((id) => !consultados.current.has(id))
        .slice(0, 100)
      if (pares.length === 0) return
      if (s.enviar('presence.query', { user_ids: pares })) for (const id of pares) consultados.current.add(id)
    }

    const socket = new ChatSocket({
      url,
      ...(crearSocket ? { crearSocket } : {}),
      obtenerToken: (forzar) => (forzar ? refrescarSesion() : obtenerTokenVigente()),
      alEvento: (evento) => {
        aplicarEventoServidor(qc, evento, { miId })
      },
      alEstado: setEstado,
      alConectar: () => {
        consultados.current.clear()
        consultarPresenciaPendiente()
      },
      alResincronizar: () => {
        consultados.current.clear()
        resincronizar(qc)
          .then(consultarPresenciaPendiente)
          .catch(() => {
            /* la próxima reconexión o el refetch normal lo recuperará */
          })
      },
      alSesionRevocada: () => {
        cerrarSesionLocal('revocada')
      },
    })
    socketRef.current = socket
    socket.conectar()

    // Token renovado por REST (refresco proactivo o tras un 401): reautenticar sin reconectar.
    const dejarAuth = useAuth.subscribe((s, previo) => {
      if (s.accessToken && s.accessToken !== previo.accessToken && socket.estado === 'conectado') {
        void socket.reautenticar()
      }
    })
    // Nuevas conversaciones cargadas: pedir la presencia de sus participantes.
    const dejarCache = qc.getQueryCache().subscribe((e) => {
      if (e.type === 'updated' && (e.query.queryKey as readonly unknown[])[0] === claves.conversaciones()[0]) consultarPresenciaPendiente()
    })
    const alVolverRed = () => {
      socket.reconectarAhora()
    }
    window.addEventListener('online', alVolverRed)

    return () => {
      dejarAuth()
      dejarCache()
      window.removeEventListener('online', alVolverRed)
      socket.desconectar()
      socketRef.current = null
      setEstado('inactivo')
    }
  }, [autenticado, miId, qc, url, crearSocket])

  const enviarEscribiendo = useCallback(
    (conversacionId: string, activo: boolean) =>
      socketRef.current?.enviar('typing', { conversation_id: conversacionId, state: activo ? 'start' : 'stop' }) ?? false,
    [],
  )
  const enviarVisto = useCallback(
    (conversacionId: string, mensajeId: string) =>
      socketRef.current?.enviar('seen', { conversation_id: conversacionId, up_to_message_id: mensajeId }) ?? false,
    [],
  )
  const consultarPresencia = useCallback(
    (usuarioIds: string[]) => socketRef.current?.enviar('presence.query', { user_ids: usuarioIds.slice(0, 100) }) ?? false,
    [],
  )

  return useMemo(
    () => ({ estado, enviarEscribiendo, enviarVisto, consultarPresencia }),
    [estado, enviarEscribiendo, enviarVisto, consultarPresencia],
  )
}
