import { useRef, useState, type SyntheticEvent, type ReactNode } from 'react'
import { ApiError, mensajeDeError } from '@/api/errores'
import type { Me } from '@/api/tipos'
import { cerrarSesion } from '@/auth/sesion'
import { Avatar } from '@/components/ui/Avatar'
import { avisar } from '@/components/ui/Avisos'
import { Boton } from '@/components/ui/Boton'
import { Campo, CampoArea, ErrorFormulario } from '@/components/ui/Campo'
import { Dialogo } from '@/components/ui/Dialogo'
import { EstadoError } from '@/components/ui/Estados'
import { Icono } from '@/components/ui/Icono'
import { Cargando } from '@/components/ui/Spinner'
import { TIPOS_AVATAR, validarArchivo } from '@/features/subidas'
import { SelectorTema } from '@/layout/SelectorTema'
import { esTelefonoE164, normalizarTelefono, telefonoLegible, ultimaVez } from '@/lib/formato'
import {
  useActualizarPerfil,
  useCambiarAvatar,
  useCambiarPassword,
  useCambiarTelefono,
  useDesactivarCuenta,
  useRevocarOtras,
  useRevocarSesion,
  useSesiones,
  useYo,
} from './consultas'

function Tarjeta({ titulo, descripcion, children, id }: { titulo: string; descripcion?: string; children: ReactNode; id: string }) {
  return (
    <section aria-labelledby={id} className="rounded-tarjeta border border-borde bg-superficie p-5 shadow-suave sm:p-6">
      <h2 id={id} className="text-lg font-bold">
        {titulo}
      </h2>
      {descripcion && <p className="mt-0.5 text-sm text-tenue">{descripcion}</p>}
      <div className="mt-4">{children}</div>
    </section>
  )
}

function Cabecera({ yo }: { yo: Me }) {
  const selector = useRef<HTMLInputElement>(null)
  const avatar = useCambiarAvatar()
  return (
    <div className="flex flex-col items-center gap-3 text-center sm:flex-row sm:text-left">
      <div className="relative">
        <Avatar nombre={yo.display_name} semilla={yo.id} media={yo.avatar} tamano="xl" />
        <input
          ref={selector}
          type="file"
          accept={TIPOS_AVATAR.join(',')}
          className="sr-only"
          tabIndex={-1}
          aria-hidden="true"
          onChange={(e) => {
            const f = e.target.files?.[0]
            e.target.value = ''
            if (!f) return
            const error = validarArchivo(f, 'avatar')
            if (error) {
              avisar(error, 'error')
              return
            }
            avatar.mutate(f, {
              onSuccess: () => {
                avisar('Foto actualizada.')
              },
              onError: (err) => {
                avisar(mensajeDeError(err), 'error')
              },
            })
          }}
        />
        <button
          type="button"
          aria-label="Cambiar foto de perfil"
          title="Cambiar foto"
          disabled={avatar.isPending}
          onClick={() => selector.current?.click()}
          className="absolute -right-1 -bottom-1 flex size-9 items-center justify-center rounded-full border-2 border-superficie bg-primario text-sobre-primario shadow-suave"
        >
          <Icono nombre="camara" tamano={17} />
        </button>
      </div>
      <div className="flex flex-col gap-0.5">
        <p className="text-2xl font-extrabold tracking-tight">{yo.display_name}</p>
        <p className="text-sm text-tenue">
          {telefonoLegible(yo.phone)} · {yo.email}
        </p>
        {yo.avatar && (
          <button
            type="button"
            className="self-center text-sm font-semibold text-primario underline-offset-4 hover:underline sm:self-start"
            onClick={() => {
              avatar.mutate(null, {
                onSuccess: () => {
                  avisar('Foto eliminada.')
                },
              })
            }}
          >
            Quitar foto
          </button>
        )}
      </div>
    </div>
  )
}

function FormularioPerfil({ yo }: { yo: Me }) {
  const [nombre, setNombre] = useState(yo.display_name)
  const [about, setAbout] = useState(yo.about ?? '')
  const actualizar = useActualizarPerfil()
  const error = actualizar.error instanceof ApiError ? actualizar.error.campos : {}
  return (
    <form
      noValidate
      className="flex flex-col gap-4"
      onSubmit={(e) => {
        e.preventDefault()
        if (!nombre.trim()) return
        actualizar.mutate(
          { display_name: nombre.trim(), about: about.trim() || null },
          {
            onSuccess: () => {
              avisar('Perfil guardado.')
            },
          },
        )
      }}
    >
      {actualizar.error && !(actualizar.error instanceof ApiError && actualizar.error.status === 422) && (
        <ErrorFormulario>{mensajeDeError(actualizar.error)}</ErrorFormulario>
      )}
      <Campo
        etiqueta="Nombre"
        maxLength={50}
        value={nombre}
        onChange={(e) => {
          setNombre(e.target.value)
        }}
        error={!nombre.trim() ? 'El nombre no puede estar vacío.' : error.display_name}
      />
      <CampoArea
        etiqueta="Info"
        maxLength={140}
        rows={2}
        value={about}
        onChange={(e) => {
          setAbout(e.target.value)
        }}
        error={error.about}
        ayuda={`${about.length} / 140`}
      />
      <Boton type="submit" className="self-end" cargando={actualizar.isPending}>
        Guardar
      </Boton>
    </form>
  )
}

