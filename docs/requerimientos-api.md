# Requerimientos de la API REST de CR_Chat (v1)

Propuesta del agente backend (fase 1, contratos). Contratos de referencia:

- `docs/contratos/openapi.yaml`: API REST, servidor `/api/v1`.
- `docs/contratos/ws-eventos.md`: eventos WebSocket (`ws://host:8080/ws`).
- `docs/contratos/db-funciones.md`: funciones de BD (lo escribe el agente DBA).

Prioridad **MoSCoW**: **M** = imprescindible para v1, **S** = debería estar en v1,
**C** = podría estar si hay tiempo, **W** = no entra en esta versión (queda anotado).

## 1. Principios generales

| Id | Requerimiento | Prioridad | Justificación |
|---|---|---|---|
| G-01 | Versionado en la ruta: `/api/v1`. Las rutas antiguas `/api/*` responden **410 Gone** con un problema que indica la ruta nueva durante una versión y luego se eliminan | M | Cambiar contratos sin romper clientes en silencio |
| G-02 | PostgreSQL es la única fuente de verdad: escrituras por `haproxy:5000`, lecturas por `haproxy:5001` (con lectura propia tras escribir dirigida al primario). Se elimina el failover a MySQL de `conexion.php` | M | El failover reasignaba ids entre motores (JWT de un usuario apuntando a otro) |
| G-03 | Ids públicos UUID (v7) opacos en todos los recursos; los `bigint` internos nunca se exponen | M | Elimina la enumeración de ids secuenciales (IDOR en `/usr/profile/{id}`) |
| G-04 | Errores RFC 9457 (`application/problem+json`: `type`, `title`, `status`, `detail`, `instance`, `request_id`, `errors[]` en 422). Nunca trazas, SQL ni rutas de archivo, aunque `app_debug=true` (los detalles solo van al log) | M | Contrato de error estándar; corrige la filtración de `app_debug` |
| G-05 | Recursos ajenos responden **404** (igual que inexistentes). La propiedad se valida en PHP **y** pasando el id del usuario autenticado a la función de BD | M | Defensa en profundidad contra IDOR |
| G-06 | Validación estricta de entrada: `additionalProperties: false`, longitudes y formatos de `openapi.yaml`; texto sin caracteres de control y normalizado NFC | M | Hallazgos BAJO de validación |
| G-07 | `X-Request-Id` en cada respuesta (se respeta el del proxy si es un UUID válido) y en los logs estructurados JSON | S | Trazabilidad entre API, WS y BD |
| G-08 | Swagger UI en `/docs` (estático, versión fijada) y `openapi.yaml` servido en `/docs/openapi.yaml`. En producción se puede desactivar con `docs_enabled=false` | S | Documentación navegable para el portafolio y el frontend |
| G-09 | Pruebas de contrato: las respuestas de `api_test.py` se validan contra `openapi.yaml` (p. ej. con `openapi-core`) y el lint de Redocly corre en CI | S | Evita que código y contrato diverjan |
| G-10 | Encabezados de seguridad: `X-Content-Type-Options: nosniff`, `Cache-Control: no-store` en respuestas autenticadas, `Referrer-Policy: no-referrer`, `Strict-Transport-Security` detrás de TLS | S | Endurecimiento básico |

## 2. Autenticación, sesiones y cuenta

