import { useState } from 'react'
import type { Media } from '@/api/tipos'
import { cn } from '@/lib/cn'
import { iniciales } from '@/lib/formato'

/** Fondos para iniciales: pares con contraste AA con su texto. */
const TONOS = [
  'bg-selva-100 text-selva-900 dark:bg-selva-900 dark:text-selva-100',
  'bg-guaria-100 text-guaria-900 dark:bg-guaria-900 dark:text-guaria-100',
  'bg-piedra-200 text-piedra-800 dark:bg-piedra-700 dark:text-piedra-100',
  'bg-selva-200 text-selva-950 dark:bg-selva-800 dark:text-selva-50',
  'bg-guaria-200 text-guaria-950 dark:bg-guaria-800 dark:text-guaria-50',
]

function tonoPara(semilla: string): string {
  let h = 0
  for (const c of semilla) h = (h * 31 + c.charCodeAt(0)) | 0
  return TONOS[Math.abs(h) % TONOS.length] ?? TONOS[0] ?? ''
}

interface Props {
  nombre: string
  semilla: string
  media?: Media | null
  tamano?: 'sm' | 'md' | 'lg' | 'xl'
  /** undefined = no se muestra el punto de presencia. */
  enLinea?: boolean | undefined
  className?: string
}

const TAMANOS = { sm: 'size-8 text-xs', md: 'size-11 text-sm', lg: 'size-14 text-lg', xl: 'size-24 text-3xl' }

export function Avatar({ nombre, semilla, media, tamano = 'md', enLinea, className }: Props) {
  const [fallo, setFallo] = useState(false)
  const conImagen = media?.url && !fallo
  return (
    <span className={cn('relative inline-flex shrink-0', className)}>
      {conImagen ? (
        <img
          src={media.url}
          alt=""
          className={cn('rounded-full object-cover', TAMANOS[tamano])}
          onError={() => {
            setFallo(true)
          }}
        />
      ) : (
        <span
          aria-hidden="true"
          className={cn('inline-flex items-center justify-center rounded-full font-bold tracking-wide', TAMANOS[tamano], tonoPara(semilla))}
        >
          {iniciales(nombre)}
        </span>
      )}
      {enLinea !== undefined && (
        <span
          aria-hidden="true"
          className={cn(
            'absolute right-0 bottom-0 rounded-full border-2 border-superficie',
            tamano === 'sm' ? 'size-2.5' : 'size-3.5',
            enLinea ? 'bg-en-linea' : 'hidden',
          )}
        />
      )}
    </span>
  )
}
