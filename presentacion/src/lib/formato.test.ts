import { describe, expect, it } from 'vitest'
import { consultaContactos } from './formato'

describe('consultaContactos', () => {
  it('convierte teléfonos escritos a mano en prefijos E.164', () => {
    expect(consultaContactos('7000 0003')).toBe('+50670000003')
    expect(consultaContactos(' 7000-00 ')).toBe('+506700000')
    expect(consultaContactos('+506 7000 0003')).toBe('+50670000003')
    expect(consultaContactos('50670000003')).toBe('+50670000003')
  })

  it('deja intactos nombres y alias', () => {
    expect(consultaContactos('  Carla (trabajo) ')).toBe('Carla (trabajo)')
    expect(consultaContactos('Bruno 2')).toBe('Bruno 2')
  })
})