| Id | Requerimiento | Prioridad | Justificación |
|---|---|---|---|
| A-01 | Login **solo por email** (citext). El teléfono nunca es credencial; se valida E.164 con libphonenumber | M | Corrige el robo de cuenta (registrar un `phone_number` igual al email de otra persona) |
| A-02 | Contraseñas con `password_hash(PASSWORD_ARGON2ID)` y `password_verify` en PHP; `password_needs_rehash` en el login. La BD solo guarda el hash. Política: 10–128 caracteres, distinta de email/teléfono, contra lista de contraseñas comunes | M | Elimina el cifrado reversible con `key_decryption` |
| A-03 | Login con tiempo constante: si el email no existe se verifica contra un hash ficticio; mismo 401 para usuario inexistente, contraseña incorrecta o cuenta desactivada | M | Evita enumeración de emails por tiempo o mensaje |
| A-04 | **Sesiones por dispositivo**: cada login crea una fila de sesión (`id`, `device_name`, `user_agent`, `ip` truncada, `created_at`, `last_used_at`, `expires_at`, `revoked_at`) con su refresh | M | Antes había un único refresh por usuario (un login cerraba los demás dispositivos) |
| A-05 | Refresh token opaco (32 bytes aleatorios, base64url), solo su hash SHA-256 en BD, rotación en cada uso con `jti`; reutilizar uno rotado revoca la sesión (detección de robo). Vida 30 días deslizante, máximo absoluto 90 días | M | Rotación segura y revocable |
| A-06 | Access token JWT HS256 de 15 min con **clave propia** (`jwt_access_key`), claims `iss`, `aud`, `sub` (UUID), `sid`, `jti`, `iat`, `exp`, `typ`. Se validan `iss`, `aud`, `typ` y `alg`; 30 s de margen de reloj. **Sin teléfono, email ni nombre** | M | Hallazgos: misma clave access/refresh, `iss` sin validar, teléfono en el token |
| A-07 | Comprobación de sesión activa en cada petición: `JwtMiddleware` consulta `session:{sid}` en Redis (con *fallback* a BD) y rechaza sesiones revocadas o usuarios desactivados | M | Logout no revocaba el access; usuarios desactivados seguían entrando |
| A-08 | `POST /auth/logout` revoca la sesión actual y cierra sus WebSocket | M | Hallazgo: logout no revoca el access |
| A-09 | `GET /me/sessions`, `DELETE /me/sessions/{id}`, `DELETE /me/sessions` (todas menos la actual) | S | Control del usuario sobre sus dispositivos |
| A-10 | Cambio de contraseña (`PUT /me/password`) y de teléfono (`PUT /me/phone`) exigen la contraseña actual y revocan las demás sesiones | M | Hallazgo ALTO: `PUT /usr/update` cambiaba contraseña/teléfono sin contraseña actual |
| A-11 | `DELETE /me` con contraseña: desactiva, revoca todas las sesiones; anonimización a los 30 días (job) | M | Coherencia con A-07 y derecho de supresión |
| A-12 | `POST /auth/reactivate` solo dentro del plazo de gracia; 401 genérico | S | Mantiene la función actual sin filtrar estado de la cuenta |
| A-13 | Respuestas uniformes anti-enumeración: register → 409 genérico sin indicar campo; contacto → 404 genérico; cambio de teléfono → 409 protegido por contraseña | M | Hallazgo MEDIO: 409/422 distintos permitían enumerar teléfonos |
| A-14 | Verificación de email por enlace firmado (y de teléfono por OTP) antes de permitir ser encontrado por teléfono | C | Asegura la titularidad del teléfono; requiere proveedor de correo/SMS |
| A-15 | Refresh en cookie `HttpOnly; Secure; SameSite=Strict; Path=/api/v1/auth` para el cliente web (con protección CSRF por encabezado personalizado) en lugar de en el cuerpo | C | Reduce el impacto de un XSS en el frontend |
| A-16 | 2FA TOTP y OAuth/OIDC | W | Fuera del alcance del portafolio v1 |

## 3. Usuarios, contactos y bloqueo

| Id | Requerimiento | Prioridad | Justificación |
|---|---|---|---|
| U-01 | `GET /users/{id}` solo si hay relación (contacto en cualquier sentido o conversación compartida) y no hay bloqueo; si no, 404. Nunca expone email; teléfono solo si es mi contacto | M | Hallazgo ALTO: IDOR en `GET /usr/profile/{id}` |
| U-02 | Contactos con FK `contact_user_id` al usuario destino (no se duplica el teléfono como clave de unión). Alta por teléfono E.164, idempotente (200 si ya existía) | M | Modelo normalizado; elimina el 409 que servía para enumerar |
| U-03 | Edición solo del alias (`PATCH /contacts/{id}`); el teléfono no se edita | M | El teléfono identifica al usuario; editarlo rompía la relación con el chat |
| U-04 | Listado con cursor `(nombre_orden, id)` y **búsqueda** `q` (alias/nombre sin acentos ni mayúsculas con `unaccent` + índice trigram; prefijo de teléfono) | M | Hallazgo BAJO: paginación rota por `lim/pag` |
| U-05 | **Bloqueo** (`PUT/DELETE /blocks/{userId}`, `GET /blocks`): el bloqueado no puede enviar mensajes (403 `bloqueado`), crear conversación, ver perfil/avatar/presencia ni agregar como contacto (404) | M | Hallazgo MEDIO: mensajes no solicitados sin bloqueo |
| U-06 | Solicitudes de mensaje: una conversación iniciada por alguien que no está en mis contactos aparece con `is_contact=false`; el cliente la muestra separada con opciones "Agregar" y "Bloquear" | S | Control de mensajes no solicitados sin impedir el primer contacto |
| U-07 | Avatares por `media_id` (subida prefirmada, ver M-05); se elimina el campo de URL libre `profile_picture` | M | Hallazgo BAJO: URLs sin validar (`javascript:`) |
| U-08 | Importación masiva de contactos (lista de teléfonos con hash) | W | Riesgo alto de enumeración; requiere diseño específico |

