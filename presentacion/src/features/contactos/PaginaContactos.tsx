import { useEffect, useState, type SyntheticEvent } from 'react'
import { useNavigate, useSearchParams } from 'react-router'
import { ApiError, mensajeDeError } from '@/api/errores'
import type { Contacto } from '@/api/tipos'
import { Avatar } from '@/components/ui/Avatar'
import { avisar } from '@/components/ui/Avisos'
import { Boton } from '@/components/ui/Boton'
import { Campo, claseControl, ErrorFormulario } from '@/components/ui/Campo'
import { Dialogo } from '@/components/ui/Dialogo'
import { EsqueletoLista, EstadoError, EstadoVacio } from '@/components/ui/Estados'
import { Icono } from '@/components/ui/Icono'
import { Menu } from '@/components/ui/Menu'
import { useIniciarConversacion } from '@/features/conversaciones/consultas'
import { cn } from '@/lib/cn'
import { esTelefonoE164, normalizarTelefono, telefonoLegible } from '@/lib/formato'
import { useBloqueos, useBloquear, useBorrarContacto, useContactos, useCrearContacto, useEditarAlias } from './consultas'

function useRetrasado<T>(valor: T, ms: number): T {
  const [v, setV] = useState(valor)
  useEffect(() => {
    const t = setTimeout(() => {
      setV(valor)
    }, ms)
    return () => {
      clearTimeout(t)
    }
  }, [valor, ms])
  return v
}

function nombreContacto(c: Contacto): string {
  return c.alias ?? c.user.display_name
}

function DialogoAgregar({ abierto, alCerrar }: { abierto: boolean; alCerrar: () => void }) {
  const [telefono, setTelefono] = useState('')
  const [alias, setAlias] = useState('')
  const [errorTel, setErrorTel] = useState<string>()
  const crear = useCrearContacto()

  const cerrar = () => {
    setTelefono('')
    setAlias('')
    setErrorTel(undefined)
    crear.reset()
    alCerrar()
  }

  const enviar = (e: SyntheticEvent) => {
    e.preventDefault()
    const phone = normalizarTelefono(telefono)
    if (!esTelefonoE164(phone)) {
      setErrorTel('Número no válido. Ejemplo: 8888 0001 o +50688880001.')
      return
    }
    setErrorTel(undefined)
    crear.mutate(
      { phone, ...(alias.trim() ? { alias: alias.trim() } : {}) },
      {
        onSuccess: ({ contacto, creado }) => {
          avisar(creado ? `${nombreContacto(contacto)} se agregó a tus contactos.` : `${nombreContacto(contacto)} ya estaba en tus contactos.`)
          cerrar()
        },
      },
    )
  }

  const error = crear.error
  const texto =
    error instanceof ApiError && error.status === 404
      ? 'No encontramos a nadie con ese número en CR_Chat.'
      : error instanceof ApiError && error.status === 422
        ? (error.campos.phone ?? error.campos.alias ?? mensajeDeError(error))
        : error
          ? mensajeDeError(error)
          : null

  return (
    <Dialogo abierto={abierto} alCerrar={cerrar} titulo="Agregar contacto" descripcion="Busca a la persona por su número de teléfono.">
      <form onSubmit={enviar} noValidate className="flex flex-col gap-4">
        {texto && <ErrorFormulario>{texto}</ErrorFormulario>}
        <Campo
          etiqueta="Teléfono"
          type="tel"
          inputMode="tel"
          autoComplete="off"
          placeholder="8888 0001"
          value={telefono}
          onChange={(e) => {
            setTelefono(e.target.value)
          }}
          error={errorTel}
          ayuda="Sin código de país se asume Costa Rica (+506)."
          autoFocus
        />
        <Campo
          etiqueta="Alias (opcional)"
          maxLength={50}
          value={alias}
          onChange={(e) => {
            setAlias(e.target.value)
          }}
          placeholder="Cómo quieres verlo en tu lista"
        />
        <div className="flex justify-end gap-2">
          <Boton variante="secundario" onClick={cerrar}>
            Cancelar
          </Boton>
          <Boton type="submit" icono="agregar" cargando={crear.isPending}>
            Agregar
          </Boton>
        </div>
      </form>
    </Dialogo>
  )
}

function DialogoAlias({ contacto, alCerrar }: { contacto: Contacto | null; alCerrar: () => void }) {
  const [alias, setAlias] = useState(contacto?.alias ?? '')
  const editar = useEditarAlias()
  return (
    <Dialogo abierto={contacto !== null} alCerrar={alCerrar} titulo="Editar alias" descripcion="Déjalo vacío para usar el nombre de la persona.">
      <form
        noValidate
        className="flex flex-col gap-4"
        onSubmit={(e) => {
          e.preventDefault()
          if (!contacto) return
          editar.mutate(
            { id: contacto.id, alias: alias.trim() || null },
            {
              onSuccess: () => {
                avisar('Alias actualizado.')
                alCerrar()
              },
            },
          )
        }}
      >
        {editar.error && <ErrorFormulario>{mensajeDeError(editar.error)}</ErrorFormulario>}
        <Campo
          etiqueta="Alias"
          maxLength={50}
          value={alias}
          placeholder={contacto?.user.display_name}
          onChange={(e) => {
            setAlias(e.target.value)
          }}
          autoFocus
        />
        <div className="flex justify-end gap-2">
          <Boton variante="secundario" onClick={alCerrar}>
            Cancelar
          </Boton>
          <Boton type="submit" cargando={editar.isPending}>
            Guardar
          </Boton>
        </div>
      </form>
    </Dialogo>
  )
}

