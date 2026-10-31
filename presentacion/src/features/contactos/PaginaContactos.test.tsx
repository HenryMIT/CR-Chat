import { describe, expect, it } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { iniciarSesion } from '@/auth/sesion'
import { entrarComoAna, renderApp } from '@/test/utilidades'

describe('contactos', () => {
  it('lista por alias y busca sin distinguir acentos ni mayúsculas', async () => {
    await entrarComoAna()
    const u = userEvent.setup()
    renderApp('/contactos')
    const region = await screen.findByRole('region', { name: 'Tus contactos' })
    expect(await within(region).findByText('Carla (trabajo)')).toBeInTheDocument()
    expect(within(region).getByText('Bruno')).toBeInTheDocument()
    await u.type(screen.getByRole('searchbox', { name: /Buscar/ }), 'CÁRLA')
    await waitFor(() => {
      expect(within(region).queryByText('Bruno')).not.toBeInTheDocument()
    })
    expect(within(region).getByText('Carla (trabajo)')).toBeInTheDocument()
  })

  it('agrega por teléfono local y muestra 404 genérico si el número no existe', async () => {
    await iniciarSesion('+50670000002', 'Demo-Bruno-2026!')
    const u = userEvent.setup()
    renderApp('/contactos')
    await u.click(await screen.findByRole('button', { name: 'Agregar' }))
    const dialogo = await screen.findByRole('dialog', { name: 'Agregar contacto' })
    await u.type(within(dialogo).getByLabelText('Teléfono'), '8888 9999')
    await u.click(within(dialogo).getByRole('button', { name: 'Agregar' }))
    expect(await within(dialogo).findByRole('alert')).toHaveTextContent('No encontramos a nadie con ese número')

    await u.clear(within(dialogo).getByLabelText('Teléfono'))
    await u.type(within(dialogo).getByLabelText('Teléfono'), '7000 0003')
    await u.type(within(dialogo).getByLabelText('Alias (opcional)'), 'Carlita')
    await u.click(within(dialogo).getByRole('button', { name: 'Agregar' }))
    expect(await screen.findByText('Carlita se agregó a tus contactos.')).toBeInTheDocument()
    expect(await within(screen.getByRole('region', { name: 'Tus contactos' })).findByText('Carlita')).toBeInTheDocument()
  })

  it('bloquear un contacto lo marca y aparece en la sección de bloqueados', async () => {
    await entrarComoAna()
    const u = userEvent.setup()
    renderApp('/contactos')
    await u.click(await screen.findByRole('button', { name: 'Opciones de Bruno' }))
    await u.click(screen.getByRole('menuitem', { name: 'Bloquear' }))
    await u.click(within(await screen.findByRole('dialog')).getByRole('button', { name: 'Bloquear' }))
    const bloqueados = await screen.findByRole('region', { name: 'Usuarios bloqueados' })
    expect(within(bloqueados).getByText('Bruno Demo')).toBeInTheDocument()
    expect(within(screen.getByRole('region', { name: 'Tus contactos' })).getByText('Bloqueado')).toBeInTheDocument()
  })
})
