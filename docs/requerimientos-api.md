# Requerimientos de la API REST de CR_Chat (v1)

Agente backend. Fase 1: contratos; **Fase 2: implementado** en `datos/` (ver §11). Contratos de referencia:

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
| G-03 | Ids públicos UUID opacos en todos los recursos (la BD genera v4 con `gen_random_uuid`; el cliente no asume versión); los `bigint` internos nunca se exponen | M | Elimina la enumeración de ids secuenciales (IDOR en `/usr/profile/{id}`) |
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
| A-01 | Login con **teléfono o email** en un único campo `identifier` (email si contiene `@`, si no teléfono E.164). El teléfono se valida E.164 estricto (`^\+[1-9][0-9]{7,14}$`) en PHP (patrón + libphonenumber) y con un `CHECK` en la BD, así que nunca puede tener forma de email. Una sola consulta (`fn_credenciales_login`) devuelve el hash y PHP lo verifica con `password_verify` | M | Corrige el robo de cuenta (registrar un `phone_number` igual al email de otra persona): un email ya no cabe en el campo teléfono |
| A-02 | Contraseñas con `password_hash(PASSWORD_ARGON2ID)` y `password_verify` en PHP; `password_needs_rehash` en el login. La BD solo guarda el hash. Política: 10–128 caracteres, distinta de email/teléfono, contra lista de contraseñas comunes | M | Elimina el cifrado reversible con `key_decryption` |
| A-03 | Login con tiempo constante: si el identificador no existe se verifica contra un hash ficticio; mismo 401 para usuario inexistente, contraseña incorrecta o cuenta desactivada | M | Evita enumeración de emails por tiempo o mensaje |
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
| A-15 | **Adoptado (opt-in)**: con `X-Refresh-Cookie: 1` el refresh viaja en la cookie `cr_refresh` (`HttpOnly; Secure; SameSite=Strict; Path=/api/v1/auth`) y no en el cuerpo. CSRF: `SameSite=Strict` + encabezado propio (obliga a preflight) + `Origin` en la lista blanca (403 si no); CORS con `Access-Control-Allow-Credentials: true` solo para orígenes permitidos. Los clientes que no son navegador siguen con el refresh en el cuerpo | S | Un XSS ya no puede leer el refresh (solo el access de 15 min en memoria); frente a `localStorage`, el coste es mínimo porque el frontend va en el mismo sitio |
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
| P-03 | CORS con **lista blanca** de orígenes (`CORS_ORIGINS` separada por comas; por defecto `http://localhost:5173,http://localhost:4200`; la misma lista valida el `Origin` del WS), eco del origen permitido, `Vary: Origin`, sin `*`, `Access-Control-Max-Age: 600`, `Access-Control-Expose-Headers: Location, Retry-After, RateLimit, RateLimit-Policy, X-Request-Id` | M | Hallazgo MEDIO: CORS `*` sin `Vary: Origin` |
| P-04 | Claves separadas en `datos/.env.example` (valores ficticios): `JWT_ACCESS_KEY`, `MSG_ENC_KEY` (+ `MSG_ENC_KEY_ID`, `MSG_ENC_KEYS_OLD`), `REDIS_PASSWORD`, `MINIO_*`, `DB_RW_*`/`DB_RO_*`; se eliminan `key`, `key_decryption` y las variables de MySQL | M | Separación de secretos por uso y rotación independiente |
| P-05 | `APP_DEBUG` solo en desarrollo; con `APP_ENV=production` se fuerza a `false` aunque la variable diga lo contrario | M | Hallazgo MEDIO |
| P-06 | Logs estructurados sin datos sensibles (sin contraseñas, tokens, contenido de mensajes ni teléfonos completos) | S | Privacidad y cumplimiento |
| P-07 | Métricas Prometheus (`/metrics` en red interna): latencia por ruta, 4xx/5xx, 429, conexiones WS | C | Observabilidad |
| P-08 | Auditoría de eventos de seguridad (login fallido, cambio de contraseña/teléfono, revocación) en tabla propia | C | Investigación de incidentes |

