import { useEffect, useId, useRef, type ReactNode } from 'react'
import { BotonIcono } from './Boton'

interface Props {
  abierto: boolean
  alCerrar: () => void
  titulo: string
  descripcion?: ReactNode
  children: ReactNode
}

/**
 * Diálogo modal sobre <dialog> nativo: atrapa el foco, cierra con Esc y devuelve el foco
 * al control que lo abrió. Si el entorno no soporta showModal se abre como no modal.
 */
export function Dialogo({ abierto, alCerrar, titulo, descripcion, children }: Props) {
  const ref = useRef<HTMLDialogElement>(null)
  const idTitulo = useId()
  const idDescripcion = useId()

  useEffect(() => {
    const d = ref.current
    if (!d) return
    if (abierto && !d.open) {
      if (typeof d.showModal === 'function') d.showModal()
      else d.setAttribute('open', '')
    } else if (!abierto && d.open) {
      if (typeof d.close === 'function') d.close()
      else d.removeAttribute('open')
    }
  }, [abierto])

  return (
    <dialog
      ref={ref}
      aria-labelledby={idTitulo}
      aria-describedby={descripcion ? idDescripcion : undefined}
      onCancel={(e) => {
        e.preventDefault()
        alCerrar()
      }}
      onClick={(e) => {
        // Clic en el fondo (fuera de la tarjeta) cierra.
        if (e.target === e.currentTarget) alCerrar()
      }}
      className="m-auto w-[min(92vw,28rem)] rounded-tarjeta bg-superficie p-0 text-texto shadow-flotante backdrop:bg-piedra-950/55 backdrop:backdrop-blur-[2px] open:animate-aparecer"
    >
      {abierto && (
        <div className="flex flex-col gap-4 p-5 sm:p-6">
          <div className="flex items-start justify-between gap-3">
            <div className="flex flex-col gap-1">
              <h2 id={idTitulo} className="text-xl font-bold">
                {titulo}
              </h2>
              {descripcion && (
                <p id={idDescripcion} className="text-sm text-tenue">
                  {descripcion}
                </p>
              )}
            </div>
            <BotonIcono icono="cerrar" etiqueta="Cerrar" onClick={alCerrar} className="-mt-1 -mr-2" />
          </div>
          {children}
        </div>
      )}
    </dialog>
  )
}
