import type { ButtonHTMLAttributes, ReactNode } from 'react'
import { cn } from '@/lib/cn'
import { Icono, type NombreIcono } from './Icono'
import { Spinner } from './Spinner'

type Variante = 'primario' | 'secundario' | 'fantasma' | 'peligro'
type Tamano = 'sm' | 'md' | 'lg'

const VARIANTES: Record<Variante, string> = {
  primario: 'bg-primario text-sobre-primario hover:bg-primario-hover shadow-suave',
  secundario: 'bg-superficie text-texto border border-borde hover:bg-superficie-2',
  fantasma: 'text-texto hover:bg-superficie-2',
  peligro: 'bg-peligro text-blanco hover:opacity-90 dark:text-piedra-950',
}

const TAMANOS: Record<Tamano, string> = {
  sm: 'h-8 px-3 text-sm gap-1.5',
  md: 'h-10 px-4 text-base gap-2',
  lg: 'h-12 px-5 text-base gap-2',
}

interface Props extends ButtonHTMLAttributes<HTMLButtonElement> {
  variante?: Variante
  tamano?: Tamano
  icono?: NombreIcono
  cargando?: boolean
  anchoCompleto?: boolean
  children?: ReactNode
}

export function Boton({
  variante = 'primario',
  tamano = 'md',
  icono,
  cargando = false,
  anchoCompleto = false,
  className,
  children,
  disabled,
  type = 'button',
  ...resto
}: Props) {
  return (
    <button
      type={type}
      disabled={disabled ?? cargando}
      aria-busy={cargando || undefined}
      className={cn(
        'inline-flex shrink-0 items-center justify-center rounded-control font-semibold transition-colors',
        'disabled:cursor-not-allowed disabled:opacity-55',
        VARIANTES[variante],
        TAMANOS[tamano],
        anchoCompleto && 'w-full',
        className,
      )}
      {...resto}
    >
      {cargando ? <Spinner tamano={16} /> : icono ? <Icono nombre={icono} tamano={tamano === 'sm' ? 16 : 18} /> : null}
      {children}
    </button>
  )
}

interface PropsIcono extends ButtonHTMLAttributes<HTMLButtonElement> {
  icono: NombreIcono
  /** Obligatorio: es el nombre accesible del botón. */
  etiqueta: string
  tamano?: number
  variante?: 'fantasma' | 'primario' | 'suave'
}

export function BotonIcono({ icono, etiqueta, tamano = 20, variante = 'fantasma', className, type = 'button', ...resto }: PropsIcono) {
  return (
    <button
      type={type}
      aria-label={etiqueta}
      title={etiqueta}
      className={cn(
        'inline-flex size-10 shrink-0 items-center justify-center rounded-full transition-colors disabled:opacity-50',
        variante === 'fantasma' && 'text-tenue hover:bg-superficie-2 hover:text-texto',
        variante === 'primario' && 'bg-primario text-sobre-primario hover:bg-primario-hover',
        variante === 'suave' && 'bg-primario-suave text-primario hover:opacity-90',
        className,
      )}
      {...resto}
    >
      <Icono nombre={icono} tamano={tamano} />
    </button>
  )
}