## 6. Límites de peticiones (rate limiting)

Claves en Redis `rl:{política}:{sha256(sujeto)}:{ventana}:{n}` (ventana deslizante aproximada, script
Lua atómico). Sujeto = IP (para rutas públicas, tomando la IP real de `X-Forwarded-For` solo si la
conexión viene de `TRUSTED_PROXIES`), usuario o IP + identificador. Al exceder: 429 + `Retry-After`.
Cada política se puede sobrescribir con `RL_<POLITICA>=límite/segundos[,…]` (el entorno de pruebas
sube `register` y `login-ip`). Si Redis no responde, el límite se omite (*fail-open*) y se registra.

| Política | Rutas | Límite | Sujeto |
|---|---|---|---|
| `login` | `POST /auth/login` | 5 por minuto y 20 por hora; tras 10 fallos seguidos por identificador, bloqueo progresivo 1, 5, 15 min | IP + identificador (y IP sola, `login-ip`: 50/hora) |
| `register` | `POST /auth/register` | 3 por hora | IP |
| `reactivate` | `POST /auth/reactivate` | 5 por 15 min | IP + identificador |
| `refresh` | `POST /auth/refresh` | 30 por minuto | IP (la sesión no se conoce hasta validar el token); tokens inválidos: `refresh-invalid` 60/hora por IP |
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
| CRÍTICO | Robo de cuenta en login (PG): registrar un `phone_number` igual al email de otra persona; teléfono sin validar | A-01: `CHECK` E.164 estricto del teléfono en la BD + validación en PHP (patrón + libphonenumber) + login en una sola consulta (`fn_credenciales_login`, por email si hay `@` y si no por teléfono) que devuelve el hash verificado con `password_verify`. Un email ya no puede guardarse como teléfono, así que no hay colisión posible. Probado en `api_test.py` |
| ALTO | IDOR en `GET /usr/profile/{id}` con ids secuenciales | U-01 (relación obligatoria, 404), G-03 (UUID), G-05 |
| ALTO | `PUT /usr/update` cambia contraseña/teléfono sin contraseña actual y sin revocar refresh | A-10 (`PUT /me/password`, `PUT /me/phone` con `current_password` y revocación), `PATCH /me` solo datos no sensibles |
| ALTO | Contraseñas cifradas de forma reversible | A-02 (argon2id en PHP). Los datos antiguos no se migran (§9) |
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
| `POST /auth/login` `{phone_number, pass}` | `POST /auth/login` `{identifier, password, device_name?}` | Login por teléfono o email; crea sesión; respuesta `TokenPair` (`access_token`, `refresh_token`, `session_id`, `user`) |
| `POST /auth/refresh` `{tkRef}` | `POST /auth/refresh` `{refresh_token}` | Refresh opaco con rotación y detección de reutilización |
| `POST /auth/logout` | `POST /auth/logout` | Revoca la sesión actual (access incluido) |
| `POST /auth/reactivate` `{phone_number, pass}` | `POST /auth/reactivate` `{identifier, password}` | Plazo de gracia 30 días |
| `GET /usr/profile` | `GET /me` | — |
| `GET /usr/profile/{id_usr}` | `GET /users/{userId}` | UUID; solo con relación; 404 en otro caso |
| `PUT /usr/update` | `PATCH /me` | Solo `display_name`, `about`, `avatar_media_id` |
| `PUT /usr/update` (`pass`) | `PUT /me/password` | Exige `current_password`; revoca otras sesiones |
| `PUT /usr/update` (`phone_number`) | `PUT /me/phone` | Exige `current_password`; E.164 |
| `DELETE /usr/delete` `{pass}` | `DELETE /me` `{password}` | Revoca todas las sesiones |
| — | `GET /me/sessions`, `DELETE /me/sessions[/{sessionId}]` | Nuevo |
| `POST /contact/create` `{contact_number, contact_name}` | `POST /contacts` `{phone, alias?}` o `{user_id, alias?}` | Idempotente; 404 genérico; `user_id` para agregar desde una solicitud de mensaje |
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

