import '@testing-library/jest-dom/vitest'
import { cleanup } from '@testing-library/react'
import { afterAll, afterEach, beforeAll } from 'vitest'
import { reiniciarSesionParaPruebas } from '@/auth/sesion'
import { reiniciarEfimero } from '@/realtime/estadoEfimero'
import { servidor, reiniciarDb } from './servidor'

beforeAll(() => {
  servidor.listen({ onUnhandledFrame: 'error' })
})

afterEach(() => {
  cleanup()
  servidor.resetHandlers()
  reiniciarDb()
  reiniciarSesionParaPruebas()
  reiniciarEfimero()
  localStorage.clear()
})

afterAll(() => {
  servidor.close()
})
