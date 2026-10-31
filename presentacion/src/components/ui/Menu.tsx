import { useEffect, useId, useRef, useState, type KeyboardEvent } from 'react'
import { cn } from '@/lib/cn'
import { Icono, type NombreIcono } from './Icono'

export interface OpcionMenu {
  etiqueta: string
  icono?: NombreIcono
  peligro?: boolean
  alElegir: () => void
}

interface Props {
  etiqueta: string
  opciones: OpcionMenu[]
  icono?: NombreIcono
  lado?: 'abajo' | 'arriba'
  alinear?: 'inicio' | 'fin'
  className?: string
  claseBoton?: string
}

/**
 * Menú de acciones con el patrón ARIA "menu button": flechas, Inicio/Fin, Esc devuelve
 * el foco al botón y Tab o un clic fuera lo cierran.
 */
export function Menu({ etiqueta, opciones, icono = 'mas', lado = 'abajo', alinear = 'fin', className, claseBoton }: Props) {
  const [abierto, setAbierto] = useState(false)
  const idMenu = useId()
  const boton = useRef<HTMLButtonElement>(null)
  const contenedor = useRef<HTMLDivElement>(null)
  const items = useRef<(HTMLButtonElement | null)[]>([])

  useEffect(() => {
    if (!abierto) return
    items.current[0]?.focus()
    const fuera = (e: PointerEvent) => {
      if (!contenedor.current?.contains(e.target as Node)) setAbierto(false)
    }
    document.addEventListener('pointerdown', fuera)
    return () => {
      document.removeEventListener('pointerdown', fuera)
    }
  }, [abierto])

  const mover = (e: KeyboardEvent<HTMLDivElement>) => {
    const lista = items.current.filter((x): x is HTMLButtonElement => x !== null)
    const actual = lista.indexOf(document.activeElement as HTMLButtonElement)
    const ir = (i: number) => {
      e.preventDefault()
      lista[(i + lista.length) % lista.length]?.focus()
    }
    if (e.key === 'ArrowDown') ir(actual + 1)
    else if (e.key === 'ArrowUp') ir(actual - 1)
    else if (e.key === 'Home') ir(0)
    else if (e.key === 'End') ir(lista.length - 1)
    else if (e.key === 'Escape') {
      e.preventDefault()
      setAbierto(false)
      boton.current?.focus()
    } else if (e.key === 'Tab') setAbierto(false)
  }

  return (
    <div ref={contenedor} className={cn('relative', className)}>
      <button
        ref={boton}
        type="button"
        aria-label={etiqueta}
        title={etiqueta}
        aria-haspopup="menu"
        aria-expanded={abierto}
        aria-controls={abierto ? idMenu : undefined}
        onClick={() => {
          setAbierto((v) => !v)
        }}
        onKeyDown={(e) => {
          if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
            e.preventDefault()
            setAbierto(true)
          }
        }}
        className={cn(
          'inline-flex size-9 items-center justify-center rounded-full text-tenue transition-colors hover:bg-superficie-2 hover:text-texto',
          claseBoton,
        )}
      >
        <Icono nombre={icono} tamano={20} />
      </button>
      {abierto && (
        <div
          id={idMenu}
          role="menu"
          aria-label={etiqueta}
          tabIndex={-1}
          onKeyDown={mover}
          className={cn(
            'absolute z-30 min-w-48 animate-aparecer overflow-hidden rounded-control border border-borde bg-superficie py-1 shadow-flotante',
            lado === 'abajo' ? 'top-full mt-1' : 'bottom-full mb-1',
            alinear === 'fin' ? 'right-0' : 'left-0',
          )}
        >
          {opciones.map((o, i) => (
            <button
              key={o.etiqueta}
              ref={(el) => {
                items.current[i] = el
              }}
              type="button"
              role="menuitem"
              tabIndex={-1}
              onClick={() => {
                setAbierto(false)
                boton.current?.focus()
                o.alElegir()
              }}
              className={cn(
                'flex w-full items-center gap-2.5 px-3.5 py-2.5 text-left text-sm font-medium hover:bg-superficie-2 focus-visible:bg-superficie-2',
                o.peligro ? 'text-peligro' : 'text-texto',
              )}
            >
              {o.icono && <Icono nombre={o.icono} tamano={18} />}
              {o.etiqueta}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}
