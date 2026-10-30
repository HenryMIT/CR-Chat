# Contrato de funciones de base de datos (PostgreSQL 17) — v1

Fuente: `Postgres/migraciones/005_funciones_api_v1.sql` (esquema en `002` + `004`).
Modelo: [`docs/db/modelo.md`](../db/modelo.md). API: [`openapi.yaml`](openapi.yaml), [`ws-eventos.md`](ws-eventos.md).
Estado: **Fase 1b** (contrato cerrado con la API v1). Las funciones de la `003` (ids `bigint`) quedan
reemplazadas por la `005`; no se deben usar.

## 1. Conexión esperada

| Uso | Host:puerto | Rol | Notas |
|---|---|---|---|
| Escritura, autenticación, sesiones, job de media | `haproxy:5000` (líder Patroni) | `app_rw` | Todas las funciones. `statement_timeout=5s`. |
| Lectura | `haproxy:5001` (réplicas) | `app_ro` | Solo las funciones de la tabla 3.10. Sesiones en `default_transaction_read_only`. |
| Migraciones | `haproxy:5000` | superusuario para 001 y 004 (extensiones); `migrator` el resto | dbmate, `Postgres/migraciones/`. |

Variables para `.env.example` (los valores nunca van al repo):

```
DB_NAME=cr_chat
DB_RW_HOST=haproxy   DB_RW_PORT=5000  DB_RW_USER=app_rw  DB_RW_PASSWORD=
DB_RO_HOST=haproxy   DB_RO_PORT=5001  DB_RO_USER=app_ro  DB_RO_PASSWORD=
MINIO_BUCKET=cr-chat-media        # se pasa a fn_registrar_media (p_bucket)
```

DSN PDO: `pgsql:host=haproxy;port=5000;dbname=cr_chat;application_name=cr_chat_api`.

### 1.1 Identificadores (decisión)

- **Todos los ids que entran o salen de las funciones son `public_id uuid`** (usuario, contacto, conversación,
  mensaje, sesión, media). Los `bigint` son internos y ninguna función de la API los recibe ni los devuelve
  (lo verifica `Postgres/pruebas/catalogo.sql`, consulta 6).
- **El usuario autenticado llega como `p_usuario uuid`**: es el `sub` del JWT ya validado (el `public_id`
  del usuario). Nunca se toma del cuerpo, la ruta ni la query. Así la API no necesita conocer ni cachear el
  `bigint` interno. La sesión del access token (`sid`) es el `public_id` de `sesion`.
- `gen_random_uuid()` genera UUID **v4** (decisión aprobada). La API no debe asumir v7 (el `openapi.yaml`
  dice "UUID v7"; para la API son opacos y v4 no filtra la hora de creación).

### 1.2 Reglas de uso

- Llamar con `SELECT * FROM fn_x(...)` y parámetros enlazados (`PDO::prepare`). Los `bytea` con
  `PDO::PARAM_LOB`; `uuid`, `timestamptz`, `interval`, `inet` y arrays (`'{...}'`) como texto.
- Cada llamada es atómica (autocommit). Si la API agrupa varias en una transacción, publica en Redis **después del COMMIT**.
- **Lectura después de escritura:** las réplicas pueden ir atrasadas. Para releer lo recién escrito usa el pool `app_rw`.
- Ninguna función usa `WHEN OTHERS`: un SQLSTATE fuera de la tabla 2 es un 500 real y se registra.
- Campos de media (`avatar`, `peer_avatar`, `media`, `ult_media`) son `jsonb` o NULL:
  `{"id": uuid, "bucket", "clave_objeto", "mime", "tamano_bytes", "ancho", "alto"}`. La API genera la URL
  GET prefirmada con `bucket` + `clave_objeto` y responde el schema `Media` (`id`, `content_type`, `size_bytes`,
  `width`, `height`, `url`, `url_expires_at`). Nunca se exponen `bucket` ni `clave_objeto` al cliente.
