-- migrate:up
-- =============================================================================
-- 004 - Esquema para el contrato de la API v1 (Fase 1b).
--
--  * Ids públicos: `public_id uuid UNIQUE DEFAULT gen_random_uuid()` en usuario,
--    contacto, conversacion, mensaje, sesion y media. Los bigint quedan internos
--    (PK, FK, índices); nunca salen de la BD a través de las funciones.
--  * media: archivos en MinIO (avatar y adjuntos) con estado pendiente/confirmado/
--    borrado. usuario.foto_perfil (URL libre) -> usuario.avatar_media_id (FK).
--    mensaje.media_url (URL libre) -> mensaje.id_media (FK).
--  * mensaje: nonce (XChaCha20-Poly1305, 24 bytes), key_id (rotación de clave),
--    client_id (idempotencia por emisor), lápida (deleted_at => contenido NULL).
--  * sesion: una fila POR DISPOSITIVO con id estable (sid del JWT) y la cadena de
--    refresh tokens en sesion_refresh (solo el hash SHA-256 de cada token).
--  * teléfono: CHECK E.164 estricto (^\+[1-9][0-9]{7,14}$, igual que la API).
--
-- Los datos de prueba anteriores no se migran (decisión del proyecto). La 005
-- reemplaza las funciones de la 003; aplicar 004 y 005 juntas (dbmate up).
--
-- Requiere superusuario (o dueño de la BD) SOLO por CREATE EXTENSION unaccent,
-- que va antes del SET LOCAL ROLE. unaccent es "trusted" en PG13+.
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS unaccent;

SET LOCAL ROLE migrator;

-- -----------------------------------------------------------------------------
-- media
-- -----------------------------------------------------------------------------
CREATE TABLE media (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id      uuid        NOT NULL DEFAULT gen_random_uuid(),
    -- El dueño es quien lo subió. Borrado FÍSICO del usuario => se borran sus
    -- filas de media (los objetos de MinIO los limpia el job de huérfanos).
    id_dueno       bigint      NOT NULL REFERENCES usuario (id) ON DELETE CASCADE,
    proposito      text        NOT NULL,
    bucket         text        NOT NULL,
    clave_objeto   text        NOT NULL,     -- la genera la BD: <proposito>/<AAAA>/<MM>/<public_id>
    mime           text        NOT NULL,
    tamano_bytes   bigint      NOT NULL,
    ancho          int,
    alto           int,
    estado         text        NOT NULL DEFAULT 'pendiente',
    created_at     timestamptz NOT NULL DEFAULT now(),
    confirmado_at  timestamptz,
    borrado_at     timestamptz,
    CONSTRAINT media_public_id_uq  UNIQUE (public_id),
    CONSTRAINT media_objeto_uq     UNIQUE (bucket, clave_objeto),
    -- Destino de las FK compuestas (id, dueño): garantiza que un avatar o adjunto
    -- solo puede referenciarlo su propio dueño.
    CONSTRAINT media_id_dueno_uq   UNIQUE (id, id_dueno),
    CONSTRAINT media_proposito_ck  CHECK (proposito IN ('avatar', 'mensaje')),
    CONSTRAINT media_estado_ck     CHECK (estado IN ('pendiente', 'confirmado', 'borrado')),
    CONSTRAINT media_bucket_ck     CHECK (bucket ~ '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$'),
    CONSTRAINT media_clave_ck      CHECK (char_length(clave_objeto) BETWEEN 1 AND 512
                                          AND clave_objeto !~ '(^/|\.\.|[[:cntrl:]])'),
    CONSTRAINT media_mime_ck       CHECK (mime IN ('image/jpeg', 'image/png', 'image/webp', 'image/gif',
                                                   'application/pdf', 'audio/ogg', 'audio/mpeg', 'video/mp4')),
    CONSTRAINT media_avatar_mime_ck CHECK (proposito <> 'avatar' OR mime IN ('image/jpeg', 'image/png', 'image/webp')),
    -- 20 MiB adjuntos, 2 MiB avatar (requerimiento M-09).
    CONSTRAINT media_tamano_ck     CHECK (tamano_bytes >= 1 AND tamano_bytes <=
                                          CASE WHEN proposito = 'avatar' THEN 2097152 ELSE 20971520 END),
    CONSTRAINT media_dimensiones_ck CHECK ((ancho IS NULL OR ancho BETWEEN 1 AND 20000)
                                           AND (alto IS NULL OR alto BETWEEN 1 AND 20000)),
    CONSTRAINT media_fechas_ck     CHECK ((estado <> 'confirmado' OR confirmado_at IS NOT NULL)
                                          AND (estado <> 'borrado' OR borrado_at IS NOT NULL))
);
COMMENT ON TABLE media IS 'Objetos en MinIO (avatar/adjunto). pendiente -> confirmado al referenciarse; borrado => el job lo elimina.';

