# Contrato de funciones de base de datos (PostgreSQL 17)

Fuente: `Postgres/migraciones/003_funciones.sql`. Modelo: [`docs/db/modelo.md`](../db/modelo.md).
Estado: **Fase 1 (contratos)**. Los endpoints de la columna "API" son la propuesta para el backend;
si el backend cambia una ruta, actualizar este documento y no la firma.

## 1. Conexión esperada

| Uso | Host:puerto | Rol | Notas |
|---|---|---|---|
| Escritura y autenticación | `haproxy:5000` (líder Patroni) | `app_rw` | Todas las funciones. `statement_timeout=5s`. |
| Lectura | `haproxy:5001` (réplicas) | `app_ro` | Solo las 4 funciones de lectura. Sesiones en `default_transaction_read_only`. |
| Migraciones | `haproxy:5000` | `migrator` (001: superusuario) | dbmate, `Postgres/migraciones/`. |

Variables que el backend debe leer (nombres propuestos para `.env.example`; los valores nunca van al repo):

```
DB_NAME=cr_chat
DB_RW_HOST=haproxy   DB_RW_PORT=5000  DB_RW_USER=app_rw  DB_RW_PASSWORD=
DB_RO_HOST=haproxy   DB_RO_PORT=5001  DB_RO_USER=app_ro  DB_RO_PASSWORD=
```

DSN PDO: `pgsql:host=haproxy;port=5000;dbname=cr_chat;application_name=cr_chat_api`.

Reglas para el backend:

- **`p_id_usuario` siempre es el `sub` del JWT ya validado**, nunca un valor del cuerpo, la ruta o la query.
- **Lectura después de escritura:** las réplicas pueden ir atrasadas (replicación asíncrona). Si una pantalla
  necesita ver lo que el mismo usuario acaba de escribir (por ejemplo, la respuesta de `POST` que luego recarga la lista), usa
  el pool `app_rw` (5000) para esa lectura.
- Llamar con `SELECT * FROM fn_x(...)` y parámetros enlazados (`PDO::prepare`). Pasa `bytea` con
  `PDO::PARAM_LOB`. Los `uuid` y `timestamptz` se pasan como texto ISO 8601.
- Cada llamada es atómica por sí misma (autocommit). No es necesario abrir transacciones explícitas.
- Ninguna función usa `WHEN OTHERS`: cualquier SQLSTATE fuera de la tabla 2 es un error 500 real y se registra.

## 2. Errores (SQLSTATE propios, clase `CR`)

| SQLSTATE | HTTP sugerido | Significado |
|---|---|---|
| `CR401` | 401 | El usuario autenticado no existe o está dado de baja; refresh token desconocido, revocado o expirado. En `fn_rotar_sesion`, `HINT = 'reutilizacion'` indica que se reutilizó un refresh ya rotado. |
| `CR403` | 403 | Operación prohibida sobre un recurso visible: hay un bloqueo, o no eres el autor del mensaje. |
| `CR404` | 404 | El recurso no existe **o no pertenece al usuario**. Es el mismo error en los dos casos para no revelar si el recurso existe (protección contra IDOR y enumeración). |
| `CR409` | 409 | Duplicado: teléfono/email ya registrado (`DETAIL` = nombre del constraint: `usuario_telefono_uq` / `usuario_email_uq`), contacto existente (`DETAIL` = id), jti repetido. |
| `CR422` | 422 | Parámetros inválidos: formato, longitud, límite de página, cursor incompleto o auto-referencia. `DETAIL` puede traer el constraint violado. |
| `42501` | 500 (alerta) | `insufficient_privilege`: se llamó con el rol equivocado, por ejemplo una escritura por `app_ro`. Es un error de configuración. |
| `25006` | 500 (alerta) | `read_only_sql_transaction`: se escribió por 5001. |

En PHP: `PDOException::errorInfo[0]` trae el SQLSTATE y `errorInfo[2]` el mensaje. Para leer `DETAIL` y `HINT`, revisa el texto del mensaje
(pdo_pgsql los anexa) o usa `pg_result_error_field` si se usa la extensión `pgsql`.

Límites de formato validados en la BD:

