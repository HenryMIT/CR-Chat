import { Link } from 'react-router'
import { EstadoVacio } from '@/components/ui/Estados'

export function NoEncontrada() {
  return (
    <main className="flex h-full items-center justify-center">
      <EstadoVacio
        icono="alerta"
        titulo="Página no encontrada"
        accion={
          <Link to="/chats" className="font-semibold text-primario underline-offset-4 hover:underline">
            Ir a tus chats
          </Link>
        }
      />
    </main>
  )
}