-- FK id_dueno + "mis archivos".
CREATE INDEX media_id_dueno_ix ON media (id_dueno, created_at);
-- Job de limpieza: pendientes viejos y borrados.
CREATE INDEX media_limpieza_ix ON media (created_at) WHERE estado <> 'confirmado';

-- -----------------------------------------------------------------------------
-- usuario
-- -----------------------------------------------------------------------------
ALTER TABLE usuario
    ADD COLUMN public_id       uuid NOT NULL DEFAULT gen_random_uuid(),
    ADD COLUMN avatar_media_id bigint,
    ADD COLUMN last_seen_at    timestamptz,
    DROP COLUMN foto_perfil,                       -- se va con usuario_foto_ck
    ALTER COLUMN descripcion DROP NOT NULL,        -- `about` es anulable en la API
    ADD CONSTRAINT usuario_public_id_uq UNIQUE (public_id),
    ADD CONSTRAINT usuario_avatar_uq    UNIQUE (avatar_media_id),
    -- El avatar debe ser media DEL MISMO usuario. Si la fila de media se purga,
    -- solo se anula la columna del avatar (PG15+: SET NULL con lista de columnas).
    ADD CONSTRAINT usuario_avatar_fk FOREIGN KEY (avatar_media_id, id)
        REFERENCES media (id, id_dueno) ON DELETE SET NULL (avatar_media_id),
    DROP CONSTRAINT usuario_telefono_ck,
    ADD CONSTRAINT usuario_telefono_ck CHECK (telefono ~ '^\+[1-9][0-9]{7,14}$');
COMMENT ON COLUMN usuario.public_id IS 'Id público (sub del JWT, ids en la API). El bigint id es interno.';
COMMENT ON COLUMN usuario.last_seen_at IS 'Última desconexión del WebSocket (respaldo de last_seen:{id} en Redis).';

-- -----------------------------------------------------------------------------
-- contacto
-- -----------------------------------------------------------------------------
-- alias pasa a ser opcional (NULL = se muestra el nombre del usuario) y 1..50
-- como en la API. El orden del listado es por coalesce(alias, nombre) normalizado
-- (sin mayúsculas ni acentos), que cruza dos tablas: se ordena en memoria sobre
-- la agenda de UN usuario (acotada), por eso se retiran los índices por alias.
DROP INDEX contacto_listado_ix;
DROP INDEX contacto_alias_trgm_ix;
ALTER TABLE contacto
    ADD COLUMN public_id uuid NOT NULL DEFAULT gen_random_uuid(),
    ADD CONSTRAINT contacto_public_id_uq UNIQUE (public_id),
    ALTER COLUMN alias DROP NOT NULL,
    DROP CONSTRAINT contacto_alias_ck,
    ADD CONSTRAINT contacto_alias_ck CHECK (alias IS NULL OR (char_length(alias) <= 50 AND btrim(alias) <> ''));
-- Contactos activos de un usuario (listado, relación para perfil/presencia).
CREATE INDEX contacto_activo_ix ON contacto (id_usuario, contact_user_id) WHERE deleted_at IS NULL;
-- La relación inversa ("yo estoy en su agenda") la cubren contacto_par_uq (par
-- concreto) y contacto_contact_user_id_ix (todos los que me agendaron).

-- -----------------------------------------------------------------------------
-- bloqueo
-- -----------------------------------------------------------------------------
-- Listado paginado de mis bloqueos (created_at DESC).
CREATE INDEX bloqueo_listado_ix ON bloqueo (id_usuario, created_at DESC);

