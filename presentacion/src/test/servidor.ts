/**
 * Servidor MSW para Vitest: los mismos handlers (HTTP + WebSocket) que usa la app en
 * desarrollo, sobre una MockDb que vuelve a los datos semilla tras cada prueba.
 */
import { setupServer } from 'msw/node'
import { MockDb } from '@/mocks/db'
import { crearHandlers } from '@/mocks/handlers'
import { crearHandlersWs } from '@/mocks/ws'

export const API = 'http://api.test/api/v1'
export const WS = 'ws://ws.test/ws'

export const db = new MockDb()

const ws = crearHandlersWs(db, { wsUrl: WS, esperaAuthMs: 2000 })
export const conexionesWs = ws.conexiones

export const servidor = setupServer(...crearHandlers(db, { apiUrl: API }), ws.handler)

export function reiniciarDb(): void {
  db.reiniciar()
}