- Mensajes: la BD guarda `contenido` (ciphertext + tag), `nonce` (24 bytes) y `key_id` (≥ 1) tal cual los
  produce `sodium_crypto_aead_xchacha20poly1305_ietf_encrypt` en PHP. Los tres van juntos o ninguno.

## 2. Errores (SQLSTATE propios, clase `CR`)

| SQLSTATE | HTTP sugerido | Significado | `HINT` (estable, para elegir el `type` del problema) |
|---|---|---|---|
| `CR401` | 401 | Usuario autenticado inexistente o dado de baja; refresh desconocido, de sesión revocada o expirada. | En `fn_rotar_sesion`: `desconocido`, `revocada`, `expirada`, `inactivo`. |
| `CR403` | 403 | Prohibido sobre un recurso visible. | `bloqueado` (bloqueo en cualquier sentido o destinatario dado de baja) · `no-autor` (editar/borrar mensaje ajeno). |
| `CR404` | 404 | No existe **o no pertenece al usuario** (mismo error: anti-IDOR/enumeración). | — |
| `CR409` | 409 | Conflicto de unicidad. **La API responde un 409 genérico** (A-13); `DETAIL` (nombre del constraint) solo va al log. | `client_id` (reutilizado en otra conversación). |
| `CR422` | 422 (o 400 si es `cursor`) | Parámetros inválidos. `DETAIL` puede traer el constraint violado. | Campo de la API: `alias`, `about`, `avatar_media_id`, `media_id`, `text`, `phone`, `status`, `user_ids`, `q`, `cursor` · `edicion-expirada`. |
| `42501` | 500 (alerta) | `insufficient_privilege`: rol equivocado (escritura por `app_ro`). | — |
| `25006` | 500 (alerta) | `read_only_sql_transaction`: se escribió por 5001. | — |

Mapeos sugeridos al `openapi.yaml`: `CR403/no-autor` en `PATCH/DELETE /messages/{id}` → **404** si se quiere seguir
literalmente el contrato REST ("un mensaje ajeno responde 404"); la BD distingue para que el log sea útil.
`CR422/cursor` → 400 (`BadRequest`).

En PHP: `PDOException::errorInfo[0]` = SQLSTATE; `errorInfo[2]` incluye `DETAIL`/`HINT` en el texto
(o `pg_result_error_field` con la extensión `pgsql`).

### 2.1 Límites validados en la BD

| Campo | Regla |
|---|---|
| `telefono` | E.164 estricto `^\+[1-9][0-9]{7,14}$` (normalizar con libphonenumber en la API) |
| `email` | `citext`, ≤ 254, `algo@dominio.tld` |
| `nombre_usuario` | 1..50 (con `btrim`) |
| `descripcion` (`about`) | ≤ 140 o NULL |
| `pass_hash` | empieza por `$argon2id$`, ≤ 255 |
| `alias` (contacto) | 1..50 o NULL (NULL = se muestra el nombre del usuario) |
| `contenido` / `nonce` / `key_id` | `bytea` 1..65 536 / exactamente 24 bytes / `smallint` ≥ 1; los tres o ninguno |
| media | `mime` ∈ {jpeg, png, webp, gif, pdf, ogg, mpeg, mp4}; avatar solo jpeg/png/webp; tamaño 1..20 MiB (avatar ≤ 2 MiB); `bucket` nombre S3 válido |
| sesión | `dispositivo` 1..100; `user_agent` ≤ 512; refresh = SHA-256 (32 bytes); IP truncada a /24 o /48 por la BD |
| `p_limite` | 1..100 (por defecto 50, como `Limit` en la API) |

## 3. Funciones

Todas son `SECURITY INVOKER`, `SET search_path = public, pg_temp`, sin `EXECUTE` para `PUBLIC`. Todas las que
reciben `p_usuario` exigen que exista y esté activo (si no, `CR401`). "Propiedad" = lo que la función valida.