## 4. Conversaciones y mensajes

| Id | Requerimiento | Prioridad | Justificación |
|---|---|---|---|
| M-01 | Modelo `conversacion` + `participante` (una conversación 1:1 única por par de usuarios, con restricción de unicidad); sustituye a los dos chats espejo `id_sender/id_receiver` | M | Normalización; elimina inconsistencias entre las dos copias |
| M-02 | `POST /conversations {contact_id}` idempotente (crea u obtiene). `GET /conversations` con cursor por actividad, `last_message` y `unread_count` calculado desde el marcador de lectura | M | Lista de chats usable y paginada |
| M-03 | Mensajes con **cursor** `(created_at, id)` y modos `before`/`after`; tamaño 1–100 (50 por defecto) | M | Hallazgo BAJO: `GET /message/load/{id}` devolvía todo sin paginar |
| M-04 | Envío idempotente con `client_id`/`Idempotency-Key` (único por emisor, 24 h) | M | Reintentos del cliente sin duplicados; reconciliación de mensajes optimistas |
| M-05 | Contenido cifrado en PHP con libsodium (`sodium_crypto_aead_xchacha20poly1305_ietf_*`), nonce aleatorio por mensaje, `key_id` para rotación de clave; la clave nunca llega a la BD. Texto máximo 4000 caracteres | M | Requisito de la arquitectura; sustituye a AES en SQL con la clave como parámetro |
| M-06 | Edición solo del autor en 15 min; borrado para todos con lápida (`deleted_at`) que elimina contenido y adjunto | M | Comportamiento esperado de un chat; evita reescribir historia antigua |
| M-07 | **Recibos** `entregado`/`visto` por participante como marcador monótono (`up_to_message_id`) en `recibo_mensaje`; endpoint `POST /conversations/{id}/receipts` y evento WS `seen` | M | Doble check y contador de no leídos coherentes |
| M-08 | Publicación en Redis pub/sub `user:{id}` tras el COMMIT de cada escritura (mensajes, ediciones, borrados, recibos, conversación nueva) | M | Tiempo real (ver `ws-eventos.md`) |
| M-09 | Adjuntos: `POST /uploads` devuelve URL **PUT prefirmada de MinIO** (5 min) y `media_id`; al referenciarlo se verifica tamaño/MIME real con HEAD; descarga con URL GET prefirmada (10 min). Tipos permitidos y máximo 20 MiB (avatar 2 MiB). Objetos huérfanos se borran a las 24 h | S | Elimina `content_media` como URL libre; PHP no transporta binarios |
| M-10 | Presencia online/offline y `last_seen` por WS, solo para usuarios con relación y sin bloqueo | S | Funcionalidad esperada; ver privacidad |
| M-11 | Indicador `typing` por WS (no persistido) | S | Experiencia de chat |
| M-12 | Búsqueda de texto dentro de los mensajes | W | Incompatible con el cifrado en la app sin un índice cifrado/ciego; se pospone |
| M-13 | Grupos (más de 2 participantes) | W | El modelo `participante` lo permite a futuro; fuera de v1 |
| M-14 | Entrega *at-least-once* con Redis Streams | W | v1 usa at-most-once + resincronización por cursor, suficiente para el alcance |
| M-15 | Escaneo antivirus de adjuntos (ClamAV) y miniaturas | C | Seguridad de archivos subidos |

