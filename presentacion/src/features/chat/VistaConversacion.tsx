import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react'
import { Link, useParams } from 'react-router'
import { useQueryClient } from '@tanstack/react-query'
import { ApiError, mensajeDeError } from '@/api/errores'
import { claves } from '@/api/claves'
import type { Conversacion, MensajeChat } from '@/api/tipos'
import { useAuth } from '@/auth/sesion'
import { mensajesOrdenados, quitarMensaje, type CacheMensajes } from '@/cache/mensajes'
import { Avatar } from '@/components/ui/Avatar'
import { avisar } from '@/components/ui/Avisos'
import { Boton } from '@/components/ui/Boton'
import { Dialogo } from '@/components/ui/Dialogo'
import { EstadoError, EstadoVacio } from '@/components/ui/Estados'
import { Icono } from '@/components/ui/Icono'
import { Menu } from '@/components/ui/Menu'
import { Cargando } from '@/components/ui/Spinner'
import { useBloquear } from '@/features/contactos/consultas'
import { useConversacion } from '@/features/conversaciones/consultas'
import { fijarConversacionActiva, useEscribiendo, usePresencia } from '@/realtime/estadoEfimero'
import { useTiempoReal } from '@/realtime/TiempoReal'
import { ultimaVez } from '@/lib/formato'
import { Compositor } from './Compositor'
import { archivoPendiente, olvidarArchivo, useBorrarMensaje, useEnviarMensaje, useMarcarVisto, useMensajes } from './consultas'
import { ListaMensajes } from './ListaMensajes'

function suscribirVisibilidad(alCambiar: () => void) {
  document.addEventListener('visibilitychange', alCambiar)
  return () => {
    document.removeEventListener('visibilitychange', alCambiar)
  }
}

function useDocumentoVisible(): boolean {
  return useSyncExternalStore(suscribirVisibilidad, () => document.visibilityState === 'visible')
}

export function VistaConversacion() {
  const { conversacionId = '' } = useParams()
  const { conversacion, cargando, error } = useConversacion(conversacionId)

  useEffect(() => {
    fijarConversacionActiva(conversacionId)
    return () => {
      fijarConversacionActiva(null)
    }
  }, [conversacionId])

  if (cargando) return <Cargando texto="Abriendo conversación…" className="flex-1" />
  if (!conversacion) {
    const noExiste = error instanceof ApiError && error.status === 404
    return (
      <div className="flex flex-1 flex-col items-center justify-center">
        {noExiste || !error ? (
          <EstadoVacio
            icono="chats"
            titulo="Conversación no encontrada"
            accion={
              <Link to="/chats" className="font-semibold text-primario underline-offset-4 hover:underline">
                Volver a tus chats
              </Link>
            }
          />
        ) : (
          <EstadoError error={error} />
        )}
      </div>
    )
  }
  return <PanelConversacion key={conversacion.id} conversacion={conversacion} />
}

function EstadoPar({ conversacion }: { conversacion: Conversacion }) {
  const escribiendo = useEscribiendo(conversacion.id)
  const presencia = usePresencia(conversacion.peer.id)
  let texto = ''
  if (escribiendo) texto = 'escribiendo…'
  else if (presencia?.estado === 'online') texto = 'en línea'
  else if (presencia?.ultimaVez) texto = `últ. vez ${ultimaVez(presencia.ultimaVez)}`
  return (
    <p aria-live="polite" className={escribiendo ? 'text-xs font-semibold text-primario' : 'text-xs text-tenue'}>
      {texto}
    </p>
  )
}

function IndicadorEscribiendo({ conversacionId, nombre }: { conversacionId: string; nombre: string }) {
  const escribiendo = useEscribiendo(conversacionId)
  if (!escribiendo) return null
  return (
    <div className="mx-auto mt-3 flex max-w-4xl" aria-hidden="true" title={`${nombre} está escribiendo`}>
      <span className="flex items-center gap-1 rounded-burbuja rounded-bl-md bg-burbuja-otra px-4 py-3 shadow-suave">
        {[0, 1, 2].map((i) => (
          <span key={i} className="size-1.5 animate-punto rounded-full bg-tenue" style={{ animationDelay: `${i * 160}ms` }} />
        ))}
      </span>
    </div>
  )
}

