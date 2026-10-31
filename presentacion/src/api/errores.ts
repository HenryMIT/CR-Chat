import type { Problema } from './tipos'

/** Error de la API construido a partir de un problema RFC 9457. */
export class ApiError extends Error {
  readonly status: number
  readonly tipo: string | undefined
  readonly titulo: string | undefined
  readonly campos: Record<string, string>
  readonly reintentarEn: number | undefined

  constructor(status: number, problema?: Partial<Problema>, reintentarEn?: number) {
    super(mensajeParaPersona(status, problema, reintentarEn))
    this.name = 'ApiError'
    this.status = status
    this.tipo = problema?.type
    this.titulo = problema?.title
    this.reintentarEn = reintentarEn
    this.campos = {}
    for (const e of problema?.errors ?? []) this.campos[e.field] = e.detail
  }
}

/** Error de red (sin respuesta del servidor). */
export class ErrorDeRed extends Error {
  constructor() {
    super('No hay conexión con el servidor. Revisa tu red e inténtalo de nuevo.')
    this.name = 'ErrorDeRed'
  }
}

function mensajeParaPersona(status: number, problema?: Partial<Problema>, reintentarEn?: number): string {
  if (status === 429) {
    return reintentarEn
      ? `Demasiados intentos. Vuelve a intentarlo en ${reintentarEn} s.`
      : 'Demasiados intentos. Espera un momento y vuelve a intentarlo.'
  }
  if (problema?.detail) return problema.detail
  switch (status) {
    case 400:
      return 'La petición no es válida.'
    case 401:
      return 'Tu sesión no es válida. Inicia sesión de nuevo.'
    case 403:
      return 'No tienes permiso para hacer esto.'
    case 404:
      return 'No se encontró lo que buscabas.'
    case 409:
      return 'No se pudo completar la operación con esos datos.'
    case 422:
      return 'Revisa los datos del formulario.'
    default:
      return status >= 500 ? 'El servidor tuvo un problema. Inténtalo de nuevo en un momento.' : 'Ocurrió un error inesperado.'
  }
}

/** Construye un ApiError a partir de la respuesta (lee Retry-After en 429). */
export function errorDesdeRespuesta(response: Response, cuerpo: unknown): ApiError {
  const retry = Number(response.headers.get('Retry-After'))
  const problema = typeof cuerpo === 'object' && cuerpo !== null ? (cuerpo as Partial<Problema>) : undefined
  return new ApiError(response.status, problema, Number.isFinite(retry) && retry > 0 ? retry : undefined)
}

export function mensajeDeError(error: unknown): string {
  if (error instanceof Error) return error.message
  return 'Ocurrió un error inesperado.'
}

export function esBloqueo(error: unknown): boolean {
  return error instanceof ApiError && error.status === 403 && (error.tipo?.endsWith('/bloqueado') ?? false)
}
