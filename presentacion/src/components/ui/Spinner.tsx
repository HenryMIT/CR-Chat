import { cn } from '@/lib/cn'

export function Spinner({ tamano = 20, className }: { tamano?: number; className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      width={tamano}
      height={tamano}
      aria-hidden="true"
      className={cn('animate-spin', className)}
    >
      <circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" strokeOpacity="0.2" strokeWidth="3" />
      <path d="M21 12a9 9 0 0 0-9-9" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" />
    </svg>
  )
}

/** Indicador de carga con texto para lectores de pantalla. */
export function Cargando({ texto = 'Cargando…', className }: { texto?: string; className?: string }) {
  return (
    <div role="status" className={cn('flex items-center justify-center gap-2 p-6 text-sm text-tenue', className)}>
      <Spinner />
      <span>{texto}</span>
    </div>
  )
}