function ElementoContacto({
  c,
  alEditar,
  alEliminar,
  alBloquear,
}: {
  c: Contacto
  alEditar: () => void
  alEliminar: () => void
  alBloquear: () => void
}) {
  const navegar = useNavigate()
  const iniciar = useIniciarConversacion()
  const nombre = nombreContacto(c)
  const abrirChat = () => {
    if (c.conversation_id) {
      void navegar(`/chats/${c.conversation_id}`)
      return
    }
    iniciar.mutate(c.id, {
      onSuccess: (conv) => void navegar(`/chats/${conv.id}`),
      onError: (e) => {
        avisar(mensajeDeError(e), 'error')
      },
    })
  }
  return (
    <li className="flex items-center gap-3 rounded-control px-3 py-2.5 hover:bg-superficie-2">
      <Avatar nombre={c.user.display_name} semilla={c.user.id} media={c.user.avatar} />
      <div className="min-w-0 flex-1">
        <p className="flex items-center gap-2 truncate font-semibold">
          {nombre}
          {c.blocked && <span className="rounded-full bg-peligro-suave px-2 text-2xs font-bold text-peligro">Bloqueado</span>}
        </p>
        <p className="truncate text-sm text-tenue">
          {c.alias && c.alias !== c.user.display_name ? `${c.user.display_name} · ` : ''}
          {telefonoLegible(c.phone)}
        </p>
      </div>
      {!c.blocked && (
        <Boton variante="secundario" tamano="sm" icono="chats" cargando={iniciar.isPending} onClick={abrirChat} aria-label={`Enviar mensaje a ${nombre}`}>
          <span className="hidden sm:inline">Mensaje</span>
        </Boton>
      )}
      <Menu
        etiqueta={`Opciones de ${nombre}`}
        opciones={[
          { etiqueta: 'Editar alias', icono: 'editar', alElegir: alEditar },
          { etiqueta: c.blocked ? 'Desbloquear' : 'Bloquear', icono: 'bloquear', peligro: !c.blocked, alElegir: alBloquear },
          { etiqueta: 'Eliminar contacto', icono: 'papelera', peligro: true, alElegir: alEliminar },
        ]}
      />
    </li>
  )
}

function SeccionBloqueados() {
  const consulta = useBloqueos()
  const bloquear = useBloquear()
  const bloqueos = consulta.data?.pages.flatMap((p) => p.items) ?? []
  if (consulta.isPending || bloqueos.length === 0) return null
  return (
    <section aria-labelledby="titulo-bloqueados" className="mt-6">
      <h2 id="titulo-bloqueados" className="px-3 pb-2 text-xs font-bold tracking-wide text-tenue uppercase">
        Usuarios bloqueados
      </h2>
      <ul className="flex flex-col gap-0.5">
        {bloqueos.map((b) => (
          <li key={b.user.id} className="flex items-center gap-3 rounded-control px-3 py-2.5">
            <Avatar nombre={b.user.display_name} semilla={b.user.id} media={b.user.avatar} tamano="sm" />
            <span className="min-w-0 flex-1 truncate font-medium">{b.user.display_name}</span>
            <Boton
              variante="secundario"
              tamano="sm"
              onClick={() => {
                bloquear.mutate(
                  { usuarioId: b.user.id, bloquear: false },
                  {
                    onSuccess: () => {
                      avisar(`Desbloqueaste a ${b.user.display_name}.`)
                    },
                  },
                )
              }}
            >
              Desbloquear
            </Boton>
          </li>
        ))}
      </ul>
    </section>
  )
}

