import { Outlet, useParams } from 'react-router'
import { EstadoVacio } from '@/components/ui/Estados'
import { cn } from '@/lib/cn'
import { ListaConversaciones } from './ListaConversaciones'

/** Dos paneles en escritorio (lista + conversación); en móvil, uno u otro. */
export function DisenoChats() {
  const { conversacionId } = useParams()
  return (
    <div className="flex h-full">
      <section
        aria-label="Conversaciones"
        className={cn('w-full flex-col border-r border-borde bg-superficie md:flex md:w-lista md:shrink-0', conversacionId ? 'hidden' : 'flex')}
      >
        <ListaConversaciones />
      </section>
      <div className={cn('min-w-0 flex-1', conversacionId ? 'flex' : 'hidden md:flex')}>
        <Outlet />
      </div>
    </div>
  )
}

export function SinConversacion() {
  return (
    <div className="fondo-conversacion flex flex-1 items-center justify-center">
      <EstadoVacio icono="chats" titulo="Elige una conversación">
        Tus mensajes aparecerán aquí. Los nuevos llegan al instante.
      </EstadoVacio>
    </div>
  )
}