function FormularioPassword() {
  const [actual, setActual] = useState('')
  const [nueva, setNueva] = useState('')
  const [repetir, setRepetir] = useState('')
  const [local, setLocal] = useState<string>()
  const cambiar = useCambiarPassword()
  const enviar = (e: SyntheticEvent) => {
    e.preventDefault()
    if (nueva.length < 10 || nueva.length > 128) {
      setLocal('La nueva contraseña debe tener entre 10 y 128 caracteres.')
      return
    }
    if (nueva !== repetir) {
      setLocal('Las contraseñas no coinciden.')
      return
    }
    setLocal(undefined)
    cambiar.mutate(
      { current_password: actual, new_password: nueva },
      {
        onSuccess: () => {
          avisar('Contraseña cambiada. Cerramos tus otras sesiones.')
          setActual('')
          setNueva('')
          setRepetir('')
        },
      },
    )
  }
  const errorServidor =
    cambiar.error instanceof ApiError && cambiar.error.status === 403 ? 'La contraseña actual no es correcta.' : cambiar.error ? mensajeDeError(cambiar.error) : null
  return (
    <form noValidate onSubmit={enviar} className="flex flex-col gap-4">
      <h3 className="text-base font-bold">Cambiar contraseña</h3>
      {(local ?? errorServidor) && <ErrorFormulario>{local ?? errorServidor}</ErrorFormulario>}
      <Campo etiqueta="Contraseña actual" type="password" autoComplete="current-password" revelable value={actual} onChange={(e) => { setActual(e.target.value) }} required />
      <Campo etiqueta="Nueva contraseña" type="password" autoComplete="new-password" revelable value={nueva} onChange={(e) => { setNueva(e.target.value) }} ayuda="Entre 10 y 128 caracteres." required />
      <Campo etiqueta="Repite la nueva contraseña" type="password" autoComplete="new-password" value={repetir} onChange={(e) => { setRepetir(e.target.value) }} required />
      <Boton type="submit" variante="secundario" className="self-end" cargando={cambiar.isPending} disabled={!actual || !nueva}>
        Cambiar contraseña
      </Boton>
    </form>
  )
}

function FormularioTelefono() {
  const [telefono, setTelefono] = useState('')
  const [password, setPassword] = useState('')
  const [local, setLocal] = useState<string>()
  const cambiar = useCambiarTelefono()
  const enviar = (e: SyntheticEvent) => {
    e.preventDefault()
    const phone = normalizarTelefono(telefono)
    if (!esTelefonoE164(phone)) {
      setLocal('Número no válido. Ejemplo: 8888 0001 o +50688880001.')
      return
    }
    setLocal(undefined)
    cambiar.mutate(
      { phone, current_password: password },
      {
        onSuccess: () => {
          avisar('Teléfono actualizado.')
          setTelefono('')
          setPassword('')
        },
      },
    )
  }
  const errorServidor =
    cambiar.error instanceof ApiError && cambiar.error.status === 403
      ? 'La contraseña actual no es correcta.'
      : cambiar.error instanceof ApiError && cambiar.error.status === 409
        ? 'Ese número no está disponible.'
        : cambiar.error
          ? mensajeDeError(cambiar.error)
          : null
  return (
    <form noValidate onSubmit={enviar} className="flex flex-col gap-4">
      <h3 className="text-base font-bold">Cambiar teléfono</h3>
      {(local ?? errorServidor) && <ErrorFormulario>{local ?? errorServidor}</ErrorFormulario>}
      <Campo etiqueta="Nuevo teléfono" type="tel" inputMode="tel" autoComplete="tel" value={telefono} onChange={(e) => { setTelefono(e.target.value) }} required />
      <Campo etiqueta="Contraseña actual" type="password" autoComplete="current-password" revelable value={password} onChange={(e) => { setPassword(e.target.value) }} required />
      <Boton type="submit" variante="secundario" className="self-end" cargando={cambiar.isPending} disabled={!telefono || !password}>
        Cambiar teléfono
      </Boton>
    </form>
  )
}

