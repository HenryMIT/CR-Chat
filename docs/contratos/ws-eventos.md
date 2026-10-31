# Contrato de eventos WebSocket de CR_Chat (v1)

Estilo AsyncAPI 3.0 en Markdown. Complementa a `docs/contratos/openapi.yaml`: **el envío, la
edición y el borrado de mensajes se hacen siempre por REST**; el WebSocket solo entrega eventos en
tiempo real y transporta las señales efímeras (`typing`, `seen`, presencia).

## 1. Servidor

| Campo | Valor |
|---|---|
| URL | `ws://host:8080/ws` (en producción `wss://` detrás del proxy TLS) |
| Implementación | Workerman (PHP 8.4), servicio `ws` de `docker-compose.yml`, misma imagen que `datos/` |
| Subprotocolo | `cr-chat.v1` (`Sec-WebSocket-Protocol`). Si el cliente no lo pide, el servidor lo acepta igual |
| Codificación | Frames de texto, JSON UTF-8. Máximo 16 KiB por frame (más grande: cierre `1009`) |
| Origen | Se valida el encabezado `Origin` contra la misma lista de orígenes permitidos de CORS (`CORS_ORIGINS`, por defecto `http://localhost:5173,http://localhost:4200`). Si no coincide, se rechaza el handshake (HTTP 403). Sin `Origin` (clientes que no son navegador) se acepta: el riesgo de CSWSH solo existe en navegadores, que siempre lo envían |
| Bus interno | Redis pub/sub (la API publica y cada proceso WS hace `PSUBSCRIBE user:* session:*`) |
| Implementación | `datos/ws/server.php` + `datos/src/Ws/Hub.php`; `php ws/server.php start`. Procesos: `cr-chat-ws` (`WS_WORKERS`) y `cr-chat-tareas` (job de media) |

El token **no** viaja en la URL (quedaría en logs del proxy y en el historial): se envía en el
primer mensaje `auth`.

## 2. Sobre (envelope)

Todos los mensajes, en los dos sentidos, tienen la misma forma:

```json
{
  "type": "message.new",
  "id": "0192d5a1-0b7c-7f00-8a11-3c4d5e6f7a8b",
  "ts": "2026-10-29T14:03:12.123Z",
  "data": { }
}
```

| Campo | Tipo | Descripción |
|---|---|---|
| `type` | string | Nombre del evento (ver catálogo). Un `type` desconocido se ignora en el cliente y produce `error` `unknown_type` en el servidor |
| `id` | string (UUID) | Id del evento. Los eventos del cliente que esperan respuesta (`auth`, `seen`, `ping`) reciben un evento con `data.reply_to = id` |
| `ts` | string (RFC 3339 UTC) | Momento de emisión según quien envía. El servidor ignora el `ts` del cliente para cualquier lógica |
| `data` | object | Carga útil propia de cada evento |

Los objetos dentro de `data` (`Message`, `UserSummary`, etc.) usan **exactamente** los esquemas
de `openapi.yaml` (`components/schemas`), con los mismos nombres de campo y los ids públicos UUID.

## 3. Ciclo de vida de la conexión

```
cliente                                   servidor ws
   |-- handshake HTTP Upgrade ---------------->|  valida Origin
   |<------------------------- 101 Switching --|  arranca temporizador de auth (5 s)
   |-- auth {access_token} ------------------->|  verifica JWT + sesión activa (Redis)
   |<------------------- auth.ok {user_id,...} -|  SUBSCRIBE user:{user_id}, session:{sid}
   |<------------- message.new / receipt.* ... -|
   |-- typing / seen / ping ------------------->|
   |<---------------------------------- pong --|
   |   (token renovado por REST)               |
   |-- auth {access_token nuevo} ------------->|  reautenticación sin reconectar
   |<------------------------------- auth.ok --|
```

### 3.1 Autenticación (`auth`)

1. Tras el handshake el cliente dispone de **5 segundos** para enviar `auth`. Si no lo hace, el
   servidor cierra con código `4001` (`auth_timeout`).
2. Antes de `auth.ok`, cualquier otro mensaje del cliente produce cierre `4003` (`not_authenticated`).
3. El servidor valida el JWT igual que `JwtMiddleware` (firma, `iss`, `aud`, `typ=access`, `exp`)
   **y** comprueba en Redis que la sesión `sid` siga activa y el usuario no esté desactivado.
   Si falla: `error` con `code: invalid_token` y cierre `4401` (el primer fallo cierra la conexión;
   no hay reintentos dentro de la misma conexión).
