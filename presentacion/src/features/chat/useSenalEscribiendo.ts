import { useCallback, useEffect, useRef } from 'react'
import { useTiempoReal } from '@/realtime/TiempoReal'

/** Como máximo un `start` cada 3 s (límite del contrato) y `stop` tras 4 s sin teclear. */
const INTERVALO_START_MS = 3000
const INACTIVIDAD_MS = 4000

export function useSenalEscribiendo(conversacionId: string) {
  const { enviarEscribiendo } = useTiempoReal()
  const activo = useRef(false)
  const ultimoStart = useRef(0)
  const temporizador = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)

  const detener = useCallback(() => {
    clearTimeout(temporizador.current)
    if (activo.current) {
      activo.current = false
      enviarEscribiendo(conversacionId, false)
    }
  }, [conversacionId, enviarEscribiendo])

  const tecleo = useCallback(() => {
    const ahora = Date.now()
    if ((!activo.current || ahora - ultimoStart.current > INTERVALO_START_MS) && enviarEscribiendo(conversacionId, true)) {
      activo.current = true
      ultimoStart.current = ahora
    }
    clearTimeout(temporizador.current)
    temporizador.current = setTimeout(detener, INACTIVIDAD_MS)
  }, [conversacionId, enviarEscribiendo, detener])

  useEffect(() => detener, [detener])

  return { tecleo, detener }
}