-- -----------------------------------------------------------------------------
-- conversacion
-- -----------------------------------------------------------------------------
ALTER TABLE conversacion
    ADD COLUMN public_id uuid NOT NULL DEFAULT gen_random_uuid(),
    ADD CONSTRAINT conversacion_public_id_uq UNIQUE (public_id);

-- -----------------------------------------------------------------------------
-- mensaje
-- -----------------------------------------------------------------------------
ALTER TABLE mensaje
    ADD COLUMN public_id uuid NOT NULL DEFAULT gen_random_uuid(),
    ADD COLUMN nonce     bytea,
    ADD COLUMN key_id    smallint,
    ADD COLUMN client_id uuid,
    ADD COLUMN id_media  bigint,
    DROP COLUMN media_url,                         -- se va con mensaje_media_ck
    ALTER COLUMN contenido DROP NOT NULL,          -- lápida o mensaje solo con adjunto
    ADD CONSTRAINT mensaje_public_id_uq UNIQUE (public_id),
    -- Idempotencia del envío: un client_id por emisor (permanente, más estricto
    -- que las 24 h del requerimiento M-04; los client_id son UUID del cliente).
    ADD CONSTRAINT mensaje_client_id_uq UNIQUE (id_remitente, client_id),
    -- Un adjunto pertenece a un solo mensaje...
    ADD CONSTRAINT mensaje_media_uq UNIQUE (id_media),
    -- ...y es del propio remitente. NO ACTION: la purga de media nunca puede
    -- dejar un mensaje apuntando a nada (la lápida desreferencia antes).
    ADD CONSTRAINT mensaje_media_fk FOREIGN KEY (id_media, id_remitente)
        REFERENCES media (id, id_dueno) ON DELETE NO ACTION,
    -- XChaCha20-Poly1305 IETF (libsodium): nonce de 24 bytes.
    ADD CONSTRAINT mensaje_nonce_ck  CHECK (nonce IS NULL OR octet_length(nonce) = 24),
    ADD CONSTRAINT mensaje_key_id_ck CHECK (key_id IS NULL OR key_id >= 1),
    -- contenido, nonce y key_id van juntos (los tres o ninguno).
    ADD CONSTRAINT mensaje_cifrado_ck CHECK ((contenido IS NULL) = (nonce IS NULL)
                                             AND (contenido IS NULL) = (key_id IS NULL)),
    -- Vivo: texto y/o adjunto. Lápida: sin contenido ni adjunto.
    ADD CONSTRAINT mensaje_lapida_ck CHECK (CASE WHEN deleted_at IS NULL
                                                 THEN contenido IS NOT NULL OR id_media IS NOT NULL
                                                 ELSE contenido IS NULL AND id_media IS NULL END);
COMMENT ON COLUMN mensaje.contenido IS 'Ciphertext+tag (libsodium) generado por la API. NULL en lápidas o mensajes solo con adjunto.';
COMMENT ON COLUMN mensaje.key_id IS 'Versión de la clave de cifrado de la API (msg_enc_key_id) para rotación.';

-- Las lápidas se listan (la API las muestra): el índice del cursor deja de ser parcial.
DROP INDEX mensaje_cursor_ix;
CREATE INDEX mensaje_cursor_ix ON mensaje (id_conversacion, created_at DESC, id DESC);
-- mensaje_client_id_uq (id_remitente, client_id) ya cubre las búsquedas por remitente.
DROP INDEX mensaje_id_remitente_ix;

-- -----------------------------------------------------------------------------
-- recibo_mensaje
-- -----------------------------------------------------------------------------
-- Marcar entregado recorre solo los recibos pendientes de entrega.
CREATE INDEX recibo_no_entregado_ix ON recibo_mensaje (id_usuario, id_conversacion, id_mensaje)
    WHERE entregado_at IS NULL;

-- -----------------------------------------------------------------------------
-- sesion + sesion_refresh (reemplaza la sesion de la 002)
-- -----------------------------------------------------------------------------
-- La 002 creaba una fila por refresh token (la sesión cambiaba de id en cada
-- rotación). El JWT de acceso lleva `sid` estable, así que ahora la sesión es
-- el dispositivo y los refresh tokens rotados cuelgan de ella.
DROP TABLE sesion;

