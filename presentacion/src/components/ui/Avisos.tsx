import { create } from 'zustand'
import { cn } from '@/lib/cn'
import { Icono } from './Icono'

interface Aviso {
  id: number
  texto: string
  tipo: 'info' | 'error'
}

const useAvisos = create<{ avisos: Aviso[] }>()(() => ({ avisos: [] }))
let siguiente = 1

/** Muestra un aviso breve (no bloqueante) que se anuncia a lectores de pantalla. */
// eslint-disable-next-line react-refresh/only-export-components
export function avisar(texto: string, tipo: Aviso['tipo'] = 'info'): void {
  const id = siguiente++
  useAvisos.setState((s) => ({ avisos: [...s.avisos.slice(-2), { id, texto, tipo }] }))
  setTimeout(() => {
    cerrar(id)
  }, 5000)
}

function cerrar(id: number): void {
  useAvisos.setState((s) => ({ avisos: s.avisos.filter((a) => a.id !== id) }))
}

export function Avisos() {
  const avisos = useAvisos((s) => s.avisos)
  return (
    <div
      role="status"
      aria-live="polite"
      className="pointer-events-none fixed inset-x-0 bottom-20 z-50 flex flex-col items-center gap-2 px-4 md:bottom-6"
    >
      {avisos.map((a) => (
        <div
          key={a.id}
          className={cn(
            'pointer-events-auto flex max-w-md animate-aparecer items-center gap-3 rounded-control px-4 py-3 text-sm font-medium shadow-flotante',
            a.tipo === 'error' ? 'bg-peligro text-blanco dark:text-piedra-950' : 'bg-piedra-900 text-piedra-50 dark:bg-piedra-100 dark:text-piedra-900',
          )}
        >
          {a.tipo === 'error' && <Icono nombre="alerta" tamano={18} />}
          <span>{a.texto}</span>
          <button
            type="button"
            aria-label="Cerrar aviso"
            className="-mr-1 rounded-full p-1 opacity-80 hover:opacity-100"
            onClick={() => {
              cerrar(a.id)
            }}
          >
            <Icono nombre="cerrar" tamano={16} />
          </button>
        </div>
      ))}
    </div>
  )
}