### 3.1 Autenticación y cuenta

| Firma | API | Notas / errores |
|---|---|---|
| `fn_registrar_usuario(p_nombre_usuario text, p_telefono text, p_email text, p_pass_hash text) → uuid` | `POST /auth/register` | Devuelve el `public_id`. Luego `fn_leer_perfil` para responder `Me`. `CR409` (genérico), `CR422`. |
| `fn_credenciales_login(p_identificador text) → TABLE(id_usuario uuid, pass_hash text, eliminado bool, eliminado_at timestamptz)` | `POST /auth/login`, `/auth/reactivate` | **Solo login.** Con `@` busca por email (citext), si no por teléfono (decisión: login por teléfono **o** email). No compara contraseñas; 0 filas → 401 genérico + `password_verify` contra un hash ficticio. `eliminado` → 401 en login; en reactivate → `fn_reactivar_usuario`. Tras éxito: `password_needs_rehash` → `fn_rehash_pass`. Solo `app_rw`. |
| `fn_leer_perfil(p_usuario uuid) → TABLE(id uuid, nombre_usuario, telefono, email, descripcion, avatar jsonb, created_at)` | `GET /me` | Schema `Me`. |
| `fn_actualizar_usuario(p_usuario uuid, p_nombre_usuario text = NULL, p_descripcion text = NULL, p_quitar_descripcion bool = false, p_avatar uuid = NULL, p_quitar_avatar bool = false) → mismo TABLE que fn_leer_perfil` | `PATCH /me` | NULL = no cambiar; `about: null` → `p_quitar_descripcion => true`; `avatar_media_id: null` → `p_quitar_avatar => true`. `p_avatar`: media **propia**, `proposito='avatar'`, pendiente (o el avatar actual). La API hace antes `fn_obtener_media` + HEAD en MinIO. Confirma la media y deja la anterior en `borrado`. `CR422` (`avatar_media_id`, `about`, nombre). |
| `fn_rehash_pass(p_usuario uuid, p_pass_hash text) → void` | login (rehash) | No revoca sesiones. `CR422`. |
| `fn_cambiar_pass_hash(p_usuario uuid, p_pass_hash text, p_sesion_actual uuid) → TABLE(id_sesion uuid)` | `PUT /me/password` | PHP verifica la contraseña actual antes. Revoca **las demás** sesiones (NULL = todas) y devuelve sus `sid` → publicar `session.revoked` en `session:{sid}`. `CR422`. |
| `fn_cambiar_telefono(p_usuario uuid, p_telefono text, p_sesion_actual uuid) → TABLE(id_sesion uuid)` | `PUT /me/phone` | Igual que arriba. `CR409` genérico, `CR422 phone`. |
| `fn_borrar_usuario(p_usuario uuid) → TABLE(id_sesion uuid)` | `DELETE /me` | Baja lógica; revoca **todas** las sesiones y las devuelve. |
| `fn_reactivar_usuario(p_usuario uuid, p_plazo interval = '30 days') → void` | `POST /auth/reactivate` | Solo dentro del plazo de gracia. `CR404` si activa, inexistente o fuera de plazo (la API responde el 401 genérico). |
| `fn_perfil_publico(p_usuario uuid, p_objetivo uuid) → TABLE(id uuid, nombre_usuario, descripcion, avatar jsonb, telefono text, es_contacto bool)` | `GET /users/{userId}` | **Propiedad:** relación (contacto activo en cualquier sentido o conversación compartida) y **sin bloqueo en ningún sentido**; si no, o si no existe / está inactivo → `CR404`. Nunca email. `telefono` solo si es mi contacto. Uno mismo cuenta como relacionado. |

### 3.2 Sesiones (una por dispositivo; refresh opaco rotado)

El refresh token es opaco (32 bytes aleatorios, base64url). La BD solo guarda `sha256(token)` (32 bytes) y su
`jti`; la API calcula el hash con `hash('sha256', $token, true)`. La sesión (`sid`) es estable entre rotaciones.