4. Máximo 10 conexiones simultáneas por usuario y proceso WS (la más antigua se cierra con `4008`
   `too_many_connections`).

### 3.2 Reautenticación

El access token dura 15 minutos. El servidor guarda su `exp` y:

- 60 s antes del vencimiento envía `auth.expiring` (`data.expires_at`).
- El cliente renueva por `POST /auth/refresh` y envía un nuevo `auth` **sobre la misma conexión**.
  El nuevo token debe pertenecer al mismo usuario (si no, cierre `4401`).
- Si `exp` llega sin reautenticación, cierre `4401` (`token_expired`); el cliente renueva y reconecta.

### 3.3 Revocación

Al hacer logout, revocar una sesión, cambiar la contraseña o desactivar la cuenta, la API publica
en `session:{sid}` (o en `user:{id}` para todas) un evento interno `session.revoked`. El servidor
cierra las conexiones afectadas con `4401` (`session_revoked`). El cliente **no** debe reintentar
con el mismo token.

### 3.4 Heartbeat

- El cliente envía `ping` cada **25 s**; el servidor responde `pong`.
- El servidor además envía frames de control WebSocket ping cada 30 s y cierra la conexión si no
  recibe nada (frame de datos o pong de control) durante **60 s** (`1001`).
- Si el cliente no recibe `pong` en 10 s, da la conexión por muerta y reconecta.

### 3.5 Reconexión

Reintento con *backoff* exponencial con *jitter*: 1 s, 2 s, 4 s… hasta 30 s. Tras reconectar y
recibir `auth.ok`, el cliente **resincroniza por REST** (ver §6).

### 3.6 Códigos de cierre

| Código | Motivo | ¿Reintentar? |
|---|---|---|
| 1000 | Cierre normal | No |
| 1001 | Servidor reiniciando o heartbeat perdido | Sí |
| 1008 | Origen no permitido / violación de política | No |
| 1009 | Frame demasiado grande | Sí, corrigiendo el cliente |
| 4001 | `auth_timeout` | Sí |
| 4003 | `not_authenticated` (mensaje antes de `auth`) | Sí |
| 4008 | `too_many_connections` | Sí, con backoff |
| 4029 | `rate_limited` (exceso sostenido de mensajes) | Sí, tras 30 s |
| 4401 | `invalid_token` / `token_expired` / `session_revoked` | Solo tras renovar el token (salvo `session_revoked`: volver al login) |

## 4. Canales

### 4.1 Publicación desde la API (Redis pub/sub)

La API publica **después del COMMIT** de la transacción (nunca dentro), con la misma forma de sobre
que recibe el cliente. Si Redis no está disponible la petición REST **no falla**: se registra un
aviso y los clientes recuperan el evento al resincronizar.

| Canal Redis | Publica | Contenido |
|---|---|---|
| `user:{user_id}` | API | Todos los eventos dirigidos a un usuario (uno por destinatario; un mensaje nuevo se publica en el canal del receptor **y** en el del emisor, para sus otros dispositivos) |
| `session:{session_id}` | API | `session.revoked` de una sesión concreta |
| *(presencia)* | Servidor WS | Los cambios de presencia se publican como evento `presence` en `user:{id}` de cada usuario relacionado, así llegan a cualquier nodo WS (no hace falta un canal `presence` aparte) |

`user_id` es el UUID público. Cada proceso WS se suscribe por patrón a `user:*` y `session:*` y
reenvía el sobre tal cual a sus conexiones locales de ese usuario/sesión, filtrando los eventos
internos: `session.revoked` (cierra las conexiones de la sesión con `4401 session_revoked`) y
`block.changed` (lo publica la API al bloquear/desbloquear para invalidar la caché de relaciones).

Ejemplo (PHP, tras el commit del envío):

```php
$redis->publish("user:$receptorId", json_encode($evento, JSON_UNESCAPED_UNICODE));
$redis->publish("user:$emisorId",   json_encode($evento, JSON_UNESCAPED_UNICODE));
```

### 4.2 Estado de presencia en Redis

- `presence:{user_id}` → contador de conexiones (INCR/DECR) con TTL de 90 s renovado con el heartbeat.
- `last_seen:{user_id}` → marca temporal de la última desconexión.

## 5. Catálogo de eventos

### 5.1 Servidor → cliente

