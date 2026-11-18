import { Navigate, Outlet, useLocation } from 'react-router'
import { Boton } from '@/components/ui/Boton'
import { Cargando } from '@/components/ui/Spinner'
import { Logo } from '@/components/ui/Logo'
import { arrancarSesion, useAuth } from './sesion'

function PantallaArranque() {
  const error = useAuth((s) => s.errorArranque)
  return (
    <main className="flex h-full flex-col items-center justify-center gap-6 p-6">
      <Logo />
      {error ? (
        <div role="alert" className="flex flex-col items-center gap-3 text-center">
          <p className="max-w-xs text-sm text-tenue">{error}</p>
          <Boton variante="secundario" icono="reintentar" onClick={() => void arrancarSesion()}>
            Reintentar
          </Boton>
        </div>
      ) : (
        <Cargando texto="Recuperando tu sesión…" />
      )}
    </main>
  )
}

/** Rutas privadas: sin sesión redirige a /entrar recordando a dónde se quería ir. */
export function RequiereSesion() {
  const estado = useAuth((s) => s.estado)
  const ubicacion = useLocation()
  if (estado === 'iniciando') return <PantallaArranque />
  if (estado === 'anonimo') return <Navigate to="/entrar" replace state={{ desde: ubicacion.pathname }} />
  return <Outlet />
}

/** Rutas públicas (login/registro): con sesión se va directo a la app. */
export function SoloAnonimo() {
  const estado = useAuth((s) => s.estado)
  const ubicacion = useLocation()
  if (estado === 'iniciando') return <PantallaArranque />
  if (estado === 'autenticado') {
    const desde = (ubicacion.state as { desde?: string } | null)?.desde
    return <Navigate to={desde && desde !== '/entrar' ? desde : '/chats'} replace />
  }
  return <Outlet />
}