| Firma | API | Notas / errores |
|---|---|---|
| `fn_crear_sesion(p_usuario uuid, p_jti uuid, p_refresh_hash bytea, p_dispositivo text, p_user_agent text = NULL, p_ip inet = NULL, p_vida interval = '30 days', p_vida_max interval = '90 days') → TABLE(id_sesion uuid, expira_at timestamptz)` | login, reactivate | `id_sesion` = `sid` del JWT. La BD trunca la IP a /24 (IPv4) o /48 (IPv6). `CR409` jti/hash repetido, `CR422`. |
| `fn_rotar_sesion(p_refresh_hash bytea, p_jti_nuevo uuid, p_hash_nuevo bytea, p_vida interval = '30 days') → TABLE(estado text, id_usuario uuid, id_sesion uuid, expira_at timestamptz)` | `POST /auth/refresh` | Busca por hash (no necesita `sub`). `estado='ok'`: rota y desliza `expira_at` sin pasar el máximo absoluto. **`estado='reutilizacion'`**: el refresh ya se había rotado → la función **revoca la sesión y confirma** (no lanza error para que la revocación persista); la API responde 401 y publica `session.revoked`. `CR401` con HINT `desconocido` / `revocada` / `expirada` / `inactivo`. Nota: dos refresh simultáneos con el mismo token disparan la detección; el cliente debe serializar el refresh. |
| `fn_tocar_sesion(p_usuario uuid, p_sesion uuid) → boolean` | middleware (respaldo de Redis) | `true` si la sesión es del usuario, no revocada ni expirada y el usuario activo; actualiza `last_used_at` como mucho una vez por minuto. Nunca lanza CR404 (sesión ajena = `false`). |
| `fn_listar_sesiones(p_usuario uuid, p_sesion_actual uuid) → TABLE(id uuid, dispositivo, user_agent, ip_hint text, created_at, last_used_at, expira_at, actual bool)` | `GET /me/sessions` | Solo activas; `last_used_at DESC`. `ip_hint` → `ip_hint`, `dispositivo` → `device_name`. |
| `fn_revocar_sesion(p_usuario uuid, p_sesion uuid, p_motivo text = 'revocada') → boolean` | `POST /auth/logout` (`'logout'`), `DELETE /me/sessions/{id}` | Ajena/inexistente → `CR404`. Ya revocada → `false` (idempotente). `CR422` motivo. |
| `fn_revocar_sesiones(p_usuario uuid, p_excepto uuid = NULL) → TABLE(id_sesion uuid)` | `DELETE /me/sessions` (`p_excepto` = `sid` actual) | Devuelve los `sid` revocados. |

### 3.3 Contactos (schema `Contact`)

Columnas comunes: `id uuid, alias text, telefono text, id_usuario uuid, nombre_usuario text, avatar jsonb,
id_conversacion uuid, bloqueado bool, created_at timestamptz, orden text`. `alias` NULL → la UI muestra
`nombre_usuario`. `bloqueado` = yo bloqueé a ese usuario. `orden` es la clave del cursor. El avatar es NULL si
ese usuario me bloqueó.

