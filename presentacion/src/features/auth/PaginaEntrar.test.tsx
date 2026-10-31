import { describe, expect, it } from 'vitest'
import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { arrancarSesion, useAuth } from '@/auth/sesion'
import { renderApp } from '@/test/utilidades'
import { validarRegistro } from './validacion'

describe('acceso', () => {
  it('una ruta protegida sin sesión redirige a /entrar', async () => {
    await arrancarSesion()
    const { router } = renderApp('/contactos')
    expect(await screen.findByRole('heading', { name: 'Bienvenida de vuelta' })).toBeInTheDocument()
    expect(router.state.location.pathname).toBe('/entrar')
  })

  it('valida campos vacíos y muestra el 401 de forma genérica', async () => {
    await arrancarSesion()
    const u = userEvent.setup()
    renderApp('/entrar')
    await u.click(await screen.findByRole('button', { name: 'Entrar' }))
    expect(screen.getByLabelText('Teléfono o correo')).toHaveAccessibleDescription(/Escribe tu teléfono o tu correo/)

    await u.type(screen.getByLabelText('Teléfono o correo'), '70000001')
    await u.type(screen.getByLabelText('Contraseña'), 'incorrecta')
    await u.click(screen.getByRole('button', { name: 'Entrar' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Teléfono, correo o contraseña incorrectos.')
  })

  it('entra con un teléfono local (se asume +506) y vuelve a la ruta pedida', async () => {
    await arrancarSesion()
    const u = userEvent.setup()
    const { router } = renderApp('/perfil')
    await u.type(await screen.findByLabelText('Teléfono o correo'), '70000001')
    await u.type(screen.getByLabelText('Contraseña'), 'Demo-Ana-2026!')
    await u.click(screen.getByRole('button', { name: 'Entrar' }))
    await waitFor(() => {
      expect(router.state.location.pathname).toBe('/perfil')
    })
    expect(useAuth.getState().usuario?.display_name).toBe('Ana Demo')
    expect(await screen.findByRole('heading', { name: 'Perfil', level: 1 })).toBeInTheDocument()
  })

  it('el botón de mostrar contraseña es accesible', async () => {
    await arrancarSesion()
    const u = userEvent.setup()
    renderApp('/entrar')
    const campo = await screen.findByLabelText('Contraseña')
    expect(campo).toHaveAttribute('type', 'password')
    await u.click(screen.getByRole('button', { name: 'Mostrar contraseña' }))
    expect(campo).toHaveAttribute('type', 'text')
    expect(screen.getByRole('button', { name: 'Ocultar contraseña' })).toHaveAttribute('aria-pressed', 'true')
  })
})

describe('validación del registro', () => {
  it('aplica las reglas del contrato', () => {
    const e = validarRegistro({ display_name: ' ', phone: '123', email: 'no-es', password: 'corta', confirmar: 'x' })
    expect(Object.keys(e).sort()).toEqual(['confirmar', 'display_name', 'email', 'password', 'phone'])
    expect(
      validarRegistro({ display_name: 'Dani', phone: '8888 0001', email: 'dani@ejemplo.cr', password: 'una frase larga', confirmar: 'una frase larga' }),
    ).toEqual({})
  })
})
