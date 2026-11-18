import { describe, expect, it } from 'vitest'
import { act, renderHook, waitFor } from '@testing-library/react'
import type { ReactNode } from 'react'
import { claves } from '@/api/claves'
import { Proveedores } from '@/app/App'
import { useAuth } from '@/auth/sesion'
import { buscarConversacion, type CacheConversaciones } from '@/cache/conversaciones'
import { mensajesOrdenados, type CacheMensajes } from '@/cache/mensajes'
import { IDS } from '@/mocks/db'
import { db, WS } from '@/test/servidor'
import { clientePruebas, entrarComoAna } from '@/test/utilidades'
import { useConversaciones } from '@/features/conversaciones/consultas'
import { useMensajes } from '@/features/chat/consultas'
import { fijarConversacionActiva, useEfimero } from './estadoEfimero'
import { useChatSocket } from './useChatSocket'

function montar() {
  const cliente = clientePruebas()
  const envoltorio = ({ children }: { children: ReactNode }) => <Proveedores cliente={cliente}>{children}</Proveedores>
  const hook = renderHook(
    () => {
      const socket = useChatSocket({ url: WS })
      const conversaciones = useConversaciones()
      const mensajes = useMensajes(IDS.convAnaBruno)
      return { socket, conversaciones, mensajes }
    },
    { wrapper: envoltorio },
  )
  return { ...hook, cliente }
}

describe('useChatSocket (contra el WebSocket simulado con MSW)', () => {
  it('se conecta, se autentica y pide la presencia de los participantes', async () => {
    await entrarComoAna()
    const { result } = montar()
    await waitFor(() => {
      expect(result.current.socket.estado).toBe('conectado')
    })
    await waitFor(() => {
      expect(result.current.conversaciones.isSuccess).toBe(true)
    })
    await waitFor(() => {
      expect(useEfimero.getState().presencia[IDS.bruno]).toMatchObject({ estado: 'offline' })
    })
  })

  it('integra message.new en la caché de mensajes y de conversaciones (+1 no leído)', async () => {
    await entrarComoAna()
    const { result, cliente } = montar()
    await waitFor(() => {
      expect(result.current.socket.estado).toBe('conectado')
      expect(result.current.mensajes.isSuccess).toBe(true)
      expect(result.current.conversaciones.isSuccess).toBe(true)
    })
    const antes = buscarConversacion(cliente.getQueryData<CacheConversaciones>(claves.conversaciones()), IDS.convAnaBruno)?.unread_count ?? 0

    act(() => {
      db.enviarMensaje(IDS.bruno, IDS.convAnaBruno, { text: 'Mensaje en tiempo real' })
    })

    await waitFor(() => {
      const lista = mensajesOrdenados(cliente.getQueryData<CacheMensajes>(claves.mensajes(IDS.convAnaBruno)))
      expect(lista.at(-1)?.text).toBe('Mensaje en tiempo real')
    })
    const conv = buscarConversacion(cliente.getQueryData<CacheConversaciones>(claves.conversaciones()), IDS.convAnaBruno)
    expect(conv?.last_message?.text).toBe('Mensaje en tiempo real')
    expect(conv?.unread_count).toBe(antes + 1)
    // La conversación con actividad sube al principio.
    expect(cliente.getQueryData<CacheConversaciones>(claves.conversaciones())?.pages[0]?.items[0]?.id).toBe(IDS.convAnaBruno)
  })

  it('no suma no leídos si la conversación está abierta, y refleja typing y recibos', async () => {
    await entrarComoAna()
    const { result, cliente } = montar()
    await waitFor(() => {
      expect(result.current.socket.estado).toBe('conectado')
      expect(result.current.mensajes.isSuccess).toBe(true)
      expect(result.current.conversaciones.isSuccess).toBe(true)
    })
    fijarConversacionActiva(IDS.convAnaBruno)
    const antes = buscarConversacion(cliente.getQueryData<CacheConversaciones>(claves.conversaciones()), IDS.convAnaBruno)?.unread_count

    act(() => {
      db.publicar(IDS.ana, 'typing', { conversation_id: IDS.convAnaBruno, user_id: IDS.bruno, state: 'start' })
    })
    await waitFor(() => {
      expect(useEfimero.getState().escribiendo[IDS.convAnaBruno]).toMatchObject({ usuarioId: IDS.bruno })
    })

    // Ana envía; Bruno lo ve → ✓✓ en el mensaje de Ana.
    const anaId = useAuth.getState().usuario?.id ?? ''
    let enviadoId = ''
    act(() => {
      enviadoId = db.enviarMensaje(anaId, IDS.convAnaBruno, { text: 'hola' }).mensaje.id
      db.marcarRecibo(IDS.bruno, IDS.convAnaBruno, 'seen', enviadoId)
      db.enviarMensaje(IDS.bruno, IDS.convAnaBruno, { text: 'respuesta' })
    })
    await waitFor(() => {
      const m = mensajesOrdenados(cliente.getQueryData<CacheMensajes>(claves.mensajes(IDS.convAnaBruno))).find((x) => x.id === enviadoId)
      expect(m?.status).toBe('seen')
    })
    // Llegó un mensaje de Bruno: el indicador "escribiendo" se apaga.
    expect(useEfimero.getState().escribiendo[IDS.convAnaBruno]).toBeUndefined()
    expect(buscarConversacion(cliente.getQueryData<CacheConversaciones>(claves.conversaciones()), IDS.convAnaBruno)?.unread_count).toBe(antes)
  })

  it('al revocarse la sesión (logout en otro lado) vuelve a estado anónimo', async () => {
    await entrarComoAna()
    const { result } = montar()
    await waitFor(() => {
      expect(result.current.socket.estado).toBe('conectado')
    })
    act(() => {
      const { usuario, sesionId } = useAuth.getState()
      db.revocarSesion(usuario?.id ?? '', sesionId ?? '')
    })
    await waitFor(() => {
      expect(useAuth.getState()).toMatchObject({ estado: 'anonimo', motivoSalida: 'revocada' })
    })
  })
})