## 5. Plataforma y operación

| Id | Requerimiento | Prioridad | Justificación |
|---|---|---|---|
| P-01 | `GET /health` (vida, sin dependencias) y `GET /ready` (PG escritura/lectura, Redis, MinIO con timeout 1 s; 503 si falla) para los `healthcheck` de Docker | M | Orquestación y despliegues sin tráfico a instancias no listas |
| P-02 | **Rate limiting** en Redis (ventana deslizante / token bucket) con encabezados `RateLimit-Policy`, `RateLimit` y 429 + `Retry-After` (límites en §6) | M | Hallazgo MEDIO: sin rate limiting (fuerza bruta, enumeración, spam) |
| P-03 | CORS con **lista blanca** de orígenes (`cors_origins` separada por comas), eco del origen permitido, `Vary: Origin`, sin `*`, `Access-Control-Max-Age: 600`, `Access-Control-Expose-Headers: Location, Retry-After, RateLimit, RateLimit-Policy, X-Request-Id` | M | Hallazgo MEDIO: CORS `*` sin `Vary: Origin` |
| P-04 | Claves separadas en `.env.example` (valores ficticios): `jwt_access_key`, `msg_enc_key` (+ `msg_enc_key_id`), `redis_password`, `minio_*`; se eliminan `key` y `key_decryption` | M | Separación de secretos por uso y rotación independiente |
| P-05 | `app_debug` solo en desarrollo; con `app_env=production` se fuerza a `false` aunque la variable diga lo contrario | M | Hallazgo MEDIO |
| P-06 | Logs estructurados sin datos sensibles (sin contraseñas, tokens, contenido de mensajes ni teléfonos completos) | S | Privacidad y cumplimiento |
| P-07 | Métricas Prometheus (`/metrics` en red interna): latencia por ruta, 4xx/5xx, 429, conexiones WS | C | Observabilidad |
| P-08 | Auditoría de eventos de seguridad (login fallido, cambio de contraseña/teléfono, revocación) en tabla propia | C | Investigación de incidentes |

## 6. Límites de peticiones (rate limiting)

Claves en Redis `rl:{política}:{sujeto}`. Sujeto = IP (para rutas públicas, tomando la IP real solo
desde el proxy de confianza), usuario o sesión. Al exceder: 429 + `Retry-After`.

| Política | Rutas | Límite | Sujeto |
|---|---|---|---|
| `login` | `POST /auth/login` | 5 por minuto y 20 por hora; tras 10 fallos seguidos por email, bloqueo progresivo 1, 5, 15 min | IP + email (y IP sola: 50/hora) |
| `register` | `POST /auth/register` | 3 por hora | IP |
| `reactivate` | `POST /auth/reactivate` | 5 por 15 min | IP + email |
| `refresh` | `POST /auth/refresh` | 30 por minuto | sesión (IP si el token es inválido: 60/hora) |
| `sensitive` | `PUT /me/password`, `PUT /me/phone`, `DELETE /me` | 5 por 15 min | usuario |
| `contact-add` | `POST /contacts` | 30 por hora y 200 por día | usuario |
| `profile-read` | `GET /users/{id}` | 60 por minuto | usuario |
| `send` | `POST /conversations/{id}/messages` | 20 por 10 s (ráfaga) y 300 por hora | usuario |
| `edit` | `PATCH/DELETE /messages/{id}` | 30 por minuto | usuario |
| `upload` | `POST /uploads` | 30 por hora | usuario |
| `default-auth` | resto de rutas autenticadas | 300 por minuto | usuario |
| `default-anon` | resto de rutas públicas (salvo `/health`, `/ready`) | 60 por minuto | IP |
| WS | ver `ws-eventos.md` §5.2 | 20 mensajes / 10 s por conexión; 10 conexiones por usuario | conexión / usuario |

## 7. Hallazgos de la auditoría → mitigación

