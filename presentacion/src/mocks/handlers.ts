/**
 * Handlers HTTP de MSW derivados de docs/contratos/openapi.yaml (servidor /api/v1).
 * Única diferencia deliberada: /auth/login acepta `identifier` (teléfono o correo),
 * decisión aprobada que el backend alineará; también acepta `email` del contrato actual.
 */
import { delay, http, HttpResponse, type HttpHandler, type PathParams } from 'msw'
import { ErrorMock, type MockDb } from './db'

export const HOST_ALMACEN = 'https://almacen.mock.crchat.local'

export interface OpcionesHandlers {
  apiUrl: string
  /** Latencia simulada (ms) para que la demo se sienta real; 0 en pruebas. */
  latencia?: number
}

type Cuerpo = Record<string, unknown>

function problema(e: ErrorMock, instancia: string): Response {
  return new HttpResponse(
    JSON.stringify({
      type: `https://cr-chat.example/problemas/${e.tipo}`,
      title: e.titulo,
      status: e.status,
      detail: e.detalle,
      instance: instancia,
      ...(e.errores ? { errors: e.errores } : {}),
    }),
    { status: e.status, headers: { 'Content-Type': 'application/problem+json' } },
  )
}

function crearUrlArchivo(blob: Blob): string {
  try {
    return URL.createObjectURL(blob)
  } catch {
    // Entornos sin createObjectURL (algunas pruebas): imagen transparente de 1×1.
    return 'data:image/gif;base64,R0lGODlhAQABAAAAACw='
  }
}