function PanelConversacion({ conversacion }: { conversacion: Conversacion }) {
  const qc = useQueryClient()
  const miId = useAuth((s) => s.usuario?.id ?? '')
  const { estado: estadoSocket } = useTiempoReal()
  const presencia = usePresencia(conversacion.peer.id)
  const id = conversacion.id
  const nombre = conversacion.peer.display_name

  const consulta = useMensajes(id, { sondeoMs: estadoSocket === 'conectado' ? false : 15_000 })
  const mensajes = useMemo(() => mensajesOrdenados(consulta.data), [consulta.data])
  const enviar = useEnviarMensaje(id)
  const borrar = useBorrarMensaje(id)
  const bloquear = useBloquear()
  const marcarVisto = useMarcarVisto(id)
  const [editando, setEditando] = useState<MensajeChat | null>(null)
  const [aBorrar, setABorrar] = useState<MensajeChat | null>(null)
  const [confirmarBloqueo, setConfirmarBloqueo] = useState(false)

  // Recibo "visto": al abrir con no leídos o al llegar uno nuevo con la pestaña visible.
  const visible = useDocumentoVisible()
  const ultimoDelPar = useMemo(() => {
    for (let i = mensajes.length - 1; i >= 0; i--) {
      const m = mensajes[i]
      if (m && m.sender_id !== miId && !m.local) return m
    }
    return undefined
  }, [mensajes, miId])
  const inicialDelPar = useRef<string | undefined>(undefined)
  const vistoEnviado = useRef<string | null>(null)
  const noLeidos = conversacion.unread_count
  useEffect(() => {
    if (!ultimoDelPar) return
    inicialDelPar.current ??= ultimoDelPar.id
    if (!visible || vistoEnviado.current === ultimoDelPar.id) return
    if (noLeidos > 0 || ultimoDelPar.id !== inicialDelPar.current) {
      vistoEnviado.current = ultimoDelPar.id
      marcarVisto(ultimoDelPar.id)
    }
  }, [ultimoDelPar, visible, noLeidos, marcarVisto])

  const cargarMas = useCallback(() => {
    if (consulta.hasNextPage && !consulta.isFetchingNextPage) void consulta.fetchNextPage()
  }, [consulta])

  const alReintentar = useCallback(
    (m: MensajeChat) => {
      if (!m.client_id) return
      enviar.mutate({ clientId: m.client_id, texto: m.text ?? undefined, archivo: archivoPendiente(m.client_id) })
    },
    [enviar],
  )
  const alDescartar = useCallback(
    (m: MensajeChat) => {
      if (m.client_id) olvidarArchivo(m.client_id)
      qc.setQueryData<CacheMensajes>(claves.mensajes(id), (c) => quitarMensaje(c, m.id))
    },
    [qc, id],
  )
  const alEditar = useCallback((m: MensajeChat) => {
    setEditando(m)
  }, [])
  const alBorrar = useCallback((m: MensajeChat) => {
    setABorrar(m)
  }, [])

  const cambiarBloqueo = () => {
    const nuevo = !conversacion.blocked
    bloquear.mutate(
      { usuarioId: conversacion.peer.id, bloquear: nuevo },
      {
        onSuccess: () => {
          avisar(nuevo ? `Bloqueaste a ${nombre}.` : `Desbloqueaste a ${nombre}.`)
        },
        onError: (e) => {
          avisar(mensajeDeError(e), 'error')
        },
        onSettled: () => {
          setConfirmarBloqueo(false)
        },
      },
    )
  }

  return (
    <section aria-labelledby="titulo-conversacion" className="flex min-w-0 flex-1 flex-col bg-fondo">
      <header className="flex items-center gap-2 border-b border-borde bg-superficie px-2 py-2 sm:px-4">
        <Link to="/chats" aria-label="Volver a chats" className="flex size-10 items-center justify-center rounded-full text-tenue hover:bg-superficie-2 md:hidden">
          <Icono nombre="atras" />
        </Link>
        <Avatar nombre={nombre} semilla={conversacion.peer.id} media={conversacion.peer.avatar} enLinea={presencia?.estado === 'online'} />
        <div className="min-w-0 flex-1">
          <h1 id="titulo-conversacion" className="truncate text-base font-bold">
            {nombre}
          </h1>
          <EstadoPar conversacion={conversacion} />
        </div>
        <Menu
          etiqueta="Opciones de la conversación"
          opciones={[
            conversacion.blocked
              ? { etiqueta: `Desbloquear a ${nombre}`, icono: 'bloquear', alElegir: cambiarBloqueo }
              : { etiqueta: `Bloquear a ${nombre}`, icono: 'bloquear', peligro: true, alElegir: () => { setConfirmarBloqueo(true) } },
          ]}
        />
      </header>

      {!conversacion.is_contact && !conversacion.blocked && (
        <div role="note" className="flex flex-wrap items-center justify-between gap-2 border-b border-borde bg-guaria-50 px-4 py-2.5 text-sm text-guaria-900 dark:bg-guaria-950 dark:text-guaria-100">
          <span>
            <strong>{nombre}</strong> no está en tus contactos.
          </span>
          <span className="flex gap-2">
            <Link to="/contactos?agregar=1" className="rounded-full px-3 py-1 font-semibold hover:bg-guaria-100 dark:hover:bg-guaria-900">
              Agregar
            </Link>
            <button type="button" onClick={() => { setConfirmarBloqueo(true) }} className="rounded-full px-3 py-1 font-semibold hover:bg-guaria-100 dark:hover:bg-guaria-900">
              Bloquear
            </button>
          </span>
        </div>
      )}

      {consulta.isPending ? (
        <Cargando texto="Cargando mensajes…" className="fondo-conversacion flex-1" />
      ) : consulta.isError ? (
        <div className="fondo-conversacion flex flex-1 items-center justify-center">
          <EstadoError error={consulta.error} alReintentar={() => void consulta.refetch()} />
        </div>
      ) : mensajes.length === 0 ? (
        <div className="fondo-conversacion flex flex-1 items-center justify-center">
          <EstadoVacio icono="chats" titulo="Di hola 👋">
            Este es el comienzo de tu conversación con {nombre}.
          </EstadoVacio>
        </div>
      ) : (
        <ListaMensajes
          mensajes={mensajes}
          miId={miId}
          nombrePar={nombre}
          hayMas={consulta.hasNextPage}
          cargandoMas={consulta.isFetchingNextPage}
          cargarMas={cargarMas}
          alEditar={alEditar}
          alBorrar={alBorrar}
          alReintentar={alReintentar}
          alDescartar={alDescartar}
          pie={<IndicadorEscribiendo conversacionId={id} nombre={nombre} />}
        />
      )}

      {conversacion.blocked ? (
        <div className="flex flex-wrap items-center justify-center gap-3 border-t border-borde bg-superficie px-4 py-4 text-sm text-tenue">
          <span>Bloqueaste a {nombre}. No podrás enviarle mensajes.</span>
          <Boton variante="secundario" tamano="sm" cargando={bloquear.isPending} onClick={cambiarBloqueo}>
            Desbloquear
          </Boton>
        </div>
      ) : (
        <Compositor
          key={editando?.id ?? 'nuevo'}
          conversacionId={id}
          editando={editando}
          alTerminarEdicion={() => {
            setEditando(null)
          }}
        />
      )}

      <Dialogo
        abierto={aBorrar !== null}
        alCerrar={() => {
          setABorrar(null)
        }}
        titulo="¿Eliminar este mensaje?"
        descripcion="Se eliminará para todos los participantes. Esta acción no se puede deshacer."
      >
        <div className="flex justify-end gap-2">
          <Boton variante="secundario" onClick={() => { setABorrar(null) }}>
            Cancelar
          </Boton>
          <Boton
            variante="peligro"
            icono="papelera"
            onClick={() => {
              if (aBorrar) borrar.mutate(aBorrar.id)
              setABorrar(null)
            }}
          >
            Eliminar
          </Boton>
        </div>
      </Dialogo>

      <Dialogo
        abierto={confirmarBloqueo}
        alCerrar={() => {
          setConfirmarBloqueo(false)
        }}
        titulo={`¿Bloquear a ${nombre}?`}
        descripcion="No podrá enviarte mensajes, ver tu perfil ni tu estado de conexión. Puedes desbloquearlo cuando quieras."
      >
        <div className="flex justify-end gap-2">
          <Boton variante="secundario" onClick={() => { setConfirmarBloqueo(false) }}>
            Cancelar
          </Boton>
          <Boton variante="peligro" icono="bloquear" cargando={bloquear.isPending} onClick={cambiarBloqueo}>
            Bloquear
          </Boton>
        </div>
      </Dialogo>
    </section>
  )
}