CREATE TABLE sesion (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id         uuid        NOT NULL DEFAULT gen_random_uuid(),
    id_usuario        bigint      NOT NULL REFERENCES usuario (id) ON DELETE CASCADE,
    dispositivo       text        NOT NULL,
    user_agent        text,
    ip_hint           cidr,       -- IP truncada (/24 IPv4, /48 IPv6): la trunca la BD
    created_at        timestamptz NOT NULL DEFAULT now(),
    last_used_at      timestamptz NOT NULL DEFAULT now(),
    expira_at         timestamptz NOT NULL,   -- deslizante (30 días por defecto)
    expira_max_at     timestamptz NOT NULL,   -- absoluto (90 días por defecto)
    revocada_at       timestamptz,
    motivo_revocacion text,
    CONSTRAINT sesion_public_id_uq   UNIQUE (public_id),
    CONSTRAINT sesion_dispositivo_ck CHECK (char_length(dispositivo) <= 100 AND btrim(dispositivo) <> ''),
    CONSTRAINT sesion_user_agent_ck  CHECK (user_agent IS NULL OR char_length(user_agent) <= 512),
    CONSTRAINT sesion_ip_hint_ck     CHECK (ip_hint IS NULL
                                            OR (family(ip_hint) = 4 AND masklen(ip_hint) <= 24)
                                            OR (family(ip_hint) = 6 AND masklen(ip_hint) <= 48)),
    CONSTRAINT sesion_expira_ck      CHECK (expira_at > created_at AND expira_at <= expira_max_at),
    CONSTRAINT sesion_revocacion_ck  CHECK ((revocada_at IS NULL) = (motivo_revocacion IS NULL)),
    CONSTRAINT sesion_motivo_ck      CHECK (motivo_revocacion IN
        ('logout', 'revocada', 'cambio_pass', 'cambio_telefono', 'baja', 'reutilizacion'))
);
COMMENT ON TABLE sesion IS 'Sesión por dispositivo. public_id = sid del JWT. Los refresh tokens están en sesion_refresh.';
CREATE INDEX sesion_id_usuario_ix ON sesion (id_usuario);
-- "Mis sesiones activas" (listado y revocación masiva).
CREATE INDEX sesion_activa_ix ON sesion (id_usuario, last_used_at DESC) WHERE revocada_at IS NULL;

CREATE TABLE sesion_refresh (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_sesion   bigint      NOT NULL REFERENCES sesion (id) ON DELETE CASCADE,
    jti         uuid        NOT NULL,
    token_hash  bytea       NOT NULL,     -- SHA-256 del refresh opaco; el token nunca llega a la BD
    created_at  timestamptz NOT NULL DEFAULT now(),
    rotado_at   timestamptz,              -- NOT NULL => ya se usó; reutilizarlo revoca la sesión
    CONSTRAINT sesion_refresh_jti_uq  UNIQUE (jti),
    CONSTRAINT sesion_refresh_hash_uq UNIQUE (token_hash),
    CONSTRAINT sesion_refresh_hash_ck CHECK (octet_length(token_hash) = 32)
);
COMMENT ON TABLE sesion_refresh IS 'Cadena de refresh tokens de una sesión (hash SHA-256). Uno vigente por sesión.';
CREATE INDEX sesion_refresh_id_sesion_ix ON sesion_refresh (id_sesion);
-- Exactamente un refresh vigente por sesión.
CREATE UNIQUE INDEX sesion_refresh_vigente_uq ON sesion_refresh (id_sesion) WHERE rotado_at IS NULL;

-- -----------------------------------------------------------------------------
-- Privilegios
-- -----------------------------------------------------------------------------
-- DELETE en media: purga de huérfanos por el job de la API (que también borra el objeto en MinIO).
GRANT SELECT, INSERT, UPDATE, DELETE ON media TO app_rw;
GRANT SELECT, INSERT, UPDATE ON sesion, sesion_refresh TO app_rw;
GRANT SELECT ON media TO app_ro;
GRANT SELECT (public_id, avatar_media_id, last_seen_at) ON usuario TO app_ro;

-- migrate:down
-- Reversión con pérdida: las lápidas reciben un contenido de relleno y los
-- contactos sin alias toman el nombre del usuario, para volver a los NOT NULL de la 002.
DROP EXTENSION IF EXISTS unaccent;   -- antes del SET ROLE: la extensión es del superusuario
SET LOCAL ROLE migrator;