| `type` | Origen | Destinatarios | `data` |
|---|---|---|---|
| `auth.ok` | WS | la conexión | `{ reply_to, user_id, session_id, expires_at, heartbeat_interval: 25 }` |
| `auth.expiring` | WS | la conexión | `{ expires_at }` |
| `pong` | WS | la conexión | `{ reply_to }` |
| `message.new` | API | emisor y receptor | `{ message: Message }` |
| `message.edited` | API | ambos participantes | `{ message: Message }` (con `edited_at`) |
| `message.deleted` | API | ambos participantes | `{ conversation_id, message_id, deleted_at }` |
| `receipt.delivered` | API/WS | emisor de los mensajes | `{ conversation_id, user_id, up_to_message_id, at }` |
| `receipt.seen` | API/WS | emisor de los mensajes | `{ conversation_id, user_id, up_to_message_id, at }` |
| `conversation.new` | API | ambos participantes | `{ conversation: Conversation }` (vista de cada destinatario; en la del otro participante `contact_alias` puede ser null) |
| `typing` | WS | el otro participante | `{ conversation_id, user_id, state: "start" \| "stop" }` |
| `presence` | WS | usuarios con relación | `{ user_id, status: "online" \| "offline", last_seen_at }` (`last_seen_at` null si online) |
| `error` | WS | la conexión | `{ reply_to?, code, detail }` |

Ejemplo `message.new`:

```json
{
  "type": "message.new",
  "id": "0192d5a1-0c00-7000-8000-000000000001",
  "ts": "2026-10-29T14:03:12.130Z",
  "data": {
    "message": {
      "id": "0192d5a1-0b7c-7f00-8a11-3c4d5e6f7a8b",
      "conversation_id": "0192d59f-11aa-7b2c-8d3e-4f5a6b7c8d9e",
      "sender_id": "0192d590-aaaa-7bbb-8ccc-ddddeeeeffff",
      "client_id": "0192d5a0-6a1e-7c1a-9f3b-2d5e8c7a1b00",
      "text": "Hola, ¿cómo estás?",
      "media": null,
      "created_at": "2026-10-29T14:03:12.123Z",
      "edited_at": null,
      "deleted_at": null,
      "cursor": "MjAyNi0xMC0yOVQxNDowMzoxMi4xMjNafDAxOTJkNWExLTBiN2M"
    }
  }
}
```

Notas:
- El contenido viaja **descifrado** (la API lo descifra antes de publicar). Redis está en la red
  interna de Docker, sin puerto expuesto y con contraseña (`requirepass`); el canal WS público debe
  ir sobre TLS (`wss://`) en producción. Si se quiere evitar texto en claro en Redis, la alternativa
  es publicar solo `{conversation_id, message_id}` y que el cliente lo pida por REST (más latencia).
- `media.url` es una URL prefirmada de corta duración; si caducó, el cliente la renueva pidiendo el
  mensaje por REST.
- **Presencia**: solo se emite a usuarios con relación (contacto en cualquier sentido o conversación
  compartida) y nunca entre usuarios bloqueados. Al conectar, el servidor no envía la presencia de
  todos los contactos: el cliente la pregunta con `presence.query` (ver abajo).
- `receipt.delivered` lo genera automáticamente el servidor WS cuando entrega `message.new` a
  alguna conexión del receptor (llama a `fn_marcar_recibos` con el usuario receptor y publica al
  emisor solo si cambió algo). La API también publica `receipt.delivered` al listar mensajes y
  `receipt.seen` cuando el usuario envía un mensaje (responder implica haber leído lo anterior).
- `message.new` / `message.edited`: el emisor recibe su vista (con `client_id` y `status`); el otro
  participante, la suya (`client_id: null`, sin `status`).

Códigos de `error`:

| `code` | Significado |
|---|---|
| `invalid_token` | Token inválido, expirado o de una sesión revocada |
| `not_found` | Conversación o mensaje inexistente o ajeno (no se distingue) |
| `blocked` | Acción no permitida por bloqueo |
| `rate_limited` | Exceso de eventos; `data.retry_after` en segundos |
| `invalid_payload` | JSON inválido o `data` con forma incorrecta |
| `unknown_type` | `type` no soportado |
| `internal` | Error interno (sin detalles) |

### 5.2 Cliente → servidor

| `type` | `data` | Respuesta | Límite |
|---|---|---|---|
| `auth` | `{ access_token }` | `auth.ok` o `error` + cierre `4401` | 3 fallos por conexión |
| `ping` | `{}` | `pong` | 1 cada 5 s (orientativo; cuenta para el límite global) |
| `typing` | `{ conversation_id, state: "start" \| "stop" }` | ninguna (o `error`) | 1 `start` cada 3 s por conversación (los repetidos no se reenvían, solo renuevan la caducidad) |
| `seen` | `{ conversation_id, up_to_message_id }` | `error` solo si falla | 10 cada 10 s |
| `presence.query` | `{ user_ids: [UUID, …] }` (máx. 100) | un `presence` por usuario con relación | 5 por minuto |

