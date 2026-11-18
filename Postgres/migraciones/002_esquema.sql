-- migrate:up
-- =============================================================================
-- 002 - Esquema normalizado (3FN) de CR_Chat para la API v1.
--
-- Consolida las antiguas 002 (esquema base) y 004 (ids públicos, media,
-- sesión por dispositivo, cifrado del mensaje). Nada se había desplegado, así
-- que el historial se reescribió sin cambiar el esquema final (ver
-- docs/db/README.md, "Historial de migraciones").
--
--  * Ids públicos: `public_id uuid UNIQUE DEFAULT gen_random_uuid()` en usuario,
--    contacto, conversacion, mensaje, sesion y media. Los bigint son internos
--    (PK, FK, índices) y nunca salen de la BD a través de las funciones.
--  * media: objetos en MinIO (avatar y adjuntos) pendiente/confirmado/borrado.
--  * mensaje: contenido cifrado por la API (bytea), nonce XChaCha20-Poly1305 de
--    24 bytes, key_id (rotación), client_id (idempotencia), lápida al borrar.
--  * sesion: una fila POR DISPOSITIVO (sid del JWT) y la cadena de refresh
--    tokens en sesion_refresh (solo el hash SHA-256 de cada token).
--
-- No necesita superusuario: todo se crea como `migrator` (las extensiones
-- están en la 001).
-- =============================================================================
SET LOCAL ROLE migrator;

-- Utilidad: mantener updated_at ----------------------------------------------
-- En usuario, un cambio que SOLO toca last_seen_at (presencia) no cuenta como
-- edición del perfil y no mueve updated_at.
CREATE FUNCTION fn_tg_updated_at() RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    -- (IF anidado: NEW.last_seen_at no existe en las demás tablas.)
    IF TG_TABLE_NAME = 'usuario' THEN
        IF (to_jsonb(NEW) - 'last_seen_at') = (to_jsonb(OLD) - 'last_seen_at') THEN
            RETURN NEW;
        END IF;
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END
$$;