-- sesion (vuelve la de la 002) ---------------------------------------------------
DROP TABLE sesion_refresh;
DROP TABLE sesion;
CREATE TABLE sesion (
    jti              uuid        PRIMARY KEY,
    id_usuario       bigint      NOT NULL REFERENCES usuario (id) ON DELETE CASCADE,
    dispositivo      text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    expira_at        timestamptz NOT NULL,
    revocada_at      timestamptz,
    reemplazada_por  uuid REFERENCES sesion (jti) ON DELETE SET NULL,
    CONSTRAINT sesion_dispositivo_ck CHECK (dispositivo IS NULL OR char_length(dispositivo) <= 120),
    CONSTRAINT sesion_expira_ck      CHECK (expira_at > created_at)
);
CREATE INDEX sesion_id_usuario_ix ON sesion (id_usuario);
CREATE INDEX sesion_activa_ix ON sesion (id_usuario) WHERE revocada_at IS NULL;
CREATE INDEX sesion_reemplazada_por_ix ON sesion (reemplazada_por);
GRANT SELECT, INSERT, UPDATE ON sesion TO app_rw;

-- recibo_mensaje -------------------------------------------------------------------
DROP INDEX recibo_no_entregado_ix;

-- mensaje ---------------------------------------------------------------------------
DROP INDEX mensaje_cursor_ix;
CREATE INDEX mensaje_cursor_ix ON mensaje (id_conversacion, created_at DESC, id DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX mensaje_id_remitente_ix ON mensaje (id_remitente);
ALTER TABLE mensaje
    DROP CONSTRAINT mensaje_lapida_ck,
    DROP CONSTRAINT mensaje_cifrado_ck;
UPDATE mensaje SET contenido = '\x00'::bytea WHERE contenido IS NULL;
COMMENT ON COLUMN mensaje.contenido IS NULL;
ALTER TABLE mensaje
    DROP COLUMN id_media,
    DROP COLUMN client_id,
    DROP COLUMN key_id,
    DROP COLUMN nonce,
    DROP COLUMN public_id,
    ALTER COLUMN contenido SET NOT NULL,
    ADD COLUMN media_url text,
    ADD CONSTRAINT mensaje_media_ck CHECK (media_url IS NULL OR char_length(media_url) BETWEEN 1 AND 2048);

-- conversacion / bloqueo ----------------------------------------------------------
ALTER TABLE conversacion DROP COLUMN public_id;
DROP INDEX bloqueo_listado_ix;

-- contacto --------------------------------------------------------------------------
DROP INDEX contacto_activo_ix;
UPDATE contacto c SET alias = left(u.nombre_usuario, 60)
FROM usuario u WHERE u.id = c.contact_user_id AND c.alias IS NULL;
ALTER TABLE contacto
    DROP CONSTRAINT contacto_alias_ck,
    ALTER COLUMN alias SET NOT NULL,
    ADD CONSTRAINT contacto_alias_ck CHECK (char_length(btrim(alias)) BETWEEN 1 AND 60),
    DROP COLUMN public_id;
CREATE INDEX contacto_listado_ix ON contacto (id_usuario, alias, id) WHERE deleted_at IS NULL;
CREATE INDEX contacto_alias_trgm_ix ON contacto USING gin (alias gin_trgm_ops) WHERE deleted_at IS NULL;

-- usuario ---------------------------------------------------------------------------
UPDATE usuario SET descripcion = '' WHERE descripcion IS NULL;
ALTER TABLE usuario
    DROP CONSTRAINT usuario_avatar_fk,
    DROP COLUMN avatar_media_id,
    DROP COLUMN last_seen_at,
    DROP COLUMN public_id,
    ALTER COLUMN descripcion SET NOT NULL,
    ADD COLUMN foto_perfil text,
    ADD CONSTRAINT usuario_foto_ck CHECK (foto_perfil IS NULL OR char_length(foto_perfil) BETWEEN 1 AND 512),
    DROP CONSTRAINT usuario_telefono_ck,
    ADD CONSTRAINT usuario_telefono_ck CHECK (telefono ~ '^\+?[0-9]{8,15}$');
GRANT SELECT (foto_perfil) ON usuario TO app_ro;

DROP TABLE media;
