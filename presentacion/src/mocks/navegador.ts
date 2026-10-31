/**
 * Arranque de MSW en el navegador (solo si VITE_USE_MOCKS=true). Este módulo se importa
 * de forma dinámica desde main.tsx, así que con mocks desactivados no entra en el bundle.
 */
import { setupWorker } from 'msw/browser'
import { MockDb } from './db'
import { crearHandlers } from './handlers'
import { crearHandlersWs } from './ws'
import { iniciarBot } from './bot'

export const CLAVE_DB_DEMO = 'crchat.mock.db'

export async function iniciarMocks(config: { apiUrl: string; wsUrl: string }): Promise<void> {
  const db = new MockDb({ persistirEn: CLAVE_DB_DEMO })
  const { handler } = crearHandlersWs(db, { wsUrl: config.wsUrl })
  iniciarBot(db)
  const worker = setupWorker(...crearHandlers(db, { apiUrl: config.apiUrl, latencia: 150 }), handler)
  await worker.start({
    quiet: true,
    // Fuentes, módulos de Vite, HMR…: se dejan pasar sin avisos.
    onUnhandledFrame: 'bypass',
  })
  // Atajo de consola para volver a los datos iniciales de la demo.
  Object.assign(window, {
    crchatReiniciarDemo: () => {
      db.reiniciar()
      location.reload()
    },
  })
}
