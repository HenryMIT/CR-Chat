import type { ReactNode } from 'react'
import { cn } from '@/lib/cn'
import { mensajeDeError } from '@/api/errores'
import { Boton } from './Boton'
import { Icono, type NombreIcono } from './Icono'

export function EstadoVacio({
  icono,
  titulo,
  children,
  accion,
  className,
}: {
  icono: NombreIcono
  titulo: string
  children?: ReactNode
  accion?: ReactNode
  className?: string
}) {
  return (
    <div className={cn('flex flex-col items-center justify-center gap-3 px-6 py-12 text-center', className)}>
      <span className="flex size-16 items-center justify-center rounded-tarjeta bg-primario-suave text-primario">
        <Icono nombre={icono} tamano={30} />
      </span>
      <h2 className="text-lg font-bold text-texto">{titulo}</h2>
      {children && <p className="max-w-xs text-sm text-tenue">{children}</p>}
      {accion}
    </div>
  )
}

export function EstadoError({
  error,
  alReintentar,
  titulo = 'No se pudo cargar',
  className,
}: {
  error: unknown
  alReintentar?: () => void
  titulo?: string
  className?: string
}) {
  return (
    <div role="alert" className={cn('flex flex-col items-center justify-center gap-3 px-6 py-10 text-center', className)}>
      <span className="flex size-14 items-center justify-center rounded-tarjeta bg-peligro-suave text-peligro">
        <Icono nombre="alerta" tamano={26} />
      </span>
      <h2 className="text-base font-bold text-texto">{titulo}</h2>
      <p className="max-w-xs text-sm text-tenue">{mensajeDeError(error)}</p>
      {alReintentar && (
        <Boton variante="secundario" tamano="sm" icono="reintentar" onClick={alReintentar}>
          Reintentar
        </Boton>
      )}
    </div>
  )
}

/** Filas de esqueleto para listas mientras cargan. */
export function EsqueletoLista({ filas = 6, etiqueta = 'Cargando…' }: { filas?: number; etiqueta?: string }) {
  return (
    <div role="status" aria-label={etiqueta} className="flex flex-col gap-1 p-2">
      {Array.from({ length: filas }, (_, i) => (
        <div key={i} className="flex items-center gap-3 rounded-control px-3 py-3" aria-hidden="true">
          <div className="size-11 animate-pulse rounded-full bg-superficie-2" />
          <div className="flex flex-1 flex-col gap-2">
            <div className="h-3 w-2/5 animate-pulse rounded bg-superficie-2" />
            <div className="h-3 w-4/5 animate-pulse rounded bg-superficie-2" />
          </div>
        </div>
      ))}
    </div>
  )
}