function Sesiones() {
  const sesiones = useSesiones()
  const revocar = useRevocarSesion()
  const revocarOtras = useRevocarOtras()
  if (sesiones.isPending) return <Cargando texto="Cargando sesiones…" />
  if (sesiones.isError) return <EstadoError error={sesiones.error} alReintentar={() => void sesiones.refetch()} />
  const otras = sesiones.data.filter((s) => !s.current)
  return (
    <div className="flex flex-col gap-3">
      <ul className="flex flex-col divide-y divide-borde">
        {sesiones.data.map((s) => (
          <li key={s.id} className="flex items-center gap-3 py-3">
            <span className="flex size-10 shrink-0 items-center justify-center rounded-control bg-superficie-2 text-tenue">
              <Icono nombre="dispositivo" />
            </span>
            <div className="min-w-0 flex-1">
              <p className="flex flex-wrap items-center gap-2 font-semibold">
                {s.device_name}
                {s.current && <span className="rounded-full bg-primario-suave px-2 text-2xs font-bold text-primario">Esta sesión</span>}
              </p>
              <p className="text-xs text-tenue">
                {s.current ? 'Activa ahora' : `Último uso ${ultimaVez(s.last_used_at)}`}
                {s.ip_hint ? ` · ${s.ip_hint}` : ''}
              </p>
            </div>
            {!s.current && (
              <Boton
                variante="fantasma"
                tamano="sm"
                aria-label={`Cerrar sesión en ${s.device_name}`}
                cargando={revocar.isPending && revocar.variables === s.id}
                onClick={() => {
                  revocar.mutate(s.id, {
                    onSuccess: () => {
                      avisar(`Sesión cerrada en ${s.device_name}.`)
                    },
                  })
                }}
              >
                Cerrar
              </Boton>
            )}
          </li>
        ))}
      </ul>
      {otras.length > 0 && (
        <Boton
          variante="secundario"
          icono="salir"
          className="self-start"
          cargando={revocarOtras.isPending}
          onClick={() => {
            revocarOtras.mutate(undefined, {
              onSuccess: () => {
                avisar('Cerraste las demás sesiones.')
              },
            })
          }}
        >
          Cerrar las demás sesiones
        </Boton>
      )}
    </div>
  )
}

function ZonaPeligro() {
  const [abierto, setAbierto] = useState(false)
  const [password, setPassword] = useState('')
  const desactivar = useDesactivarCuenta()
  const error =
    desactivar.error instanceof ApiError && desactivar.error.status === 403 ? 'La contraseña no es correcta.' : desactivar.error ? mensajeDeError(desactivar.error) : null
  return (
    <>
      <p className="text-sm text-tenue">
        Desactiva tu cuenta y cierra todas tus sesiones. Tienes 30 días para reactivarla antes de que se borren tus datos.
      </p>
      <Boton
        variante="peligro"
        className="mt-3"
        onClick={() => {
          setAbierto(true)
        }}
      >
        Desactivar cuenta
      </Boton>
      <Dialogo
        abierto={abierto}
        alCerrar={() => {
          setAbierto(false)
          setPassword('')
          desactivar.reset()
        }}
        titulo="¿Desactivar tu cuenta?"
        descripcion="Confirma con tu contraseña. Se cerrarán todas tus sesiones."
      >
        <form
          noValidate
          className="flex flex-col gap-4"
          onSubmit={(e) => {
            e.preventDefault()
            desactivar.mutate(password)
          }}
        >
          {error && <ErrorFormulario>{error}</ErrorFormulario>}
          <Campo etiqueta="Contraseña" type="password" autoComplete="current-password" revelable value={password} onChange={(e) => { setPassword(e.target.value) }} autoFocus />
          <div className="flex justify-end gap-2">
            <Boton variante="secundario" onClick={() => { setAbierto(false) }}>
              Cancelar
            </Boton>
            <Boton type="submit" variante="peligro" cargando={desactivar.isPending} disabled={!password}>
              Desactivar
            </Boton>
          </div>
        </form>
      </Dialogo>
    </>
  )
}

export function PaginaPerfil() {
  const yo = useYo()
  const [saliendo, setSaliendo] = useState(false)
  return (
    <div className="h-full overflow-y-auto">
      <div className="mx-auto flex max-w-2xl flex-col gap-5 px-4 pt-4 pb-10">
        <h1 className="text-2xl font-extrabold tracking-tight">Perfil</h1>
        {yo.isPending ? (
          <Cargando />
        ) : yo.isError ? (
          <EstadoError error={yo.error} alReintentar={() => void yo.refetch()} />
        ) : (
          <>
            <Cabecera yo={yo.data} />
            <Tarjeta id="t-datos" titulo="Datos del perfil" descripcion="Así te ven tus contactos.">
              <FormularioPerfil key={yo.data.id} yo={yo.data} />
            </Tarjeta>
            <Tarjeta id="t-apariencia" titulo="Apariencia">
              <SelectorTema />
            </Tarjeta>
            <Tarjeta id="t-seguridad" titulo="Seguridad" descripcion="Cambiar la contraseña o el teléfono cierra tus otras sesiones.">
              <div className="flex flex-col gap-8">
                <FormularioPassword />
                <FormularioTelefono />
              </div>
            </Tarjeta>
            <Tarjeta id="t-sesiones" titulo="Sesiones activas" descripcion="Dispositivos donde tu cuenta está abierta.">
              <Sesiones />
            </Tarjeta>
            <Boton
              variante="secundario"
              icono="salir"
              tamano="lg"
              cargando={saliendo}
              onClick={() => {
                setSaliendo(true)
                void cerrarSesion()
              }}
            >
              Cerrar sesión
            </Boton>
            <Tarjeta id="t-peligro" titulo="Zona de peligro">
              <ZonaPeligro />
            </Tarjeta>
          </>
        )}
      </div>
    </div>
  )
}
