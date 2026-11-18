import { describe, expect, it } from 'vitest'
import { act, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { delay, http, HttpResponse } from 'msw'
import { IDS } from '@/mocks/db'
import { API, conexionesWs, db, servidor } from '@/test/servidor'
import { entrarComoAna, renderApp } from '@/test/utilidades'

describe('lista de conversaciones', () => {
  it('muestra último mensaje, no leídos y separa las solicitudes de mensaje', async () => {
    await entrarComoAna()
    renderApp('/chats')
    const lista = await screen.findByRole('region', { name: 'Conversaciones' })
    const bruno = await within(lista).findByRole('link', { name: /Bruno Demo/ })
    expect(bruno).toHaveTextContent('Pura vida. ¿Lo vemos el viernes?')
    expect(bruno).toHaveTextContent('2 mensajes sin leer')
    // La navegación principal anuncia el total de no leídos.
    expect(screen.getAllByRole('link', { name: /Chats, \d+ sin leer/ }).length).toBeGreaterThan(0)
  })
})

describe('conversación', () => {
  it('carga el historial reciente y ofrece cargar mensajes anteriores (scroll infinito)', async () => {
    await entrarComoAna()
    const u = userEvent.setup()
    renderApp(`/chats/${IDS.convAnaBruno}`)
    const log = await screen.findByRole('log', { name: 'Mensajes con Bruno Demo' })
    await waitFor(() => {
      expect(within(log).getAllByRole('listitem').length).toBeGreaterThan(20)
    })
    const antes = within(log).getAllByText(/:/, { selector: 'time' }).length
    await u.click(within(log).getByRole('button', { name: 'Cargar mensajes anteriores' }))
    expect(await within(log).findByText('Inicio de la conversación')).toBeInTheDocument()
    expect(within(log).getAllByText(/:/, { selector: 'time' }).length).toBeGreaterThan(antes)
  })

  it('envía de forma optimista: aparece al instante como "Enviando" y luego se confirma', async () => {
    await entrarComoAna()
    servidor.use(
      http.post(`${API}/conversations/:id/messages`, async () => {
        await delay(150)
        return undefined // deja pasar al handler normal tras la demora
      }),
    )
    const u = userEvent.setup()
    renderApp(`/chats/${IDS.convAnaBruno}`)
    const caja = await screen.findByRole('textbox', { name: 'Escribe un mensaje' })
    await u.type(caja, 'Hola desde la prueba{Enter}')
    expect(caja).toHaveValue('')
    const burbuja = (await screen.findByText('Hola desde la prueba')).closest('li')
    if (!burbuja) throw new Error('sin burbuja')
    expect(within(burbuja).getByRole('img', { name: 'Enviando' })).toBeInTheDocument()
    await waitFor(() => {
      expect(within(burbuja).queryByRole('img', { name: 'Enviando' })).not.toBeInTheDocument()
    })
    expect(within(burbuja).getByRole('img', { name: /Enviado|Entregado|Visto/ })).toBeInTheDocument()
  })

  it('si el envío falla permite reintentar sin duplicar (idempotencia por client_id)', async () => {
    await entrarComoAna()
    let fallar = true
    const claves = new Set<string>()
    servidor.events.on('request:start', ({ request }) => {
      if (request.method === 'POST' && request.url.endsWith('/messages')) claves.add(request.headers.get('Idempotency-Key') ?? '')
    })
    servidor.use(
      http.post(`${API}/conversations/:id/messages`, () => {
        if (!fallar) return undefined
        fallar = false
        return HttpResponse.json({ type: 'x', title: 'Error', status: 503 }, { status: 503 })
      }),
    )
    const u = userEvent.setup()
    renderApp(`/chats/${IDS.convAnaBruno}`)
    await u.type(await screen.findByRole('textbox', { name: 'Escribe un mensaje' }), 'Reintento{Enter}')
    const burbuja = (await screen.findByText('Reintento')).closest('li')
    if (!burbuja) throw new Error('sin burbuja')
    expect(await within(burbuja).findByRole('img', { name: 'No enviado' })).toBeInTheDocument()
    await u.click(within(burbuja).getByRole('button', { name: 'Reintentar' }))
    await waitFor(() => {
      expect(within(burbuja).queryByRole('img', { name: 'No enviado' })).not.toBeInTheDocument()
    })
    expect(screen.getAllByText('Reintento')).toHaveLength(1)
    expect(claves.size).toBe(1)
    servidor.events.removeAllListeners()
  })

  it('edita y borra un mensaje propio desde su menú de acciones', async () => {
    await entrarComoAna()
    const u = userEvent.setup()
    renderApp(`/chats/${IDS.convAnaBruno}`)
    await u.type(await screen.findByRole('textbox', { name: 'Escribe un mensaje' }), 'Texto original{Enter}')
    const original = await screen.findByText('Texto original')
    await waitFor(() => {
      expect(within(original.closest('li') as HTMLElement).queryByRole('img', { name: 'Enviando' })).not.toBeInTheDocument()
    })

    await u.click(within(original.closest('li') as HTMLElement).getByRole('button', { name: 'Acciones del mensaje' }))
    await u.click(screen.getByRole('menuitem', { name: 'Editar' }))
    const edicion = await screen.findByRole('textbox', { name: 'Editar mensaje' })
    await u.clear(edicion)
    await u.type(edicion, 'Texto corregido{Enter}')
    const editado = await screen.findByText('Texto corregido')
    expect(within(editado.closest('li') as HTMLElement).getByText(/editado/)).toBeInTheDocument()

    await u.click(within(editado.closest('li') as HTMLElement).getByRole('button', { name: 'Acciones del mensaje' }))
    await u.click(screen.getByRole('menuitem', { name: 'Eliminar para todos' }))
    const dialogo = await screen.findByRole('dialog', { name: '¿Eliminar este mensaje?' })
    await u.click(within(dialogo).getByRole('button', { name: 'Eliminar' }))
    expect(await screen.findByText('Mensaje eliminado')).toBeInTheDocument()
    expect(screen.queryByText('Texto corregido')).not.toBeInTheDocument()
  })

  it('marca visto el primer mensaje del par en un chat que no tenía mensajes suyos', async () => {
    // Chat vacío (como el seed real): el primer mensaje recibido no debe tomarse como «ya visto».
    db.d.mensajes = db.d.mensajes.filter((m) => m.conversation_id !== IDS.convAnaBruno)
    db.d.marcadores = {}
    await entrarComoAna()
    renderApp(`/chats/${IDS.convAnaBruno}`)
    await screen.findByRole('heading', { name: /Di hola/ })
    await waitFor(() => {
      expect(conexionesWs.size).toBeGreaterThan(0)
    })
    await act(async () => {
      await delay(50)
      db.enviarMensaje(IDS.bruno, IDS.convAnaBruno, { text: 'Primer mensaje de Bruno' })
    })
    await screen.findByText('Primer mensaje de Bruno')
    const primero = db.d.mensajes.find((m) => m.text === 'Primer mensaje de Bruno')
    await waitFor(() => {
      expect(db.d.marcadores[`${IDS.convAnaBruno}:${IDS.ana}`]?.seen).toBe(primero?.id)
    })
  })

  it('en una solicitud de mensaje (no es contacto) ofrece agregar o bloquear', async () => {
    const { iniciarSesion } = await import('@/auth/sesion')
    await iniciarSesion('carla@demo.crchat.local', 'Demo-Carla-2026!')
    const u = userEvent.setup()
    renderApp(`/chats/${IDS.convAnaCarla}`)
    const nota = await screen.findByRole('note')
    expect(nota).toHaveTextContent('Ana Demo no está en tus contactos.')
    await u.click(within(nota).getByRole('button', { name: 'Bloquear' }))
    const dialogo = await screen.findByRole('dialog', { name: '¿Bloquear a Ana Demo?' })
    await u.click(within(dialogo).getByRole('button', { name: 'Bloquear' }))
    expect(await screen.findByText(/Bloqueaste a Ana Demo\. No podrás enviarle mensajes/)).toBeInTheDocument()
    expect(screen.queryByRole('textbox', { name: 'Escribe un mensaje' })).not.toBeInTheDocument()
  })
})