export function crearHandlers(db: MockDb, opciones: OpcionesHandlers): HttpHandler[] {
  const base = opciones.apiUrl.replace(/\/+$/, '')
  const latencia = opciones.latencia ?? 0

  /** Envuelve un resolver: latencia, errores RFC 9457 y persistencia tras escribir. */
  const ruta =
    // eslint-disable-next-line @typescript-eslint/no-unnecessary-type-parameters -- tipa los params de cada ruta
    <P extends Record<string, string> = Record<string, string>>(
      fn: (args: { request: Request; params: P; url: URL }) => Promise<Response> | Response,
      escribe = false,
    ) =>
    async ({ request, params }: { request: Request; params: PathParams }) => {
      if (latencia > 0) await delay(latencia + Math.round(Math.random() * latencia))
      const url = new URL(request.url)
      try {
        const res = await fn({ request, params: params as P, url })
        if (escribe) db.guardar()
        return res
      } catch (e) {
        if (e instanceof ErrorMock) return problema(e, url.pathname)
        throw e
      }
    }

  const sesion = (request: Request) => db.autenticar(request.headers.get('Authorization')?.replace(/^Bearer\s+/i, '') ?? null)
  const cuerpo = async (request: Request): Promise<Cuerpo> => {
    try {
      return (await request.json()) as Cuerpo
    } catch {
      throw new ErrorMock(400, 'peticion-invalida', 'Petición inválida', 'El cuerpo de la petición debe ser un JSON válido.')
    }
  }
  const limite = (url: URL) => Math.min(100, Math.max(1, Number(url.searchParams.get('limit') ?? 50) || 50))
  const sinContenido = () => new HttpResponse(null, { status: 204 })
  const str = (v: unknown): string => (typeof v === 'string' ? v : '')

  return [
    // ---------------------------------------------------------------- auth
    http.post(
      `${base}/auth/register`,
      ruta(async ({ request }) => {
        const b = await cuerpo(request)
        const me = db.registrar({ email: str(b.email), phone: str(b.phone), display_name: str(b.display_name), password: str(b.password) })
        return HttpResponse.json(me, { status: 201, headers: { Location: `${base}/me` } })
      }, true),
    ),
    http.post(
      `${base}/auth/login`,
      ruta(async ({ request }) => {
        const b = await cuerpo(request)
        const identificador = str(b.identifier) || str(b.email)
        const par = db.login(identificador, str(b.password), typeof b.device_name === 'string' ? b.device_name : undefined)
        return HttpResponse.json(par, { headers: { 'Cache-Control': 'no-store' } })
      }, true),
    ),
    http.post(
      `${base}/auth/refresh`,
      ruta(async ({ request }) => {
        const b = await cuerpo(request)
        return HttpResponse.json(db.refrescar(str(b.refresh_token)), { headers: { 'Cache-Control': 'no-store' } })
      }, true),
    ),
    http.post(
      `${base}/auth/logout`,
      ruta(({ request }) => {
        db.cerrarSesion(sesion(request).sesion)
        return sinContenido()
      }, true),
    ),

    // ---------------------------------------------------------------- me
    http.get(
      `${base}/me`,
      ruta(({ request }) => HttpResponse.json(db.me(sesion(request).usuario))),
    ),
    http.patch(
      `${base}/me`,
      ruta(async ({ request }) => {
        const { usuario } = sesion(request)
        const b = await cuerpo(request)
        return HttpResponse.json(
          db.actualizarPerfil(usuario, {
            ...(typeof b.display_name === 'string' ? { display_name: b.display_name } : {}),
            ...('about' in b ? { about: typeof b.about === 'string' ? b.about : null } : {}),
            ...('avatar_media_id' in b ? { avatar_media_id: typeof b.avatar_media_id === 'string' ? b.avatar_media_id : null } : {}),
          }),
        )
      }, true),
    ),
    http.delete(
      `${base}/me`,
      ruta(async ({ request }) => {
        const { usuario, sesion: s } = sesion(request)
        const b = await cuerpo(request)
        db.verificarPassword(usuario, str(b.password))
        db.revocarOtras(usuario.id, '')
        db.cerrarSesion(s)
        return sinContenido()
      }, true),
    ),
    http.put(
      `${base}/me/password`,
      ruta(async ({ request }) => {
        const { usuario, sesion: s } = sesion(request)
        const b = await cuerpo(request)
        db.verificarPassword(usuario, str(b.current_password))
        const nueva = str(b.new_password)
        if (nueva.length < 10 || nueva.length > 128) {
          throw new ErrorMock(422, 'validacion', 'Datos inválidos', 'Uno o más campos no son válidos.', [
            { field: 'new_password', detail: 'Debe tener entre 10 y 128 caracteres.' },
          ])
        }
        usuario.password = nueva
        db.revocarOtras(usuario.id, s.id)
        return sinContenido()
      }, true),
    ),
    http.put(
      `${base}/me/phone`,
      ruta(async ({ request }) => {
        const { usuario, sesion: s } = sesion(request)
        const b = await cuerpo(request)
        db.verificarPassword(usuario, str(b.current_password))
        const telefono = str(b.phone)
        if (!/^\+[1-9][0-9]{7,14}$/.test(telefono)) {
          throw new ErrorMock(422, 'validacion', 'Datos inválidos', 'Uno o más campos no son válidos.', [
            { field: 'phone', detail: 'Debe estar en formato E.164, p. ej. +50688880001.' },
          ])
        }
        if (db.d.usuarios.some((u) => u.phone === telefono && u.id !== usuario.id)) {
          throw new ErrorMock(409, 'no-disponible', 'Valor no disponible', 'El número de teléfono no está disponible.')
        }
        usuario.phone = telefono
        db.revocarOtras(usuario.id, s.id)
        return HttpResponse.json(db.me(usuario))
      }, true),
    ),
    http.get(
      `${base}/me/sessions`,
      ruta(({ request }) => {
        const { usuario, sesion: s } = sesion(request)
        return HttpResponse.json({ items: db.sesiones(usuario.id, s.id) })
      }),
    ),
    http.delete(
      `${base}/me/sessions`,
      ruta(({ request }) => {
        const { usuario, sesion: s } = sesion(request)
        db.revocarOtras(usuario.id, s.id)
        return sinContenido()
      }, true),
    ),
    http.delete(
      `${base}/me/sessions/:sessionId`,
      ruta<{ sessionId: string }>(({ request, params }) => {
        db.revocarSesion(sesion(request).usuario.id, params.sessionId)
        return sinContenido()
      }, true),
    ),

    // ---------------------------------------------------------------- users
    http.get(
      `${base}/users/:userId`,
      ruta<{ userId: string }>(({ request, params }) => HttpResponse.json(db.usuarioPublico(sesion(request).usuario.id, params.userId))),
    ),

    // ---------------------------------------------------------------- contacts
    http.get(
      `${base}/contacts`,
      ruta(({ request, url }) =>
        HttpResponse.json(db.listarContactos(sesion(request).usuario.id, url.searchParams.get('q'), url.searchParams.get('cursor'), limite(url))),
      ),
    ),
    http.post(
      `${base}/contacts`,
      ruta(async ({ request }) => {
        const yo = sesion(request).usuario.id
        const b = await cuerpo(request)
        const { contacto, creado } = db.crearContacto(yo, str(b.phone), typeof b.alias === 'string' ? b.alias : undefined)
        return HttpResponse.json(contacto, {
          status: creado ? 201 : 200,
          ...(creado ? { headers: { Location: `${base}/contacts/${contacto.id}` } } : {}),
        })
      }, true),
    ),
    http.get(
      `${base}/contacts/:contactId`,
      ruta<{ contactId: string }>(({ request, params }) => HttpResponse.json(db.obtenerContacto(sesion(request).usuario.id, params.contactId))),
    ),
    http.patch(
      `${base}/contacts/:contactId`,
      ruta<{ contactId: string }>(async ({ request, params }) => {
        const yo = sesion(request).usuario.id
        const b = await cuerpo(request)
        return HttpResponse.json(db.editarAlias(yo, params.contactId, typeof b.alias === 'string' ? b.alias : null))
      }, true),
    ),
    http.delete(
      `${base}/contacts/:contactId`,
      ruta<{ contactId: string }>(({ request, params }) => {
        db.borrarContacto(sesion(request).usuario.id, params.contactId)
        return sinContenido()
      }, true),
    ),

    // ---------------------------------------------------------------- blocks
    http.get(
      `${base}/blocks`,
      ruta(({ request, url }) => HttpResponse.json(db.listarBloqueos(sesion(request).usuario.id, url.searchParams.get('cursor'), limite(url)))),
    ),
    http.put(
      `${base}/blocks/:userId`,
      ruta<{ userId: string }>(({ request, params }) => {
        db.bloquear(sesion(request).usuario.id, params.userId)
        return sinContenido()
      }, true),
    ),
    http.delete(
      `${base}/blocks/:userId`,
      ruta<{ userId: string }>(({ request, params }) => {
        db.desbloquear(sesion(request).usuario.id, params.userId)
        return sinContenido()
      }, true),
    ),

    // ---------------------------------------------------------------- conversations
    http.get(
      `${base}/conversations`,
      ruta(({ request, url }) =>
        HttpResponse.json(db.listarConversaciones(sesion(request).usuario.id, url.searchParams.get('cursor'), limite(url))),
      ),
    ),
    http.post(
      `${base}/conversations`,
      ruta(async ({ request }) => {
        const yo = sesion(request).usuario.id
        const b = await cuerpo(request)
        const { conversacion, creada } = db.crearConversacion(yo, str(b.contact_id))
        return HttpResponse.json(conversacion, { status: creada ? 201 : 200 })
      }, true),
    ),
    http.get(
      `${base}/conversations/:conversationId`,
      ruta<{ conversationId: string }>(({ request, params }) => {
        const yo = sesion(request).usuario.id
        return HttpResponse.json(db.conversacionVista(db.participante(yo, params.conversationId), yo))
      }),
    ),
    http.get(
      `${base}/conversations/:conversationId/messages`,
      ruta<{ conversationId: string }>(({ request, params, url }) => {
        const yo = sesion(request).usuario.id
        const before = url.searchParams.get('before')
        const after = url.searchParams.get('after')
        if (before && after) throw new ErrorMock(400, 'peticion-invalida', 'Petición inválida', '`before` y `after` son excluyentes.')
        return HttpResponse.json(db.listarMensajes(yo, params.conversationId, { before, after, limite: limite(url) }))
      }, true),
    ),
    http.post(
      `${base}/conversations/:conversationId/messages`,
      ruta<{ conversationId: string }>(async ({ request, params }) => {
        const yo = sesion(request).usuario.id
        const b = await cuerpo(request)
        const clientId = str(b.client_id) || request.headers.get('Idempotency-Key') || undefined
        const { mensaje, creado } = db.enviarMensaje(yo, params.conversationId, {
          ...(clientId ? { client_id: clientId } : {}),
          ...(typeof b.text === 'string' ? { text: b.text } : {}),
          ...(typeof b.media_id === 'string' ? { media_id: b.media_id } : {}),
        })
        return HttpResponse.json(mensaje, { status: creado ? 201 : 200 })
      }, true),
    ),
    http.post(
      `${base}/conversations/:conversationId/receipts`,
      ruta<{ conversationId: string }>(async ({ request, params }) => {
        const yo = sesion(request).usuario.id
        const b = await cuerpo(request)
        const estado = b.status === 'seen' ? 'seen' : 'delivered'
        return HttpResponse.json(db.marcarRecibo(yo, params.conversationId, estado, str(b.up_to_message_id)))
      }, true),
    ),

    // ---------------------------------------------------------------- messages
    http.patch(
      `${base}/messages/:messageId`,
      ruta<{ messageId: string }>(async ({ request, params }) => {
        const yo = sesion(request).usuario.id
        const b = await cuerpo(request)
        return HttpResponse.json(db.editarMensaje(yo, params.messageId, str(b.text)))
      }, true),
    ),
    http.delete(
      `${base}/messages/:messageId`,
      ruta<{ messageId: string }>(({ request, params }) => {
        db.borrarMensaje(sesion(request).usuario.id, params.messageId)
        return sinContenido()
      }, true),
    ),

    // ---------------------------------------------------------------- uploads (MinIO simulado)
    http.post(
      `${base}/uploads`,
      ruta(async ({ request }) => {
        const yo = sesion(request).usuario.id
        const b = await cuerpo(request)
        const media = db.crearSubida(yo, {
          purpose: b.purpose === 'avatar' ? 'avatar' : 'message',
          content_type: str(b.content_type),
          size_bytes: typeof b.size_bytes === 'number' ? b.size_bytes : 0,
        })
        return HttpResponse.json(
          {
            media_id: media.id,
            upload_url: `${HOST_ALMACEN}/subidas/${media.id}?X-Amz-Expires=300&X-Amz-Signature=demo`,
            method: 'PUT',
            headers: { 'Content-Type': media.content_type },
            expires_at: new Date(Date.now() + 5 * 60_000).toISOString(),
          },
          { status: 201 },
        )
      }, true),
    ),
    http.put(`${HOST_ALMACEN}/subidas/:mediaId`, async ({ request, params }) => {
      const blob = await request.blob()
      const ok = db.completarSubida(String(params.mediaId), crearUrlArchivo(blob))
      if (ok) db.guardar()
      return new HttpResponse(null, { status: ok ? 200 : 403 })
    }),

    // ---------------------------------------------------------------- health
    http.get(`${base}/health`, () => HttpResponse.json({ status: 'ok' })),
    http.get(`${base}/ready`, () => HttpResponse.json({ status: 'ok', checks: { db_write: 'ok', db_read: 'ok', redis: 'ok', storage: 'ok' } })),
  ]
}