-- usuario ---------------------------------------------------------------------
CREATE TABLE usuario (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre_usuario  text        NOT NULL,
    telefono        text        NOT NULL,
    email           citext      NOT NULL,
    -- Hash argon2id generado y verificado en PHP. La BD nunca ve la contraseña.
    pass_hash       text        NOT NULL,
    descripcion     text        DEFAULT 'Hey there, I am using CR_Chat',  -- `about`, anulable en la API
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz,
    public_id       uuid        NOT NULL DEFAULT gen_random_uuid(),
    avatar_media_id bigint,     -- FK a media (se agrega después de crear media)
    last_seen_at    timestamptz,
    CONSTRAINT usuario_telefono_uq  UNIQUE (telefono),
    CONSTRAINT usuario_email_uq     UNIQUE (email),
    CONSTRAINT usuario_public_id_uq UNIQUE (public_id),
    CONSTRAINT usuario_avatar_uq    UNIQUE (avatar_media_id),
    CONSTRAINT usuario_nombre_ck    CHECK (char_length(btrim(nombre_usuario)) BETWEEN 1 AND 50),
    -- E.164 estricto, igual que la API.
    CONSTRAINT usuario_telefono_ck  CHECK (telefono ~ '^\+[1-9][0-9]{7,14}$'),
    CONSTRAINT usuario_email_ck     CHECK (char_length(email) <= 254
                                           AND email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
    CONSTRAINT usuario_pass_hash_ck CHECK (pass_hash LIKE '$argon2id$%' AND char_length(pass_hash) <= 255),
    CONSTRAINT usuario_descripcion_ck CHECK (char_length(descripcion) <= 140)
);
COMMENT ON TABLE  usuario IS 'Cuenta de usuario. Baja lógica con deleted_at (reactivable).';
COMMENT ON COLUMN usuario.pass_hash IS 'argon2id (PHP password_hash). Solo se lee en el flujo de login.';
COMMENT ON COLUMN usuario.public_id IS 'Id público (sub del JWT, ids en la API). El bigint id es interno.';
COMMENT ON COLUMN usuario.last_seen_at IS 'Última desconexión del WebSocket (respaldo de last_seen:{id} en Redis).';

CREATE TRIGGER usuario_updated_at BEFORE UPDATE ON usuario
    FOR EACH ROW EXECUTE FUNCTION fn_tg_updated_at();

-- media -----------------------------------------------------------------------
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

-- El avatar debe ser media DEL MISMO usuario. Si la fila de media se purga,
-- solo se anula la columna del avatar (PG15+: SET NULL con lista de columnas).
-- La cubre usuario_avatar_uq (avatar_media_id) como índice de la FK.
ALTER TABLE usuario
    ADD CONSTRAINT usuario_avatar_fk FOREIGN KEY (avatar_media_id, id)
        REFERENCES media (id, id_dueno) ON DELETE SET NULL (avatar_media_id);

-- contacto --------------------------------------------------------------------
CREATE TABLE contacto (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_usuario       bigint      NOT NULL REFERENCES usuario (id) ON DELETE CASCADE,
    contact_user_id  bigint      NOT NULL REFERENCES usuario (id) ON DELETE CASCADE,
    -- Opcional: NULL = se muestra el nombre del usuario.
    alias            text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    deleted_at       timestamptz,
    public_id        uuid        NOT NULL DEFAULT gen_random_uuid(),
    CONSTRAINT contacto_par_uq       UNIQUE (id_usuario, contact_user_id),
    CONSTRAINT contacto_public_id_uq UNIQUE (public_id),
    CONSTRAINT contacto_no_self_ck   CHECK (id_usuario <> contact_user_id),
    CONSTRAINT contacto_alias_ck     CHECK (alias IS NULL OR (char_length(alias) <= 50 AND btrim(alias) <> ''))
);
COMMENT ON TABLE contacto IS 'Agenda privada de cada usuario. Enlazada a usuario por FK (no por teléfono).';

-- El UNIQUE (id_usuario, contact_user_id) cubre la FK id_usuario y el par concreto.
-- "Todos los que me agendaron" (relación inversa) y FK contact_user_id.
CREATE INDEX contacto_contact_user_id_ix ON contacto (contact_user_id);
-- Contactos activos de un usuario (listado, relación para perfil/presencia). El
-- orden por coalesce(alias, nombre) normalizado cruza dos tablas: se ordena en
-- memoria sobre la agenda de UN usuario (acotada).
CREATE INDEX contacto_activo_ix ON contacto (id_usuario, contact_user_id) WHERE deleted_at IS NULL;

CREATE TRIGGER contacto_updated_at BEFORE UPDATE ON contacto
    FOR EACH ROW EXECUTE FUNCTION fn_tg_updated_at();

-- bloqueo ---------------------------------------------------------------------
CREATE TABLE bloqueo (
    id_usuario    bigint      NOT NULL REFERENCES usuario (id) ON DELETE CASCADE,
    id_bloqueado  bigint      NOT NULL REFERENCES usuario (id) ON DELETE CASCADE,
    created_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id_usuario, id_bloqueado),
    CONSTRAINT bloqueo_no_self_ck CHECK (id_usuario <> id_bloqueado)
);
CREATE INDEX bloqueo_id_bloqueado_ix ON bloqueo (id_bloqueado);
-- Listado paginado de mis bloqueos (created_at DESC).
CREATE INDEX bloqueo_listado_ix ON bloqueo (id_usuario, created_at DESC);

-- conversacion + participante ------------------------------------------------
-- Una sola fila por conversación (antes había dos filas `chat` por conversación).
-- Para conversaciones directas, (id_usuario_menor, id_usuario_mayor) es la clave
-- natural que impide duplicados; `participante` es la relación N:M general
-- (deja la puerta abierta a grupos sin cambiar mensaje/recibo).
CREATE TABLE conversacion (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tipo               text        NOT NULL DEFAULT 'directa',
    id_usuario_menor   bigint      NOT NULL REFERENCES usuario (id) ON DELETE CASCADE,
    id_usuario_mayor   bigint      NOT NULL REFERENCES usuario (id) ON DELETE CASCADE,
    created_at         timestamptz NOT NULL DEFAULT now(),
    ultimo_mensaje_at  timestamptz NOT NULL DEFAULT now(),
    public_id          uuid        NOT NULL DEFAULT gen_random_uuid(),
    CONSTRAINT conversacion_tipo_ck      CHECK (tipo = 'directa'),
    CONSTRAINT conversacion_orden_ck     CHECK (id_usuario_menor < id_usuario_mayor),
    CONSTRAINT conversacion_par_uq       UNIQUE (id_usuario_menor, id_usuario_mayor),
    CONSTRAINT conversacion_public_id_uq UNIQUE (public_id)
);
CREATE INDEX conversacion_id_usuario_mayor_ix ON conversacion (id_usuario_mayor);

