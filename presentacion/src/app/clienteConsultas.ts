import { QueryClient } from '@tanstack/react-query'
import { ApiError } from '@/api/errores'

/** No se reintentan errores del cliente (4xx) salvo 408; sí los de red y 5xx (hasta 2 veces). */
export function debeReintentar(intentos: number, error: unknown): boolean {
  if (error instanceof ApiError && error.status < 500 && error.status !== 408) return false
  return intentos < 2
}

export function crearClienteConsultas(): QueryClient {
  return new QueryClient({
    defaultOptions: {
      queries: {
        staleTime: 30_000,
        retry: debeReintentar,
        retryDelay: (intento) => Math.min(1000 * 2 ** intento, 8000),
      },
      mutations: { retry: false },
    },
  })
}