| Severidad | Hallazgo | Mitigación (requerimiento / contrato) |
|---|---|---|
| CRÍTICO | Robo de cuenta en login (PG): registrar un `phone_number` igual al email de otra persona; teléfono sin validar | A-01 (login solo por email), validación E.164 del teléfono (`Phone` en OpenAPI), restricciones `CHECK` en BD (pedido al DBA) |
| ALTO | IDOR en `GET /usr/profile/{id}` con ids secuenciales | U-01 (relación obligatoria, 404), G-03 (UUID), G-05 |
| ALTO | `PUT /usr/update` cambia contraseña/teléfono sin contraseña actual y sin revocar refresh | A-10 (`PUT /me/password`, `PUT /me/phone` con `current_password` y revocación), `PATCH /me` solo datos no sensibles |
| ALTO | Contraseñas cifradas de forma reversible | A-02 (argon2id en PHP), migración: rehash obligatorio (ver §9) |
| ALTO | JWT con id que cambia de dueño tras el failover | G-02 (sin failover, PG única fuente), G-03 (`sub` = UUID estable), A-07 |
| MEDIO | Sin rate limiting | P-02 y §6 |
| MEDIO | Enumeración de teléfonos (409/422 distintos en register, contact create, update) | A-13, U-02 (404 genérico, idempotente), límites `register`/`contact-add` |
| MEDIO | Misma clave para access y refresh; `iss` no validado | A-05 (refresh opaco, no JWT), A-06 (clave propia, `iss`/`aud`/`alg` validados) |
| MEDIO | Teléfono dentro del access token | A-06 (claims mínimos) |
| MEDIO | Usuarios desactivados siguen con acceso | A-07, A-11 (revocación de todas las sesiones, comprobación por petición y en WS) |
| MEDIO | Logout no revoca el access | A-07, A-08 |
| MEDIO | Un único refresh por usuario | A-04, A-09 (sesiones por dispositivo) |
| MEDIO | CORS `*`, sin `Vary: Origin` | P-03; validación de `Origin` en el handshake WS |
| MEDIO | `app_debug` filtra detalles | G-04, P-05 |
| MEDIO | Mensajes no solicitados sin bloqueo | U-05, U-06 |
| BAJO | Validaciones de longitud/formato | G-06 (esquemas con `minLength/maxLength/pattern`, `additionalProperties: false`) |
| BAJO | URLs de `profile_picture`/`content_media` sin validar (`javascript:`) | U-07, M-09 (solo `media_id` + URL prefirmada generada por el servidor) |
| BAJO | Paginación rota de mensajes/chats/contactos | M-03, M-02, U-04 (cursor opaco) |

## 8. Rutas antiguas → nuevas

| Antigua (`/api`) | Nueva (`/api/v1`) | Cambios |
|---|---|---|
| `POST /auth/register` | `POST /auth/register` | Campos `email, phone, display_name, password`; 409 genérico; devuelve `Me` |
| `POST /auth/login` `{phone_number, pass}` | `POST /auth/login` `{email, password, device_name?}` | Login por email; crea sesión; respuesta `TokenPair` (`access_token`, `refresh_token`, `session_id`, `user`) |
| `POST /auth/refresh` `{tkRef}` | `POST /auth/refresh` `{refresh_token}` | Refresh opaco con rotación y detección de reutilización |
| `POST /auth/logout` | `POST /auth/logout` | Revoca la sesión actual (access incluido) |
| `POST /auth/reactivate` `{phone_number, pass}` | `POST /auth/reactivate` `{email, password}` | Plazo de gracia 30 días |
| `GET /usr/profile` | `GET /me` | — |
| `GET /usr/profile/{id_usr}` | `GET /users/{userId}` | UUID; solo con relación; 404 en otro caso |
| `PUT /usr/update` | `PATCH /me` | Solo `display_name`, `about`, `avatar_media_id` |
| `PUT /usr/update` (`pass`) | `PUT /me/password` | Exige `current_password`; revoca otras sesiones |
| `PUT /usr/update` (`phone_number`) | `PUT /me/phone` | Exige `current_password`; E.164 |
| `DELETE /usr/delete` `{pass}` | `DELETE /me` `{password}` | Revoca todas las sesiones |
| — | `GET /me/sessions`, `DELETE /me/sessions[/{sessionId}]` | Nuevo |
| `POST /contact/create` `{contact_number, contact_name}` | `POST /contacts` `{phone, alias?}` | Idempotente; 404 genérico |
| `GET /contact/load/{lim}/{pag}?phone_contact=&contact_name=` | `GET /contacts?q=&cursor=&limit=` | Cursor y búsqueda unificada |
| — | `GET /contacts/{contactId}` | Nuevo |
| `PUT /contact/update` `{id_contact, contact_number?, contact_name?}` | `PATCH /contacts/{contactId}` `{alias}` | Solo alias |
| `DELETE /contact/delete/{id_contact}` | `DELETE /contacts/{contactId}` | — |
| — | `GET /blocks`, `PUT/DELETE /blocks/{userId}` | Nuevo |
| `POST /chat/create` `{id_contact}` | `POST /conversations` `{contact_id}` | Idempotente (200/201) |
| `GET /chat/load` | `GET /conversations?cursor=&limit=` | Con `last_message` y `unread_count` |
| — | `GET /conversations/{conversationId}` | Nuevo |
| `POST /message/send` `{id_chat, text_content, content_media?}` | `POST /conversations/{conversationId}/messages` `{client_id?, text?, media_id?}` | Idempotente; adjuntos por `media_id`; devuelve el `Message` |
| `GET /message/load/{id_chat}` | `GET /conversations/{conversationId}/messages?before=&after=&limit=` | Cursor |
| `PUT /message/edit` `{id_message, new_text}` | `PATCH /messages/{messageId}` `{text}` | Ventana de 15 min |
| `DELETE /message/delete/{id_message}` | `DELETE /messages/{messageId}` | Lápida; idempotente |
| — | `POST /conversations/{conversationId}/receipts` | Nuevo (entregado/visto) |
| — | `POST /uploads` | Nuevo (URL prefirmada MinIO) |
| — | `GET /health`, `GET /ready` | Nuevo |
| — | `/docs` (Swagger UI) | Nuevo |