export function PaginaContactos() {
  const [parametros, setParametros] = useSearchParams()
  const [busqueda, setBusqueda] = useState('')
  const q = useRetrasado(busqueda, 300)
  const consulta = useContactos(q)
  const [agregar, setAgregar] = useState(parametros.get('agregar') === '1')
  const [editarAlias, setEditarAlias] = useState<Contacto | null>(null)
  const [aEliminar, setAEliminar] = useState<Contacto | null>(null)
  const [aBloquear, setABloquear] = useState<Contacto | null>(null)
  const borrar = useBorrarContacto()
  const bloquear = useBloquear()
  const contactos = consulta.data?.pages.flatMap((p) => p.items) ?? []

  const alternarBloqueo = (c: Contacto) => {
    const nuevo = !c.blocked
    bloquear.mutate(
      { usuarioId: c.user.id, bloquear: nuevo },
      {
        onSuccess: () => {
          avisar(nuevo ? `Bloqueaste a ${nombreContacto(c)}.` : `Desbloqueaste a ${nombreContacto(c)}.`)
          setABloquear(null)
        },
        onError: (e) => {
          avisar(mensajeDeError(e), 'error')
        },
      },
    )
  }

  return (
    <div className="h-full overflow-y-auto">
      <div className="mx-auto flex max-w-2xl flex-col px-2 pt-4 pb-8 sm:px-4">
        <header className="flex items-center justify-between gap-3 px-2 pb-3">
          <h1 className="text-2xl font-extrabold tracking-tight">Contactos</h1>
          <Boton
            icono="agregar"
            onClick={() => {
              setAgregar(true)
            }}
          >
            Agregar
          </Boton>
        </header>
        <div className="px-2 pb-3">
          <label className="relative block">
            <span className="sr-only">Buscar por nombre, alias o teléfono</span>
            <Icono nombre="buscar" tamano={18} className="pointer-events-none absolute top-1/2 left-3 -translate-y-1/2 text-tenue" />
            <input
              type="search"
              value={busqueda}
              onChange={(e) => {
                setBusqueda(e.target.value)
              }}
              maxLength={50}
              placeholder="Buscar por nombre, alias o teléfono"
              className={cn(claseControl, 'h-11 pl-9')}
            />
          </label>
        </div>

        <section aria-label="Tus contactos" aria-busy={consulta.isFetching}>
          {consulta.isPending ? (
            <EsqueletoLista etiqueta="Cargando contactos" />
          ) : consulta.isError ? (
            <EstadoError error={consulta.error} alReintentar={() => void consulta.refetch()} />
          ) : contactos.length === 0 ? (
            q ? (
              <EstadoVacio icono="buscar" titulo="Sin resultados">
                Nadie coincide con «{q}».
              </EstadoVacio>
            ) : (
              <EstadoVacio
                icono="contactos"
                titulo="Tu agenda está vacía"
                accion={
                  <Boton
                    icono="agregar"
                    onClick={() => {
                      setAgregar(true)
                    }}
                  >
                    Agregar contacto
                  </Boton>
                }
              >
                Agrega a alguien por su número para empezar a chatear.
              </EstadoVacio>
            )
          ) : (
            <>
              <p className="sr-only" aria-live="polite">
                {contactos.length === 1 ? '1 contacto' : `${contactos.length} contactos`}
              </p>
              <ul className="flex flex-col gap-0.5">
                {contactos.map((c) => (
                  <ElementoContacto
                    key={c.id}
                    c={c}
                    alEditar={() => {
                      setEditarAlias(c)
                    }}
                    alEliminar={() => {
                      setAEliminar(c)
                    }}
                    alBloquear={() => {
                      if (c.blocked) alternarBloqueo(c)
                      else setABloquear(c)
                    }}
                  />
                ))}
              </ul>
              {consulta.hasNextPage && (
                <div className="flex justify-center py-3">
                  <Boton variante="fantasma" tamano="sm" cargando={consulta.isFetchingNextPage} onClick={() => void consulta.fetchNextPage()}>
                    Cargar más
                  </Boton>
                </div>
              )}
            </>
          )}
        </section>

        <SeccionBloqueados />
      </div>

      <DialogoAgregar
        abierto={agregar}
        alCerrar={() => {
          setAgregar(false)
          if (parametros.has('agregar')) setParametros({}, { replace: true })
        }}
      />
      <DialogoAlias
        key={editarAlias?.id ?? 'ninguno'}
        contacto={editarAlias}
        alCerrar={() => {
          setEditarAlias(null)
        }}
      />
      <Dialogo
        abierto={aEliminar !== null}
        alCerrar={() => {
          setAEliminar(null)
        }}
        titulo="¿Eliminar contacto?"
        descripcion="La conversación con esta persona se conserva."
      >
        <div className="flex justify-end gap-2">
          <Boton variante="secundario" onClick={() => { setAEliminar(null) }}>
            Cancelar
          </Boton>
          <Boton
            variante="peligro"
            icono="papelera"
            cargando={borrar.isPending}
            onClick={() => {
              if (!aEliminar) return
              borrar.mutate(aEliminar.id, {
                onSuccess: () => {
                  avisar('Contacto eliminado.')
                  setAEliminar(null)
                },
                onError: (e) => {
                  avisar(mensajeDeError(e), 'error')
                },
              })
            }}
          >
            Eliminar
          </Boton>
        </div>
      </Dialogo>
      <Dialogo
        abierto={aBloquear !== null}
        alCerrar={() => {
          setABloquear(null)
        }}
        titulo={`¿Bloquear a ${aBloquear ? nombreContacto(aBloquear) : ''}?`}
        descripcion="No podrá enviarte mensajes, ver tu perfil ni tu estado de conexión."
      >
        <div className="flex justify-end gap-2">
          <Boton variante="secundario" onClick={() => { setABloquear(null) }}>
            Cancelar
          </Boton>
          <Boton
            variante="peligro"
            icono="bloquear"
            cargando={bloquear.isPending}
            onClick={() => {
              if (aBloquear) alternarBloqueo(aBloquear)
            }}
          >
            Bloquear
          </Boton>
        </div>
      </Dialogo>
    </div>
  )
}
