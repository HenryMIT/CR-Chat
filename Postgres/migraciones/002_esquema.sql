-- migrate:up
-- =============================================================================
-- 002 - Esquema normalizado (3FN) de CR_Chat.
-- Reemplaza usr/contact/chat/message_chat/logs_* del esquema anterior (los datos
-- anteriores eran de prueba y no se migran).
-- Todos los objetos quedan con dueño `migrator`.
-- =============================================================================
SET LOCAL ROLE migrator;

-- Utilidad: mantener updated_at ----------------------------------------------
CREATE FUNCTION fn_tg_updated_at() RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
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
    foto_perfil     text,       -- NULL = avatar por defecto (lo decide el cliente)
    descripcion     text        NOT NULL DEFAULT 'Hey there, I am using CR_Chat',
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz,
    CONSTRAINT usuario_telefono_uq UNIQUE (telefono),
    CONSTRAINT usuario_email_uq    UNIQUE (email),
    CONSTRAINT usuario_nombre_ck   CHECK (char_length(btrim(nombre_usuario)) BETWEEN 1 AND 50),
    CONSTRAINT usuario_telefono_ck CHECK (telefono ~ '^\+?[0-9]{8,15}$'),
    CONSTRAINT usuario_email_ck    CHECK (char_length(email) <= 254
                                          AND email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
    CONSTRAINT usuario_pass_hash_ck CHECK (pass_hash LIKE '$argon2id$%' AND char_length(pass_hash) <= 255),
    CONSTRAINT usuario_foto_ck     CHECK (foto_perfil IS NULL OR char_length(foto_perfil) BETWEEN 1 AND 512),
    CONSTRAINT usuario_descripcion_ck CHECK (char_length(descripcion) <= 140)
);
COMMENT ON TABLE  usuario IS 'Cuenta de usuario. Baja lógica con deleted_at (reactivable).';
COMMENT ON COLUMN usuario.pass_hash IS 'argon2id (PHP password_hash). Solo se lee en el flujo de login.';

CREATE TRIGGER usuario_updated_at BEFORE UPDATE ON usuario
    FOR EACH ROW EXECUTE FUNCTION fn_tg_updated_at();

-- contacto --------------------------------------------------------------------
CREATE TABLE contacto (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_usuario       bigint      NOT NULL REFERENCES usuario (id) ON DELETE CASCADE,
    contact_user_id  bigint      NOT NULL REFERENCES usuario (id) ON DELETE CASCADE,
    alias            text        NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    deleted_at       timestamptz,
    CONSTRAINT contacto_par_uq   UNIQUE (id_usuario, contact_user_id),
    CONSTRAINT contacto_no_self_ck CHECK (id_usuario <> contact_user_id),
    CONSTRAINT contacto_alias_ck CHECK (char_length(btrim(alias)) BETWEEN 1 AND 60)
);
COMMENT ON TABLE contacto IS 'Agenda privada de cada usuario. Enlazada a usuario por FK (no por teléfono).';

-- El UNIQUE (id_usuario, contact_user_id) cubre la FK id_usuario.
CREATE INDEX contacto_contact_user_id_ix ON contacto (contact_user_id);
-- Listado paginado por (alias, id) de los contactos activos de un usuario.
CREATE INDEX contacto_listado_ix ON contacto (id_usuario, alias, id) WHERE deleted_at IS NULL;
-- Búsqueda ILIKE '%texto%' por alias.
CREATE INDEX contacto_alias_trgm_ix ON contacto USING gin (alias gin_trgm_ops) WHERE deleted_at IS NULL;

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
    CONSTRAINT conversacion_tipo_ck  CHECK (tipo = 'directa'),
    CONSTRAINT conversacion_orden_ck CHECK (id_usuario_menor < id_usuario_mayor),
    CONSTRAINT conversacion_par_uq   UNIQUE (id_usuario_menor, id_usuario_mayor)
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
    -- Cifrado por la app (nonce + ciphertext + tag). La BD no conoce la clave.
    contenido        bytea       NOT NULL,
    media_url        text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    editado_at       timestamptz,
    deleted_at       timestamptz,
    -- El remitente DEBE ser participante de la conversación (integridad en la BD).
    CONSTRAINT mensaje_remitente_participante_fk
        FOREIGN KEY (id_conversacion, id_remitente)
        REFERENCES participante (id_conversacion, id_usuario) ON DELETE CASCADE,
    CONSTRAINT mensaje_contenido_ck CHECK (octet_length(contenido) BETWEEN 1 AND 65536),
    CONSTRAINT mensaje_media_ck     CHECK (media_url IS NULL OR char_length(media_url) BETWEEN 1 AND 2048),
    -- Destino de la FK compuesta de recibo_mensaje (garantiza que el recibo y el
    -- mensaje pertenecen a la misma conversación).
    CONSTRAINT mensaje_id_conv_uq UNIQUE (id, id_conversacion)
);
-- Cursor de paginación (created_at, id) por conversación; solo mensajes visibles.
CREATE INDEX mensaje_cursor_ix ON mensaje (id_conversacion, created_at DESC, id DESC)
    WHERE deleted_at IS NULL;
-- Índice completo para la FK compuesta (borrado en cascada desde participante).
CREATE INDEX mensaje_conv_remitente_ix ON mensaje (id_conversacion, id_remitente);
-- FK implícita a usuario a través de participante; consultas por remitente.
CREATE INDEX mensaje_id_remitente_ix ON mensaje (id_remitente);

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

-- sesion ----------------------------------------------------------------------
-- Refresh tokens por dispositivo: la API guarda el jti del refresh token emitido.
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
CREATE INDEX sesion_reemplazada_por_ix ON sesion (reemplazada_por);  -- completo: lo usa la FK

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
-- Uso operativo (cron/pg_cron, Fase 2): SELECT fn_crear_particiones_auditoria(3);
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
-- Nunca DELETE físico (salvo bloqueo) ni TRUNCATE/REFERENCES/TRIGGER.

GRANT SELECT, INSERT, UPDATE ON usuario, contacto, conversacion, mensaje, recibo_mensaje, sesion TO app_rw;
GRANT SELECT, INSERT         ON participante TO app_rw;
GRANT SELECT, INSERT, DELETE ON bloqueo TO app_rw;
GRANT INSERT                 ON auditoria TO app_rw;

-- app_ro: lectura sin pass_hash (privilegio por columna) y sin sesiones/auditoría.
GRANT SELECT (id, nombre_usuario, telefono, email, foto_perfil, descripcion,
              created_at, updated_at, deleted_at) ON usuario TO app_ro;
GRANT SELECT ON contacto, bloqueo, conversacion, participante, mensaje, recibo_mensaje TO app_ro;

-- migrate:down
SET LOCAL ROLE migrator;
DROP TABLE IF EXISTS auditoria CASCADE;
DROP TABLE IF EXISTS sesion;
DROP TABLE IF EXISTS recibo_mensaje;
DROP TABLE IF EXISTS mensaje;
DROP TABLE IF EXISTS participante;
DROP TABLE IF EXISTS conversacion;
DROP TABLE IF EXISTS bloqueo;
DROP TABLE IF EXISTS contacto;
DROP TABLE IF EXISTS usuario;
DROP FUNCTION IF EXISTS fn_crear_particiones_auditoria(int);
DROP FUNCTION IF EXISTS fn_tg_auditar_mensaje();
DROP FUNCTION IF EXISTS fn_tg_auditar_usuario();
DROP FUNCTION IF EXISTS fn_tg_updated_at();