| Campo | Regla |
|---|---|
| `telefono` | `^\+?[0-9]{8,15}$` (E.164 sin espacios; normalizar en la API) |
| `email` | `citext`, ≤ 254, `algo@dominio.tld` |
| `nombre_usuario` | 1..50 caracteres (se aplica `btrim`) |
| `pass_hash` | empieza por `$argon2id$`, ≤ 255 |
| `descripcion` | ≤ 140 |
| `foto_perfil` | 1..512 (URL) o NULL |
| `alias` (contacto) | 1..60 |
| `contenido` (mensaje) | `bytea` 1..65 536 bytes (ya cifrado) |
| `media_url` | 1..2048 o NULL |
| `dispositivo` (sesión) | ≤ 120 |
| `p_limite` | 1..100 (por defecto 30) |

## 3. Funciones

Convenciones: todas son `SECURITY INVOKER`, `SET search_path = public, pg_temp`, sin `EXECUTE` para
`PUBLIC`. "Propiedad" describe lo que la función valida en la BD. Además, todas las que reciben
`p_id_usuario` exigen que ese usuario exista y esté activo (si no, `CR401`).

### 3.1 Autenticación y usuario

#### `fn_registrar_usuario(p_nombre_usuario text, p_telefono text, p_email text, p_pass_hash text) → bigint`
- **API:** `POST /auth/register`. Rol: `app_rw`.
- Devuelve el `id` del usuario nuevo. PHP genera `p_pass_hash` con `password_hash($pass, PASSWORD_ARGON2ID)`.
- **Errores:** `CR409` teléfono o email ya existen (el email se compara sin distinguir mayúsculas). `CR422` formato inválido.

#### `fn_credenciales_login(p_identificador text) → TABLE(id_usuario bigint, pass_hash text, eliminado boolean)`
- **API:** `POST /auth/login` y `POST /auth/reactivate`. Rol: `app_rw`; `app_ro` no tiene permiso.
- **Solo para el flujo de login.** Si `p_identificador` contiene `@` busca por email; si no, por teléfono.
  **No compara contraseñas.** Devuelve 0 o 1 fila.
- Flujo en PHP:
  1. 0 filas → 401 genérico. Para igualar el tiempo de respuesta, ejecuta igual un `password_verify` contra un hash ficticio.
  2. `password_verify()` falla → el mismo 401 genérico.
  3. `eliminado = true` → en `/auth/login` responde 401 o 403 con "cuenta desactivada". En `/auth/reactivate`, llama a `fn_reactivar_usuario`.
  4. Si todo es correcto, `password_needs_rehash()` → `fn_cambiar_pass_hash`. Después, `fn_crear_sesion`.
- No lanza errores de negocio.

#### `fn_leer_perfil(p_id_usuario bigint) → TABLE(id_usuario bigint, nombre_usuario text, telefono text, email text, foto_perfil text, descripcion text, created_at timestamptz)`
- **API:** `GET /me`. Rol: `app_ro` o `app_rw`.
- **Propiedad:** solo el perfil propio.

#### `fn_actualizar_usuario(p_id_usuario bigint, p_nombre_usuario text = NULL, p_telefono text = NULL, p_email text = NULL, p_foto_perfil text = NULL, p_descripcion text = NULL) → void`
- **API:** `PATCH /me`. Rol: `app_rw`.
- `NULL` = no cambiar. `p_foto_perfil = ''` borra la foto (vuelve al avatar por defecto).
- **Errores:** `CR409` teléfono o email de otro usuario. `CR422` formato.
- Los cambios de teléfono y email se registran en `auditoria`.

#### `fn_cambiar_pass_hash(p_id_usuario bigint, p_pass_hash text) → void`
- **API:** `PUT /me/password`. Rol: `app_rw`. También se usa en el rehash tras el login.
- PHP verifica la contraseña actual (con `fn_credenciales_login`) **antes** de llamar. Revoca **todas** las sesiones del usuario.
- **Errores:** `CR422` si el hash no es argon2id.

#### `fn_borrar_usuario(p_id_usuario bigint) → void`
- **API:** `DELETE /me`. Rol: `app_rw`. Hace una baja lógica (`deleted_at`) y revoca todas las sesiones.
- PHP verifica la contraseña **antes** de llamar. Después, cualquier función con ese id responde `CR401`.