CREATE TABLE participante (
    id_conversacion bigint      NOT NULL REFERENCES conversacion (id) ON DELETE CASCADE,
    id_usuario      bigint      NOT NULL REFERENCES usuario (id) ON DELETE CASCADE,
    unido_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id_conversacion, id_usuario)
);
-- FK id_usuario + "conversaciones de un usuario".
CREATE INDEX participante_id_usuario_ix ON participante (id_usuario, id_conversacion);

-- mensaje ---------------------------------------------------------------------
CREATE TABLE mensaje (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_conversacion  bigint      NOT NULL,
    id_remitente     bigint      NOT NULL,
    -- Cifrado por la app (ciphertext + tag). La BD no conoce la clave.
    contenido        bytea,
    created_at       timestamptz NOT NULL DEFAULT now(),
    editado_at       timestamptz,
    deleted_at       timestamptz,
    public_id        uuid        NOT NULL DEFAULT gen_random_uuid(),
    nonce            bytea,
    key_id           smallint,
    client_id        uuid,
    id_media         bigint,
    -- El remitente DEBE ser participante de la conversación (integridad en la BD).
    CONSTRAINT mensaje_remitente_participante_fk
        FOREIGN KEY (id_conversacion, id_remitente)
        REFERENCES participante (id_conversacion, id_usuario) ON DELETE CASCADE,
    CONSTRAINT mensaje_contenido_ck CHECK (octet_length(contenido) BETWEEN 1 AND 65536),
    -- Destino de la FK compuesta de recibo_mensaje (garantiza que el recibo y el
    -- mensaje pertenecen a la misma conversación).
    CONSTRAINT mensaje_id_conv_uq   UNIQUE (id, id_conversacion),
    CONSTRAINT mensaje_public_id_uq UNIQUE (public_id),
    -- Idempotencia del envío: un client_id por emisor (permanente, más estricto
    -- que las 24 h del requerimiento M-04; los client_id son UUID del cliente).
    CONSTRAINT mensaje_client_id_uq UNIQUE (id_remitente, client_id),
    -- Un adjunto pertenece a un solo mensaje...
    CONSTRAINT mensaje_media_uq     UNIQUE (id_media),
    -- ...y es del propio remitente. NO ACTION: la purga de media nunca puede
    -- dejar un mensaje apuntando a nada (la lápida desreferencia antes).
    CONSTRAINT mensaje_media_fk FOREIGN KEY (id_media, id_remitente)
        REFERENCES media (id, id_dueno) ON DELETE NO ACTION,
    -- XChaCha20-Poly1305 IETF (libsodium): nonce de 24 bytes.
    CONSTRAINT mensaje_nonce_ck  CHECK (nonce IS NULL OR octet_length(nonce) = 24),
    CONSTRAINT mensaje_key_id_ck CHECK (key_id IS NULL OR key_id >= 1),
    -- contenido, nonce y key_id van juntos (los tres o ninguno).
    CONSTRAINT mensaje_cifrado_ck CHECK ((contenido IS NULL) = (nonce IS NULL)
                                         AND (contenido IS NULL) = (key_id IS NULL)),
    -- Vivo: texto y/o adjunto. Lápida: sin contenido ni adjunto.
    CONSTRAINT mensaje_lapida_ck CHECK (CASE WHEN deleted_at IS NULL
                                             THEN contenido IS NOT NULL OR id_media IS NOT NULL
                                             ELSE contenido IS NULL AND id_media IS NULL END)
);
COMMENT ON COLUMN mensaje.contenido IS 'Ciphertext+tag (libsodium) generado por la API. NULL en lápidas o mensajes solo con adjunto.';
COMMENT ON COLUMN mensaje.key_id IS 'Versión de la clave de cifrado de la API (msg_enc_key_id) para rotación.';

-- Cursor de paginación (created_at, id) por conversación. No es parcial: la API
-- también lista las lápidas.
CREATE INDEX mensaje_cursor_ix ON mensaje (id_conversacion, created_at DESC, id DESC);
-- Índice completo para la FK compuesta (borrado en cascada desde participante).
-- mensaje_client_id_uq (id_remitente, client_id) cubre las búsquedas por remitente.
CREATE INDEX mensaje_conv_remitente_ix ON mensaje (id_conversacion, id_remitente);

