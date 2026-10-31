/**
 * Cliente HTTP tipado (openapi-fetch) generado desde docs/contratos/openapi.yaml.
 * Añade el access token, y ante un 401 renueva la sesión una sola vez y repite la petición.
 */
import createClient from 'openapi-fetch'
import { env } from '@/lib/env'
import { obtenerTokenVigente, refrescarSesion } from '@/auth/sesion'
import { ErrorDeRed, errorDesdeRespuesta } from './errores'
import type { paths } from './schema'

const RUTAS_PUBLICAS = ['/auth/login', '/auth/register', '/auth/refresh', '/auth/reactivate', '/health', '/ready']

function conToken(request: Request, token: string | null): Request {
  if (!token) return request
  const headers = new Headers(request.headers)
  headers.set('Authorization', `Bearer ${token}`)
  return new Request(request, { headers })
}

async function red(request: Request): Promise<Response> {
  try {
    // globalThis.fetch se resuelve en cada llamada (MSW lo intercepta en desarrollo y pruebas).
    return await globalThis.fetch(request)
  } catch (e) {
    if (e instanceof DOMException && e.name === 'AbortError') throw e
    throw new ErrorDeRed()
  }
}

export async function fetchAutenticado(request: Request): Promise<Response> {
  const ruta = new URL(request.url).pathname
  if (RUTAS_PUBLICAS.some((r) => ruta.endsWith(r))) return red(request)

  // Copia antes de consumir el cuerpo, por si hay que repetir tras renovar el token.
  const copia = request.clone()
  const token = await obtenerTokenVigente()
  const respuesta = await red(conToken(request, token))
  if (respuesta.status !== 401 || !token) return respuesta

  const nuevo = await refrescarSesion()
  if (!nuevo) return respuesta
  return red(conToken(copia, nuevo))
}

export const api = createClient<paths>({ baseUrl: env.apiUrl, fetch: fetchAutenticado })

interface ResultadoFetch<T> {
  data?: T
  error?: unknown
  response: Response
}

/** Devuelve `data` o lanza un ApiError con el problema RFC 9457. */
export async function ok<T>(peticion: Promise<ResultadoFetch<T>>): Promise<T> {
  const { data, error, response } = await peticion
  if (!response.ok) throw errorDesdeRespuesta(response, error)
  return data as T
}