#### `fn_reactivar_usuario(p_id_usuario bigint) → void`
- **API:** `POST /auth/reactivate`. Rol: `app_rw`. Se llama solo después de `fn_credenciales_login` con `eliminado = true` y un `password_verify` correcto.
- **Errores:** `CR404` si el id no existe o la cuenta ya está activa.

### 3.2 Sesiones (refresh token por dispositivo)

El access token (JWT corto) no se guarda en la BD. El refresh token es un JWT o un valor opaco con un `jti` (uuid v4) y la BD guarda ese `jti`.

#### `fn_crear_sesion(p_id_usuario bigint, p_jti uuid, p_expira_at timestamptz, p_dispositivo text = NULL) → void`
- **API:** `POST /auth/login` y `POST /auth/reactivate`, después de verificar la contraseña. Rol: `app_rw`.
- **Errores:** `CR409` si el jti ya existe. `CR422` si `expira_at` está en el pasado o `dispositivo` es demasiado largo.

#### `fn_rotar_sesion(p_id_usuario bigint, p_jti_actual uuid, p_jti_nuevo uuid, p_expira_at timestamptz) → void`
- **API:** `POST /auth/refresh`. Rol: `app_rw`.
- **Propiedad:** `p_jti_actual` debe pertenecer a `p_id_usuario` (el `sub` del refresh token). Si no, `CR401`.
- Revoca `p_jti_actual`, enlaza `reemplazada_por` y crea `p_jti_nuevo`, que hereda el dispositivo.
- **Errores:** `CR401` en estos casos: jti desconocido o ajeno, expirado, o revocado.
  - Con `HINT = 'reutilizacion'`, alguien está reutilizando un refresh ya rotado (posible robo). En ese caso, la API **debe** llamar
    `fn_revocar_sesiones(p_id_usuario)` (en otra llamada, porque el error revierte la transacción) y responder 401.

#### `fn_revocar_sesion(p_id_usuario bigint, p_jti uuid) → void`
- **API:** `POST /auth/logout`. Rol: `app_rw`. Es idempotente. Un jti ajeno no se toca y no da error.

#### `fn_revocar_sesiones(p_id_usuario bigint) → int`
- **API:** `POST /auth/logout-all` y la respuesta a la reutilización de un refresh. Rol: `app_rw`. Devuelve cuántas sesiones revocó.

### 3.3 Contactos y bloqueos

#### `fn_crear_contacto(p_id_usuario bigint, p_telefono text, p_alias text) → bigint`
- **API:** `POST /contacts`. Rol: `app_rw`. Devuelve `id_contacto`.
- Busca un usuario **activo** con ese teléfono. Si el contacto estaba borrado lógicamente, lo reactiva con el nuevo alias y devuelve el mismo id.
- **Errores:** `CR404` si no hay usuario activo con ese teléfono. `CR422` si el contacto eres tú mismo o el alias es inválido. `CR409` si el contacto ya existe (`DETAIL` = id existente).

#### `fn_listar_contactos(p_id_usuario bigint, p_busqueda text = NULL, p_limite int = 30, p_cursor_alias text = NULL, p_cursor_id bigint = NULL) → TABLE(id_contacto bigint, contact_user_id bigint, alias text, telefono text, nombre_usuario text, foto_perfil text, descripcion text)`
- **API:** `GET /contacts?q=&limit=&cursor=`. Rol: `app_ro` o `app_rw`.
- **Propiedad:** solo los contactos propios, activos y de usuarios activos.
- La búsqueda encuentra el alias que **contiene** `q` (sin distinguir mayúsculas) o el teléfono que **empieza** por `q`. Los comodines `%` y `_` del usuario se escapan.
- Orden `(alias, id)`. Para la página siguiente, pasa el `alias` y el `id_contacto` de la última fila.
  El cursor que expone la API puede ser `base64(json{alias,id})`.
- **Errores:** `CR422` si el límite está fuera de 1..100 o el cursor está incompleto.

#### `fn_actualizar_contacto(p_id_usuario bigint, p_id_contacto bigint, p_alias text) → void`
- **API:** `PATCH /contacts/{id}`. Rol: `app_rw`. Solo cambia el alias: otro teléfono es otro usuario, así que es otro contacto.
- **Propiedad:** el contacto debe ser de `p_id_usuario`. Si no, `CR404`. **Errores:** `CR422` si el alias es inválido.

