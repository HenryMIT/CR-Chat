import { render } from '@testing-library/react'
import { QueryClient } from '@tanstack/react-query'
import { createMemoryRouter } from 'react-router'
import { RouterProvider } from 'react-router/dom'
import { Proveedores } from '@/app/App'
import { rutas } from '@/app/rutas'
import { iniciarSesion } from '@/auth/sesion'

export const ANA = { telefono: '+50670000001', password: 'Demo-Ana-2026!' }

export function clientePruebas(): QueryClient {
  return new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity }, mutations: { retry: false } } })
}

/** Inicia sesión como Ana contra el MSW de pruebas. */
export async function entrarComoAna() {
  return iniciarSesion(ANA.telefono, ANA.password)
}

/** Monta la app completa con un router en memoria. */
export function renderApp(ruta: string, cliente = clientePruebas()) {
  const router = createMemoryRouter(rutas, { initialEntries: [ruta] })
  const utils = render(
    <Proveedores cliente={cliente}>
      <RouterProvider router={router} />
    </Proveedores>,
  )
  return { ...utils, router, cliente }
}