| Firma | API | Notas / errores |
|---|---|---|
| `fn_crear_contacto(p_usuario uuid, p_telefono text, p_alias text = NULL) → TABLE(<columnas>, creado bool)` | `POST /contacts` | Idempotente: existente → `creado=false` (200, alias sin cambios); nuevo o reactivado → `creado=true` (201). No registrado, uno mismo o **el destino me bloqueó** → el mismo `CR404`. `CR422 alias`. |
| `fn_obtener_contacto(p_usuario uuid, p_contacto uuid) → TABLE(<columnas>)` | `GET /contacts/{id}` | Ajeno, borrado o de usuario inactivo → `CR404`. |
| `fn_listar_contactos(p_usuario uuid, p_busqueda text = NULL, p_limite int = 50, p_cursor_orden text = NULL, p_cursor_id uuid = NULL) → TABLE(<columnas>)` | `GET /contacts?q=&cursor=&limit=` | Orden `(orden COLLATE "C", id)`; `orden` = alias o nombre en minúsculas y sin acentos. `q` (≤ 50): subcadena en alias o nombre sin acentos/mayúsculas, o prefijo del teléfono con o sin `+`; comodines escapados. Cursor = `orden` + `id` de la última fila (p. ej. `base64url(json)`). `CR422 cursor/q`. |
| `fn_actualizar_contacto(p_usuario uuid, p_contacto uuid, p_alias text) → TABLE(<columnas>)` | `PATCH /contacts/{id}` | Solo alias; NULL vuelve al nombre. `CR404`, `CR422 alias`. |
| `fn_borrar_contacto(p_usuario uuid, p_contacto uuid) → void` | `DELETE /contacts/{id}` | Baja lógica; la conversación se conserva. `CR404`. |

### 3.4 Bloqueos

| Firma | API | Notas / errores |
|---|---|---|
| `fn_bloquear_usuario(p_usuario uuid, p_objetivo uuid) → boolean` | `PUT /blocks/{userId}` | Idempotente (`true` = nuevo). Solo con relación; inexistente, inactivo o sin relación → `CR404`; a uno mismo → `CR422`. |
| `fn_desbloquear_usuario(p_usuario uuid, p_objetivo uuid) → boolean` | `DELETE /blocks/{userId}` | Idempotente (`true` = existía). Nunca `CR404`. |
| `fn_listar_bloqueos(p_usuario uuid, p_limite int = 50, p_cursor_at timestamptz = NULL, p_cursor_id uuid = NULL) → TABLE(id_usuario uuid, nombre_usuario, avatar jsonb, created_at)` | `GET /blocks` | Más reciente primero. Cursor = `created_at` + `id_usuario` de la última fila. |

Efectos del bloqueo (en cualquier sentido): `CR403 bloqueado` al enviar, editar o crear conversación; `CR404` en
perfil público; excluido de presencia; avatar oculto **para el bloqueado**; `fn_crear_contacto` → `CR404` si el
destino me bloqueó.

### 3.5 Conversaciones (schema `Conversation`)

Columnas comunes: `id uuid, id_peer uuid, peer_nombre text, peer_avatar jsonb, peer_activo bool, id_contacto uuid,
es_contacto bool, bloqueado bool, no_leidos int, created_at, ultimo_mensaje_at` y el último mensaje
(`last_message`, NULL si no hay): `ult_id uuid, ult_id_remitente uuid, ult_client_id uuid, ult_contenido bytea,
ult_nonce bytea, ult_key_id smallint, ult_media jsonb, ult_created_at, ult_editado_at, ult_deleted_at, ult_estado text`.

- `es_contacto=false` → solicitud de mensaje (U-06). `bloqueado` = yo bloqueé al otro.
- `no_leidos` (`unread_count`) tiene **tope 100** ("99+"); excluye mensajes borrados.
- `last_message` puede ser una lápida (`ult_deleted_at` no NULL, contenido NULL). `ult_estado` (`sent|delivered|seen`) y
  `ult_client_id` solo en mensajes propios.