-- recibo_mensaje --------------------------------------------------------------
-- Estado entregado/visto POR destinatario (antes eran booleanos en el mensaje).
-- id_conversacion es redundante con mensaje, pero está AMARRADA por dos FK
-- compuestas (al mensaje y al participante), así que no puede divergir. Permite
-- contar no leídos y marcar entregado/visto por conversación sin recorrer todos
-- los mensajes (ver docs/db/optimizacion.md).
CREATE TABLE recibo_mensaje (
    id_mensaje      bigint      NOT NULL,
    id_conversacion bigint      NOT NULL,
    id_usuario      bigint      NOT NULL,
    entregado_at    timestamptz,
    visto_at        timestamptz,
    PRIMARY KEY (id_mensaje, id_usuario),
    CONSTRAINT recibo_mensaje_fk FOREIGN KEY (id_mensaje, id_conversacion)
        REFERENCES mensaje (id, id_conversacion) ON DELETE CASCADE,
    -- El destinatario DEBE ser participante de la conversación.
    CONSTRAINT recibo_participante_fk FOREIGN KEY (id_conversacion, id_usuario)
        REFERENCES participante (id_conversacion, id_usuario) ON DELETE CASCADE,
    CONSTRAINT recibo_visto_implica_entregado_ck CHECK (visto_at IS NULL OR entregado_at IS NOT NULL)
);
-- FK al mensaje: la PK (id_mensaje, ...) la cubre por su primera columna (id es único).
-- FK al participante + marcar entregado por conversación.
CREATE INDEX recibo_participante_ix ON recibo_mensaje (id_usuario, id_conversacion, id_mensaje);
-- No leídos por usuario y conversación (contador del listado y marcar visto).
CREATE INDEX recibo_no_visto_ix ON recibo_mensaje (id_usuario, id_conversacion, id_mensaje)
    WHERE visto_at IS NULL;
-- Marcar entregado recorre solo los recibos pendientes de entrega.
CREATE INDEX recibo_no_entregado_ix ON recibo_mensaje (id_usuario, id_conversacion, id_mensaje)
    WHERE entregado_at IS NULL;

-- sesion + sesion_refresh -----------------------------------------------------
-- La sesión es el dispositivo (id estable = `sid` del JWT de acceso) y los
-- refresh tokens rotados cuelgan de ella.
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

-- auditoria (particionada por mes) -------------------------------------------
-- ON DELETE SET NULL: borrar físicamente un usuario NO borra su auditoría.
CREATE TABLE auditoria (
    id           bigint GENERATED ALWAYS AS IDENTITY,
    ocurrido_at  timestamptz NOT NULL DEFAULT now(),
    id_usuario   bigint REFERENCES usuario (id) ON DELETE SET NULL,
    accion       text        NOT NULL,
    entidad      text        NOT NULL,
    id_entidad   bigint,
    usuario_db   text        NOT NULL DEFAULT current_user,
    detalle      jsonb,
    PRIMARY KEY (id, ocurrido_at),
    CONSTRAINT auditoria_accion_ck CHECK (char_length(accion) BETWEEN 1 AND 50)
) PARTITION BY RANGE (ocurrido_at);
CREATE INDEX auditoria_id_usuario_ix ON auditoria (id_usuario, ocurrido_at);
CREATE INDEX auditoria_entidad_ix ON auditoria (entidad, id_entidad);

-- Partición red de seguridad: si falta la partición del mes la fila no se pierde.
CREATE TABLE auditoria_default PARTITION OF auditoria DEFAULT;

-- Crea particiones mensuales [mes actual - 1, mes actual + p_meses]. Idempotente.
-- Uso operativo: job mensual del contenedor `backup` (infra/backup/crontab), como migrator.
CREATE FUNCTION fn_crear_particiones_auditoria(p_meses int DEFAULT 3) RETURNS int
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_mes   date;
    v_nombre text;
    v_creadas int := 0;
BEGIN
    FOR i IN -1 .. p_meses LOOP
        v_mes := (date_trunc('month', now()) + make_interval(months => i))::date;
        v_nombre := format('auditoria_%s', to_char(v_mes, 'YYYY_MM'));
        IF to_regclass(v_nombre) IS NULL THEN
            EXECUTE format(
                'CREATE TABLE %I PARTITION OF auditoria FOR VALUES FROM (%L) TO (%L)',
                v_nombre, v_mes, (v_mes + interval '1 month')::date);
            v_creadas := v_creadas + 1;
        END IF;
    END LOOP;
    RETURN v_creadas;
END
$$;
REVOKE ALL ON FUNCTION fn_crear_particiones_auditoria(int) FROM PUBLIC;

SELECT fn_crear_particiones_auditoria(3);

