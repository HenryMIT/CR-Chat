import { memo } from 'react'
import type { Media, MensajeChat } from '@/api/tipos'
import { Icono } from '@/components/ui/Icono'
import { Menu, type OpcionMenu } from '@/components/ui/Menu'
import { cn } from '@/lib/cn'
import { fechaCompleta, horaCorta, tamanoArchivo } from '@/lib/formato'
import { ReciboMensaje } from './ReciboMensaje'

/** Ventana de edición del contrato (15 min desde el envío). */
export const VENTANA_EDICION_MS = 15 * 60_000

function Adjunto({ media, mio }: { media: Media; mio: boolean }) {
  const tipo = media.content_type
  if (tipo.startsWith('image/')) {
    return (
      <a href={media.url} target="_blank" rel="noopener noreferrer" className="-mx-1.5 -mt-0.5 mb-1 block overflow-hidden rounded-xl">
        <img src={media.url} alt="Imagen adjunta" loading="lazy" className="max-h-72 w-full object-cover" />
      </a>
    )
  }
  if (tipo.startsWith('video/')) {
    return <video src={media.url} controls preload="metadata" className="-mx-1.5 mb-1 max-h-72 rounded-xl" aria-label="Vídeo adjunto" />
  }
  if (tipo.startsWith('audio/')) {
    return <audio src={media.url} controls preload="metadata" className="mb-1 max-w-full" aria-label="Audio adjunto" />
  }
  return (
    <a
      href={media.url}
      target="_blank"
      rel="noopener noreferrer"
      className={cn(
        'mb-1 flex items-center gap-3 rounded-xl px-3 py-2.5',
        mio ? 'bg-negro/15 hover:bg-negro/25' : 'bg-superficie-2 hover:bg-borde',
      )}
    >
      <Icono nombre="archivo" tamano={26} />
      <span className="flex flex-col">
        <span className="text-sm font-semibold">{tipo === 'application/pdf' ? 'Documento PDF' : 'Archivo'}</span>
        <span className="text-xs opacity-80">{tamanoArchivo(media.size_bytes)}</span>
      </span>
    </a>
  )
}

interface Props {
  mensaje: MensajeChat
  mio: boolean
  /** Mismo remitente que el anterior y poco tiempo después: se compacta. */
  agrupado: boolean
  nombreRemitente: string
  /** Reloj compartido (ms) para la ventana de edición; lo actualiza la lista. */
  ahora: number
  alEditar: (m: MensajeChat) => void
  alBorrar: (m: MensajeChat) => void
  alReintentar: (m: MensajeChat) => void
  alDescartar: (m: MensajeChat) => void
}

export const Burbuja = memo(function Burbuja({ mensaje: m, mio, agrupado, nombreRemitente, ahora, alEditar, alBorrar, alReintentar, alDescartar }: Props) {
  const borrado = m.deleted_at !== null
  const editable = mio && !borrado && !m.local && m.text !== null && ahora - new Date(m.created_at).getTime() < VENTANA_EDICION_MS
  const opciones: OpcionMenu[] = []
  if (mio && !borrado && !m.local) {
    if (editable) opciones.push({ etiqueta: 'Editar', icono: 'editar', alElegir: () => { alEditar(m) } })
    opciones.push({ etiqueta: 'Eliminar para todos', icono: 'papelera', peligro: true, alElegir: () => { alBorrar(m) } })
  }

  return (
    <li className={cn('group flex animate-aparecer', mio ? 'justify-end' : 'justify-start', agrupado ? 'mt-0.5' : 'mt-3')}>
      <div className={cn('flex max-w-[min(85%,38rem)] items-center gap-1', mio ? 'flex-row-reverse' : 'flex-row')}>
        <div
          className={cn(
            'relative min-w-0 rounded-burbuja px-3.5 py-2 shadow-suave',
            mio ? 'bg-burbuja-mia text-sobre-burbuja-mia' : 'bg-burbuja-otra text-sobre-burbuja-otra',
            !agrupado && (mio ? 'rounded-br-md' : 'rounded-bl-md'),
            m.local === 'enviando' && 'opacity-80',
          )}
        >
          <span className="sr-only">{mio ? 'Tú' : nombreRemitente}: </span>
          {borrado ? (
            <p className="flex items-center gap-1.5 text-sm italic opacity-80">
              <Icono nombre="bloquear" tamano={14} />
              Mensaje eliminado
            </p>
          ) : (
            <>
              {m.media && <Adjunto media={m.media} mio={mio} />}
              {m.text && <p className="text-base break-words whitespace-pre-wrap">{m.text}</p>}
            </>
          )}
          <span className={cn('mt-0.5 flex items-center justify-end gap-1 text-2xs', mio ? 'text-burbuja-mia-meta' : 'text-tenue')}>
            {m.edited_at && !borrado && <span>editado ·</span>}
            <time dateTime={m.created_at} title={fechaCompleta(m.created_at)}>
              {horaCorta(m.created_at)}
            </time>
            {mio && !borrado && <ReciboMensaje mensaje={m} />}
          </span>
        </div>

        {opciones.length > 0 && (
          <Menu
            etiqueta="Acciones del mensaje"
            opciones={opciones}
            lado="arriba"
            alinear={mio ? 'fin' : 'inicio'}
            className="opacity-0 transition-opacity group-hover:opacity-100 focus-within:opacity-100 [@media(hover:none)]:opacity-100"
          />
        )}
      </div>
      {m.local === 'fallido' && (
        <div className={cn('flex items-center gap-1 self-center text-xs', mio ? 'order-first mr-2' : 'ml-2')}>
          <button type="button" onClick={() => { alReintentar(m) }} className="rounded-full px-2 py-1 font-semibold text-peligro hover:bg-peligro-suave">
            Reintentar
          </button>
          <button type="button" onClick={() => { alDescartar(m) }} className="rounded-full px-2 py-1 text-tenue hover:bg-superficie-2">
            Descartar
          </button>
        </div>
      )}
    </li>
  )
})