#### `fn_borrar_contacto(p_id_usuario bigint, p_id_contacto bigint) → void`
- **API:** `DELETE /contacts/{id}`. Rol: `app_rw`. Hace una baja lógica. La conversación se mantiene.
- **Propiedad:** el contacto debe ser propio y estar activo. Si no, `CR404`.

#### `fn_bloquear_usuario(p_id_usuario bigint, p_id_bloqueado bigint) → void`
- **API:** `POST /blocks/{userId}`. Rol: `app_rw`. Es idempotente. **Errores:** `CR422` si te bloqueas a ti mismo, `CR404` si el usuario no existe.

#### `fn_desbloquear_usuario(p_id_usuario bigint, p_id_bloqueado bigint) → void`
- **API:** `DELETE /blocks/{userId}`. Rol: `app_rw`. Es idempotente.

### 3.4 Conversaciones

#### `fn_crear_conversacion(p_id_usuario bigint, p_id_contacto bigint) → TABLE(id_conversacion bigint, creada boolean)`
- **API:** `POST /conversations` con cuerpo `{ "id_contacto": … }`. Rol: `app_rw`. Responde 201 si `creada` y 200 si no.
- Obtiene la conversación o la crea (es idempotente y segura ante carreras): existe **una sola** conversación directa por par de usuarios, sin importar quién la cree.
- **Propiedad:** `p_id_contacto` debe ser un contacto propio, activo y de un usuario activo. Si no, `CR404`.
- **Errores:** `CR403` si hay un bloqueo en cualquier dirección.

#### `fn_listar_conversaciones(p_id_usuario bigint, p_limite int = 30, p_cursor_at timestamptz = NULL, p_cursor_id bigint = NULL) → TABLE(id_conversacion bigint, id_otro_usuario bigint, alias text, nombre_usuario text, telefono text, foto_perfil text, ultimo_mensaje_at timestamptz, no_leidos int)`
- **API:** `GET /conversations?limit=&cursor=`. Rol: `app_ro` o `app_rw`.
- **Propiedad:** solo las conversaciones en las que el usuario participa.
- `alias` es NULL si el otro usuario no está en mi agenda. En ese caso, la UI muestra el teléfono o `nombre_usuario`.
- `no_leidos` tiene un tope de **100**: un valor de 100 significa "100 o más" y la UI lo muestra como "99+".
- Orden: `ultimo_mensaje_at DESC, id DESC`. Para la página siguiente, pasa el `ultimo_mensaje_at` y el `id_conversacion` de la última fila.

### 3.5 Mensajes

#### `fn_enviar_mensaje(p_id_usuario bigint, p_id_conversacion bigint, p_contenido bytea, p_media_url text = NULL) → TABLE(id_mensaje bigint, created_at timestamptz)`
- **API:** `POST /conversations/{id}/messages`. También lo usa el WS, a través de la API. Rol: `app_rw`.
- `p_contenido` llega **ya cifrado** por la API (por ejemplo, libsodium `crypto_secretbox` o AES-256-GCM: nonce + ciphertext + tag). La BD no recibe claves.
- Crea un recibo pendiente por cada destinatario y actualiza `conversacion.ultimo_mensaje_at`.
- **Propiedad:** el usuario debe ser participante. Si no, `CR404`. La BD también lo garantiza con una FK compuesta.
- **Errores:** `CR403` si hay un bloqueo en cualquier dirección o el destinatario está dado de baja. `CR422` si el contenido está vacío o supera 64 KiB, o si `media_url` es inválido.

#### `fn_listar_mensajes(p_id_usuario bigint, p_id_conversacion bigint, p_limite int = 30, p_antes_at timestamptz = NULL, p_antes_id bigint = NULL) → TABLE(id_mensaje bigint, id_remitente bigint, contenido bytea, media_url text, created_at timestamptz, editado_at timestamptz, entregado_at timestamptz, visto_at timestamptz)`
- **API:** `GET /conversations/{id}/messages?limit=&before=`. Rol: `app_ro` o `app_rw`.
- **Propiedad:** el usuario debe ser participante. Si no, `CR404`.
- Paginación **hacia atrás**: devuelve los `p_limite` mensajes más recientes anteriores al cursor `(created_at, id)`,
  **del más nuevo al más viejo**. Si los quiere en orden cronológico, el cliente los invierte. La primera página va sin cursor. La siguiente usa el `created_at`
  y el `id_mensaje` de la **última** fila recibida, que es la más vieja. Esto corrige el bug anterior, que devolvía los 15 más viejos y no tenía offset.
