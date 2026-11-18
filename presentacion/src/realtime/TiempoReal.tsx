import { createContext, useContext, type ReactNode } from 'react'
import { useChatSocket, type ApiTiempoReal, type OpcionesUseChatSocket } from './useChatSocket'

const sinConexion: ApiTiempoReal = {
  estado: 'inactivo',
  enviarEscribiendo: () => false,
  enviarVisto: () => false,
  consultarPresencia: () => false,
}

const ContextoTiempoReal = createContext<ApiTiempoReal>(sinConexion)

/** Monta la única conexión WebSocket de la app y la comparte por contexto. */
export function TiempoRealProvider({ children, ...opciones }: OpcionesUseChatSocket & { children: ReactNode }) {
  const api = useChatSocket(opciones)
  return <ContextoTiempoReal value={api}>{children}</ContextoTiempoReal>
}

// eslint-disable-next-line react-refresh/only-export-components
export function useTiempoReal(): ApiTiempoReal {
  return useContext(ContextoTiempoReal)
}