-- Triggers de auditoría -------------------------------------------------------
-- SECURITY INVOKER: la app (app_rw) solo tiene INSERT sobre auditoria.
CREATE FUNCTION fn_tg_auditar_usuario() RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_accion text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_accion := 'usuario_alta';
    ELSIF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
        v_accion := 'usuario_baja';
    ELSIF NEW.deleted_at IS NULL AND OLD.deleted_at IS NOT NULL THEN
        v_accion := 'usuario_reactivacion';
    ELSIF NEW.telefono IS DISTINCT FROM OLD.telefono THEN
        v_accion := 'usuario_cambio_telefono';
    ELSIF NEW.email IS DISTINCT FROM OLD.email THEN
        v_accion := 'usuario_cambio_email';
    ELSIF NEW.pass_hash IS DISTINCT FROM OLD.pass_hash THEN
        v_accion := 'usuario_cambio_pass';
    ELSE
        RETURN NULL;  -- cambios de perfil cosméticos no se auditan
    END IF;
    INSERT INTO auditoria (id_usuario, accion, entidad, id_entidad)
    VALUES (NEW.id, v_accion, 'usuario', NEW.id);
    RETURN NULL;
END
$$;
CREATE TRIGGER usuario_auditoria AFTER INSERT OR UPDATE ON usuario
    FOR EACH ROW EXECUTE FUNCTION fn_tg_auditar_usuario();

CREATE FUNCTION fn_tg_auditar_mensaje() RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
        INSERT INTO auditoria (id_usuario, accion, entidad, id_entidad, detalle)
        VALUES (NEW.id_remitente, 'mensaje_borrado', 'mensaje', NEW.id,
                jsonb_build_object('id_conversacion', NEW.id_conversacion));
    ELSIF NEW.editado_at IS DISTINCT FROM OLD.editado_at THEN
        INSERT INTO auditoria (id_usuario, accion, entidad, id_entidad, detalle)
        VALUES (NEW.id_remitente, 'mensaje_editado', 'mensaje', NEW.id,
                jsonb_build_object('id_conversacion', NEW.id_conversacion));
    END IF;
    RETURN NULL;
END
$$;
CREATE TRIGGER mensaje_auditoria AFTER UPDATE ON mensaje
    FOR EACH ROW EXECUTE FUNCTION fn_tg_auditar_mensaje();

REVOKE ALL ON FUNCTION fn_tg_updated_at(), fn_tg_auditar_usuario(), fn_tg_auditar_mensaje() FROM PUBLIC;

-- Privilegios sobre tablas ---------------------------------------------------
-- Las funciones son SECURITY INVOKER, así que el rol de la app necesita DML mínimo.
-- Nunca DELETE físico (salvo bloqueo y media) ni TRUNCATE/REFERENCES/TRIGGER.
GRANT SELECT, INSERT, UPDATE ON usuario, contacto, conversacion, mensaje, recibo_mensaje,
                                sesion, sesion_refresh TO app_rw;
GRANT SELECT, INSERT         ON participante TO app_rw;
GRANT SELECT, INSERT, DELETE ON bloqueo TO app_rw;
-- DELETE en media: purga de huérfanos por el job de la API (que también borra el objeto en MinIO).
GRANT SELECT, INSERT, UPDATE, DELETE ON media TO app_rw;
GRANT INSERT                 ON auditoria TO app_rw;

-- app_ro: lectura sin pass_hash (privilegio por columna) y sin sesiones/auditoría.
GRANT SELECT (id, nombre_usuario, telefono, email, descripcion, created_at, updated_at,
              deleted_at, public_id, avatar_media_id, last_seen_at) ON usuario TO app_ro;
GRANT SELECT ON contacto, bloqueo, conversacion, participante, mensaje, recibo_mensaje, media TO app_ro;

-- migrate:down
SET LOCAL ROLE migrator;
DROP TABLE IF EXISTS auditoria CASCADE;
DROP TABLE IF EXISTS sesion_refresh;
DROP TABLE IF EXISTS sesion;
DROP TABLE IF EXISTS recibo_mensaje;
DROP TABLE IF EXISTS mensaje;
DROP TABLE IF EXISTS participante;
DROP TABLE IF EXISTS conversacion;
DROP TABLE IF EXISTS bloqueo;
DROP TABLE IF EXISTS contacto;
ALTER TABLE IF EXISTS usuario DROP CONSTRAINT IF EXISTS usuario_avatar_fk;
DROP TABLE IF EXISTS media;
DROP TABLE IF EXISTS usuario;
DROP FUNCTION IF EXISTS fn_crear_particiones_auditoria(int);
DROP FUNCTION IF EXISTS fn_tg_auditar_mensaje();
DROP FUNCTION IF EXISTS fn_tg_auditar_usuario();
DROP FUNCTION IF EXISTS fn_tg_updated_at();
