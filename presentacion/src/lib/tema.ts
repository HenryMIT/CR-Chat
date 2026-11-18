/** Preferencia de tema (sistema / claro / oscuro) persistida en localStorage. */
import { create } from 'zustand'

export type Tema = 'sistema' | 'claro' | 'oscuro'
const CLAVE = 'crchat.tema'

function leer(): Tema {
  try {
    const t = localStorage.getItem(CLAVE)
    return t === 'claro' || t === 'oscuro' ? t : 'sistema'
  } catch {
    return 'sistema'
  }
}

function sistemaOscuro(): boolean {
  return typeof matchMedia === 'function' && matchMedia('(prefers-color-scheme: dark)').matches
}

export const useTema = create<{ tema: Tema }>()(() => ({ tema: leer() }))

export function aplicarTema(tema: Tema): void {
  const oscuro = tema === 'oscuro' || (tema === 'sistema' && sistemaOscuro())
  document.documentElement.classList.toggle('dark', oscuro)
}

export function fijarTema(tema: Tema): void {
  try {
    localStorage.setItem(CLAVE, tema)
  } catch {
    /* sin almacenamiento: vale para esta sesión */
  }
  useTema.setState({ tema })
  aplicarTema(tema)
}

/** Sigue los cambios del sistema operativo mientras la preferencia sea "sistema". */
export function escucharTemaSistema(): () => void {
  if (typeof matchMedia !== 'function') return () => undefined
  const mq = matchMedia('(prefers-color-scheme: dark)')
  const alCambiar = () => {
    if (useTema.getState().tema === 'sistema') aplicarTema('sistema')
  }
  mq.addEventListener('change', alCambiar)
  return () => {
    mq.removeEventListener('change', alCambiar)
  }
}
