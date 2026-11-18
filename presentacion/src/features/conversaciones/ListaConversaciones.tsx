import { useMemo, useState, type KeyboardEvent } from 'react'
import { Link, NavLink } from 'react-router'
import type { Conversacion } from '@/api/tipos'
import { useAuth } from '@/auth/sesion'
import { todasLasConversaciones } from '@/cache/conversaciones'
import { Avatar } from '@/components/ui/Avatar'
import { Boton } from '@/components/ui/Boton'
import { claseControl } from '@/components/ui/Campo'
import { EsqueletoLista, EstadoError, EstadoVacio } from '@/components/ui/Estados'
import { Icono } from '@/components/ui/Icono'
import { ReciboMensaje } from '@/features/chat/ReciboMensaje'
import { useEscribiendo, usePresencia } from '@/realtime/estadoEfimero'
import { cn } from '@/lib/cn'
import { marcaLista } from '@/lib/formato'
import { useConversaciones } from './consultas'

function VistaPrevia({ c, miId }: { c: Conversacion; miId: string }) {
  const escribiendo = useEscribiendo(c.id)
  if (escribiendo) return <span className="font-semibold text-primario">escribiendo…</span>
  const m = c.last_message
  if (!m) return <span className="italic">Sin mensajes todavía</span>
  const mio = m.sender_id === miId
  let texto: string
  if (m.deleted_at) texto = 'Mensaje eliminado'
  else if (m.text) texto = m.text
  else if (m.media?.content_type.startsWith('image/')) texto = '📷 Foto'
  else texto = '📎 Archivo'
  return (
    <span className="flex min-w-0 items-center gap-1">
      {mio && <ReciboMensaje mensaje={m} />}
      <span className={cn('truncate', m.deleted_at && 'italic')}>
        {mio ? 'Tú: ' : ''}
        {texto}
      </span>
    </span>
  )
}

function ElementoConversacion({ c, miId }: { c: Conversacion; miId: string }) {
  const presencia = usePresencia(c.peer.id)
  const noLeidos = c.unread_count
  const fecha = c.last_message?.created_at ?? c.created_at
  return (
    <li>
      <NavLink
        to={`/chats/${c.id}`}
        data-elemento-lista
        className={({ isActive }) =>
          cn(
            'flex items-center gap-3 rounded-control px-3 py-2.5 transition-colors',
            isActive ? 'bg-primario-suave' : 'hover:bg-superficie-2',
          )
        }
      >
        <Avatar nombre={c.peer.display_name} semilla={c.peer.id} media={c.peer.avatar} enLinea={presencia?.estado === 'online'} />
        <span className="flex min-w-0 flex-1 flex-col gap-0.5">
          <span className="flex items-baseline justify-between gap-2">
            <span className={cn('truncate', noLeidos > 0 ? 'font-bold' : 'font-semibold')}>{c.peer.display_name}</span>
            <time dateTime={fecha} className={cn('shrink-0 text-xs', noLeidos > 0 ? 'font-bold text-acento' : 'text-tenue')}>
              {marcaLista(fecha)}
            </time>
          </span>
          <span className="flex items-center justify-between gap-2 text-sm text-tenue">
            <VistaPrevia c={c} miId={miId} />
            {noLeidos > 0 && (
              <span aria-hidden="true" className="min-w-5 shrink-0 rounded-full bg-acento px-1.5 text-center text-2xs leading-5 font-bold text-sobre-acento">
                {noLeidos > 99 ? '99+' : noLeidos}
              </span>
            )}
          </span>
          {noLeidos > 0 && <span className="sr-only">{noLeidos === 1 ? '1 mensaje sin leer' : `${noLeidos} mensajes sin leer`}</span>}
          {c.blocked && <span className="text-2xs font-semibold text-peligro">Bloqueado</span>}
        </span>
      </NavLink>
    </li>
  )
}