| Firma | API | Notas / errores |
|---|---|---|
| `fn_crear_conversacion(p_usuario uuid, p_contacto uuid) → TABLE(<columnas>, creada bool)` | `POST /conversations` | Obtener-o-crear, seguro ante carreras (una sola 1:1 por par). 201 si `creada`, 200 si no. Contacto ajeno/inexistente → `CR404`; bloqueo → `CR403 bloqueado`. Publicar `conversation.new` a ambos con la vista de cada uno: para el otro participante, la API llama `fn_obtener_conversacion` con **su** uuid (única excepción a "p_usuario = sub del JWT": evento generado por el servidor para un participante devuelto por `fn_participantes_conversacion`). |
| `fn_obtener_conversacion(p_usuario uuid, p_conversacion uuid) → TABLE(<columnas>)` | `GET /conversations/{id}` | No participante → `CR404`. |
| `fn_listar_conversaciones(p_usuario uuid, p_limite int = 50, p_cursor_at timestamptz = NULL, p_cursor_id uuid = NULL) → TABLE(<columnas>)` | `GET /conversations` | `ultimo_mensaje_at DESC, id DESC`. Cursor = `ultimo_mensaje_at` + `id` de la última fila. |
| `fn_participantes_conversacion(p_usuario uuid, p_conversacion uuid) → TABLE(id_usuario uuid)` | interno (Redis `user:{id}`) | Incluye al llamante. No participante → `CR404`. Para `typing` el WS puede cachearlo 5 min. |

### 3.6 Mensajes (schema `Message`)

Columnas comunes: `id uuid, id_conversacion uuid, id_remitente uuid, client_id uuid, contenido bytea, nonce bytea,
key_id smallint, media jsonb, created_at, editado_at, deleted_at, estado text`. Orden cronológico ascendente.
`client_id` y `estado` (`sent|delivered|seen`, agregado de los recibos del otro) solo en mensajes propios.
Lápida: `deleted_at` no NULL y `contenido`/`nonce`/`key_id`/`media` NULL. El `cursor` del schema `Message` = el
`id` del mensaje codificado de forma opaca.

| Firma | API | Notas / errores |
|---|---|---|
| `fn_enviar_mensaje(p_usuario uuid, p_conversacion uuid, p_contenido bytea = NULL, p_nonce bytea = NULL, p_key_id smallint = NULL, p_media uuid = NULL, p_client_id uuid = NULL) → TABLE(<columnas>, creado bool)` | `POST /conversations/{id}/messages` | Texto y/o adjunto. `p_client_id` = `client_id` o `Idempotency-Key`: si ya existe en esta conversación devuelve el original (`creado=false` → 200), incluso si después hubo un bloqueo; en otra conversación → `CR409 client_id`. La unicidad es permanente (más estricta que las 24 h de M-04). `p_media`: media propia `proposito='mensaje'` **pendiente** (un adjunto = un mensaje) → queda confirmada; si no, `CR422 media_id`. Sin texto ni adjunto → `CR422 text`. No participante → `CR404`; bloqueo o destinatario de baja → `CR403 bloqueado`. Crea los recibos y actualiza `ultimo_mensaje_at`. |
| `fn_listar_mensajes(p_usuario uuid, p_conversacion uuid, p_limite int = 50, p_antes uuid = NULL, p_despues uuid = NULL) → TABLE(<columnas>)` | `GET /conversations/{id}/messages?before=&after=&limit=` | Sin cursor: los más recientes; `p_antes`: los inmediatamente anteriores; `p_despues`: los inmediatamente posteriores (resincronización WS). Siempre ascendente. `next_cursor`: con before la **primera** fila, con after la **última**; si llegan menos de `p_limite` filas no hay más. Ambos → `CR422 cursor`; cursor que no es de esa conversación → `CR422 cursor` (400). No participante → `CR404`. **No marca entregado**: la API llama después `fn_marcar_recibos(..., 'delivered', <último id recibido>)` por el pool rw. |
| `fn_editar_mensaje(p_usuario uuid, p_mensaje uuid, p_contenido bytea, p_nonce bytea, p_key_id smallint) → TABLE(<columnas>)` | `PATCH /messages/{id}` | Solo el autor y **dentro de 15 min**. No participante, inexistente o borrado → `CR404`; participante no autor → `CR403 no-autor`; bloqueo → `CR403 bloqueado`; fuera de plazo → `CR422 edicion-expirada`. Publicar `message.edited`. |
| `fn_borrar_mensaje(p_usuario uuid, p_mensaje uuid) → TABLE(id_conversacion uuid, deleted_at timestamptz, borrado bool)` | `DELETE /messages/{id}` | Lápida para todos: borra contenido y adjunto (la media pasa a `borrado`). Ya borrado → `borrado=false` (204 idempotente, no volver a publicar). `CR404` / `CR403 no-autor`. Publicar `message.deleted` si `borrado`. |