- Los mensajes borrados no se devuelven. El WS notifica los borrados en vivo.
- `entregado_at` y `visto_at`: en mis mensajes, es el estado del destinatario. En los mensajes recibidos, es mi propio recibo.
- **Errores:** `CR422` si el límite o el cursor son inválidos.

#### `fn_editar_mensaje(p_id_usuario bigint, p_id_mensaje bigint, p_contenido bytea) → timestamptz`
- **API:** `PATCH /messages/{id}`. Rol: `app_rw`. Devuelve `editado_at`.
- **Propiedad:** si el usuario no es participante, o el mensaje no existe o está borrado → `CR404`. Si es participante pero no es el autor → `CR403`.
- **Errores:** `CR422` si el contenido es inválido.

#### `fn_borrar_mensaje(p_id_usuario bigint, p_id_mensaje bigint) → void`
- **API:** `DELETE /messages/{id}`. Rol: `app_rw`. Hace una baja lógica que se aplica para todos los participantes.
- **Propiedad:** las mismas reglas que en editar (`CR404` / `CR403`).

#### `fn_marcar_entregado(p_id_usuario bigint, p_id_conversacion bigint, p_hasta_id bigint) → int`
- **API:** `POST /conversations/{id}/delivered` con cuerpo `{ "hasta_id": … }`. También lo usa el WS cuando el cliente recibe mensajes. Rol: `app_rw`.
- Marca **mis** recibos de esa conversación con `id_mensaje <= p_hasta_id`. Devuelve cuántos cambió, así que es idempotente.
- **Propiedad:** el usuario debe ser participante. Si no, `CR404`.

#### `fn_marcar_visto(p_id_usuario bigint, p_id_conversacion bigint, p_hasta_id bigint) → int`
- **API:** `POST /conversations/{id}/seen` con cuerpo `{ "hasta_id": … }`. Rol: `app_rw`. Marcar como visto implica marcar también como entregado.
- **Propiedad:** igual que `fn_marcar_entregado`.

### 3.6 Mantenimiento (no las usa la API)

| Función | Rol | Uso |
|---|---|---|
| `fn_crear_particiones_auditoria(p_meses int = 3) → int` | `migrator` | Crea las particiones mensuales de `auditoria`. Hay que ejecutarla mensualmente con cron o pg_cron (Fase 2). |
| `fn__exigir_activo`, `fn__validar_limite`, `fn__exigir_participante`, `fn__hay_bloqueo` | `app_rw`, `app_ro` | Funciones auxiliares internas. Tienen `EXECUTE` solo porque las funciones públicas son INVOKER. No exponen datos. |

## 4. Matriz de permisos

| Objeto | `app_rw` | `app_ro` |
|---|---|---|
| `usuario` | SELECT, INSERT, UPDATE | SELECT sin `pass_hash` (por columna) |
| `contacto`, `conversacion`, `mensaje`, `recibo_mensaje` | SELECT, INSERT, UPDATE | SELECT |
| `participante` | SELECT, INSERT | SELECT |
| `bloqueo` | SELECT, INSERT, DELETE | SELECT |
| `sesion` | SELECT, INSERT, UPDATE | — |
| `auditoria` | INSERT (solo los triggers) | — |
| Funciones de lectura (4) | EXECUTE | EXECUTE |
| Funciones de escritura y autenticación | EXECUTE | — |
| DDL, TRUNCATE, DELETE físico (salvo `bloqueo`) | — | — |

Como las funciones son `SECURITY INVOKER`, `app_rw` tiene DML directo sobre las tablas. **La API solo debe usar
las funciones.** Las reglas de propiedad viven en ellas, y la revisión de código del backend debe rechazar SQL
directo sobre las tablas. Una mejora posible para una fase futura es aplicar Row Level Security con `SET app.user_id`.