/** Flechas arriba/abajo, Inicio y Fin recorren la lista de enlaces. */
function navegarConFlechas(e: KeyboardEvent<HTMLElement>) {
  if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(e.key)) return
  const enlaces = Array.from(e.currentTarget.querySelectorAll<HTMLAnchorElement>('[data-elemento-lista]'))
  if (enlaces.length === 0) return
  const i = enlaces.indexOf(document.activeElement as HTMLAnchorElement)
  const destino =
    e.key === 'Home' ? 0 : e.key === 'End' ? enlaces.length - 1 : e.key === 'ArrowDown' ? Math.min(enlaces.length - 1, i + 1) : Math.max(0, i - 1)
  e.preventDefault()
  enlaces[destino]?.focus()
}

export function ListaConversaciones() {
  const miId = useAuth((s) => s.usuario?.id ?? '')
  const consulta = useConversaciones()
  const [filtro, setFiltro] = useState('')

  const { solicitudes, chats } = useMemo(() => {
    const q = filtro.trim().toLowerCase()
    const todas = todasLasConversaciones(consulta.data).filter((c) => !q || c.peer.display_name.toLowerCase().includes(q))
    return { solicitudes: todas.filter((c) => !c.is_contact), chats: todas.filter((c) => c.is_contact) }
  }, [consulta.data, filtro])

  return (
    <div className="flex h-full flex-col">
      <header className="flex items-center justify-between gap-2 px-4 pt-4 pb-2">
        <h1 className="text-2xl font-extrabold tracking-tight">Chats</h1>
        <Link
          to="/contactos"
          aria-label="Nuevo chat"
          title="Nuevo chat"
          className="flex size-10 items-center justify-center rounded-full bg-primario-suave text-primario hover:opacity-90"
        >
          <Icono nombre="agregar" />
        </Link>
      </header>
      <div className="px-4 pb-2">
        <label className="relative block">
          <span className="sr-only">Buscar chats</span>
          <Icono nombre="buscar" tamano={18} className="pointer-events-none absolute top-1/2 left-3 -translate-y-1/2 text-tenue" />
          <input
            type="search"
            value={filtro}
            onChange={(e) => {
              setFiltro(e.target.value)
            }}
            placeholder="Buscar chats"
            className={cn(claseControl, 'h-10 bg-superficie-2 pl-9')}
          />
        </label>
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto px-2 pb-4" onKeyDown={navegarConFlechas}>
        {consulta.isPending ? (
          <EsqueletoLista etiqueta="Cargando conversaciones" />
        ) : consulta.isError ? (
          <EstadoError error={consulta.error} alReintentar={() => void consulta.refetch()} />
        ) : solicitudes.length + chats.length === 0 ? (
          filtro ? (
            <EstadoVacio icono="buscar" titulo="Sin resultados">
              Ningún chat coincide con «{filtro}».
            </EstadoVacio>
          ) : (
            <EstadoVacio
              icono="chats"
              titulo="Aún no tienes conversaciones"
              accion={
                <Link to="/contactos" className="font-semibold text-primario underline-offset-4 hover:underline">
                  Escribe a un contacto
                </Link>
              }
            >
              Empieza un chat desde tus contactos.
            </EstadoVacio>
          )
        ) : (
          <>
            {solicitudes.length > 0 && (
              <section aria-labelledby="titulo-solicitudes" className="mb-2">
                <h2 id="titulo-solicitudes" className="px-3 pt-2 pb-1 text-xs font-bold tracking-wide text-tenue uppercase">
                  Solicitudes de mensaje
                </h2>
                <ul className="flex flex-col gap-0.5">
                  {solicitudes.map((c) => (
                    <ElementoConversacion key={c.id} c={c} miId={miId} />
                  ))}
                </ul>
              </section>
            )}
            {chats.length > 0 && (
              <section aria-label="Tus chats">
                {solicitudes.length > 0 && <h2 className="px-3 pt-2 pb-1 text-xs font-bold tracking-wide text-tenue uppercase">Chats</h2>}
                <ul className="flex flex-col gap-0.5">
                  {chats.map((c) => (
                    <ElementoConversacion key={c.id} c={c} miId={miId} />
                  ))}
                </ul>
              </section>
            )}
            {consulta.hasNextPage && (
              <div className="flex justify-center py-3">
                <Boton variante="fantasma" tamano="sm" cargando={consulta.isFetchingNextPage} onClick={() => void consulta.fetchNextPage()}>
                  Cargar más
                </Boton>
              </div>
            )}
          </>
        )}
      </div>
    </div>
  )
}