- `typing`: el servidor comprueba que el usuario participa en la conversación (cache Redis de
  participantes, TTL 5 min) y que no hay bloqueo (`fn_filtrar_relacionados`, caché de 30 s que se
  invalida con `block.changed`); reenvía al otro participante. No se persiste. Si no llega `stop`, a
  los 6 s el servidor envía él mismo `typing` con `state: "stop"`.
- `seen`: equivale a `POST /conversations/{id}/receipts` con `status: seen`. El servidor WS lo
  persiste llamando a la misma función de BD (validando participación con el `user_id` autenticado)
  y publica `receipt.seen` al emisor.
- Límite global por conexión: 20 mensajes en 10 s. Al superarlo, `error` `rate_limited` (con
  `retry_after`); si se mantiene 30 s, cierre `4029`.
- Frames de más de 16 KiB: cierre `1009`. Por encima de 64 KiB la conexión TCP se corta sin frame de cierre.
- Heartbeat: el servidor envía un frame de control *ping* cada 30 s; cualquier mensaje o *pong*
  cuenta como actividad; sin actividad en 60 s cierra con `1001`.

## 6. Garantías de entrega y resincronización

- **At-most-once**: Redis pub/sub no persiste. Un evento publicado mientras el cliente está
  desconectado (o mientras el nodo WS reinicia) **se pierde** para esa conexión.
- **Sin orden global garantizado** entre canales; dentro de una conversación el orden de verdad es
  `(created_at, id)` del mensaje, no el de llegada del evento.
- **Idempotencia en el cliente**: los eventos se aplican por `message.id` (upsert). Recibir dos veces
  el mismo `message.new` o un `message.edited` antes que su `message.new` no debe romper la vista
  (si llega una edición de un mensaje desconocido, el cliente lo pide por REST).
- El emisor reconcilia su mensaje optimista con `client_id`.
- **Resincronización** (obligatoria tras cada `auth.ok` que siga a una reconexión):
  1. `GET /conversations` para actualizar la lista, `unread_count` y `last_message`.
  2. Para cada conversación abierta en pantalla:
     `GET /conversations/{id}/messages?after=<cursor del último mensaje conocido>` hasta que
     `next_cursor` sea `null`.
  3. Las ediciones/borrados de mensajes antiguos no visibles se reflejan al volver a cargarlos.
- Si se necesitara *at-least-once* en el futuro, la evolución prevista es Redis Streams con
  `XREAD` desde el último id confirmado por el cliente (ver `docs/requerimientos-api.md`).

## 7. Resumen AsyncAPI (orientativo)

```yaml
asyncapi: 3.0.0
info: { title: CR_Chat WebSocket, version: 1.0.0 }
servers:
  local: { host: 'localhost:8080', protocol: ws, pathname: /ws }
channels:
  ws:
    address: /ws
    messages:
      auth: { payload: { $ref: '#/components/schemas/Auth' } }
      ping: {}
      typing: {}
      seen: {}
      presenceQuery: {}
      authOk: {}
      authExpiring: {}
      pong: {}
      messageNew: {}
      messageEdited: {}
      messageDeleted: {}
      receiptDelivered: {}
      receiptSeen: {}
      conversationNew: {}
      typingEvent: {}
      presence: {}
      error: {}
operations:
  enviarAlServidor:
    action: receive
    channel: { $ref: '#/channels/ws' }
    messages: [auth, ping, typing, seen, presenceQuery]
  recibirDelServidor:
    action: send
    channel: { $ref: '#/channels/ws' }
    messages: [authOk, authExpiring, pong, messageNew, messageEdited, messageDeleted,
               receiptDelivered, receiptSeen, conversationNew, typingEvent, presence, error]
```

(Las referencias `$ref` a mensajes se omiten por brevedad; las cargas útiles son las de §5.)

## 8. Pruebas (`datos/tests/ws_test.py`, implementadas)

- Sin `auth` en 5 s → cierre `4001`. Mensaje antes de `auth` → `4003`.
- Token inválido / sesión revocada → `error invalid_token` + `4401`.
- A envía por REST → B recibe `message.new` y A (otra conexión) también; A recibe `receipt.delivered`.
- B envía `seen` → A recibe `receipt.seen`; `unread_count` de B pasa a 0 por REST.
- `typing` a una conversación ajena → `error not_found`; con bloqueo → `error blocked`.
- Logout de A → su conexión se cierra con `4401`.
- Reconexión: mensajes enviados durante la desconexión se recuperan con `?after=`.
