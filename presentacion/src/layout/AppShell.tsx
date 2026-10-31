import { NavLink, Outlet, useLocation } from 'react-router'
import { Avisos } from '@/components/ui/Avisos'
import { Avatar } from '@/components/ui/Avatar'
import { Icono, type NombreIcono } from '@/components/ui/Icono'
import { Logo } from '@/components/ui/Logo'
import { useAuth } from '@/auth/sesion'
import { useConversaciones } from '@/features/conversaciones/consultas'
import { TiempoRealProvider, useTiempoReal } from '@/realtime/TiempoReal'
import { cn } from '@/lib/cn'
import { SelectorTema } from './SelectorTema'

interface Destino {
  a: string
  texto: string
  icono: NombreIcono
}

const DESTINOS: Destino[] = [
  { a: '/chats', texto: 'Chats', icono: 'chats' },
  { a: '/contactos', texto: 'Contactos', icono: 'contactos' },
  { a: '/perfil', texto: 'Perfil', icono: 'perfil' },
]

function useNoLeidosTotales(): number {
  const { data } = useConversaciones()
  return data?.pages.reduce((t, p) => t + p.items.reduce((s, c) => s + c.unread_count, 0), 0) ?? 0
}

function Insignia({ n }: { n: number }) {
  if (n <= 0) return null
  return (
    <span className="absolute -top-1 -right-1.5 min-w-5 rounded-full bg-acento px-1.5 text-center text-2xs leading-5 font-bold text-sobre-acento">
      {n > 99 ? '99+' : n}
    </span>
  )
}

function etiquetaDestino(d: Destino, noLeidos: number): string {
  return d.a === '/chats' && noLeidos > 0 ? `${d.texto}, ${noLeidos} sin leer` : d.texto
}

/** Riel lateral (escritorio). */
function Riel() {
  const usuario = useAuth((s) => s.usuario)
  const noLeidos = useNoLeidosTotales()
  return (
    <nav aria-label="Principal" className="hidden w-riel shrink-0 flex-col items-center gap-2 border-r border-borde bg-superficie py-4 md:flex">
      <Logo conTexto={false} className="mb-4" />
      <ul className="flex flex-col gap-1.5">
        {DESTINOS.map((d) => (
          <li key={d.a}>
            <NavLink
              to={d.a}
              aria-label={etiquetaDestino(d, noLeidos)}
              title={d.texto}
              className={({ isActive }) =>
                cn(
                  'relative flex size-12 items-center justify-center rounded-control transition-colors',
                  isActive ? 'bg-primario-suave text-primario' : 'text-tenue hover:bg-superficie-2 hover:text-texto',
                )
              }
            >
              <Icono nombre={d.icono} tamano={22} />
              {d.a === '/chats' && <Insignia n={noLeidos} />}
            </NavLink>
          </li>
        ))}
      </ul>
      <div className="mt-auto flex flex-col items-center gap-3">
        <SelectorTema compacto />
        {usuario && (
          <NavLink to="/perfil" aria-label="Tu perfil" title={usuario.display_name}>
            <Avatar nombre={usuario.display_name} semilla={usuario.id} media={usuario.avatar} tamano="sm" />
          </NavLink>
        )}
      </div>
    </nav>
  )
}

/** Barra de pestañas inferior (móvil). */
function BarraInferior() {
  const noLeidos = useNoLeidosTotales()
  return (
    <nav aria-label="Principal" className="border-t border-borde bg-superficie pb-[env(safe-area-inset-bottom)] md:hidden">
      <ul className="grid grid-cols-3">
        {DESTINOS.map((d) => (
          <li key={d.a}>
            <NavLink
              to={d.a}
              aria-label={etiquetaDestino(d, noLeidos)}
              className={({ isActive }) =>
                cn('flex flex-col items-center gap-0.5 py-2 text-2xs font-semibold', isActive ? 'text-primario' : 'text-tenue')
              }
            >
              <span className="relative">
                <Icono nombre={d.icono} tamano={22} />
                {d.a === '/chats' && <Insignia n={noLeidos} />}
              </span>
              {d.texto}
            </NavLink>
          </li>
        ))}
      </ul>
    </nav>
  )
}

function AvisoConexion() {
  const { estado } = useTiempoReal()
  if (estado !== 'reconectando') return null
  return (
    <div role="status" className="flex items-center justify-center gap-2 bg-guaria-100 px-4 py-1.5 text-xs font-semibold text-guaria-900 dark:bg-guaria-950 dark:text-guaria-100">
      <span className="size-2 animate-pulse rounded-full bg-current" aria-hidden="true" />
      Sin conexión en tiempo real. Reconectando…
    </div>
  )
}

export function AppShell() {
  const { pathname } = useLocation()
  const enConversacion = /^\/chats\/[^/]+/.test(pathname)
  return (
    <TiempoRealProvider>
      <a
        href="#contenido"
        className="sr-only focus:not-sr-only focus:fixed focus:top-2 focus:left-2 focus:z-50 focus:rounded-control focus:bg-superficie focus:px-4 focus:py-2 focus:shadow-flotante"
      >
        Saltar al contenido
      </a>
      <div className="flex h-dvh">
        <Riel />
        <div className="flex min-w-0 flex-1 flex-col">
          <AvisoConexion />
          <main id="contenido" tabIndex={-1} className="min-h-0 flex-1 outline-none">
            <Outlet />
          </main>
          {!enConversacion && <BarraInferior />}
        </div>
      </div>
      <Avisos />
    </TiempoRealProvider>
  )
}
