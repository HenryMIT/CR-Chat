import { useEffect, useState, type ReactNode } from 'react'
import { QueryClientProvider, type QueryClient } from '@tanstack/react-query'
import { createBrowserRouter } from 'react-router'
import { RouterProvider } from 'react-router/dom'
import { alCerrarSesion, arrancarSesion, iniciarSincronizacionPestanas } from '@/auth/sesion'
import { reiniciarEfimero } from '@/realtime/estadoEfimero'
import { escucharTemaSistema } from '@/lib/tema'
import { crearClienteConsultas } from './clienteConsultas'
import { rutas } from './rutas'

/** Proveedores comunes (también los usan las pruebas con un router en memoria). */
export function Proveedores({ cliente, children }: { cliente: QueryClient; children: ReactNode }) {
  useEffect(() => {
    // Al salir (aquí o en otra pestaña) no debe quedar nada del usuario en memoria.
    const dejar = alCerrarSesion(() => {
      cliente.clear()
      reiniciarEfimero()
    })
    return dejar
  }, [cliente])
  return <QueryClientProvider client={cliente}>{children}</QueryClientProvider>
}

const router = createBrowserRouter(rutas)

export function App() {
  const [cliente] = useState(crearClienteConsultas)

  useEffect(() => {
    const dejarPestanas = iniciarSincronizacionPestanas()
    const dejarTema = escucharTemaSistema()
    void arrancarSesion()
    return () => {
      dejarPestanas()
      dejarTema()
    }
  }, [])

  return (
    <Proveedores cliente={cliente}>
      <RouterProvider router={router} />
    </Proveedores>
  )
}