### 3.7 Recibos

| Firma | API | Notas / errores |
|---|---|---|
| `fn_marcar_recibos(p_usuario uuid, p_conversacion uuid, p_estado text, p_hasta uuid) → TABLE(actualizados int, no_leidos int, marcado_at timestamptz)` | `POST /conversations/{id}/receipts`, WS `seen`, entrega automática del WS | `p_estado` ∈ `delivered`, `seen` (`CR422 status`). Marcador **monótono**: marca mis recibos de todos los mensajes con `(created_at, id) <= p_hasta` (nunca retrocede; `seen` implica `delivered`). `p_hasta` debe ser un mensaje de la conversación (si no, `CR404`). Devuelve `updated_count` y `unread_count` (tope 100). Publicar `receipt.*` solo si `actualizados > 0`, con `at = marcado_at`. |

### 3.8 Media (MinIO)

Flujo: `POST /uploads` → `fn_registrar_media` → la API firma un PUT (5 min) con `bucket` + `clave_objeto` →
el cliente sube → al referenciar (`PATCH /me` o envío) la API llama `fn_obtener_media`, hace HEAD y compara
tamaño/MIME reales con los registrados → `fn_actualizar_usuario` / `fn_enviar_mensaje` confirman la media.

| Firma | API | Notas / errores |
|---|---|---|
| `fn_registrar_media(p_usuario uuid, p_proposito text, p_mime text, p_tamano bigint, p_bucket text, p_ancho int = NULL, p_alto int = NULL) → TABLE(id uuid, bucket text, clave_objeto text)` | `POST /uploads` | `p_proposito` ∈ `avatar`, `mensaje`. La **BD genera la clave** `<proposito>/<AAAA>/<MM>/<id>` (sin rutas del cliente). `CR422` tipo/tamaño/bucket. |
| `fn_obtener_media(p_usuario uuid, p_media uuid) → TABLE(id uuid, proposito, bucket, clave_objeto, mime, tamano_bytes bigint, estado, created_at)` | verificación previa (HEAD) | Solo media **propia**; ajena o inexistente → `CR404`. |
| `fn_listar_media_huerfana(p_antiguedad interval = '24 hours', p_limite int = 100) → TABLE(id uuid, bucket, clave_objeto, estado, created_at)` | job de la API (cada hora) | Pendientes más viejas que `p_antiguedad` + todas las `borrado`. `p_limite` 1..1000. |
| `fn_purgar_media(p_ids uuid[], p_antiguedad interval = '24 hours') → int` | job, tras borrar en MinIO | Revalida la condición (una pendiente pudo confirmarse entre medio) y borra las filas. |

### 3.9 Presencia (Redis + BD)

| Firma | Uso | Notas |
|---|---|---|
| `fn_filtrar_relacionados(p_usuario uuid, p_ids uuid[]) → TABLE(id_usuario uuid, last_seen_at timestamptz)` | WS `presence.query` | De hasta 100 ids (`CR422 user_ids`) devuelve solo usuarios activos con relación y sin bloqueo en ningún sentido. |
| `fn_listar_relacionados(p_usuario uuid) → TABLE(id_usuario uuid)` | WS (a quién emitir `presence`) | Contactos en ambos sentidos + participantes de mis conversaciones, sin bloqueos ni inactivos. |
| `fn_registrar_last_seen(p_usuario uuid) → void` | WS, al cerrar la última conexión | Respaldo persistente de `last_seen:{id}` de Redis. No cambia `updated_at`. |

`typing` no toca la BD.

### 3.10 Matriz de EXECUTE

