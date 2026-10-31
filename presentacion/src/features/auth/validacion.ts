import { esTelefonoE164, normalizarTelefono } from '@/lib/formato'

export interface Formulario {
  display_name: string
  phone: string
  email: string
  password: string
  confirmar: string
}

export type Errores = Partial<Record<keyof Formulario, string>>

export const FORMULARIO_VACIO: Formulario = { display_name: '', phone: '', email: '', password: '', confirmar: '' }

/** Validaciones del contrato (RegisterRequest) antes de llamar a la API. */
export function validarRegistro(f: Formulario): Errores {
  const e: Errores = {}
  const nombre = f.display_name.trim()
  if (!nombre) e.display_name = 'Escribe cómo quieres que te vean.'
  else if (nombre.length > 50) e.display_name = 'Máximo 50 caracteres.'
  if (!esTelefonoE164(normalizarTelefono(f.phone))) e.phone = 'Número no válido. Ejemplo: 8888 0001 o +50688880001.'
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(f.email.trim())) e.email = 'Correo no válido.'
  else if (f.email.length > 254) e.email = 'Correo demasiado largo.'
  if (f.password.length < 10) e.password = 'Mínimo 10 caracteres.'
  else if (f.password.length > 128) e.password = 'Máximo 128 caracteres.'
  else if (f.password === f.email || normalizarTelefono(f.password) === normalizarTelefono(f.phone)) {
    e.password = 'No uses tu correo ni tu teléfono como contraseña.'
  }
  if (f.confirmar !== f.password) e.confirmar = 'Las contraseñas no coinciden.'
  return e
}
