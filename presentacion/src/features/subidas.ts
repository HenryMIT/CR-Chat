/**
 * Subida de archivos con URL prefirmada de MinIO (contrato: POST /uploads →
 * PUT directo a `upload_url` → referenciar `media_id`). PHP nunca transporta binarios.
 */
import { api, ok } from '@/api/cliente'
import { ErrorDeRed } from '@/api/errores'
import type { SolicitudSubida } from '@/api/tipos'

export const TIPOS_AVATAR = ['image/jpeg', 'image/png', 'image/webp'] as const
export const TIPOS_ADJUNTO = [...TIPOS_AVATAR, 'image/gif', 'application/pdf', 'audio/ogg', 'audio/mpeg', 'video/mp4'] as const
export const MAX_AVATAR = 2 * 1024 * 1024
export const MAX_ADJUNTO = 20 * 1024 * 1024

type Proposito = SolicitudSubida['purpose']

/** Valida en el cliente lo mismo que validará el servidor. Devuelve el error o null. */
export function validarArchivo(archivo: File, proposito: Proposito): string | null {
  const tipos: readonly string[] = proposito === 'avatar' ? TIPOS_AVATAR : TIPOS_ADJUNTO
  if (!tipos.includes(archivo.type)) {
    return proposito === 'avatar'
      ? 'La foto debe ser JPG, PNG o WebP.'
      : 'Tipo de archivo no permitido (imágenes, PDF, audio o vídeo MP4).'
  }
  const maximo = proposito === 'avatar' ? MAX_AVATAR : MAX_ADJUNTO
  if (archivo.size > maximo) return `El archivo supera el máximo de ${proposito === 'avatar' ? '2' : '20'} MB.`
  if (archivo.size === 0) return 'El archivo está vacío.'
  return null
}

export async function subirArchivo(archivo: File, proposito: Proposito): Promise<string> {
  const error = validarArchivo(archivo, proposito)
  if (error) throw new Error(error)
  const ticket = await ok(
    api.POST('/uploads', {
      body: { purpose: proposito, content_type: archivo.type as SolicitudSubida['content_type'], size_bytes: archivo.size },
    }),
  )
  // Content-Length lo fija el navegador (encabezado prohibido en fetch).
  const headers = Object.fromEntries(Object.entries(ticket.headers).filter(([k]) => k.toLowerCase() !== 'content-length'))
  let res: Response
  try {
    res = await fetch(ticket.upload_url, { method: ticket.method, headers, body: archivo })
  } catch {
    throw new ErrorDeRed()
  }
  if (!res.ok) throw new Error('No se pudo subir el archivo. Inténtalo de nuevo.')
  return ticket.media_id
}
