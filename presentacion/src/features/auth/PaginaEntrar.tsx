import { useState, type SyntheticEvent } from 'react'
import { Link } from 'react-router'
import { useMutation } from '@tanstack/react-query'
import { ApiError, mensajeDeError } from '@/api/errores'
import { iniciarSesion, useAuth, type MotivoSalida } from '@/auth/sesion'
import { Boton } from '@/components/ui/Boton'
import { Campo, ErrorFormulario } from '@/components/ui/Campo'
import { env } from '@/lib/env'
import { CREDENCIALES_DEMO } from '@/mocks/demo'
import { MarcoAcceso } from './MarcoAcceso'

const MOTIVOS: Partial<Record<MotivoSalida, string>> = {
  expirada: 'Tu sesión caducó. Vuelve a entrar.',
  revocada: 'Esta sesión se cerró desde otro dispositivo.',
  'otra-pestana': 'Cerraste sesión en otra pestaña.',
}

export function PaginaEntrar() {
  const [identificador, setIdentificador] = useState('')
  const [password, setPassword] = useState('')
  const [errores, setErrores] = useState<{ identificador?: string; password?: string }>({})
  const motivo = useAuth((s) => s.motivoSalida)

  const entrar = useMutation({
    mutationFn: () => iniciarSesion(identificador, password),
  })

  const enviar = (e: SyntheticEvent) => {
    e.preventDefault()
    const nuevos: typeof errores = {}
    if (!identificador.trim()) nuevos.identificador = 'Escribe tu teléfono o tu correo.'
    if (!password) nuevos.password = 'Escribe tu contraseña.'
    setErrores(nuevos)
    if (Object.keys(nuevos).length === 0) entrar.mutate()
  }

  const error = entrar.error
  const textoError =
    error instanceof ApiError && error.status === 401 ? 'Teléfono, correo o contraseña incorrectos.' : error ? mensajeDeError(error) : null

  return (
    <MarcoAcceso titulo="Bienvenida de vuelta" subtitulo="Entra con tu teléfono o tu correo.">
      {motivo && MOTIVOS[motivo] && !entrar.isPending && (
        <p role="status" className="rounded-control bg-primario-suave px-3.5 py-3 text-sm font-medium text-primario">
          {MOTIVOS[motivo]}
        </p>
      )}
      <form onSubmit={enviar} noValidate className="flex flex-col gap-4">
        {textoError && <ErrorFormulario>{textoError}</ErrorFormulario>}
        <Campo
          etiqueta="Teléfono o correo"
          name="identificador"
          autoComplete="username"
          inputMode="email"
          autoCapitalize="none"
          spellCheck={false}
          placeholder="8888 0001 o ana@correo.com"
          value={identificador}
          onChange={(e) => {
            setIdentificador(e.target.value)
          }}
          error={errores.identificador}
          required
        />
        <Campo
          etiqueta="Contraseña"
          name="password"
          type="password"
          autoComplete="current-password"
          revelable
          value={password}
          onChange={(e) => {
            setPassword(e.target.value)
          }}
          error={errores.password}
          required
        />
        <Boton type="submit" tamano="lg" anchoCompleto cargando={entrar.isPending}>
          Entrar
        </Boton>
      </form>
      <p className="text-center text-sm text-tenue">
        ¿No tienes cuenta?{' '}
        <Link to="/registro" className="font-semibold text-primario underline-offset-4 hover:underline">
          Crea una
        </Link>
      </p>

      {env.usarMocks && (
        <section aria-labelledby="demo-titulo" className="rounded-tarjeta border border-dashed border-borde p-4">
          <h2 id="demo-titulo" className="mb-2 text-sm font-bold">
            Modo demo (datos simulados)
          </h2>
          <ul className="flex flex-col gap-1.5">
            {CREDENCIALES_DEMO.map((c) => (
              <li key={c.email}>
                <button
                  type="button"
                  className="w-full rounded-control px-2 py-1.5 text-left text-sm hover:bg-superficie-2"
                  onClick={() => {
                    setIdentificador(c.phone)
                    setPassword(c.password)
                  }}
                >
                  <span className="font-semibold">{c.nombre}</span>{' '}
                  <span className="text-tenue">
                    {c.phone} · {c.password}
                  </span>
                </button>
              </li>
            ))}
          </ul>
        </section>
      )}
    </MarcoAcceso>
  )
}
