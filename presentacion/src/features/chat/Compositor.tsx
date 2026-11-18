import { useRef, useState, type SyntheticEvent, type KeyboardEvent } from 'react'
import type { MensajeChat } from '@/api/tipos'
import { BotonIcono } from '@/components/ui/Boton'
import { Icono } from '@/components/ui/Icono'
import { cn } from '@/lib/cn'
import { tamanoArchivo } from '@/lib/formato'
import { nuevoUuid } from '@/lib/uuid'
import { TIPOS_ADJUNTO, validarArchivo } from '@/features/subidas'
import { useEditarMensaje, useEnviarMensaje } from './consultas'
import { useSenalEscribiendo } from './useSenalEscribiendo'

const MAX_TEXTO = 4000
const ALTURA_MAX_PX = 160

interface Props {
  conversacionId: string
  /** Mensaje en edición. El padre remonta el compositor (key) al entrar o salir de edición. */
  editando: MensajeChat | null
  alTerminarEdicion: () => void
}

export function Compositor({ conversacionId, editando, alTerminarEdicion }: Props) {
  const [texto, setTexto] = useState(editando?.text ?? '')
  const [archivo, setArchivo] = useState<File | null>(null)
  const [errorArchivo, setErrorArchivo] = useState<string | null>(null)
  const area = useRef<HTMLTextAreaElement>(null)
  const selector = useRef<HTMLInputElement>(null)
  const enviar = useEnviarMensaje(conversacionId)
  const editar = useEditarMensaje(conversacionId)
  const senal = useSenalEscribiendo(conversacionId)

  const ajustarAltura = () => {
    const el = area.current
    if (!el) return
    el.style.height = 'auto'
    el.style.height = `${Math.min(el.scrollHeight, ALTURA_MAX_PX)}px`
  }

  const limpiar = () => {
    setTexto('')
    setArchivo(null)
    setErrorArchivo(null)
    requestAnimationFrame(ajustarAltura)
  }

  const confirmar = (e?: SyntheticEvent) => {
    e?.preventDefault()
    const limpio = texto.trim()
    if (editando) {
      if (limpio && limpio !== editando.text) editar.mutate({ id: editando.id, texto: limpio })
      alTerminarEdicion()
      return
    }
    if (!limpio && !archivo) return
    senal.detener()
    enviar.mutate({ clientId: nuevoUuid(), texto: limpio || undefined, archivo: archivo ?? undefined })
    limpiar()
    area.current?.focus()
  }

  const teclas = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) {
      e.preventDefault()
      confirmar()
    } else if (e.key === 'Escape' && editando) {
      e.preventDefault()
      alTerminarEdicion()
    }
  }

  const puedeEnviar = texto.trim().length > 0 || (archivo !== null && !editando)

  return (
    <form onSubmit={confirmar} className="border-t border-borde bg-superficie px-3 pt-2 pb-[max(0.5rem,env(safe-area-inset-bottom))] sm:px-4">
      {editando && (
        <div className="mb-2 flex items-center justify-between gap-2 rounded-control bg-primario-suave px-3 py-2 text-sm">
          <span className="flex min-w-0 items-center gap-2 text-primario">
            <Icono nombre="editar" tamano={16} />
            <span className="truncate">
              <strong>Editando:</strong> {editando.text}
            </span>
          </span>
          <button type="button" onClick={alTerminarEdicion} className="shrink-0 font-semibold text-primario underline-offset-4 hover:underline">
            Cancelar
          </button>
        </div>
      )}
      {archivo && (
        <div className="mb-2 flex items-center justify-between gap-2 rounded-control border border-borde px-3 py-2 text-sm">
          <span className="flex min-w-0 items-center gap-2">
            <Icono nombre={archivo.type.startsWith('image/') ? 'camara' : 'archivo'} tamano={18} />
            <span className="truncate font-medium">{archivo.name}</span>
            <span className="shrink-0 text-tenue">{tamanoArchivo(archivo.size)}</span>
          </span>
          <BotonIcono
            icono="cerrar"
            etiqueta="Quitar adjunto"
            tamano={16}
            className="size-8"
            onClick={() => {
              setArchivo(null)
            }}
          />
        </div>
      )}
      {errorArchivo && (
        <p role="alert" className="mb-2 text-xs font-medium text-peligro">
          {errorArchivo}
        </p>
      )}

      <div className="flex items-end gap-2">
        {!editando && (
          <>
            <input
              ref={selector}
              type="file"
              accept={TIPOS_ADJUNTO.join(',')}
              className="sr-only"
              tabIndex={-1}
              aria-hidden="true"
              onChange={(e) => {
                const f = e.target.files?.[0]
                e.target.value = ''
                if (!f) return
                const error = validarArchivo(f, 'message')
                setErrorArchivo(error)
                setArchivo(error ? null : f)
              }}
            />
            <BotonIcono icono="clip" etiqueta="Adjuntar archivo" onClick={() => selector.current?.click()} className="mb-0.5" />
          </>
        )}
        <label className="flex min-w-0 flex-1">
          <span className="sr-only">{editando ? 'Editar mensaje' : 'Escribe un mensaje'}</span>
          <textarea
            ref={area}
            rows={1}
            value={texto}
            maxLength={MAX_TEXTO}
            autoFocus={editando !== null}
            placeholder={editando ? 'Edita tu mensaje' : 'Escribe un mensaje'}
            onChange={(e) => {
              setTexto(e.target.value)
              ajustarAltura()
              if (!editando && e.target.value) senal.tecleo()
            }}
            onKeyDown={teclas}
            onBlur={senal.detener}
            className="max-h-40 min-h-11 w-full resize-none rounded-[1.375rem] border border-borde bg-superficie-2 px-4 py-2.5 text-base text-texto placeholder:text-tenue focus-visible:border-primario focus-visible:outline-2 focus-visible:outline-offset-0"
          />
        </label>
        <BotonIcono
          type="submit"
          icono={editando ? 'check' : 'enviar'}
          etiqueta={editando ? 'Guardar cambios' : 'Enviar'}
          variante="primario"
          disabled={!puedeEnviar}
          className={cn('mb-0.5 size-11', !puedeEnviar && 'opacity-50')}
        />
      </div>
      {texto.length > MAX_TEXTO - 500 && (
        <p className="mt-1 text-right text-2xs text-tenue" aria-live="polite">
          {texto.length} / {MAX_TEXTO}
        </p>
      )}
    </form>
  )
}