| Funciones | `app_rw` | `app_ro` |
|---|---|---|
| Lectura: `fn_leer_perfil`, `fn_perfil_publico`, `fn_obtener_contacto`, `fn_listar_contactos`, `fn_listar_bloqueos`, `fn_obtener_conversacion`, `fn_listar_conversaciones`, `fn_participantes_conversacion`, `fn_listar_mensajes`, `fn_obtener_media`, `fn_filtrar_relacionados`, `fn_listar_relacionados` | sí | sí |
| Escritura, autenticación, sesiones (incluidas `fn_listar_sesiones` y `fn_tocar_sesion`), recibos, media, `fn_registrar_last_seen` | sí | — |
| Mantenimiento: `fn_crear_particiones_auditoria`, `fn_purgar_sesiones(p_antiguedad interval = '30 days')` | — | — (solo `migrator`, cron en Fase 2) |
| Auxiliares `fn__*`, `fn_normalizar` | sí | sí (salvo `fn__revocar_sesiones`: solo rw) |

## 4. Permisos sobre tablas

| Objeto | `app_rw` | `app_ro` |
|---|---|---|
| `usuario` | SELECT, INSERT, UPDATE | SELECT sin `pass_hash` (por columna) |
| `contacto`, `conversacion`, `mensaje`, `recibo_mensaje` | SELECT, INSERT, UPDATE | SELECT |
| `participante` | SELECT, INSERT | SELECT |
| `bloqueo` | SELECT, INSERT, DELETE | SELECT |
| `media` | SELECT, INSERT, UPDATE, DELETE (purga de huérfanos) | SELECT |
| `sesion`, `sesion_refresh` | SELECT, INSERT, UPDATE | — |
| `auditoria` | INSERT (solo los triggers) | — |
| DDL, TRUNCATE, otros DELETE | — | — |

Como las funciones son `SECURITY INVOKER`, `app_rw` tiene DML directo sobre las tablas. **La API solo debe usar las
funciones**: la revisión de código del backend debe rechazar SQL directo. Mejora futura: Row Level Security con
`SET app.user_id`.

## 5. Cambios respecto a la versión de la 003

| Antes (003) | Ahora (005) |
|---|---|
| `p_id_usuario bigint` e ids `bigint` | `p_usuario uuid` (sub del JWT) e ids `public_id uuid` |
| `fn_crear_contacto` → `bigint`, `CR409` si existía, `CR422` a uno mismo | Idempotente `(<contacto>, creado)`, mismo `CR404` para no registrado / uno mismo / me bloqueó |
| Sesión = una fila por refresh (`jti` como PK), el id cambiaba al rotar | Sesión por dispositivo (`sid` estable) + `sesion_refresh` con hash SHA-256; reutilización revoca sin error |
| `fn_rotar_sesion(p_id_usuario, jti...)` | `fn_rotar_sesion(p_refresh_hash, ...)`; `fn_listar_sesiones`, `fn_tocar_sesion`, `fn_revocar_sesiones(p_excepto)` nuevas |
| `media_url` / `foto_perfil` (URL libre) | `media` con FK (avatar y adjunto), confirmación al referenciar, limpieza de huérfanos |
| `fn_listar_mensajes` solo hacia atrás, sin borrados, más nuevo primero | `before`/`after` por public_id, ascendente, con lápidas |
| `fn_marcar_entregado` / `fn_marcar_visto` por `id_mensaje <= n` | `fn_marcar_recibos` por orden `(created_at, id)` y devuelve `unread_count` |
| Edición sin plazo; borrado no idempotente | 15 min (`CR422 edicion-expirada`); borrado idempotente con lápida |
| — | `fn_perfil_publico`, `fn_obtener_contacto`, `fn_obtener_conversacion`, `fn_participantes_conversacion`, `fn_listar_bloqueos`, presencia, `fn_cambiar_telefono`, `fn_rehash_pass` |
