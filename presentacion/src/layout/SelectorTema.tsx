import { useId } from 'react'
import { Icono, type NombreIcono } from '@/components/ui/Icono'
import { cn } from '@/lib/cn'
import { fijarTema, useTema, type Tema } from '@/lib/tema'

const OPCIONES: { valor: Tema; texto: string; icono: NombreIcono }[] = [
  { valor: 'sistema', texto: 'Sistema', icono: 'monitor' },
  { valor: 'claro', texto: 'Claro', icono: 'sol' },
  { valor: 'oscuro', texto: 'Oscuro', icono: 'luna' },
]

/**
 * Compacto: un botón que rota entre las tres opciones (riel de escritorio).
 * Completo: grupo de radios accesible (página de perfil).
 */
export function SelectorTema({ compacto = false }: { compacto?: boolean }) {
  const tema = useTema((s) => s.tema)
  const nombre = useId()

  if (compacto) {
    const i = OPCIONES.findIndex((o) => o.valor === tema)
    const actual = OPCIONES[i] ?? OPCIONES[0]
    const siguiente = OPCIONES[(i + 1) % OPCIONES.length] ?? OPCIONES[0]
    if (!actual || !siguiente) return null
    return (
      <button
        type="button"
        onClick={() => {
          fijarTema(siguiente.valor)
        }}
        aria-label={`Tema: ${actual.texto}. Cambiar a ${siguiente.texto.toLowerCase()}`}
        title={`Tema: ${actual.texto}`}
        className="flex size-10 items-center justify-center rounded-full text-tenue hover:bg-superficie-2 hover:text-texto"
      >
        <Icono nombre={actual.icono} />
      </button>
    )
  }

  return (
    <fieldset className="flex flex-col gap-2">
      <legend className="mb-2 text-sm font-semibold">Tema</legend>
      <div className="grid grid-cols-3 gap-2">
        {OPCIONES.map((o) => (
          <label
            key={o.valor}
            className={cn(
              'flex cursor-pointer flex-col items-center gap-1.5 rounded-control border px-2 py-3 text-sm font-medium transition-colors',
              'has-focus-visible:outline-2 has-focus-visible:outline-offset-2 has-focus-visible:outline-foco',
              tema === o.valor ? 'border-primario bg-primario-suave text-primario' : 'border-borde text-tenue hover:bg-superficie-2',
            )}
          >
            <input
              type="radio"
              name={nombre}
              value={o.valor}
              checked={tema === o.valor}
              onChange={() => {
                fijarTema(o.valor)
              }}
              className="sr-only"
            />
            <Icono nombre={o.icono} />
            {o.texto}
          </label>
        ))}
      </div>
    </fieldset>
  )
}
