import type { ReactNode } from 'react'
import { Logo } from '@/components/ui/Logo'
import { SelectorTema } from '@/layout/SelectorTema'

/** Marco de las pantallas públicas: panel de marca (escritorio) + formulario. */
export function MarcoAcceso({ titulo, subtitulo, children }: { titulo: string; subtitulo: string; children: ReactNode }) {
  return (
    <div className="grid min-h-dvh lg:grid-cols-[minmax(0,1fr)_minmax(0,1.1fr)]">
      <aside
        aria-hidden="true"
        className="relative hidden overflow-hidden bg-selva-800 p-12 text-selva-50 lg:flex lg:flex-col lg:justify-between dark:bg-selva-950"
      >
        <div
          className="absolute inset-0 opacity-40"
          style={{
            backgroundImage:
              'radial-gradient(circle at 20% 20%, rgb(79 209 181 / .35), transparent 40%), radial-gradient(circle at 85% 75%, rgb(220 76 176 / .35), transparent 45%)',
          }}
        />
        <span className="relative text-2xl font-extrabold tracking-tight">
          CR<span className="text-guaria-300">_</span>Chat
        </span>
        <div className="relative flex max-w-md flex-col gap-6">
          <p className="text-3xl leading-tight font-bold">Conversaciones que llegan al instante, con la calma de la selva.</p>
          <ul className="flex flex-col gap-3 text-base text-selva-100">
            <li>• Mensajes en tiempo real con confirmación de entrega y lectura.</li>
            <li>• Tus sesiones bajo control en cada dispositivo.</li>
            <li>• Bloqueo y solicitudes de mensaje para cuidar tu privacidad.</li>
          </ul>
        </div>
        <div className="relative flex gap-3" aria-hidden="true">
          <span className="rounded-burbuja rounded-bl-md bg-selva-50/12 px-4 py-2.5 text-sm">¿Nos vemos el viernes?</span>
          <span className="self-end rounded-burbuja rounded-br-md bg-guaria-600 px-4 py-2.5 text-sm text-blanco">¡Pura vida! ✓✓</span>
        </div>
      </aside>

      <main className="flex flex-col px-5 py-6 sm:px-10">
        <div className="flex items-center justify-between">
          <Logo className="lg:invisible" />
          <SelectorTema compacto />
        </div>
        <div className="mx-auto flex w-full max-w-sm flex-1 flex-col justify-center gap-7 py-10">
          <header className="flex flex-col gap-1.5">
            <h1 className="text-3xl font-extrabold tracking-tight">{titulo}</h1>
            <p className="text-tenue">{subtitulo}</p>
          </header>
          {children}
        </div>
      </main>
    </div>
  )
}
