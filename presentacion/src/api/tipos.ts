/**
 * Alias legibles de los esquemas generados desde docs/contratos/openapi.yaml
 * (src/api/schema.d.ts, `npm run gen:api`). No se editan tipos a mano salvo las
 * diferencias acordadas con el backend, señaladas abajo.
 */
import type { components, paths } from './schema'

type S = components['schemas']

export type Id = S['Id']
export type Problema = S['Problem']
export type Me = S['Me']
export type Media = S['Media']
export type UsuarioResumen = S['UserSummary']
export type UsuarioPublico = S['PublicUser']
export type Sesion = S['Session']
export type Contacto = S['Contact']
export type PaginaContactos = S['ContactPage']
export type Bloqueo = S['Block']
export type PaginaBloqueos = S['BlockPage']
export type Conversacion = S['Conversation']
export type PaginaConversaciones = S['ConversationPage']
export type Mensaje = S['Message']
export type PaginaMensajes = S['MessagePage']
export type ResultadoRecibo = S['ReceiptResult']
export type SolicitudSubida = S['UploadRequest']
export type TicketSubida = S['UploadTicket']
export type ParTokens = S['TokenPair']
export type RegistroPeticion = S['RegisterRequest']
export type EstadoMensaje = NonNullable<Mensaje['status']>

/**
 * DIFERENCIA CON EL CONTRATO ACTUAL: login con "teléfono o correo" en un único campo
 * `identifier` (decisión aprobada; el backend alineará `LoginRequest`). Mientras tanto
 * el contrato generado solo tiene `email`.
 */
export interface LoginPeticion {
  identifier: string
  password: string
  device_name?: string
}

/**
 * `SendMessageRequest` usa `anyOf` en el contrato y openapi-typescript lo genera como
 * `unknown`; se tipa aquí con la misma forma.
 */
export interface EnviarMensajePeticion {
  client_id?: Id
  text?: string
  media_id?: Id
}

/** Estado local de un mensaje optimista que aún no confirma el servidor. */
export type EstadoLocal = 'enviando' | 'fallido'

/** Mensaje en la caché del cliente: el del contrato más metadatos locales opcionales. */
export interface MensajeChat extends Mensaje {
  local?: EstadoLocal
}

export type Rutas = paths
