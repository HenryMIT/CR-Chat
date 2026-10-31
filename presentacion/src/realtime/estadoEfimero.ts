/**
 * Estado efímero de tiempo real que no pertenece a la caché REST:
 * quién está escribiendo, presencia y la conversación abierta en pantalla.
 */
import { create } from 'zustand'

/** Un `start` caduca solo a los 6 s si no llega `stop` (contrato §5.2). */
export const TYPING_CADUCA_MS = 6000

interface Presencia {
  estado: 'online' | 'offline'
  ultimaVez: string | null
}

interface EstadoEfimero {
  /** conversación → usuario que escribe y hasta cuándo es válido. */
  escribiendo: Record<string, { usuarioId: string; hasta: number } | undefined>
  presencia: Record<string, Presencia | undefined>
  conversacionActiva: string | null
}

export const useEfimero = create<EstadoEfimero>()(() => ({
  escribiendo: {},
  presencia: {},
  conversacionActiva: null,
}))

const caducidades = new Map<string, ReturnType<typeof setTimeout>>()

export function marcarEscribiendo(conversacionId: string, usuarioId: string, activo: boolean): void {
  clearTimeout(caducidades.get(conversacionId))
  caducidades.delete(conversacionId)
  useEfimero.setState((s) => ({
    escribiendo: {
      ...s.escribiendo,
      [conversacionId]: activo ? { usuarioId, hasta: Date.now() + TYPING_CADUCA_MS } : undefined,
    },
  }))
  if (activo) {
    caducidades.set(
      conversacionId,
      setTimeout(() => {
        marcarEscribiendo(conversacionId, usuarioId, false)
      }, TYPING_CADUCA_MS),
    )
  }
}

export function fijarPresencia(usuarioId: string, estado: 'online' | 'offline', ultimaVez: string | null): void {
  useEfimero.setState((s) => ({ presencia: { ...s.presencia, [usuarioId]: { estado, ultimaVez } } }))
}

export function fijarConversacionActiva(id: string | null): void {
  useEfimero.setState({ conversacionActiva: id })
}

export function reiniciarEfimero(): void {
  for (const t of caducidades.values()) clearTimeout(t)
  caducidades.clear()
  useEfimero.setState({ escribiendo: {}, presencia: {}, conversacionActiva: null })
}

export function useEscribiendo(conversacionId: string | undefined): boolean {
  return useEfimero((s) => (conversacionId ? s.escribiendo[conversacionId] !== undefined : false))
}

export function usePresencia(usuarioId: string | undefined): Presencia | undefined {
  return useEfimero((s) => (usuarioId ? s.presencia[usuarioId] : undefined))
}