## 9. Migración de datos — DESCARTADA

Decisión del usuario (Fase 2): **los datos del esquema anterior no se migran**. La v1 arranca con una
base nueva (migraciones `001-005` + `Postgres/seed/demo.sql`); los usuarios de prueba se vuelven a
registrar. Se descartan el rehash de contraseñas, el re-cifrado de mensajes y la fusión de chats espejo.

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

## 11. Implementación (Fase 2) — decisiones y notas

- **Código**: `datos/src` (Slim 4 + PHP-DI), `datos/ws/server.php` (Workerman), `datos/bin/purgar-media.php`.
  Pruebas: `datos/tests/unit` (PHPUnit), `datos/tests/api_test.py`, `datos/tests/ws_test.py`; entorno
  aislado con `datos/tests/entorno-pruebas.sh up|test|down` (`datos/docker-compose.pruebas-backend.yml`,
  proyecto `crchat-be`, puertos `127.0.0.1:18080` API, `18081` WS, `18900` MinIO).
- **BD**: solo funciones `fn_*` con sentencias preparadas y notación con nombre; dos PDO (escritura
  `DB_RW_*`, lectura `DB_RO_*`); las lecturas tras una escritura usan el pool de escritura. Sin failover
  entre motores. SQLSTATE `CRxxx` → RFC 9457 en `datos/src/Handlers/DbErrorMap.php`.
- **Editar/borrar mensaje ajeno**: no participante → 404; participante no autor (`CR403 no-autor`) →
  **403 `no-autor`** (no filtra existencia: el mensaje ya es visible para ese usuario).
- **Listar mensajes** llama después a `fn_marcar_recibos(..., 'delivered', <último recibido>)` y publica
  `receipt.delivered`. **Enviar** marca `seen` lo recibido antes y publica `receipt.seen`.
- **`unread_count`** tiene tope 100 (la UI muestra "99+").
- **Refresh**: el cliente debe **serializar** el refresh (dos simultáneos con el mismo token se
  interpretan como reutilización y revocan la sesión). La API envía `hash('sha256', $token, true)`.
- **Sesión activa** (A-07): Redis `sess:{sid}` (caché positiva) y `sess:rev:{sid}` (marca de revocación,
  se consulta primero); si falta, `fn_tocar_sesion`. Las revocaciones publican `session.revoked`.
- **`device_name`** se deriva del User-Agent si el cliente no lo envía (la BD lo exige).
- **`conversation.new`** del otro participante: `fn_obtener_conversacion` con **su** uuid (única excepción).
- **Media**: firma AWS SigV4 propia (`ObjectStorage`, probada con el vector oficial de AWS) en lugar de
  `aws/aws-sdk-php` (decenas de MB y Guzzle para cuatro operaciones). `bucket`/`clave_objeto` nunca salen
  al cliente. Job de huérfanos cada hora en el proceso `cr-chat-tareas` del servicio `ws`.
- **Swagger UI**: `swagger-ui-dist` 5.34.1 copiado en la imagen (etapa Node del Dockerfile), sin CDN.
- **`contact_alias`** (Conversation): sale de la columna `contacto_alias` de `fn__conversaciones`
  (crear/obtener/listar conversaciones); la API ya no consulta `fn_obtener_contacto` por conversación.
- **`POST /contacts {user_id}`**: implementado con `fn_crear_contacto_usuario` (exige relación previa y
  sin bloqueo; inexistente/uno mismo/sin relación/bloqueo → el mismo 404).
- **Pendiente (S)**: validación automática de las respuestas contra `openapi.yaml` (G-09).
