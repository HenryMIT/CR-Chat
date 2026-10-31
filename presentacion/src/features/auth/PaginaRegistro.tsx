import { useState, type SyntheticEvent } from 'react'
import { Link } from 'react-router'
import { useMutation } from '@tanstack/react-query'
import { api, ok } from '@/api/cliente'
import { ApiError, mensajeDeError } from '@/api/errores'
import { iniciarSesion } from '@/auth/sesion'
import { Boton } from '@/components/ui/Boton'
import { Campo, ErrorFormulario } from '@/components/ui/Campo'
import { normalizarTelefono } from '@/lib/formato'
import { MarcoAcceso } from './MarcoAcceso'
import { FORMULARIO_VACIO, validarRegistro, type Errores, type Formulario } from './validacion'

const CAMPO_API: Record<string, keyof Formulario> = { display_name: 'display_name', phone: 'phone', email: 'email', password: 'password' }

export function PaginaRegistro() {
  const [f, setF] = useState<Formulario>(FORMULARIO_VACIO)
  const [errores, setErrores] = useState<Errores>({})

  const registrar = useMutation({
    mutationFn: async () => {
      const email = f.email.trim()
      await ok(
        api.POST('/auth/register', {
          body: { email, phone: normalizarTelefono(f.phone), display_name: f.display_name.trim(), password: f.password },
        }),
      )
      // El registro no inicia sesión (contrato): se entra a continuación.
      await iniciarSesion(email, f.password)
    },
    onError: (error) => {
      if (error instanceof ApiError && error.status === 422) {
        const delServidor: Errores = {}
        for (const [campo, detalle] of Object.entries(error.campos)) {
          const propio = CAMPO_API[campo]
          if (propio) delServidor[propio] = detalle
        }
        setErrores(delServidor)
      }
    },
  })

  const cambiar = (campo: keyof Formulario) => (e: React.ChangeEvent<HTMLInputElement>) => {
    setF((previo) => ({ ...previo, [campo]: e.target.value }))
  }

  const enviar = (e: SyntheticEvent) => {
    e.preventDefault()
    const nuevos = validarRegistro(f)
    setErrores(nuevos)
    if (Object.keys(nuevos).length === 0) registrar.mutate()
  }

  const error = registrar.error
  const textoError =
    error instanceof ApiError && error.status === 409
      ? 'No se pudo completar el registro con esos datos. Si ya tienes cuenta, entra.'
      : error && !(error instanceof ApiError && error.status === 422)
        ? mensajeDeError(error)
        : null

  return (
    <MarcoAcceso titulo="Crea tu cuenta" subtitulo="Tu teléfono sirve para que tus contactos te encuentren.">
      <form onSubmit={enviar} noValidate className="flex flex-col gap-4">
        {textoError && <ErrorFormulario>{textoError}</ErrorFormulario>}
        <Campo etiqueta="Nombre" name="display_name" autoComplete="name" maxLength={50} value={f.display_name} onChange={cambiar('display_name')} error={errores.display_name} required />
        <Campo
          etiqueta="Teléfono"
          name="phone"
          type="tel"
          autoComplete="tel"
          inputMode="tel"
          placeholder="8888 0001"
          value={f.phone}
          onChange={cambiar('phone')}
          error={errores.phone}
          ayuda="Si no indicas el código de país se asume Costa Rica (+506)."
          required
        />
        <Campo etiqueta="Correo" name="email" type="email" autoComplete="email" autoCapitalize="none" value={f.email} onChange={cambiar('email')} error={errores.email} required />
        <Campo
          etiqueta="Contraseña"
          name="password"
          type="password"
          autoComplete="new-password"
          revelable
          value={f.password}
          onChange={cambiar('password')}
          error={errores.password}
          ayuda="Entre 10 y 128 caracteres. Una frase larga es más segura."
          required
        />
        <Campo
          etiqueta="Repite la contraseña"
          name="confirmar"
          type="password"
          autoComplete="new-password"
          value={f.confirmar}
          onChange={cambiar('confirmar')}
          error={errores.confirmar}
          required
        />
        <Boton type="submit" tamano="lg" anchoCompleto cargando={registrar.isPending}>
          Crear cuenta
        </Boton>
      </form>
      <p className="text-center text-sm text-tenue">
        ¿Ya tienes cuenta?{' '}
        <Link to="/entrar" className="font-semibold text-primario underline-offset-4 hover:underline">
          Entra
        </Link>
      </p>
    </MarcoAcceso>
  )
}