## 9. Migración de datos (para coordinar con el DBA)

- **Contraseñas**: las actuales están cifradas de forma reversible. Opción recomendada: durante la
  migración, descifrar con la clave antigua **una sola vez** dentro de un script fuera de la API y
  guardar `password_hash(..., PASSWORD_ARGON2ID)`; después destruir la clave antigua. Alternativa si
  no se quiere manipular claves: marcar todas las cuentas con `must_reset_password` (no hay correo
  configurado, así que la primera opción es la viable para el portafolio).
- **Mensajes**: re-cifrar con libsodium y la nueva `msg_enc_key` (mismo script).
- **Ids**: generar `public_id uuid` (v7) para usuario, contacto, conversación, mensaje y sesión.
- **Chats espejo**: fusionar cada par `chat(A→B)` + `chat(B→A)` en una `conversacion` con dos
  `participante`.
- **Refresh tokens**: no se migran; todos los usuarios vuelven a iniciar sesión.

## 10. Necesidades hacia la BD (resumen para `db-funciones.md`)

Todas reciben el id del usuario autenticado y validan propiedad/participación dentro de la función:

1. Usuario: crear (email citext único, phone E.164 único con `CHECK`, `pass_hash`), obtener por
   email para login (devuelve `pass_hash`, estado), actualizar perfil, cambiar hash/teléfono,
   desactivar/reactivar, obtener perfil público **con comprobación de relación y bloqueo**.
2. Sesión: crear, rotar refresh (comparar hash + `jti`, detectar reutilización), revocar una / todas
   / todas menos una, listar, tocar `last_used_at`.
3. Contacto: crear idempotente por teléfono (devuelve `created` true/false), listar con cursor y `q`,
   obtener, cambiar alias, borrar.
4. Bloqueo: bloquear/desbloquear idempotente, listar, comprobar bloqueo en ambos sentidos.
5. Conversación: crear u obtener 1:1 por contacto, listar con cursor por actividad + `last_message`
   + `unread_count`, obtener, listar participantes (para publicar en Redis).
6. Mensaje: insertar (contenido cifrado `bytea`, nonce, `key_id`, `client_id` único por emisor),
   listar por cursor `before`/`after`, editar (autor + ventana), borrar (lápida).
7. Recibos: avanzar marcador `entregado`/`visto` monótono hasta un mensaje, devolver `unread_count`.
8. Media: registrar pendiente, confirmar al referenciar, listar huérfanos.
