import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react'
import type { MensajeChat } from '@/api/tipos'
import { Boton } from '@/components/ui/Boton'
import { Icono } from '@/components/ui/Icono'
import { Spinner } from '@/components/ui/Spinner'
import { etiquetaDia, mismoDia } from '@/lib/formato'
import { Burbuja } from './Burbuja'

const AGRUPAR_MS = 5 * 60_000
const UMBRAL_FINAL_PX = 120

interface Props {
  mensajes: MensajeChat[]
  miId: string
  nombrePar: string
  hayMas: boolean
  cargandoMas: boolean
  cargarMas: () => void
  alEditar: (m: MensajeChat) => void
  alBorrar: (m: MensajeChat) => void
  alReintentar: (m: MensajeChat) => void
  alDescartar: (m: MensajeChat) => void
  /** Se pinta al final (indicador "escribiendo…"). */
  pie?: ReactNode
}

/**
 * Historial con scroll infinito hacia arriba:
 * - al abrir se coloca al final;
 * - al cargar historial arriba conserva la posición visual (sin saltos);
 * - un mensaje nuevo baja la vista solo si ya estabas al final o si es tuyo;
 *   si no, aparece el botón "mensajes nuevos".
 */
export function ListaMensajes({ mensajes, miId, nombrePar, hayMas, cargandoMas, cargarMas, pie, ...acciones }: Props) {
  const contenedor = useRef<HTMLDivElement>(null)
  const centinela = useRef<HTMLDivElement>(null)
  const previo = useRef<{ primero?: string; ultimo?: string; altura: number; longitud: number }>({ altura: 0, longitud: 0 })
  const alFinalRef = useRef(true)
  const [alFinal, setAlFinal] = useState(true)
  const [anclaId, setAnclaId] = useState<string | undefined>(undefined)
  const [ahora, setAhora] = useState(() => Date.now())

  useEffect(() => {
    const t = setInterval(() => {
      setAhora(Date.now())
    }, 30_000)
    return () => {
      clearInterval(t)
    }
  }, [])

  const primero = mensajes[0]?.id
  const ultimo = mensajes[mensajes.length - 1]

  useLayoutEffect(() => {
    const el = contenedor.current
    if (!el) return
    const p = previo.current
    if (p.longitud === 0 && mensajes.length > 0) {
      el.scrollTop = el.scrollHeight
    } else if (primero !== p.primero && ultimo?.id === p.ultimo) {
      // Historial añadido arriba: compensar la nueva altura.
      el.scrollTop = el.scrollHeight - p.altura + el.scrollTop
    } else if (ultimo && ultimo.id !== p.ultimo && (alFinalRef.current || ultimo.sender_id === miId)) {
      el.scrollTop = el.scrollHeight
    }
    previo.current = { primero, ultimo: ultimo?.id, altura: el.scrollHeight, longitud: mensajes.length }
  })

  // Carga automática del historial al acercarse al principio.
  useEffect(() => {
    const raiz = contenedor.current
    const objetivo = centinela.current
    if (!raiz || !objetivo || !hayMas || typeof IntersectionObserver === 'undefined') return
    const obs = new IntersectionObserver(
      (entradas) => {
        if (entradas.some((e) => e.isIntersecting) && !cargandoMas) cargarMas()
      },
      { root: raiz, rootMargin: '200px 0px 0px 0px' },
    )
    obs.observe(objetivo)
    return () => {
      obs.disconnect()
    }
  }, [hayMas, cargandoMas, cargarMas])

  const alDesplazar = () => {
    const el = contenedor.current
    if (!el) return
    const cerca = el.scrollHeight - el.scrollTop - el.clientHeight < UMBRAL_FINAL_PX
    alFinalRef.current = cerca
    setAlFinal(cerca)
    if (cerca) setAnclaId(ultimo?.id)
  }

  const indiceAncla = anclaId ? mensajes.findIndex((m) => m.id === anclaId) : -1
  const nuevos = alFinal || indiceAncla === -1 ? 0 : mensajes.slice(indiceAncla + 1).filter((m) => m.sender_id !== miId).length

  const irAlFinal = () => {
    const el = contenedor.current
    if (el) el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' })
  }

  return (
    <div className="relative min-h-0 flex-1">
      <div
        ref={contenedor}
        onScroll={alDesplazar}
        role="log"
        aria-label={`Mensajes con ${nombrePar}`}
        tabIndex={0}
        className="fondo-conversacion h-full overflow-y-auto px-3 pt-2 pb-4 [overflow-anchor:none] sm:px-6"
      >
        <div ref={centinela} className="flex justify-center py-2">
          {cargandoMas ? (
            <span role="status" className="flex items-center gap-2 text-xs text-tenue">
              <Spinner tamano={16} /> Cargando mensajes anteriores…
            </span>
          ) : hayMas ? (
            <Boton variante="fantasma" tamano="sm" onClick={cargarMas}>
              Cargar mensajes anteriores
            </Boton>
          ) : mensajes.length > 0 ? (
            <span className="rounded-full bg-superficie/80 px-3 py-1 text-xs text-tenue">Inicio de la conversación</span>
          ) : null}
        </div>

        <ol className="mx-auto flex max-w-4xl flex-col">
          {mensajes.map((m, i) => {
            const anterior = mensajes[i - 1]
            const nuevoDia = !anterior || !mismoDia(anterior.created_at, m.created_at)
            const agrupado =
              !nuevoDia &&
              anterior.sender_id === m.sender_id &&
              new Date(m.created_at).getTime() - new Date(anterior.created_at).getTime() < AGRUPAR_MS
            return (
              <MensajeConSeparador key={m.client_id ?? m.id} separador={nuevoDia ? etiquetaDia(m.created_at) : null}>
                <Burbuja mensaje={m} mio={m.sender_id === miId} agrupado={agrupado} nombreRemitente={nombrePar} ahora={ahora} {...acciones} />
              </MensajeConSeparador>
            )
          })}
        </ol>
        {pie}
      </div>

      {nuevos > 0 && (
        <button
          type="button"
          onClick={irAlFinal}
          className="absolute bottom-4 left-1/2 flex -translate-x-1/2 items-center gap-1.5 rounded-full bg-primario px-4 py-2 text-sm font-semibold text-sobre-primario shadow-flotante"
        >
          <Icono nombre="abajo" tamano={16} />
          {nuevos === 1 ? '1 mensaje nuevo' : `${nuevos} mensajes nuevos`}
        </button>
      )}
    </div>
  )
}

function MensajeConSeparador({ separador, children }: { separador: string | null; children: ReactNode }) {
  return (
    <>
      {separador && (
        <li className="sticky top-0 z-10 my-3 flex justify-center">
          <span className="rounded-full bg-superficie px-3 py-1 text-xs font-semibold text-tenue shadow-suave">{separador}</span>
        </li>
      )}
      {children}
    </>
  )
}
