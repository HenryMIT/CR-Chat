import type { MensajeChat } from '@/api/tipos'
import { Icono } from '@/components/ui/Icono'
import { cn } from '@/lib/cn'

/** Texto del estado de un mensaje propio (también para lectores de pantalla). */
function textoEstado(m: MensajeChat): string {
  if (m.local === 'enviando') return 'Enviando'
  if (m.local === 'fallido') return 'No enviado'
  if (m.status === 'seen') return 'Visto'
  if (m.status === 'delivered') return 'Entregado'
  return 'Enviado'
}

/**
 * Indicador de recibo: reloj = enviando, ✓ tenue = enviado, ✓ = entregado,
 * ✓✓ en color de acento = visto, alerta = no enviado.
 */
export function ReciboMensaje({ mensaje, className }: { mensaje: MensajeChat; className?: string }) {
  const texto = textoEstado(mensaje)
  const icono =
    mensaje.local === 'enviando'
      ? 'reloj'
      : mensaje.local === 'fallido'
        ? 'alerta'
        : mensaje.status === 'seen'
          ? 'checkDoble'
          : 'check'
  return (
    <span
      role="img"
      aria-label={texto}
      title={texto}
      data-estado={mensaje.local ?? mensaje.status ?? 'sent'}
      className={cn(
        'inline-flex shrink-0',
        mensaje.status === 'seen' && !mensaje.local && 'text-visto',
        (mensaje.status === 'sent' || !mensaje.status) && !mensaje.local && 'opacity-60',
        mensaje.local === 'fallido' && 'text-peligro',
        className,
      )}
    >
      <Icono nombre={icono} tamano={15} strokeWidth={2.25} />
    </span>
  )
}
