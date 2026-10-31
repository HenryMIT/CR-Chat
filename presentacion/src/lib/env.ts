/** Configuración pública leída de las variables VITE_* (nunca secretos). */
function quitarBarraFinal(url: string): string {
  return url.replace(/\/+$/, '')
}

export const env = {
  apiUrl: quitarBarraFinal(import.meta.env.VITE_API_URL ?? 'http://localhost:8000/api/v1'),
  wsUrl: import.meta.env.VITE_WS_URL ?? 'ws://localhost:8080/ws',
  usarMocks: import.meta.env.VITE_USE_MOCKS === 'true',
} as const
