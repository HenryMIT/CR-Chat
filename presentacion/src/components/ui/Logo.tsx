import { cn } from '@/lib/cn'

/** Marca de CR_Chat: burbuja con el punto de la guaria. */
export function Logo({ conTexto = true, className }: { conTexto?: boolean; className?: string }) {
  return (
    <span className={cn('inline-flex items-center gap-2.5', className)}>
      <svg viewBox="0 0 32 32" width="32" height="32" aria-hidden="true">
        <rect width="32" height="32" rx="9" className="fill-selva-700 dark:fill-selva-400" />
        <path
          d="M9 10.5A3.5 3.5 0 0 1 12.5 7h7A3.5 3.5 0 0 1 23 10.5v5a3.5 3.5 0 0 1-3.5 3.5H15l-4.2 3.4c-.6.5-1.8.1-1.8-.8V10.5Z"
          className="fill-selva-50 dark:fill-selva-950"
        />
        <circle cx="22.5" cy="21.5" r="4.5" className="fill-guaria-600 stroke-selva-700 dark:fill-guaria-400 dark:stroke-selva-400" strokeWidth="2" />
      </svg>
      {conTexto && (
        <span className="text-lg font-extrabold tracking-tight text-texto">
          CR<span className="text-acento">_</span>Chat
        </span>
      )}
    </span>
  )
}
