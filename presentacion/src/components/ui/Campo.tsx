import { useId, useState, type InputHTMLAttributes, type ReactNode, type TextareaHTMLAttributes } from 'react'
import { cn } from '@/lib/cn'
import { Icono } from './Icono'

export const claseControl =
  'w-full rounded-control border border-borde bg-superficie px-3.5 text-base text-texto placeholder:text-tenue ' +
  'transition-colors focus-visible:border-primario focus-visible:outline-2 focus-visible:outline-offset-0 ' +
  'aria-invalid:border-peligro disabled:opacity-60'

interface PropsCampo extends InputHTMLAttributes<HTMLInputElement> {
  etiqueta: string
  error?: string | undefined
  ayuda?: ReactNode
  /** Botón para mostrar/ocultar la contraseña. */
  revelable?: boolean
}

/** Campo con etiqueta, ayuda y error asociados por aria-describedby. */
export function Campo({ etiqueta, error, ayuda, revelable, id, className, type, ...resto }: PropsCampo) {
  const generado = useId()
  const idCampo = id ?? generado
  const idAyuda = `${idCampo}-ayuda`
  const idError = `${idCampo}-error`
  const [visible, setVisible] = useState(false)
  const describe = [ayuda ? idAyuda : null, error ? idError : null].filter(Boolean).join(' ') || undefined

  return (
    <div className={cn('flex flex-col gap-1.5', className)}>
      <label htmlFor={idCampo} className="text-sm font-semibold text-texto">
        {etiqueta}
      </label>
      <div className="relative">
        <input
          id={idCampo}
          type={revelable && visible ? 'text' : type}
          aria-invalid={error ? true : undefined}
          aria-describedby={describe}
          className={cn(claseControl, 'h-11', revelable && 'pr-11')}
          {...resto}
        />
        {revelable && (
          <button
            type="button"
            onClick={() => {
              setVisible((v) => !v)
            }}
            aria-label={visible ? 'Ocultar contraseña' : 'Mostrar contraseña'}
            aria-pressed={visible}
            className="absolute inset-y-0 right-0 flex w-11 items-center justify-center text-tenue hover:text-texto"
          >
            <Icono nombre={visible ? 'ojoTachado' : 'ojo'} tamano={18} />
          </button>
        )}
      </div>
      {ayuda && !error && (
        <p id={idAyuda} className="text-xs text-tenue">
          {ayuda}
        </p>
      )}
      {error && (
        <p id={idError} className="flex items-center gap-1 text-xs font-medium text-peligro">
          <Icono nombre="alerta" tamano={14} />
          {error}
        </p>
      )}
    </div>
  )
}

interface PropsArea extends TextareaHTMLAttributes<HTMLTextAreaElement> {
  etiqueta: string
  error?: string | undefined
  ayuda?: ReactNode
}

export function CampoArea({ etiqueta, error, ayuda, id, className, ...resto }: PropsArea) {
  const generado = useId()
  const idCampo = id ?? generado
  const idAyuda = `${idCampo}-ayuda`
  const idError = `${idCampo}-error`
  const describe = [ayuda ? idAyuda : null, error ? idError : null].filter(Boolean).join(' ') || undefined
  return (
    <div className={cn('flex flex-col gap-1.5', className)}>
      <label htmlFor={idCampo} className="text-sm font-semibold text-texto">
        {etiqueta}
      </label>
      <textarea
        id={idCampo}
        aria-invalid={error ? true : undefined}
        aria-describedby={describe}
        className={cn(claseControl, 'min-h-20 resize-y py-2.5')}
        {...resto}
      />
      {ayuda && !error && (
        <p id={idAyuda} className="text-xs text-tenue">
          {ayuda}
        </p>
      )}
      {error && (
        <p id={idError} className="text-xs font-medium text-peligro">
          {error}
        </p>
      )}
    </div>
  )
}

/** Mensaje de error de formulario (anunciado al aparecer). */
export function ErrorFormulario({ children }: { children: ReactNode }) {
  return (
    <div role="alert" className="flex items-start gap-2 rounded-control bg-peligro-suave px-3.5 py-3 text-sm font-medium text-peligro">
      <Icono nombre="alerta" tamano={18} className="mt-px shrink-0" />
      <span>{children}</span>
    </div>
  )
}
