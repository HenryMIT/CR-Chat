-- migrate:up
-- =============================================================================
-- 005 - Funciones de la API v1 (contrato: docs/contratos/db-funciones.md).
-- Reemplaza las funciones de la 003 (ids bigint) por la versión con ids
-- públicos UUID. Se conservan de la 003, sin cambios, fn__validar_limite(int)
-- y fn__hay_bloqueo(bigint, bigint).
--
-- Reglas comunes:
--  * SECURITY INVOKER, SET search_path = public, pg_temp, sin EXECUTE para PUBLIC.
--  * p_usuario uuid = public_id del usuario AUTENTICADO (el `sub` del JWT ya
--    validado por la API; nunca un valor del cuerpo, la ruta o la query).
--    Todos los ids de recurso que entran y salen son public_id (uuid). Los
--    bigint internos nunca salen de la BD.
--  * Recurso ajeno o inexistente => el MISMO error CR404 (anti-IDOR/enumeración).
--  * Errores con SQLSTATE propios (clase CR, código ~ HTTP):
--      CR401 usuario autenticado inválido/inactivo; refresh desconocido/revocado/expirado
--      CR403 prohibido sobre un recurso visible (bloqueo, no es el autor)
--      CR404 inexistente o ajeno
--      CR409 conflicto de unicidad
--      CR422 parámetros inválidos (HINT con un código estable cuando aplica)
--    Sin WHEN OTHERS.
-- =============================================================================
SET LOCAL ROLE migrator;

-- Se retiran las funciones de la 003 cuya firma cambia (bigint -> uuid).
DROP FUNCTION
    fn_marcar_visto(bigint, bigint, bigint),
    fn_marcar_entregado(bigint, bigint, bigint),
    fn_borrar_mensaje(bigint, bigint),
    fn_editar_mensaje(bigint, bigint, bytea),
    fn_listar_mensajes(bigint, bigint, int, timestamptz, bigint),
    fn_enviar_mensaje(bigint, bigint, bytea, text),
    fn_listar_conversaciones(bigint, int, timestamptz, bigint),
    fn_crear_conversacion(bigint, bigint),
    fn_desbloquear_usuario(bigint, bigint),
    fn_bloquear_usuario(bigint, bigint),
    fn_borrar_contacto(bigint, bigint),
    fn_actualizar_contacto(bigint, bigint, text),
    fn_listar_contactos(bigint, text, int, text, bigint),
    fn_crear_contacto(bigint, text, text),
    fn_revocar_sesiones(bigint),
    fn_revocar_sesion(bigint, uuid),
    fn_rotar_sesion(bigint, uuid, uuid, timestamptz),
    fn_crear_sesion(bigint, uuid, timestamptz, text),
    fn_reactivar_usuario(bigint),
    fn_borrar_usuario(bigint),
    fn_cambiar_pass_hash(bigint, text),
    fn_actualizar_usuario(bigint, text, text, text, text, text),
    fn_leer_perfil(bigint),
    fn_credenciales_login(text),
    fn_registrar_usuario(text, text, text, text),
    fn__exigir_participante(bigint, bigint),
    fn__exigir_activo(bigint);

-- =============================================================================
-- Auxiliares internas (EXECUTE para app_rw/app_ro porque las públicas son
-- INVOKER; no exponen datos por sí solas).
-- =============================================================================

-- Texto en minúsculas y sin acentos (búsqueda y orden de contactos).
CREATE FUNCTION fn_normalizar(p_texto text) RETURNS text
LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = public, pg_temp
AS $$
    SELECT lower(unaccent('unaccent'::regdictionary, p_texto));
$$;

-- Escapa los comodines de LIKE de un texto del usuario.
CREATE FUNCTION fn__escapar_like(p_texto text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = public, pg_temp
AS $$
    SELECT replace(replace(replace(p_texto, '\', '\\'), '%', '\%'), '_', '\_');
$$;

-- Usuario autenticado activo: devuelve su id interno o CR401.
CREATE FUNCTION fn__exigir_activo(p_usuario uuid) RETURNS bigint
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
    v_id bigint;
BEGIN
    SELECT u.id INTO v_id FROM usuario u
    WHERE u.public_id = p_usuario AND u.deleted_at IS NULL;
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'usuario autenticado inválido o inactivo' USING ERRCODE = 'CR401';
    END IF;
    RETURN v_id;
END
$$;

-- Conversación por public_id en la que participa el usuario, o CR404.
CREATE FUNCTION fn__conversacion_de(p_id_usuario bigint, p_conversacion uuid) RETURNS bigint
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
    v_id bigint;
BEGIN
    SELECT cv.id INTO v_id
    FROM conversacion cv
    JOIN participante p ON p.id_conversacion = cv.id AND p.id_usuario = p_id_usuario
    WHERE cv.public_id = p_conversacion;
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'conversación no encontrada' USING ERRCODE = 'CR404';
    END IF;
    RETURN v_id;
END
$$;

-- ¿Hay relación entre a y b? (contacto activo en cualquier sentido o
-- conversación compartida). Uno mismo cuenta como relacionado.
CREATE FUNCTION fn__hay_relacion(p_a bigint, p_b bigint) RETURNS boolean
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
    SELECT p_a = p_b
        OR EXISTS (SELECT 1 FROM contacto c
                   WHERE c.id_usuario = p_a AND c.contact_user_id = p_b AND c.deleted_at IS NULL)
        OR EXISTS (SELECT 1 FROM contacto c
                   WHERE c.id_usuario = p_b AND c.contact_user_id = p_a AND c.deleted_at IS NULL)
        OR EXISTS (SELECT 1 FROM conversacion cv
                   WHERE cv.id_usuario_menor = least(p_a, p_b) AND cv.id_usuario_mayor = greatest(p_a, p_b));
$$;

-- Media confirmada como objeto JSON (la API genera la URL GET prefirmada).
CREATE FUNCTION fn__media_json(p_id_media bigint) RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
    SELECT jsonb_build_object(
               'id', m.public_id, 'bucket', m.bucket, 'clave_objeto', m.clave_objeto,
               'mime', m.mime, 'tamano_bytes', m.tamano_bytes, 'ancho', m.ancho, 'alto', m.alto)
    FROM media m
    WHERE m.id = p_id_media AND m.estado = 'confirmado';
$$;

-- Avatar del usuario p_dueno tal como lo ve p_espectador: NULL si no tiene, si
-- está inactivo o si p_dueno bloqueó a p_espectador (U-05).
CREATE FUNCTION fn__avatar_para(p_dueno bigint, p_espectador bigint) RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
    SELECT fn__media_json(u.avatar_media_id)
    FROM usuario u
    WHERE u.id = p_dueno AND u.avatar_media_id IS NOT NULL AND u.deleted_at IS NULL
      AND NOT EXISTS (SELECT 1 FROM bloqueo b
                      WHERE b.id_usuario = p_dueno AND b.id_bloqueado = p_espectador);
$$;

-- Estado agregado de un mensaje propio según los recibos de los destinatarios.
CREATE FUNCTION fn__estado_mensaje(p_id_mensaje bigint) RETURNS text
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
    SELECT CASE WHEN count(*) = 0 THEN 'sent'
                WHEN bool_and(r.visto_at IS NOT NULL) THEN 'seen'
                WHEN bool_and(r.entregado_at IS NOT NULL) THEN 'delivered'
                ELSE 'sent' END
    FROM recibo_mensaje r
    WHERE r.id_mensaje = p_id_mensaje;
$$;

-- No leídos de un usuario en una conversación, con tope 100 (la UI muestra "99+").
CREATE FUNCTION fn__no_leidos(p_id_usuario bigint, p_id_conversacion bigint) RETURNS int
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
    SELECT count(*)::int FROM (
        SELECT 1
        FROM recibo_mensaje r
        JOIN mensaje m ON m.id = r.id_mensaje
        WHERE r.id_usuario = p_id_usuario AND r.id_conversacion = p_id_conversacion
          AND r.visto_at IS NULL AND m.deleted_at IS NULL
        LIMIT 100) x;
$$;

-- Revoca sesiones activas de un usuario (salvo p_excepto) y devuelve sus public_id
-- (la API publica session.revoked en session:{sid}).
CREATE FUNCTION fn__revocar_sesiones(p_id_usuario bigint, p_excepto uuid, p_motivo text)
RETURNS TABLE (id_sesion uuid)
LANGUAGE sql
SET search_path = public, pg_temp
AS $$
    UPDATE sesion s SET revocada_at = now(), motivo_revocacion = p_motivo
    WHERE s.id_usuario = p_id_usuario AND s.revocada_at IS NULL
      AND (p_excepto IS NULL OR s.public_id <> p_excepto)
    RETURNING s.public_id;
$$;

-- -----------------------------------------------------------------------------
-- "Vistas" reutilizables: devuelven la forma completa de un recurso para una
-- lista de ids internos YA AUTORIZADOS por la función pública que las llama.
-- -----------------------------------------------------------------------------

-- Contacto (schema Contact).
CREATE FUNCTION fn__contactos(p_id_usuario bigint, p_ids bigint[])
RETURNS TABLE (id uuid, alias text, telefono text, id_usuario uuid, nombre_usuario text,
               avatar jsonb, id_conversacion uuid, bloqueado boolean,
               created_at timestamptz, orden text)
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
    SELECT c.public_id, c.alias, u.telefono, u.public_id, u.nombre_usuario,
           fn__avatar_para(u.id, p_id_usuario),
           cv.public_id,
           EXISTS (SELECT 1 FROM bloqueo b WHERE b.id_usuario = p_id_usuario AND b.id_bloqueado = u.id),
           c.created_at,
           fn_normalizar(coalesce(c.alias, u.nombre_usuario))
    FROM contacto c
    JOIN usuario u ON u.id = c.contact_user_id
    LEFT JOIN conversacion cv ON cv.id_usuario_menor = least(p_id_usuario, u.id)
                             AND cv.id_usuario_mayor = greatest(p_id_usuario, u.id)
    WHERE c.id = ANY (p_ids) AND c.id_usuario = p_id_usuario
    ORDER BY fn_normalizar(coalesce(c.alias, u.nombre_usuario)) COLLATE "C", c.public_id;
$$;

-- Conversación (schema Conversation, con last_message y unread_count).
CREATE FUNCTION fn__conversaciones(p_id_usuario bigint, p_ids bigint[])
RETURNS TABLE (id uuid, id_peer uuid, peer_nombre text, peer_avatar jsonb, peer_activo boolean,
               id_contacto uuid, es_contacto boolean, bloqueado boolean, no_leidos int,
               created_at timestamptz, ultimo_mensaje_at timestamptz,
               ult_id uuid, ult_id_remitente uuid, ult_client_id uuid,
               ult_contenido bytea, ult_nonce bytea, ult_key_id smallint, ult_media jsonb,
               ult_created_at timestamptz, ult_editado_at timestamptz, ult_deleted_at timestamptz,
               ult_estado text)
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
    SELECT cv.public_id, u.public_id, u.nombre_usuario, fn__avatar_para(u.id, p_id_usuario),
           u.deleted_at IS NULL,
           ct.public_id, ct.id IS NOT NULL,
           EXISTS (SELECT 1 FROM bloqueo b WHERE b.id_usuario = p_id_usuario AND b.id_bloqueado = u.id),
           fn__no_leidos(p_id_usuario, cv.id),
           cv.created_at, cv.ultimo_mensaje_at,
           m.public_id, rm.public_id,
           CASE WHEN m.id_remitente = p_id_usuario THEN m.client_id END,
           m.contenido, m.nonce, m.key_id,
           fn__media_json(m.id_media), m.created_at, m.editado_at, m.deleted_at,
           CASE WHEN m.id_remitente = p_id_usuario THEN fn__estado_mensaje(m.id) END
    FROM conversacion cv
    JOIN participante p  ON p.id_conversacion = cv.id AND p.id_usuario = p_id_usuario
    JOIN participante o  ON o.id_conversacion = cv.id AND o.id_usuario <> p_id_usuario
    JOIN usuario u       ON u.id = o.id_usuario
    LEFT JOIN contacto ct ON ct.id_usuario = p_id_usuario AND ct.contact_user_id = u.id
                         AND ct.deleted_at IS NULL
    LEFT JOIN LATERAL (
        SELECT x.* FROM mensaje x
        WHERE x.id_conversacion = cv.id
        ORDER BY x.created_at DESC, x.id DESC
        LIMIT 1
    ) m ON true
    LEFT JOIN usuario rm ON rm.id = m.id_remitente
    WHERE cv.id = ANY (p_ids)
    ORDER BY cv.ultimo_mensaje_at DESC, cv.public_id DESC;
$$;

-- Mensaje (schema Message). Orden cronológico ascendente.
CREATE FUNCTION fn__mensajes(p_id_usuario bigint, p_ids bigint[])
RETURNS TABLE (id uuid, id_conversacion uuid, id_remitente uuid, client_id uuid,
               contenido bytea, nonce bytea, key_id smallint, media jsonb,
               created_at timestamptz, editado_at timestamptz, deleted_at timestamptz,
               estado text)
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
    SELECT m.public_id, cv.public_id, u.public_id,
           -- client_id solo se devuelve al propio emisor (reconciliación optimista).
           CASE WHEN m.id_remitente = p_id_usuario THEN m.client_id END,
           m.contenido, m.nonce, m.key_id, fn__media_json(m.id_media),
           m.created_at, m.editado_at, m.deleted_at,
           CASE WHEN m.id_remitente = p_id_usuario THEN fn__estado_mensaje(m.id) END
    FROM mensaje m
    JOIN conversacion cv ON cv.id = m.id_conversacion
    JOIN participante p  ON p.id_conversacion = m.id_conversacion AND p.id_usuario = p_id_usuario
    JOIN usuario u       ON u.id = m.id_remitente
    WHERE m.id = ANY (p_ids)
    ORDER BY m.created_at, m.id;
$$;

-- =============================================================================
-- Usuarios y autenticación
-- =============================================================================

-- POST /auth/register. Devuelve el public_id del usuario creado.
CREATE FUNCTION fn_registrar_usuario(
    p_nombre_usuario text,
    p_telefono       text,
    p_email          text,
    p_pass_hash      text
) RETURNS uuid
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_id uuid;
    v_constraint text;
BEGIN
    INSERT INTO usuario (nombre_usuario, telefono, email, pass_hash)
    VALUES (btrim(p_nombre_usuario), p_telefono, p_email, p_pass_hash)
    RETURNING public_id INTO v_id;
    RETURN v_id;
EXCEPTION
    WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        -- La API responde un 409 GENÉRICO (A-13); DETAIL solo va al log.
        RAISE EXCEPTION 'teléfono o email no disponible'
            USING ERRCODE = 'CR409', DETAIL = v_constraint;
    WHEN check_violation OR not_null_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        RAISE EXCEPTION 'datos de registro inválidos'
            USING ERRCODE = 'CR422', DETAIL = coalesce(v_constraint, 'not_null');
END
$$;

-- POST /auth/login y /auth/reactivate (SOLO flujo de login). Por email si
-- contiene '@', si no por teléfono. No compara contraseñas. 0 filas = 401 genérico.
CREATE FUNCTION fn_credenciales_login(p_identificador text)
RETURNS TABLE (id_usuario uuid, pass_hash text, eliminado boolean, eliminado_at timestamptz)
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
BEGIN
    -- Dos ramas para que cada una use su índice UNIQUE (ver optimizacion.md).
    IF position('@' IN p_identificador) > 0 THEN
        RETURN QUERY
        SELECT u.public_id, u.pass_hash, u.deleted_at IS NOT NULL, u.deleted_at
        FROM usuario u WHERE u.email = p_identificador::citext;
    ELSE
        RETURN QUERY
        SELECT u.public_id, u.pass_hash, u.deleted_at IS NOT NULL, u.deleted_at
        FROM usuario u WHERE u.telefono = p_identificador;
    END IF;
END
$$;

-- GET /me (schema Me).
CREATE FUNCTION fn_leer_perfil(p_usuario uuid)
RETURNS TABLE (id uuid, nombre_usuario text, telefono text, email text,
               descripcion text, avatar jsonb, created_at timestamptz)
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
    v_yo bigint := fn__exigir_activo(p_usuario);
BEGIN
    RETURN QUERY
    SELECT u.public_id, u.nombre_usuario, u.telefono, u.email::text, u.descripcion,
           fn__media_json(u.avatar_media_id), u.created_at
    FROM usuario u
    WHERE u.id = v_yo;
END
$$;

-- GET /users/{userId} (schema PublicUser). Solo con relación y sin bloqueo en
-- ningún sentido; si no, CR404 (igual que inexistente o inactivo). Nunca email;
-- teléfono solo si el usuario está en mis contactos activos.
CREATE FUNCTION fn_perfil_publico(p_usuario uuid, p_objetivo uuid)
RETURNS TABLE (id uuid, nombre_usuario text, descripcion text, avatar jsonb,
               telefono text, es_contacto boolean)
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
    v_yo   bigint := fn__exigir_activo(p_usuario);
    v_otro bigint;
    v_es_contacto boolean;
BEGIN
    SELECT u.id INTO v_otro FROM usuario u
    WHERE u.public_id = p_objetivo AND u.deleted_at IS NULL;
    IF v_otro IS NULL OR fn__hay_bloqueo(v_yo, v_otro) OR NOT fn__hay_relacion(v_yo, v_otro) THEN
        RAISE EXCEPTION 'usuario no encontrado' USING ERRCODE = 'CR404';
    END IF;
    v_es_contacto := EXISTS (SELECT 1 FROM contacto c
                             WHERE c.id_usuario = v_yo AND c.contact_user_id = v_otro
                               AND c.deleted_at IS NULL);
    RETURN QUERY
    SELECT u.public_id, u.nombre_usuario, u.descripcion, fn__avatar_para(u.id, v_yo),
           CASE WHEN v_es_contacto THEN u.telefono END, v_es_contacto
    FROM usuario u WHERE u.id = v_otro;
END
$$;

-- PATCH /me. Solo datos no sensibles. NULL = no cambiar; para anular `about`
-- o el avatar se usan las banderas p_quitar_*. El avatar se referencia por el
-- public_id de una media propia con proposito 'avatar' (pendiente o el avatar
-- actual): queda confirmada y el avatar anterior pasa a 'borrado'.
-- La API debe haber comprobado el objeto (HEAD en MinIO) antes de llamar.
CREATE FUNCTION fn_actualizar_usuario(
    p_usuario            uuid,
    p_nombre_usuario     text    DEFAULT NULL,
    p_descripcion        text    DEFAULT NULL,
    p_quitar_descripcion boolean DEFAULT false,
    p_avatar             uuid    DEFAULT NULL,
    p_quitar_avatar      boolean DEFAULT false
)
RETURNS TABLE (id uuid, nombre_usuario text, telefono text, email text,
               descripcion text, avatar jsonb, created_at timestamptz)
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_yo bigint := fn__exigir_activo(p_usuario);
    v_actual bigint;
    v_media media%ROWTYPE;
    v_constraint text;
BEGIN
    IF p_avatar IS NOT NULL AND p_quitar_avatar THEN
        RAISE EXCEPTION 'avatar y quitar_avatar son excluyentes' USING ERRCODE = 'CR422', HINT = 'avatar_media_id';
    END IF;
    IF p_descripcion IS NOT NULL AND p_quitar_descripcion THEN
        RAISE EXCEPTION 'descripcion y quitar_descripcion son excluyentes' USING ERRCODE = 'CR422', HINT = 'about';
    END IF;

    SELECT u.avatar_media_id INTO v_actual FROM usuario u WHERE u.id = v_yo FOR UPDATE;

    IF p_avatar IS NOT NULL THEN
        SELECT m.* INTO v_media FROM media m
        WHERE m.public_id = p_avatar AND m.id_dueno = v_yo
        FOR UPDATE;
        IF NOT FOUND OR v_media.proposito <> 'avatar'
           OR NOT (v_media.estado = 'pendiente' OR v_media.id IS NOT DISTINCT FROM v_actual) THEN
            RAISE EXCEPTION 'media de avatar inválida' USING ERRCODE = 'CR422', HINT = 'avatar_media_id';
        END IF;
        IF v_media.estado = 'pendiente' THEN
            UPDATE media SET estado = 'confirmado', confirmado_at = now() WHERE id = v_media.id;
        END IF;
    END IF;

    UPDATE usuario u SET
        nombre_usuario  = coalesce(btrim(p_nombre_usuario), u.nombre_usuario),
        descripcion     = CASE WHEN p_quitar_descripcion THEN NULL
                               ELSE coalesce(p_descripcion, u.descripcion) END,
        avatar_media_id = CASE WHEN p_quitar_avatar THEN NULL
                               ELSE coalesce(v_media.id, u.avatar_media_id) END
    WHERE u.id = v_yo;

    -- El avatar anterior queda huérfano: el job lo borra de MinIO.
    IF v_actual IS NOT NULL AND (p_quitar_avatar OR (v_media.id IS NOT NULL AND v_media.id <> v_actual)) THEN
        UPDATE media SET estado = 'borrado', borrado_at = now() WHERE id = v_actual;
    END IF;

    RETURN QUERY SELECT * FROM fn_leer_perfil(p_usuario);
EXCEPTION
    WHEN check_violation OR not_null_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        RAISE EXCEPTION 'datos de perfil inválidos' USING ERRCODE = 'CR422', DETAIL = v_constraint;
END
$$;

-- Rehash tras el login (password_needs_rehash). No revoca sesiones.
CREATE FUNCTION fn_rehash_pass(p_usuario uuid, p_pass_hash text) RETURNS void
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_yo bigint := fn__exigir_activo(p_usuario);
BEGIN
    UPDATE usuario SET pass_hash = p_pass_hash WHERE id = v_yo;
EXCEPTION
    WHEN check_violation OR not_null_violation THEN
        RAISE EXCEPTION 'pass_hash inválido (se espera argon2id)' USING ERRCODE = 'CR422';
END
$$;

-- PUT /me/password. PHP verifica la contraseña actual ANTES de llamar.
-- Revoca todas las sesiones salvo p_sesion_actual (NULL = todas) y devuelve sus ids.
CREATE FUNCTION fn_cambiar_pass_hash(p_usuario uuid, p_pass_hash text, p_sesion_actual uuid)
RETURNS TABLE (id_sesion uuid)
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_yo bigint := fn__exigir_activo(p_usuario);
BEGIN
    UPDATE usuario SET pass_hash = p_pass_hash WHERE id = v_yo;
    RETURN QUERY SELECT r.id_sesion FROM fn__revocar_sesiones(v_yo, p_sesion_actual, 'cambio_pass') r;
EXCEPTION
    WHEN check_violation OR not_null_violation THEN
        RAISE EXCEPTION 'pass_hash inválido (se espera argon2id)' USING ERRCODE = 'CR422';
END
$$;

-- PUT /me/phone. PHP verifica la contraseña actual ANTES de llamar.
-- 409 genérico si el teléfono está en uso. Revoca las demás sesiones.
CREATE FUNCTION fn_cambiar_telefono(p_usuario uuid, p_telefono text, p_sesion_actual uuid)
RETURNS TABLE (id_sesion uuid)
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_yo bigint := fn__exigir_activo(p_usuario);
BEGIN
    UPDATE usuario SET telefono = p_telefono WHERE id = v_yo;
    RETURN QUERY SELECT r.id_sesion FROM fn__revocar_sesiones(v_yo, p_sesion_actual, 'cambio_telefono') r;
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'teléfono no disponible' USING ERRCODE = 'CR409';
    WHEN check_violation OR not_null_violation THEN
        RAISE EXCEPTION 'teléfono inválido (E.164)' USING ERRCODE = 'CR422', HINT = 'phone';
END
$$;

-- DELETE /me (baja lógica). PHP verifica la contraseña ANTES de llamar.
-- Revoca TODAS las sesiones y devuelve sus ids.
CREATE FUNCTION fn_borrar_usuario(p_usuario uuid)
RETURNS TABLE (id_sesion uuid)
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_yo bigint := fn__exigir_activo(p_usuario);
BEGIN
    UPDATE usuario SET deleted_at = now() WHERE id = v_yo;
    RETURN QUERY SELECT r.id_sesion FROM fn__revocar_sesiones(v_yo, NULL, 'baja') r;
END
$$;

-- POST /auth/reactivate, tras fn_credenciales_login (eliminado = true) +
-- password_verify correcto. Solo dentro del plazo de gracia; si no, CR404.
CREATE FUNCTION fn_reactivar_usuario(p_usuario uuid, p_plazo interval DEFAULT interval '30 days')
RETURNS void
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    UPDATE usuario SET deleted_at = NULL
    WHERE public_id = p_usuario AND deleted_at IS NOT NULL AND deleted_at > now() - p_plazo;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'cuenta no encontrada, activa o fuera de plazo' USING ERRCODE = 'CR404';
    END IF;
END
$$;

-- =============================================================================
-- Sesiones (una por dispositivo; refresh opaco rotado, solo su hash en la BD)
-- =============================================================================

-- POST /auth/login y /auth/reactivate (tras verificar la contraseña).
-- p_ip: IP del cliente; la BD guarda solo la red (/24 IPv4, /48 IPv6).
CREATE FUNCTION fn_crear_sesion(
    p_usuario      uuid,
    p_jti          uuid,
    p_refresh_hash bytea,
    p_dispositivo  text,
    p_user_agent   text     DEFAULT NULL,
    p_ip           inet     DEFAULT NULL,
    p_vida         interval DEFAULT interval '30 days',
    p_vida_max     interval DEFAULT interval '90 days'
)
RETURNS TABLE (id_sesion uuid, expira_at timestamptz)
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_yo  bigint := fn__exigir_activo(p_usuario);
    v_sid bigint;
    v_constraint text;
BEGIN
    IF p_vida IS NULL OR p_vida_max IS NULL OR p_vida <= interval '0' OR p_vida > p_vida_max THEN
        RAISE EXCEPTION 'vida de sesión inválida' USING ERRCODE = 'CR422';
    END IF;
    BEGIN
        INSERT INTO sesion (id_usuario, dispositivo, user_agent, ip_hint, expira_at, expira_max_at)
        VALUES (v_yo, btrim(p_dispositivo), p_user_agent,
                CASE WHEN p_ip IS NULL THEN NULL
                     ELSE network(set_masklen(p_ip, CASE WHEN family(p_ip) = 4 THEN 24 ELSE 48 END)) END,
                now() + p_vida, now() + p_vida_max)
        RETURNING sesion.id, sesion.public_id, sesion.expira_at INTO v_sid, id_sesion, expira_at;
        INSERT INTO sesion_refresh (id_sesion, jti, token_hash)
        VALUES (v_sid, p_jti, p_refresh_hash);
    EXCEPTION
        WHEN unique_violation THEN
            RAISE EXCEPTION 'jti o refresh duplicado' USING ERRCODE = 'CR409';
        WHEN check_violation OR not_null_violation THEN
            GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
            RAISE EXCEPTION 'datos de sesión inválidos' USING ERRCODE = 'CR422', DETAIL = v_constraint;
    END;
    RETURN NEXT;
END
$$;

-- POST /auth/refresh. Recibe el hash SHA-256 del refresh presentado y el del nuevo.
--  * desconocido, sesión revocada/expirada o usuario inactivo => CR401
--    (HINT: 'desconocido' | 'revocada' | 'expirada' | 'inactivo').
--  * refresh YA ROTADO (reutilización, posible robo) => revoca la sesión
--    (motivo 'reutilizacion') y devuelve estado = 'reutilizacion' SIN error,
--    para que la revocación quede confirmada. La API responde 401 y publica
--    session.revoked.
--  * correcto => rota, desliza expira_at (sin pasar expira_max_at) y devuelve 'ok'.
CREATE FUNCTION fn_rotar_sesion(
    p_refresh_hash bytea,
    p_jti_nuevo    uuid,
    p_hash_nuevo   bytea,
    p_vida         interval DEFAULT interval '30 days'
)
RETURNS TABLE (estado text, id_usuario uuid, id_sesion uuid, expira_at timestamptz)
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_r  sesion_refresh%ROWTYPE;
    v_s  sesion%ROWTYPE;
    v_u  usuario%ROWTYPE;
BEGIN
    SELECT r.* INTO v_r FROM sesion_refresh r WHERE r.token_hash = p_refresh_hash FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'refresh token desconocido' USING ERRCODE = 'CR401', HINT = 'desconocido';
    END IF;
    SELECT s.* INTO v_s FROM sesion s WHERE s.id = v_r.id_sesion FOR UPDATE;
    SELECT u.* INTO v_u FROM usuario u WHERE u.id = v_s.id_usuario;

    IF v_s.revocada_at IS NOT NULL THEN
        RAISE EXCEPTION 'sesión revocada' USING ERRCODE = 'CR401', HINT = 'revocada';
    END IF;
    IF v_r.rotado_at IS NOT NULL THEN
        UPDATE sesion SET revocada_at = now(), motivo_revocacion = 'reutilizacion' WHERE id = v_s.id;
        RETURN QUERY SELECT 'reutilizacion'::text, v_u.public_id, v_s.public_id, NULL::timestamptz;
        RETURN;
    END IF;
    IF v_s.expira_at <= now() THEN
        RAISE EXCEPTION 'sesión expirada' USING ERRCODE = 'CR401', HINT = 'expirada';
    END IF;
    IF v_u.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'usuario inactivo' USING ERRCODE = 'CR401', HINT = 'inactivo';
    END IF;
    IF p_vida IS NULL OR p_vida <= interval '0' THEN
        RAISE EXCEPTION 'vida de sesión inválida' USING ERRCODE = 'CR422';
    END IF;

    UPDATE sesion_refresh SET rotado_at = now() WHERE id = v_r.id;
    BEGIN
        INSERT INTO sesion_refresh (id_sesion, jti, token_hash) VALUES (v_s.id, p_jti_nuevo, p_hash_nuevo);
    EXCEPTION
        WHEN unique_violation THEN
            RAISE EXCEPTION 'jti o refresh duplicado' USING ERRCODE = 'CR409';
        WHEN check_violation OR not_null_violation THEN
            RAISE EXCEPTION 'refresh nuevo inválido (SHA-256 de 32 bytes)' USING ERRCODE = 'CR422';
    END;
    UPDATE sesion s SET expira_at = least(now() + p_vida, s.expira_max_at), last_used_at = now()
    WHERE s.id = v_s.id;

    RETURN QUERY
    SELECT 'ok'::text, v_u.public_id, s.public_id, s.expira_at FROM sesion s WHERE s.id = v_s.id;
END
$$;

-- Middleware de la API (respaldo de session:{sid} en Redis): true si la sesión
-- es del usuario, no está revocada ni expirada y el usuario está activo. Toca
-- last_used_at como mucho una vez por minuto (evita una escritura por petición).
CREATE FUNCTION fn_tocar_sesion(p_usuario uuid, p_sesion uuid) RETURNS boolean
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_id bigint;
    v_ultimo timestamptz;
BEGIN
    SELECT s.id, s.last_used_at INTO v_id, v_ultimo
    FROM sesion s JOIN usuario u ON u.id = s.id_usuario
    WHERE s.public_id = p_sesion AND u.public_id = p_usuario AND u.deleted_at IS NULL
      AND s.revocada_at IS NULL AND s.expira_at > now();
    IF v_id IS NULL THEN
        RETURN false;
    END IF;
    IF v_ultimo < now() - interval '1 minute' THEN
        UPDATE sesion SET last_used_at = now() WHERE id = v_id;
    END IF;
    RETURN true;
END
$$;

-- GET /me/sessions (schema Session). Activas, la más usada recientemente primero.
CREATE FUNCTION fn_listar_sesiones(p_usuario uuid, p_sesion_actual uuid)
RETURNS TABLE (id uuid, dispositivo text, user_agent text, ip_hint text,
               created_at timestamptz, last_used_at timestamptz, expira_at timestamptz,
               actual boolean)
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
    v_yo bigint := fn__exigir_activo(p_usuario);
BEGIN
    RETURN QUERY
    SELECT s.public_id, s.dispositivo, s.user_agent, s.ip_hint::text,
           s.created_at, s.last_used_at, s.expira_at,
           s.public_id = p_sesion_actual
    FROM sesion s
    WHERE s.id_usuario = v_yo AND s.revocada_at IS NULL AND s.expira_at > now()
    ORDER BY s.last_used_at DESC, s.public_id;
END
$$;

-- POST /auth/logout (p_motivo 'logout') y DELETE /me/sessions/{id} ('revocada').
-- Sesión ajena o inexistente => CR404. Propia ya revocada => false (idempotente).
CREATE FUNCTION fn_revocar_sesion(p_usuario uuid, p_sesion uuid, p_motivo text DEFAULT 'revocada')
RETURNS boolean
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_yo bigint := fn__exigir_activo(p_usuario);
    v_id bigint;
    v_revocada timestamptz;
BEGIN
    IF p_motivo IS NULL OR p_motivo NOT IN ('logout', 'revocada') THEN
        RAISE EXCEPTION 'motivo inválido (logout | revocada)' USING ERRCODE = 'CR422';
    END IF;
    SELECT s.id, s.revocada_at INTO v_id, v_revocada FROM sesion s
    WHERE s.public_id = p_sesion AND s.id_usuario = v_yo
    FOR UPDATE;
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'sesión no encontrada' USING ERRCODE = 'CR404';
    END IF;
    IF v_revocada IS NOT NULL THEN
        RETURN false;
    END IF;
    UPDATE sesion SET revocada_at = now(), motivo_revocacion = p_motivo WHERE id = v_id;
    RETURN true;
END
$$;

-- DELETE /me/sessions (todas menos la actual: p_excepto = sid del access token).
-- p_excepto NULL = todas. Devuelve los ids revocados.
CREATE FUNCTION fn_revocar_sesiones(p_usuario uuid, p_excepto uuid DEFAULT NULL)
RETURNS TABLE (id_sesion uuid)
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_yo bigint := fn__exigir_activo(p_usuario);
BEGIN
    RETURN QUERY SELECT r.id_sesion FROM fn__revocar_sesiones(v_yo, p_excepto, 'revocada') r;
END
$$;

-- =============================================================================
-- Contactos
-- =============================================================================

-- POST /contacts. Idempotente por teléfono E.164: si ya existe (activo) devuelve
-- el existente con creado = false; si estaba borrado lo reactiva (creado = true).
-- No registrado, uno mismo o el destino me bloqueó => el MISMO CR404.
CREATE FUNCTION fn_crear_contacto(p_usuario uuid, p_telefono text, p_alias text DEFAULT NULL)
RETURNS TABLE (id uuid, alias text, telefono text, id_usuario uuid, nombre_usuario text,
               avatar jsonb, id_conversacion uuid, bloqueado boolean,
               created_at timestamptz, orden text, creado boolean)
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_yo      bigint := fn__exigir_activo(p_usuario);
    v_destino bigint;
    v_id      bigint;
    v_borrado timestamptz;
    v_alias   text := nullif(btrim(p_alias), '');
    v_creado  boolean := true;
BEGIN
    SELECT u.id INTO v_destino FROM usuario u
    WHERE u.telefono = p_telefono AND u.deleted_at IS NULL;
    IF v_destino IS NULL OR v_destino = v_yo
       OR EXISTS (SELECT 1 FROM bloqueo b WHERE b.id_usuario = v_destino AND b.id_bloqueado = v_yo) THEN
        RAISE EXCEPTION 'contacto no disponible' USING ERRCODE = 'CR404';
    END IF;

    BEGIN
        INSERT INTO contacto (id_usuario, contact_user_id, alias)
        VALUES (v_yo, v_destino, v_alias)
        ON CONFLICT ON CONSTRAINT contacto_par_uq DO NOTHING
        RETURNING contacto.id INTO v_id;
    EXCEPTION
        WHEN check_violation THEN
            RAISE EXCEPTION 'alias inválido (1..50 caracteres)' USING ERRCODE = 'CR422', HINT = 'alias';
    END;

    IF v_id IS NULL THEN
        SELECT c.id, c.deleted_at INTO v_id, v_borrado FROM contacto c
        WHERE c.id_usuario = v_yo AND c.contact_user_id = v_destino
        FOR UPDATE;
        IF v_borrado IS NOT NULL THEN
            BEGIN
                UPDATE contacto SET deleted_at = NULL, alias = v_alias, created_at = now()
                WHERE contacto.id = v_id;
            EXCEPTION
                WHEN check_violation THEN
                    RAISE EXCEPTION 'alias inválido (1..50 caracteres)' USING ERRCODE = 'CR422', HINT = 'alias';
            END;
        ELSE
            v_creado := false;   -- ya existía: se devuelve tal cual (200)
        END IF;
    END IF;

    RETURN QUERY SELECT d.*, v_creado FROM fn__contactos(v_yo, ARRAY[v_id]) d;
END
$$;

-- GET /contacts/{id}.
CREATE FUNCTION fn_obtener_contacto(p_usuario uuid, p_contacto uuid)
RETURNS TABLE (id uuid, alias text, telefono text, id_usuario uuid, nombre_usuario text,
               avatar jsonb, id_conversacion uuid, bloqueado boolean,
               created_at timestamptz, orden text)
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_yo bigint := fn__exigir_activo(p_usuario);
    v_id bigint;
BEGIN
    SELECT c.id INTO v_id FROM contacto c
    JOIN usuario u ON u.id = c.contact_user_id AND u.deleted_at IS NULL
    WHERE c.public_id = p_contacto AND c.id_usuario = v_yo AND c.deleted_at IS NULL;
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'contacto no encontrado' USING ERRCODE = 'CR404';
    END IF;
    RETURN QUERY SELECT * FROM fn__contactos(v_yo, ARRAY[v_id]);
END
$$;

-- GET /contacts?q=&limit=&cursor=. Orden por `orden` (alias o nombre, en
-- minúsculas y sin acentos, COLLATE "C") y public_id. q: subcadena en alias o
-- nombre (sin mayúsculas ni acentos) o prefijo de teléfono (con o sin '+').
-- Cursor: (orden, id) de la última fila recibida.
CREATE FUNCTION fn_listar_contactos(
    p_usuario      uuid,
    p_busqueda     text DEFAULT NULL,
    p_limite       int  DEFAULT 50,
    p_cursor_orden text DEFAULT NULL,
    p_cursor_id    uuid DEFAULT NULL
)
RETURNS TABLE (id uuid, alias text, telefono text, id_usuario uuid, nombre_usuario text,
               avatar jsonb, id_conversacion uuid, bloqueado boolean,
               created_at timestamptz, orden text)
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_yo     bigint := fn__exigir_activo(p_usuario);
    v_q      text := nullif(btrim(p_busqueda), '');
    v_patron text;
    v_tel    text;
    v_ids    bigint[];
BEGIN
    PERFORM fn__validar_limite(p_limite);
    IF (p_cursor_orden IS NULL) <> (p_cursor_id IS NULL) THEN
        RAISE EXCEPTION 'el cursor requiere orden e id' USING ERRCODE = 'CR422', HINT = 'cursor';
    END IF;
    IF char_length(v_q) > 50 THEN
        RAISE EXCEPTION 'búsqueda demasiado larga (máx. 50)' USING ERRCODE = 'CR422', HINT = 'q';
    END IF;
    v_patron := fn__escapar_like(fn_normalizar(v_q));
    v_tel    := fn__escapar_like(ltrim(v_q, '+'));

    v_ids := ARRAY(
        SELECT c.id
        FROM contacto c
        JOIN usuario u ON u.id = c.contact_user_id AND u.deleted_at IS NULL
        WHERE c.id_usuario = v_yo AND c.deleted_at IS NULL
          AND (v_q IS NULL
               OR fn_normalizar(coalesce(c.alias, '')) LIKE '%' || v_patron || '%'
               OR fn_normalizar(u.nombre_usuario)      LIKE '%' || v_patron || '%'
               OR u.telefono LIKE '+' || v_tel || '%')
          AND (p_cursor_id IS NULL
               OR (fn_normalizar(coalesce(c.alias, u.nombre_usuario)) COLLATE "C", c.public_id)
                  > (p_cursor_orden COLLATE "C", p_cursor_id))
        ORDER BY fn_normalizar(coalesce(c.alias, u.nombre_usuario)) COLLATE "C", c.public_id
        LIMIT p_limite);

    RETURN QUERY SELECT * FROM fn__contactos(v_yo, v_ids);
END
$$;

-- PATCH /contacts/{id}. Solo el alias; NULL vuelve al nombre del usuario.
CREATE FUNCTION fn_actualizar_contacto(p_usuario uuid, p_contacto uuid, p_alias text)
RETURNS TABLE (id uuid, alias text, telefono text, id_usuario uuid, nombre_usuario text,
               avatar jsonb, id_conversacion uuid, bloqueado boolean,
               created_at timestamptz, orden text)
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_yo bigint := fn__exigir_activo(p_usuario);
    v_id bigint;
BEGIN
    UPDATE contacto c SET alias = btrim(p_alias)
    WHERE c.public_id = p_contacto AND c.id_usuario = v_yo AND c.deleted_at IS NULL
    RETURNING c.id INTO v_id;
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'contacto no encontrado' USING ERRCODE = 'CR404';
    END IF;
    RETURN QUERY SELECT * FROM fn__contactos(v_yo, ARRAY[v_id]);
EXCEPTION
    WHEN check_violation THEN
        RAISE EXCEPTION 'alias inválido (1..50 caracteres)' USING ERRCODE = 'CR422', HINT = 'alias';
END
$$;

-- DELETE /contacts/{id} (baja lógica; la conversación se conserva).
CREATE FUNCTION fn_borrar_contacto(p_usuario uuid, p_contacto uuid) RETURNS void
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_yo bigint := fn__exigir_activo(p_usuario);
BEGIN
    UPDATE contacto SET deleted_at = now()
    WHERE public_id = p_contacto AND id_usuario = v_yo AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'contacto no encontrado' USING ERRCODE = 'CR404';
    END IF;
END
$$;

-- =============================================================================
-- Bloqueos
-- =============================================================================

-- PUT /blocks/{userId}. Idempotente (true = bloqueo nuevo). Solo con relación;
-- inexistente, inactivo o sin relación => CR404. A uno mismo => CR422.
CREATE FUNCTION fn_bloquear_usuario(p_usuario uuid, p_objetivo uuid) RETURNS boolean
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_yo   bigint := fn__exigir_activo(p_usuario);
    v_otro bigint;
BEGIN
    IF p_objetivo = p_usuario THEN
        RAISE EXCEPTION 'no puedes bloquearte' USING ERRCODE = 'CR422';
    END IF;
    SELECT u.id INTO v_otro FROM usuario u WHERE u.public_id = p_objetivo AND u.deleted_at IS NULL;
    IF v_otro IS NULL THEN
        RAISE EXCEPTION 'usuario no encontrado' USING ERRCODE = 'CR404';
    END IF;
    IF EXISTS (SELECT 1 FROM bloqueo b WHERE b.id_usuario = v_yo AND b.id_bloqueado = v_otro) THEN
        RETURN false;
    END IF;
    IF NOT fn__hay_relacion(v_yo, v_otro) THEN
        RAISE EXCEPTION 'usuario no encontrado' USING ERRCODE = 'CR404';
    END IF;
    INSERT INTO bloqueo (id_usuario, id_bloqueado) VALUES (v_yo, v_otro)
    ON CONFLICT DO NOTHING;
    RETURN FOUND;
END
$$;

-- DELETE /blocks/{userId}. Idempotente (true = existía). Nunca CR404.
CREATE FUNCTION fn_desbloquear_usuario(p_usuario uuid, p_objetivo uuid) RETURNS boolean
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_yo bigint := fn__exigir_activo(p_usuario);
BEGIN
    DELETE FROM bloqueo b
    USING usuario u
    WHERE b.id_usuario = v_yo AND b.id_bloqueado = u.id AND u.public_id = p_objetivo;
    RETURN FOUND;
END
$$;

-- GET /blocks (schema Block). Más reciente primero; cursor (created_at, id).
CREATE FUNCTION fn_listar_bloqueos(
    p_usuario   uuid,
    p_limite    int         DEFAULT 50,
    p_cursor_at timestamptz DEFAULT NULL,
    p_cursor_id uuid        DEFAULT NULL
)
RETURNS TABLE (id_usuario uuid, nombre_usuario text, avatar jsonb, created_at timestamptz)
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
    v_yo bigint := fn__exigir_activo(p_usuario);
BEGIN
    PERFORM fn__validar_limite(p_limite);
    IF (p_cursor_at IS NULL) <> (p_cursor_id IS NULL) THEN
        RAISE EXCEPTION 'el cursor requiere fecha e id' USING ERRCODE = 'CR422', HINT = 'cursor';
    END IF;
    RETURN QUERY
    SELECT u.public_id, u.nombre_usuario, fn__avatar_para(u.id, v_yo), b.created_at
    FROM bloqueo b
    JOIN usuario u ON u.id = b.id_bloqueado
    WHERE b.id_usuario = v_yo
      AND (p_cursor_at IS NULL OR (b.created_at, u.public_id) < (p_cursor_at, p_cursor_id))
    ORDER BY b.created_at DESC, u.public_id DESC
    LIMIT p_limite;
END
$$;

-- =============================================================================
-- Conversaciones
-- =============================================================================

-- POST /conversations {contact_id}. Obtener-o-crear (creada = false si existía).
-- Contacto ajeno/inexistente => CR404; bloqueo en cualquier sentido => CR403.
CREATE FUNCTION fn_crear_conversacion(p_usuario uuid, p_contacto uuid)
RETURNS TABLE (id uuid, id_peer uuid, peer_nombre text, peer_avatar jsonb, peer_activo boolean,
               id_contacto uuid, es_contacto boolean, bloqueado boolean, no_leidos int,
               created_at timestamptz, ultimo_mensaje_at timestamptz,
               ult_id uuid, ult_id_remitente uuid, ult_client_id uuid,
               ult_contenido bytea, ult_nonce bytea, ult_key_id smallint, ult_media jsonb,
               ult_created_at timestamptz, ult_editado_at timestamptz, ult_deleted_at timestamptz,
               ult_estado text, creada boolean)
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_yo   bigint := fn__exigir_activo(p_usuario);
    v_otro bigint;
    v_id   bigint;
    v_creada boolean := false;
BEGIN
    SELECT c.contact_user_id INTO v_otro
    FROM contacto c
    JOIN usuario u ON u.id = c.contact_user_id AND u.deleted_at IS NULL
    WHERE c.public_id = p_contacto AND c.id_usuario = v_yo AND c.deleted_at IS NULL;
    IF v_otro IS NULL THEN
        RAISE EXCEPTION 'contacto no encontrado' USING ERRCODE = 'CR404';
    END IF;
    IF fn__hay_bloqueo(v_yo, v_otro) THEN
        RAISE EXCEPTION 'no se puede conversar con este usuario' USING ERRCODE = 'CR403', HINT = 'bloqueado';
    END IF;

    INSERT INTO conversacion (id_usuario_menor, id_usuario_mayor)
    VALUES (least(v_yo, v_otro), greatest(v_yo, v_otro))
    ON CONFLICT ON CONSTRAINT conversacion_par_uq DO NOTHING
    RETURNING conversacion.id INTO v_id;

    IF v_id IS NOT NULL THEN
        INSERT INTO participante (id_conversacion, id_usuario) VALUES (v_id, v_yo), (v_id, v_otro);
        v_creada := true;
    ELSE
        SELECT cv.id INTO v_id FROM conversacion cv
        WHERE cv.id_usuario_menor = least(v_yo, v_otro) AND cv.id_usuario_mayor = greatest(v_yo, v_otro);
    END IF;

    RETURN QUERY SELECT d.*, v_creada FROM fn__conversaciones(v_yo, ARRAY[v_id]) d;
END
$$;

-- GET /conversations/{id}. No participante => CR404.
CREATE FUNCTION fn_obtener_conversacion(p_usuario uuid, p_conversacion uuid)
RETURNS TABLE (id uuid, id_peer uuid, peer_nombre text, peer_avatar jsonb, peer_activo boolean,
               id_contacto uuid, es_contacto boolean, bloqueado boolean, no_leidos int,
               created_at timestamptz, ultimo_mensaje_at timestamptz,
               ult_id uuid, ult_id_remitente uuid, ult_client_id uuid,
               ult_contenido bytea, ult_nonce bytea, ult_key_id smallint, ult_media jsonb,
               ult_created_at timestamptz, ult_editado_at timestamptz, ult_deleted_at timestamptz,
               ult_estado text)
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_yo   bigint := fn__exigir_activo(p_usuario);
    v_conv bigint := fn__conversacion_de(v_yo, p_conversacion);
BEGIN
    RETURN QUERY SELECT * FROM fn__conversaciones(v_yo, ARRAY[v_conv]);
END
$$;

-- GET /conversations?limit=&cursor=. Actividad más reciente primero.
-- Cursor: (ultimo_mensaje_at, id) de la última fila recibida.
CREATE FUNCTION fn_listar_conversaciones(
    p_usuario   uuid,
    p_limite    int         DEFAULT 50,
    p_cursor_at timestamptz DEFAULT NULL,
    p_cursor_id uuid        DEFAULT NULL
)
RETURNS TABLE (id uuid, id_peer uuid, peer_nombre text, peer_avatar jsonb, peer_activo boolean,
               id_contacto uuid, es_contacto boolean, bloqueado boolean, no_leidos int,
               created_at timestamptz, ultimo_mensaje_at timestamptz,
               ult_id uuid, ult_id_remitente uuid, ult_client_id uuid,
               ult_contenido bytea, ult_nonce bytea, ult_key_id smallint, ult_media jsonb,
               ult_created_at timestamptz, ult_editado_at timestamptz, ult_deleted_at timestamptz,
               ult_estado text)
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_yo  bigint := fn__exigir_activo(p_usuario);
    v_ids bigint[];
BEGIN
    PERFORM fn__validar_limite(p_limite);
    IF (p_cursor_at IS NULL) <> (p_cursor_id IS NULL) THEN
        RAISE EXCEPTION 'el cursor requiere fecha e id' USING ERRCODE = 'CR422', HINT = 'cursor';
    END IF;
    v_ids := ARRAY(
        SELECT cv.id
        FROM participante p
        JOIN conversacion cv ON cv.id = p.id_conversacion
        WHERE p.id_usuario = v_yo
          AND (p_cursor_at IS NULL OR (cv.ultimo_mensaje_at, cv.public_id) < (p_cursor_at, p_cursor_id))
        ORDER BY cv.ultimo_mensaje_at DESC, cv.public_id DESC
        LIMIT p_limite);
    RETURN QUERY SELECT * FROM fn__conversaciones(v_yo, v_ids);
END
$$;

-- Participantes (public_id) de una conversación, INCLUIDO el llamante, para
-- publicar en Redis user:{id}. No participante => CR404.
CREATE FUNCTION fn_participantes_conversacion(p_usuario uuid, p_conversacion uuid)
RETURNS TABLE (id_usuario uuid)
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
    v_yo   bigint := fn__exigir_activo(p_usuario);
    v_conv bigint := fn__conversacion_de(v_yo, p_conversacion);
BEGIN
    RETURN QUERY
    SELECT u.public_id FROM participante p JOIN usuario u ON u.id = p.id_usuario
    WHERE p.id_conversacion = v_conv
    ORDER BY u.public_id;
END
$$;

-- =============================================================================
-- Mensajes
-- =============================================================================

-- POST /conversations/{id}/messages. p_contenido + p_nonce + p_key_id llegan
-- CIFRADOS por la API (libsodium XChaCha20-Poly1305); la BD no recibe claves.
-- Texto y/o adjunto (p_media = public_id de una media propia 'mensaje' pendiente).
-- Idempotente por p_client_id: si ya existe un mensaje mío con ese client_id en
-- ESTA conversación lo devuelve (creado = false); en otra conversación => CR409.
CREATE FUNCTION fn_enviar_mensaje(
    p_usuario      uuid,
    p_conversacion uuid,
    p_contenido    bytea    DEFAULT NULL,
    p_nonce        bytea    DEFAULT NULL,
    p_key_id       smallint DEFAULT NULL,
    p_media        uuid     DEFAULT NULL,
    p_client_id    uuid     DEFAULT NULL
)
RETURNS TABLE (id uuid, id_conversacion uuid, id_remitente uuid, client_id uuid,
               contenido bytea, nonce bytea, key_id smallint, media jsonb,
               created_at timestamptz, editado_at timestamptz, deleted_at timestamptz,
               estado text, creado boolean)
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_yo    bigint := fn__exigir_activo(p_usuario);
    v_conv  bigint := fn__conversacion_de(v_yo, p_conversacion);
    v_id    bigint;
    v_conv_existente bigint;
    v_at    timestamptz;
    v_media bigint;
    v_constraint text;
BEGIN
    -- 1) Reintento idempotente (antes que el bloqueo: el mensaje ya se envió).
    IF p_client_id IS NOT NULL THEN
        SELECT m.id, m.id_conversacion INTO v_id, v_conv_existente FROM mensaje m
        WHERE m.id_remitente = v_yo AND m.client_id = p_client_id;
        IF v_id IS NOT NULL THEN
            IF v_conv_existente <> v_conv THEN
                RAISE EXCEPTION 'client_id ya usado en otra conversación' USING ERRCODE = 'CR409', HINT = 'client_id';
            END IF;
            RETURN QUERY SELECT d.*, false FROM fn__mensajes(v_yo, ARRAY[v_id]) d;
            RETURN;
        END IF;
    END IF;

    -- 2) Bloqueo en cualquier sentido o destinatario dado de baja.
    IF EXISTS (
        SELECT 1 FROM participante o JOIN usuario x ON x.id = o.id_usuario
        WHERE o.id_conversacion = v_conv AND o.id_usuario <> v_yo
          AND (x.deleted_at IS NOT NULL OR fn__hay_bloqueo(v_yo, o.id_usuario))
    ) THEN
        RAISE EXCEPTION 'no se puede enviar a esta conversación' USING ERRCODE = 'CR403', HINT = 'bloqueado';
    END IF;

    -- 3) Adjunto: media propia, de mensaje y pendiente (no reutilizable).
    IF p_media IS NOT NULL THEN
        SELECT m.id INTO v_media FROM media m
        WHERE m.public_id = p_media AND m.id_dueno = v_yo
          AND m.proposito = 'mensaje' AND m.estado = 'pendiente'
        FOR UPDATE;
        IF v_media IS NULL THEN
            RAISE EXCEPTION 'media inválida' USING ERRCODE = 'CR422', HINT = 'media_id';
        END IF;
    END IF;
    IF p_contenido IS NULL AND v_media IS NULL THEN
        RAISE EXCEPTION 'el mensaje requiere texto o adjunto' USING ERRCODE = 'CR422', HINT = 'text';
    END IF;

    -- 4) Inserción; ON CONFLICT cubre la carrera de dos reintentos simultáneos.
    BEGIN
        INSERT INTO mensaje (id_conversacion, id_remitente, contenido, nonce, key_id, client_id, id_media)
        VALUES (v_conv, v_yo, p_contenido, p_nonce, p_key_id, p_client_id, v_media)
        ON CONFLICT ON CONSTRAINT mensaje_client_id_uq DO NOTHING
        RETURNING mensaje.id, mensaje.created_at INTO v_id, v_at;
    EXCEPTION
        WHEN check_violation OR not_null_violation THEN
            GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
            RAISE EXCEPTION 'contenido cifrado inválido (1..65536 bytes, nonce de 24 bytes, key_id >= 1)'
                USING ERRCODE = 'CR422', DETAIL = v_constraint, HINT = 'text';
    END;
    IF v_id IS NULL THEN
        -- Otro reintento simultáneo ganó la carrera: devolver el suyo.
        SELECT m.id, m.id_conversacion INTO STRICT v_id, v_conv_existente FROM mensaje m
        WHERE m.id_remitente = v_yo AND m.client_id = p_client_id;
        IF v_conv_existente <> v_conv THEN
            RAISE EXCEPTION 'client_id ya usado en otra conversación' USING ERRCODE = 'CR409', HINT = 'client_id';
        END IF;
        RETURN QUERY SELECT d.*, false FROM fn__mensajes(v_yo, ARRAY[v_id]) d;
        RETURN;
    END IF;

    IF v_media IS NOT NULL THEN
        UPDATE media SET estado = 'confirmado', confirmado_at = now() WHERE media.id = v_media;
    END IF;
    INSERT INTO recibo_mensaje (id_mensaje, id_conversacion, id_usuario)
    SELECT v_id, v_conv, o.id_usuario FROM participante o
    WHERE o.id_conversacion = v_conv AND o.id_usuario <> v_yo;
    UPDATE conversacion SET ultimo_mensaje_at = greatest(ultimo_mensaje_at, v_at) WHERE conversacion.id = v_conv;

    RETURN QUERY SELECT d.*, true FROM fn__mensajes(v_yo, ARRAY[v_id]) d;
END
$$;

-- GET /conversations/{id}/messages?limit=&before=|after=. Cursor = public_id de
-- un mensaje de la conversación (la API lo codifica de forma opaca).
--  * sin cursor: los p_limite más recientes;
--  * p_antes: los p_limite inmediatamente anteriores al cursor;
--  * p_despues: los p_limite inmediatamente posteriores al cursor.
-- Siempre en orden cronológico ascendente; incluye lápidas (deleted_at, contenido NULL).
-- next_cursor: con before, la PRIMERA fila; con after, la ÚLTIMA; si vienen
-- menos de p_limite filas no hay más páginas.
CREATE FUNCTION fn_listar_mensajes(
    p_usuario      uuid,
    p_conversacion uuid,
    p_limite       int  DEFAULT 50,
    p_antes        uuid DEFAULT NULL,
    p_despues      uuid DEFAULT NULL
)
RETURNS TABLE (id uuid, id_conversacion uuid, id_remitente uuid, client_id uuid,
               contenido bytea, nonce bytea, key_id smallint, media jsonb,
               created_at timestamptz, editado_at timestamptz, deleted_at timestamptz,
               estado text)
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_yo   bigint := fn__exigir_activo(p_usuario);
    v_conv bigint := fn__conversacion_de(v_yo, p_conversacion);
    v_c_at timestamptz;
    v_c_id bigint;
    v_ids  bigint[];
BEGIN
    PERFORM fn__validar_limite(p_limite);
    IF p_antes IS NOT NULL AND p_despues IS NOT NULL THEN
        RAISE EXCEPTION 'before y after son excluyentes' USING ERRCODE = 'CR422', HINT = 'cursor';
    END IF;
    IF coalesce(p_antes, p_despues) IS NOT NULL THEN
        SELECT m.created_at, m.id INTO v_c_at, v_c_id FROM mensaje m
        WHERE m.public_id = coalesce(p_antes, p_despues) AND m.id_conversacion = v_conv;
        IF v_c_id IS NULL THEN
            RAISE EXCEPTION 'cursor inválido' USING ERRCODE = 'CR422', HINT = 'cursor';
        END IF;
    END IF;

    IF p_despues IS NOT NULL THEN
        v_ids := ARRAY(
            SELECT m.id FROM mensaje m
            WHERE m.id_conversacion = v_conv AND (m.created_at, m.id) > (v_c_at, v_c_id)
            ORDER BY m.created_at, m.id
            LIMIT p_limite);
    ELSE
        v_ids := ARRAY(
            SELECT m.id FROM mensaje m
            WHERE m.id_conversacion = v_conv
              AND (v_c_id IS NULL OR (m.created_at, m.id) < (v_c_at, v_c_id))
            ORDER BY m.created_at DESC, m.id DESC
            LIMIT p_limite);
    END IF;

    RETURN QUERY SELECT * FROM fn__mensajes(v_yo, v_ids);
END
$$;

-- PATCH /messages/{id}. Solo el autor y dentro de 15 minutos.
--  no participante / inexistente / ya borrado => CR404
--  participante pero no autor                  => CR403 (HINT 'no-autor')
--  bloqueo en cualquier sentido               => CR403 (HINT 'bloqueado')
--  fuera de plazo                             => CR422 (HINT 'edicion-expirada')
CREATE FUNCTION fn_editar_mensaje(
    p_usuario   uuid,
    p_mensaje   uuid,
    p_contenido bytea,
    p_nonce     bytea,
    p_key_id    smallint
)
RETURNS TABLE (id uuid, id_conversacion uuid, id_remitente uuid, client_id uuid,
               contenido bytea, nonce bytea, key_id smallint, media jsonb,
               created_at timestamptz, editado_at timestamptz, deleted_at timestamptz,
               estado text)
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_yo bigint := fn__exigir_activo(p_usuario);
    v_m  mensaje%ROWTYPE;
    v_constraint text;
BEGIN
    SELECT m.* INTO v_m FROM mensaje m
    JOIN participante p ON p.id_conversacion = m.id_conversacion AND p.id_usuario = v_yo
    WHERE m.public_id = p_mensaje AND m.deleted_at IS NULL
    FOR UPDATE OF m;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'mensaje no encontrado' USING ERRCODE = 'CR404';
    END IF;
    IF v_m.id_remitente <> v_yo THEN
        RAISE EXCEPTION 'solo el autor puede editar el mensaje' USING ERRCODE = 'CR403', HINT = 'no-autor';
    END IF;
    IF v_m.created_at < now() - interval '15 minutes' THEN
        RAISE EXCEPTION 'el plazo de edición (15 min) expiró' USING ERRCODE = 'CR422', HINT = 'edicion-expirada';
    END IF;
    IF EXISTS (SELECT 1 FROM participante o
               WHERE o.id_conversacion = v_m.id_conversacion AND o.id_usuario <> v_yo
                 AND fn__hay_bloqueo(v_yo, o.id_usuario)) THEN
        RAISE EXCEPTION 'no se puede editar en esta conversación' USING ERRCODE = 'CR403', HINT = 'bloqueado';
    END IF;
    IF p_contenido IS NULL THEN
        RAISE EXCEPTION 'la edición requiere texto' USING ERRCODE = 'CR422', HINT = 'text';
    END IF;

    UPDATE mensaje SET contenido = p_contenido, nonce = p_nonce, key_id = p_key_id, editado_at = now()
    WHERE mensaje.id = v_m.id;

    RETURN QUERY SELECT * FROM fn__mensajes(v_yo, ARRAY[v_m.id]);
EXCEPTION
    WHEN check_violation OR not_null_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        RAISE EXCEPTION 'contenido cifrado inválido' USING ERRCODE = 'CR422', DETAIL = v_constraint, HINT = 'text';
END
$$;

-- DELETE /messages/{id}. Lápida para todos: deleted_at, contenido/nonce/key_id
-- y adjunto a NULL; la media pasa a 'borrado' (el job la quita de MinIO).
-- Idempotente: si ya estaba borrado devuelve borrado = false.
-- no participante / inexistente => CR404; participante no autor => CR403.
CREATE FUNCTION fn_borrar_mensaje(p_usuario uuid, p_mensaje uuid)
RETURNS TABLE (id_conversacion uuid, deleted_at timestamptz, borrado boolean)
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_yo bigint := fn__exigir_activo(p_usuario);
    v_m  mensaje%ROWTYPE;
    v_conv uuid;
    v_at timestamptz := now();
BEGIN
    SELECT m.* INTO v_m FROM mensaje m
    JOIN participante p ON p.id_conversacion = m.id_conversacion AND p.id_usuario = v_yo
    WHERE m.public_id = p_mensaje
    FOR UPDATE OF m;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'mensaje no encontrado' USING ERRCODE = 'CR404';
    END IF;
    IF v_m.id_remitente <> v_yo THEN
        RAISE EXCEPTION 'solo el autor puede borrar el mensaje' USING ERRCODE = 'CR403', HINT = 'no-autor';
    END IF;
    SELECT cv.public_id INTO v_conv FROM conversacion cv WHERE cv.id = v_m.id_conversacion;
    IF v_m.deleted_at IS NOT NULL THEN
        RETURN QUERY SELECT v_conv, v_m.deleted_at, false;
        RETURN;
    END IF;

    UPDATE mensaje SET deleted_at = v_at, contenido = NULL, nonce = NULL, key_id = NULL, id_media = NULL
    WHERE mensaje.id = v_m.id;
    IF v_m.id_media IS NOT NULL THEN
        UPDATE media SET estado = 'borrado', borrado_at = v_at WHERE media.id = v_m.id_media;
    END IF;
    RETURN QUERY SELECT v_conv, v_at, true;
END
$$;

-- =============================================================================
-- Recibos
-- =============================================================================

-- POST /conversations/{id}/receipts y evento WS `seen`. Marcador monótono:
-- marca 'delivered' o 'seen' en MIS recibos de la conversación para todos los
-- mensajes con (created_at, id) <= el mensaje p_hasta (nunca retrocede; 'seen'
-- implica 'delivered'). p_hasta debe ser un mensaje de esa conversación (CR404).
-- Devuelve cuántos recibos cambió y el unread_count resultante (tope 100).
CREATE FUNCTION fn_marcar_recibos(p_usuario uuid, p_conversacion uuid, p_estado text, p_hasta uuid)
RETURNS TABLE (actualizados int, no_leidos int, marcado_at timestamptz)
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_yo   bigint := fn__exigir_activo(p_usuario);
    v_conv bigint := fn__conversacion_de(v_yo, p_conversacion);
    v_h_at timestamptz;
    v_h_id bigint;
    v_n    int;
    v_at   timestamptz := now();
BEGIN
    IF p_estado IS NULL OR p_estado NOT IN ('delivered', 'seen') THEN
        RAISE EXCEPTION 'estado inválido (delivered | seen)' USING ERRCODE = 'CR422', HINT = 'status';
    END IF;
    SELECT m.created_at, m.id INTO v_h_at, v_h_id FROM mensaje m
    WHERE m.public_id = p_hasta AND m.id_conversacion = v_conv;
    IF v_h_id IS NULL THEN
        RAISE EXCEPTION 'mensaje no encontrado' USING ERRCODE = 'CR404';
    END IF;

    IF p_estado = 'delivered' THEN
        UPDATE recibo_mensaje r SET entregado_at = v_at
        FROM mensaje m
        WHERE r.id_usuario = v_yo AND r.id_conversacion = v_conv AND r.entregado_at IS NULL
          AND m.id = r.id_mensaje AND (m.created_at, m.id) <= (v_h_at, v_h_id);
    ELSE
        UPDATE recibo_mensaje r SET visto_at = v_at, entregado_at = coalesce(r.entregado_at, v_at)
        FROM mensaje m
        WHERE r.id_usuario = v_yo AND r.id_conversacion = v_conv AND r.visto_at IS NULL
          AND m.id = r.id_mensaje AND (m.created_at, m.id) <= (v_h_at, v_h_id);
    END IF;
    GET DIAGNOSTICS v_n = ROW_COUNT;

    RETURN QUERY SELECT v_n, fn__no_leidos(v_yo, v_conv), v_at;
END
$$;

-- =============================================================================
-- Media (MinIO)
-- =============================================================================

-- POST /uploads. Registra la media como 'pendiente' y genera la clave del objeto
-- (<proposito>/<AAAA>/<MM>/<public_id>); la API firma el PUT con esa clave.
CREATE FUNCTION fn_registrar_media(
    p_usuario   uuid,
    p_proposito text,
    p_mime      text,
    p_tamano    bigint,
    p_bucket    text,
    p_ancho     int DEFAULT NULL,
    p_alto      int DEFAULT NULL
)
RETURNS TABLE (id uuid, bucket text, clave_objeto text)
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_yo  bigint := fn__exigir_activo(p_usuario);
    v_pub uuid := gen_random_uuid();
    v_constraint text;
BEGIN
    INSERT INTO media (public_id, id_dueno, proposito, bucket, clave_objeto, mime, tamano_bytes, ancho, alto)
    VALUES (v_pub, v_yo, p_proposito, p_bucket,
            format('%s/%s/%s', p_proposito, to_char(now() AT TIME ZONE 'UTC', 'YYYY/MM'), v_pub),
            p_mime, p_tamano, p_ancho, p_alto)
    RETURNING media.public_id, media.bucket, media.clave_objeto INTO id, bucket, clave_objeto;
    RETURN NEXT;
EXCEPTION
    WHEN check_violation OR not_null_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        RAISE EXCEPTION 'media inválida (propósito, tipo o tamaño)' USING ERRCODE = 'CR422', DETAIL = v_constraint;
END
$$;

-- Media PROPIA por public_id (para el HEAD de verificación antes de referenciarla).
-- Ajena o inexistente => CR404.
CREATE FUNCTION fn_obtener_media(p_usuario uuid, p_media uuid)
RETURNS TABLE (id uuid, proposito text, bucket text, clave_objeto text, mime text,
               tamano_bytes bigint, estado text, created_at timestamptz)
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_yo bigint := fn__exigir_activo(p_usuario);
BEGIN
    RETURN QUERY
    SELECT m.public_id, m.proposito, m.bucket, m.clave_objeto, m.mime, m.tamano_bytes, m.estado, m.created_at
    FROM media m WHERE m.public_id = p_media AND m.id_dueno = v_yo;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'media no encontrada' USING ERRCODE = 'CR404';
    END IF;
END
$$;

-- Job de limpieza (API, cada hora): media 'pendiente' más vieja que
-- p_antiguedad y toda la media 'borrado'. Tras borrar el objeto en MinIO se
-- llama a fn_purgar_media con los ids.
CREATE FUNCTION fn_listar_media_huerfana(
    p_antiguedad interval DEFAULT interval '24 hours',
    p_limite     int      DEFAULT 100
)
RETURNS TABLE (id uuid, bucket text, clave_objeto text, estado text, created_at timestamptz)
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
BEGIN
    IF p_limite IS NULL OR p_limite < 1 OR p_limite > 1000 THEN
        RAISE EXCEPTION 'p_limite debe estar entre 1 y 1000' USING ERRCODE = 'CR422';
    END IF;
    RETURN QUERY
    SELECT m.public_id, m.bucket, m.clave_objeto, m.estado, m.created_at
    FROM media m
    WHERE m.estado <> 'confirmado'
      AND (m.estado = 'borrado' OR m.created_at < now() - p_antiguedad)
    ORDER BY m.created_at
    LIMIT p_limite;
END
$$;

-- Borra las filas de media huérfana ya eliminadas de MinIO. Revalida la
-- condición (una media pendiente pudo confirmarse entre medio). Devuelve cuántas borró.
CREATE FUNCTION fn_purgar_media(p_ids uuid[], p_antiguedad interval DEFAULT interval '24 hours')
RETURNS int
LANGUAGE sql
SET search_path = public, pg_temp
AS $$
    WITH d AS (
        DELETE FROM media m
        WHERE m.public_id = ANY (p_ids)
          AND m.estado <> 'confirmado'
          AND (m.estado = 'borrado' OR m.created_at < now() - p_antiguedad)
        RETURNING 1
    )
    SELECT count(*)::int FROM d;
$$;

-- =============================================================================
-- Presencia (la presencia vive en Redis; la BD aporta relación y last_seen)
-- =============================================================================

-- presence.query: de p_ids (máx. 100) devuelve solo los usuarios activos con
-- relación y sin bloqueo en ningún sentido, con su last_seen_at.
CREATE FUNCTION fn_filtrar_relacionados(p_usuario uuid, p_ids uuid[])
RETURNS TABLE (id_usuario uuid, last_seen_at timestamptz)
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
    v_yo bigint := fn__exigir_activo(p_usuario);
BEGIN
    IF p_ids IS NULL OR cardinality(p_ids) > 100 THEN
        RAISE EXCEPTION 'entre 0 y 100 ids' USING ERRCODE = 'CR422', HINT = 'user_ids';
    END IF;
    RETURN QUERY
    SELECT u.public_id, u.last_seen_at
    FROM usuario u
    WHERE u.public_id = ANY (p_ids) AND u.deleted_at IS NULL AND u.id <> v_yo
      AND NOT fn__hay_bloqueo(v_yo, u.id)
      AND fn__hay_relacion(v_yo, u.id);
END
$$;

-- Todos los usuarios con relación y sin bloqueo (destinatarios de `presence`
-- cuando el usuario se conecta o desconecta).
CREATE FUNCTION fn_listar_relacionados(p_usuario uuid)
RETURNS TABLE (id_usuario uuid)
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
    v_yo bigint := fn__exigir_activo(p_usuario);
BEGIN
    RETURN QUERY
    WITH r AS (
        SELECT c.contact_user_id AS id FROM contacto c WHERE c.id_usuario = v_yo AND c.deleted_at IS NULL
        UNION
        SELECT c.id_usuario FROM contacto c WHERE c.contact_user_id = v_yo AND c.deleted_at IS NULL
        UNION
        SELECT o.id_usuario FROM participante p
        JOIN participante o ON o.id_conversacion = p.id_conversacion AND o.id_usuario <> v_yo
        WHERE p.id_usuario = v_yo
    )
    SELECT u.public_id FROM r JOIN usuario u ON u.id = r.id AND u.deleted_at IS NULL
    WHERE NOT fn__hay_bloqueo(v_yo, u.id);
END
$$;

-- Al cerrar la última conexión WS del usuario. Usuario inactivo: no hace nada.
CREATE FUNCTION fn_registrar_last_seen(p_usuario uuid) RETURNS void
LANGUAGE sql
SET search_path = public, pg_temp
AS $$
    UPDATE usuario SET last_seen_at = now() WHERE public_id = p_usuario AND deleted_at IS NULL;
$$;

-- =============================================================================
-- Mantenimiento (migrator, cron / pg_cron en la Fase 2)
-- =============================================================================

-- Borra sesiones revocadas o expiradas hace más de p_antiguedad (y en cascada
-- su cadena de refresh). Devuelve cuántas borró.
CREATE FUNCTION fn_purgar_sesiones(p_antiguedad interval DEFAULT interval '30 days') RETURNS int
LANGUAGE sql
SET search_path = public, pg_temp
AS $$
    WITH d AS (
        DELETE FROM sesion s
        WHERE s.revocada_at < now() - p_antiguedad OR s.expira_at < now() - p_antiguedad
        RETURNING 1
    )
    SELECT count(*)::int FROM d;
$$;

-- No se trata de un mecanismo de auditoría del usuario: last_seen_at no debe
-- disparar updated_at como si fuera una edición del perfil.
CREATE OR REPLACE FUNCTION fn_tg_updated_at() RETURNS trigger
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

-- =============================================================================
-- Privilegios
-- =============================================================================
DO $$
DECLARE f regprocedure;
BEGIN
    FOR f IN SELECT p.oid::regprocedure FROM pg_proc p
             WHERE p.pronamespace = 'public'::regnamespace
               AND p.proowner = 'migrator'::regrole
    LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    END LOOP;
END
$$;

-- Auxiliares (las públicas son INVOKER: el rol llamante necesita EXECUTE).
GRANT EXECUTE ON FUNCTION
    fn_normalizar(text), fn__escapar_like(text),
    fn__exigir_activo(uuid), fn__conversacion_de(bigint, uuid),
    fn__hay_relacion(bigint, bigint), fn__media_json(bigint), fn__avatar_para(bigint, bigint),
    fn__estado_mensaje(bigint), fn__no_leidos(bigint, bigint),
    fn__contactos(bigint, bigint[]), fn__conversaciones(bigint, bigint[]), fn__mensajes(bigint, bigint[])
TO app_rw, app_ro;
GRANT EXECUTE ON FUNCTION fn__revocar_sesiones(bigint, uuid, text) TO app_rw;

-- Lectura: réplicas (app_ro, haproxy:5001) y líder.
GRANT EXECUTE ON FUNCTION
    fn_leer_perfil(uuid),
    fn_perfil_publico(uuid, uuid),
    fn_obtener_contacto(uuid, uuid),
    fn_listar_contactos(uuid, text, int, text, uuid),
    fn_listar_bloqueos(uuid, int, timestamptz, uuid),
    fn_obtener_conversacion(uuid, uuid),
    fn_listar_conversaciones(uuid, int, timestamptz, uuid),
    fn_participantes_conversacion(uuid, uuid),
    fn_listar_mensajes(uuid, uuid, int, uuid, uuid),
    fn_obtener_media(uuid, uuid),
    fn_filtrar_relacionados(uuid, uuid[]),
    fn_listar_relacionados(uuid)
TO app_rw, app_ro;

-- Escritura, autenticación, sesiones y job de media: solo app_rw (haproxy:5000).
GRANT EXECUTE ON FUNCTION
    fn_registrar_usuario(text, text, text, text),
    fn_credenciales_login(text),
    fn_actualizar_usuario(uuid, text, text, boolean, uuid, boolean),
    fn_rehash_pass(uuid, text),
    fn_cambiar_pass_hash(uuid, text, uuid),
    fn_cambiar_telefono(uuid, text, uuid),
    fn_borrar_usuario(uuid),
    fn_reactivar_usuario(uuid, interval),
    fn_crear_sesion(uuid, uuid, bytea, text, text, inet, interval, interval),
    fn_rotar_sesion(bytea, uuid, bytea, interval),
    fn_tocar_sesion(uuid, uuid),
    fn_listar_sesiones(uuid, uuid),
    fn_revocar_sesion(uuid, uuid, text),
    fn_revocar_sesiones(uuid, uuid),
    fn_crear_contacto(uuid, text, text),
    fn_actualizar_contacto(uuid, uuid, text),
    fn_borrar_contacto(uuid, uuid),
    fn_bloquear_usuario(uuid, uuid),
    fn_desbloquear_usuario(uuid, uuid),
    fn_crear_conversacion(uuid, uuid),
    fn_enviar_mensaje(uuid, uuid, bytea, bytea, smallint, uuid, uuid),
    fn_editar_mensaje(uuid, uuid, bytea, bytea, smallint),
    fn_borrar_mensaje(uuid, uuid),
    fn_marcar_recibos(uuid, uuid, text, uuid),
    fn_registrar_media(uuid, text, text, bigint, text, int, int),
    fn_listar_media_huerfana(interval, int),
    fn_purgar_media(uuid[], interval),
    fn_registrar_last_seen(uuid)
TO app_rw;

-- migrate:down
-- Vuelve a las funciones de la 003 (ids bigint). Lo que sigue a fn_tg_updated_at
-- es copia literal de 003_funciones.sql (con CREATE OR REPLACE porque
-- fn__validar_limite y fn__hay_bloqueo no se tocaron en la 005).
SET LOCAL ROLE migrator;
-- Las funciones LANGUAGE sql de la 003 se validan contra el esquema al crearse,
-- y en este punto la tabla sesion todavía es la de la 004 (su down va después).
SET LOCAL check_function_bodies = off;

DO $$
DECLARE f regprocedure;
BEGIN
    FOR f IN SELECT p.oid::regprocedure FROM pg_proc p
             WHERE p.pronamespace = 'public'::regnamespace
               AND p.proowner = 'migrator'::regrole
               AND p.proname NOT IN ('fn_tg_updated_at', 'fn_tg_auditar_usuario', 'fn_tg_auditar_mensaje',
                                     'fn_crear_particiones_auditoria', 'fn__validar_limite', 'fn__hay_bloqueo')
    LOOP
        EXECUTE format('DROP FUNCTION %s', f);
    END LOOP;
END
$$;

-- fn_tg_updated_at tal como en la 002.
CREATE OR REPLACE FUNCTION fn_tg_updated_at() RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END
$$;

-- -----------------------------------------------------------------------------
-- Copia de 003_funciones.sql (migrate:up)
-- -----------------------------------------------------------------------------


-- -----------------------------------------------------------------------------
-- Auxiliares internas
-- -----------------------------------------------------------------------------

-- Exige que el usuario autenticado exista y esté activo.
CREATE OR REPLACE FUNCTION fn__exigir_activo(p_id_usuario bigint) RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
BEGIN
    IF p_id_usuario IS NULL OR NOT EXISTS (
        SELECT 1 FROM usuario WHERE id = p_id_usuario AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'usuario autenticado inválido o inactivo'
            USING ERRCODE = 'CR401';
    END IF;
END
$$;

-- Valida límite de página (1..100).
CREATE OR REPLACE FUNCTION fn__validar_limite(p_limite int) RETURNS void
LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
BEGIN
    IF p_limite IS NULL OR p_limite < 1 OR p_limite > 100 THEN
        RAISE EXCEPTION 'p_limite debe estar entre 1 y 100' USING ERRCODE = 'CR422';
    END IF;
END
$$;

-- Exige que el usuario participe en la conversación (CR404 si no).
CREATE OR REPLACE FUNCTION fn__exigir_participante(p_id_usuario bigint, p_id_conversacion bigint) RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM participante
        WHERE id_conversacion = p_id_conversacion AND id_usuario = p_id_usuario
    ) THEN
        RAISE EXCEPTION 'conversación no encontrada' USING ERRCODE = 'CR404';
    END IF;
END
$$;

-- ¿Hay un bloqueo en cualquier dirección entre a y b?
CREATE OR REPLACE FUNCTION fn__hay_bloqueo(p_a bigint, p_b bigint) RETURNS boolean
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1 FROM bloqueo
        WHERE (id_usuario = p_a AND id_bloqueado = p_b)
           OR (id_usuario = p_b AND id_bloqueado = p_a)
    );
$$;

-- -----------------------------------------------------------------------------
-- Usuarios y autenticación
-- -----------------------------------------------------------------------------

-- POST /auth/register. Devuelve el id del usuario creado.
CREATE OR REPLACE FUNCTION fn_registrar_usuario(
    p_nombre_usuario text,
    p_telefono       text,
    p_email          text,
    p_pass_hash      text
) RETURNS bigint
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_id bigint;
    v_constraint text;
BEGIN
    INSERT INTO usuario (nombre_usuario, telefono, email, pass_hash)
    VALUES (btrim(p_nombre_usuario), p_telefono, p_email, p_pass_hash)
    RETURNING id INTO v_id;
    RETURN v_id;
EXCEPTION
    WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        RAISE EXCEPTION 'teléfono o email ya registrado'
            USING ERRCODE = 'CR409', DETAIL = v_constraint;
    WHEN check_violation OR not_null_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        RAISE EXCEPTION 'datos de registro inválidos'
            USING ERRCODE = 'CR422', DETAIL = coalesce(v_constraint, 'not_null');
END
$$;

-- POST /auth/login y POST /auth/reactivate (USO EXCLUSIVO DEL FLUJO DE LOGIN).
-- Busca por teléfono o email y devuelve el hash para que PHP lo verifique con
-- password_verify(). NO compara contraseñas. 0 filas = credenciales inválidas.
-- La API debe responder igual (401 genérico) para "no existe" y "hash no coincide".
CREATE OR REPLACE FUNCTION fn_credenciales_login(p_identificador text)
RETURNS TABLE (id_usuario bigint, pass_hash text, eliminado boolean)
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
BEGIN
    -- Dos ramas separadas para que cada una use su índice UNIQUE
    -- (un CASE dentro del WHERE provocaba Seq Scan).
    IF position('@' IN p_identificador) > 0 THEN
        RETURN QUERY
        SELECT u.id, u.pass_hash, u.deleted_at IS NOT NULL
        FROM usuario u WHERE u.email = p_identificador::citext;
    ELSE
        RETURN QUERY
        SELECT u.id, u.pass_hash, u.deleted_at IS NOT NULL
        FROM usuario u WHERE u.telefono = p_identificador;
    END IF;
END
$$;

-- GET /me
CREATE OR REPLACE FUNCTION fn_leer_perfil(p_id_usuario bigint)
RETURNS TABLE (id_usuario bigint, nombre_usuario text, telefono text, email text,
               foto_perfil text, descripcion text, created_at timestamptz)
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM fn__exigir_activo(p_id_usuario);
    RETURN QUERY
    SELECT u.id, u.nombre_usuario, u.telefono, u.email::text,
           u.foto_perfil, u.descripcion, u.created_at
    FROM usuario u
    WHERE u.id = p_id_usuario;
END
$$;

-- PATCH /me. NULL = no cambiar. p_foto_perfil = '' borra la foto (vuelve al default).
CREATE OR REPLACE FUNCTION fn_actualizar_usuario(
    p_id_usuario     bigint,
    p_nombre_usuario text DEFAULT NULL,
    p_telefono       text DEFAULT NULL,
    p_email          text DEFAULT NULL,
    p_foto_perfil    text DEFAULT NULL,
    p_descripcion    text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_constraint text;
BEGIN
    PERFORM fn__exigir_activo(p_id_usuario);
    UPDATE usuario SET
        nombre_usuario = coalesce(btrim(p_nombre_usuario), nombre_usuario),
        telefono       = coalesce(p_telefono, telefono),
        email          = coalesce(p_email::citext, email),
        foto_perfil    = CASE WHEN p_foto_perfil IS NULL THEN foto_perfil
                              ELSE nullif(p_foto_perfil, '') END,
        descripcion    = coalesce(p_descripcion, descripcion)
    WHERE id = p_id_usuario;
EXCEPTION
    WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        RAISE EXCEPTION 'teléfono o email ya registrado'
            USING ERRCODE = 'CR409', DETAIL = v_constraint;
    WHEN check_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        RAISE EXCEPTION 'datos de perfil inválidos'
            USING ERRCODE = 'CR422', DETAIL = v_constraint;
END
$$;

-- PUT /me/password. PHP verifica la contraseña actual ANTES de llamar.
-- Revoca todas las sesiones (obliga a re-login en todos los dispositivos).
CREATE OR REPLACE FUNCTION fn_cambiar_pass_hash(p_id_usuario bigint, p_pass_hash text) RETURNS void
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM fn__exigir_activo(p_id_usuario);
    UPDATE usuario SET pass_hash = p_pass_hash WHERE id = p_id_usuario;
    UPDATE sesion SET revocada_at = now()
    WHERE id_usuario = p_id_usuario AND revocada_at IS NULL;
EXCEPTION
    WHEN check_violation THEN
        RAISE EXCEPTION 'pass_hash inválido (se espera argon2id)' USING ERRCODE = 'CR422';
END
$$;

-- DELETE /me (baja lógica). PHP verifica la contraseña ANTES de llamar.
CREATE OR REPLACE FUNCTION fn_borrar_usuario(p_id_usuario bigint) RETURNS void
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM fn__exigir_activo(p_id_usuario);
    UPDATE usuario SET deleted_at = now() WHERE id = p_id_usuario;
    UPDATE sesion SET revocada_at = now()
    WHERE id_usuario = p_id_usuario AND revocada_at IS NULL;
END
$$;

-- POST /auth/reactivate. Se llama solo después de fn_credenciales_login +
-- password_verify() correcto sobre una cuenta con eliminado = true.
CREATE OR REPLACE FUNCTION fn_reactivar_usuario(p_id_usuario bigint) RETURNS void
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    UPDATE usuario SET deleted_at = NULL
    WHERE id = p_id_usuario AND deleted_at IS NOT NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'cuenta no encontrada o ya activa' USING ERRCODE = 'CR404';
    END IF;
END
$$;

-- -----------------------------------------------------------------------------
-- Sesiones (refresh tokens por dispositivo)
-- -----------------------------------------------------------------------------

-- POST /auth/login (tras verificar el hash): registra el refresh token emitido.
CREATE OR REPLACE FUNCTION fn_crear_sesion(
    p_id_usuario  bigint,
    p_jti         uuid,
    p_expira_at   timestamptz,
    p_dispositivo text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM fn__exigir_activo(p_id_usuario);
    INSERT INTO sesion (jti, id_usuario, dispositivo, expira_at)
    VALUES (p_jti, p_id_usuario, p_dispositivo, p_expira_at);
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'jti duplicado' USING ERRCODE = 'CR409';
    WHEN check_violation THEN
        RAISE EXCEPTION 'datos de sesión inválidos' USING ERRCODE = 'CR422';
END
$$;

-- POST /auth/refresh: rotación. Revoca p_jti_actual y crea p_jti_nuevo.
-- Si p_jti_actual ya había sido rotado (reutilización de un refresh robado),
-- falla con CR401 y HINT = 'reutilizacion'. Como el error revierte la
-- transacción, la API debe entonces llamar a fn_revocar_sesiones(p_id_usuario)
-- en una transacción aparte (ver contrato).
CREATE OR REPLACE FUNCTION fn_rotar_sesion(
    p_id_usuario  bigint,
    p_jti_actual  uuid,
    p_jti_nuevo   uuid,
    p_expira_at   timestamptz
) RETURNS void
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_s sesion%ROWTYPE;
BEGIN
    PERFORM fn__exigir_activo(p_id_usuario);

    SELECT * INTO v_s FROM sesion
    WHERE jti = p_jti_actual AND id_usuario = p_id_usuario
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'refresh token desconocido' USING ERRCODE = 'CR401';
    END IF;
    IF v_s.revocada_at IS NOT NULL THEN
        RAISE EXCEPTION 'refresh token revocado'
            USING ERRCODE = 'CR401',
                  HINT = CASE WHEN v_s.reemplazada_por IS NOT NULL
                              THEN 'reutilizacion' ELSE 'revocado' END;
    END IF;
    IF v_s.expira_at <= now() THEN
        RAISE EXCEPTION 'refresh token expirado' USING ERRCODE = 'CR401';
    END IF;

    INSERT INTO sesion (jti, id_usuario, dispositivo, expira_at)
    VALUES (p_jti_nuevo, p_id_usuario, v_s.dispositivo, p_expira_at);
    UPDATE sesion SET revocada_at = now(), reemplazada_por = p_jti_nuevo
    WHERE jti = p_jti_actual;
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'jti duplicado' USING ERRCODE = 'CR409';
END
$$;

-- POST /auth/logout: revoca una sesión propia. Idempotente.
CREATE OR REPLACE FUNCTION fn_revocar_sesion(p_id_usuario bigint, p_jti uuid) RETURNS void
LANGUAGE sql
SET search_path = public, pg_temp
AS $$
    UPDATE sesion SET revocada_at = now()
    WHERE jti = p_jti AND id_usuario = p_id_usuario AND revocada_at IS NULL;
$$;

-- POST /auth/logout-all y respuesta a reutilización de refresh. Devuelve cuántas revocó.
CREATE OR REPLACE FUNCTION fn_revocar_sesiones(p_id_usuario bigint) RETURNS int
LANGUAGE sql
SET search_path = public, pg_temp
AS $$
    WITH r AS (
        UPDATE sesion SET revocada_at = now()
        WHERE id_usuario = p_id_usuario AND revocada_at IS NULL
        RETURNING 1
    )
    SELECT count(*)::int FROM r;
$$;

-- -----------------------------------------------------------------------------
-- Contactos y bloqueos
-- -----------------------------------------------------------------------------

-- POST /contacts. Agrega por teléfono. Reactiva si estaba borrado.
CREATE OR REPLACE FUNCTION fn_crear_contacto(p_id_usuario bigint, p_telefono text, p_alias text)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_destino bigint;
    v_id bigint;
    v_borrado timestamptz;
BEGIN
    PERFORM fn__exigir_activo(p_id_usuario);

    SELECT id INTO v_destino FROM usuario
    WHERE telefono = p_telefono AND deleted_at IS NULL;
    IF v_destino IS NULL THEN
        RAISE EXCEPTION 'no existe un usuario activo con ese teléfono' USING ERRCODE = 'CR404';
    END IF;
    IF v_destino = p_id_usuario THEN
        RAISE EXCEPTION 'no puedes agregarte como contacto' USING ERRCODE = 'CR422';
    END IF;

    SELECT id, deleted_at INTO v_id, v_borrado FROM contacto
    WHERE id_usuario = p_id_usuario AND contact_user_id = v_destino
    FOR UPDATE;

    IF v_id IS NOT NULL AND v_borrado IS NULL THEN
        RAISE EXCEPTION 'el contacto ya existe' USING ERRCODE = 'CR409', DETAIL = v_id::text;
    ELSIF v_id IS NOT NULL THEN
        UPDATE contacto SET deleted_at = NULL, alias = btrim(p_alias) WHERE id = v_id;
        RETURN v_id;
    END IF;

    INSERT INTO contacto (id_usuario, contact_user_id, alias)
    VALUES (p_id_usuario, v_destino, btrim(p_alias))
    RETURNING id INTO v_id;
    RETURN v_id;
EXCEPTION
    WHEN unique_violation THEN   -- carrera entre dos inserciones simultáneas
        RAISE EXCEPTION 'el contacto ya existe' USING ERRCODE = 'CR409';
    WHEN check_violation OR not_null_violation THEN
        RAISE EXCEPTION 'alias inválido (1..60 caracteres)' USING ERRCODE = 'CR422';
END
$$;

-- GET /contacts?q=&limit=&cursor=. Búsqueda por alias (contiene) o teléfono (prefijo).
-- Paginación keyset por (alias, id): pasar el alias y el id de la última fila recibida.
CREATE OR REPLACE FUNCTION fn_listar_contactos(
    p_id_usuario   bigint,
    p_busqueda     text   DEFAULT NULL,
    p_limite       int    DEFAULT 30,
    p_cursor_alias text   DEFAULT NULL,
    p_cursor_id    bigint DEFAULT NULL
)
RETURNS TABLE (id_contacto bigint, contact_user_id bigint, alias text,
               telefono text, nombre_usuario text, foto_perfil text, descripcion text)
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
    v_q text := nullif(btrim(p_busqueda), '');
    v_patron text;
BEGIN
    PERFORM fn__exigir_activo(p_id_usuario);
    PERFORM fn__validar_limite(p_limite);
    IF (p_cursor_alias IS NULL) <> (p_cursor_id IS NULL) THEN
        RAISE EXCEPTION 'el cursor requiere alias e id' USING ERRCODE = 'CR422';
    END IF;
    -- Escapar comodines de LIKE en la búsqueda del usuario.
    v_patron := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_');

    RETURN QUERY
    SELECT c.id, c.contact_user_id, c.alias, u.telefono, u.nombre_usuario,
           u.foto_perfil, u.descripcion
    FROM contacto c
    JOIN usuario u ON u.id = c.contact_user_id AND u.deleted_at IS NULL
    WHERE c.id_usuario = p_id_usuario
      AND c.deleted_at IS NULL
      AND (v_q IS NULL
           OR c.alias ILIKE '%' || v_patron || '%'
           OR u.telefono LIKE v_patron || '%')
      AND (p_cursor_id IS NULL OR (c.alias, c.id) > (p_cursor_alias, p_cursor_id))
    ORDER BY c.alias, c.id
    LIMIT p_limite;
END
$$;

-- PATCH /contacts/{id}. Solo se cambia el alias (otro teléfono = otro contacto).
CREATE OR REPLACE FUNCTION fn_actualizar_contacto(p_id_usuario bigint, p_id_contacto bigint, p_alias text)
RETURNS void
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM fn__exigir_activo(p_id_usuario);
    UPDATE contacto SET alias = btrim(p_alias)
    WHERE id = p_id_contacto AND id_usuario = p_id_usuario AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'contacto no encontrado' USING ERRCODE = 'CR404';
    END IF;
EXCEPTION
    WHEN check_violation OR not_null_violation THEN
        RAISE EXCEPTION 'alias inválido (1..60 caracteres)' USING ERRCODE = 'CR422';
END
$$;

-- DELETE /contacts/{id} (baja lógica).
CREATE OR REPLACE FUNCTION fn_borrar_contacto(p_id_usuario bigint, p_id_contacto bigint) RETURNS void
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM fn__exigir_activo(p_id_usuario);
    UPDATE contacto SET deleted_at = now()
    WHERE id = p_id_contacto AND id_usuario = p_id_usuario AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'contacto no encontrado' USING ERRCODE = 'CR404';
    END IF;
END
$$;

-- POST /blocks/{userId}. Idempotente.
CREATE OR REPLACE FUNCTION fn_bloquear_usuario(p_id_usuario bigint, p_id_bloqueado bigint) RETURNS void
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM fn__exigir_activo(p_id_usuario);
    IF p_id_bloqueado = p_id_usuario THEN
        RAISE EXCEPTION 'no puedes bloquearte' USING ERRCODE = 'CR422';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM usuario WHERE id = p_id_bloqueado) THEN
        RAISE EXCEPTION 'usuario no encontrado' USING ERRCODE = 'CR404';
    END IF;
    INSERT INTO bloqueo (id_usuario, id_bloqueado) VALUES (p_id_usuario, p_id_bloqueado)
    ON CONFLICT DO NOTHING;
END
$$;

-- DELETE /blocks/{userId}. Idempotente.
CREATE OR REPLACE FUNCTION fn_desbloquear_usuario(p_id_usuario bigint, p_id_bloqueado bigint) RETURNS void
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM fn__exigir_activo(p_id_usuario);
    DELETE FROM bloqueo WHERE id_usuario = p_id_usuario AND id_bloqueado = p_id_bloqueado;
END
$$;

-- -----------------------------------------------------------------------------
-- Conversaciones
-- -----------------------------------------------------------------------------

-- POST /conversations {id_contacto}. Get-or-create idempotente: si ya existe la
-- conversación directa entre ambos usuarios devuelve la misma (creada = false).
CREATE OR REPLACE FUNCTION fn_crear_conversacion(p_id_usuario bigint, p_id_contacto bigint)
RETURNS TABLE (id_conversacion bigint, creada boolean)
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_otro bigint;
    v_id bigint;
BEGIN
    PERFORM fn__exigir_activo(p_id_usuario);

    SELECT c.contact_user_id INTO v_otro
    FROM contacto c
    JOIN usuario u ON u.id = c.contact_user_id AND u.deleted_at IS NULL
    WHERE c.id = p_id_contacto AND c.id_usuario = p_id_usuario AND c.deleted_at IS NULL;
    IF v_otro IS NULL THEN
        RAISE EXCEPTION 'contacto no encontrado' USING ERRCODE = 'CR404';
    END IF;
    IF fn__hay_bloqueo(p_id_usuario, v_otro) THEN
        RAISE EXCEPTION 'no se puede conversar con este usuario' USING ERRCODE = 'CR403';
    END IF;

    INSERT INTO conversacion (id_usuario_menor, id_usuario_mayor)
    VALUES (least(p_id_usuario, v_otro), greatest(p_id_usuario, v_otro))
    ON CONFLICT ON CONSTRAINT conversacion_par_uq DO NOTHING
    RETURNING id INTO v_id;

    IF v_id IS NOT NULL THEN
        INSERT INTO participante (id_conversacion, id_usuario)
        VALUES (v_id, p_id_usuario), (v_id, v_otro);
        RETURN QUERY SELECT v_id, true;
    ELSE
        RETURN QUERY
        SELECT cv.id, false FROM conversacion cv
        WHERE cv.id_usuario_menor = least(p_id_usuario, v_otro)
          AND cv.id_usuario_mayor = greatest(p_id_usuario, v_otro);
    END IF;
END
$$;

-- GET /conversations?limit=&cursor=. Orden: actividad más reciente primero.
-- Keyset por (ultimo_mensaje_at, id) descendente.
CREATE OR REPLACE FUNCTION fn_listar_conversaciones(
    p_id_usuario bigint,
    p_limite     int         DEFAULT 30,
    p_cursor_at  timestamptz DEFAULT NULL,
    p_cursor_id  bigint      DEFAULT NULL
)
RETURNS TABLE (id_conversacion bigint, id_otro_usuario bigint, alias text,
               nombre_usuario text, telefono text, foto_perfil text,
               ultimo_mensaje_at timestamptz, no_leidos int)
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM fn__exigir_activo(p_id_usuario);
    PERFORM fn__validar_limite(p_limite);
    IF (p_cursor_at IS NULL) <> (p_cursor_id IS NULL) THEN
        RAISE EXCEPTION 'el cursor requiere fecha e id' USING ERRCODE = 'CR422';
    END IF;

    RETURN QUERY
    SELECT cv.id, o.id_usuario, ct.alias, u.nombre_usuario, u.telefono, u.foto_perfil,
           cv.ultimo_mensaje_at,
           -- No leídos con tope 100 (la UI muestra "99+"): el costo queda acotado
           -- aunque la conversación tenga miles de mensajes sin ver.
           (SELECT count(*)::int FROM (
                SELECT 1
                FROM recibo_mensaje r
                JOIN mensaje m ON m.id = r.id_mensaje
                WHERE r.id_usuario = p_id_usuario AND r.id_conversacion = cv.id
                  AND r.visto_at IS NULL AND m.deleted_at IS NULL
                LIMIT 100) nl)
    FROM participante p
    JOIN conversacion cv ON cv.id = p.id_conversacion
    JOIN participante o  ON o.id_conversacion = cv.id AND o.id_usuario <> p_id_usuario
    JOIN usuario u       ON u.id = o.id_usuario
    LEFT JOIN contacto ct ON ct.id_usuario = p_id_usuario
                         AND ct.contact_user_id = o.id_usuario
                         AND ct.deleted_at IS NULL
    WHERE p.id_usuario = p_id_usuario
      AND (p_cursor_id IS NULL OR (cv.ultimo_mensaje_at, cv.id) < (p_cursor_at, p_cursor_id))
    ORDER BY cv.ultimo_mensaje_at DESC, cv.id DESC
    LIMIT p_limite;
END
$$;

-- -----------------------------------------------------------------------------
-- Mensajes
-- -----------------------------------------------------------------------------

-- POST /conversations/{id}/messages. p_contenido llega CIFRADO desde la app.
CREATE OR REPLACE FUNCTION fn_enviar_mensaje(
    p_id_usuario      bigint,
    p_id_conversacion bigint,
    p_contenido       bytea,
    p_media_url       text DEFAULT NULL
)
RETURNS TABLE (id_mensaje bigint, created_at timestamptz)
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_id bigint;
    v_at timestamptz;
BEGIN
    PERFORM fn__exigir_activo(p_id_usuario);
    PERFORM fn__exigir_participante(p_id_usuario, p_id_conversacion);

    IF EXISTS (
        SELECT 1 FROM participante o
        WHERE o.id_conversacion = p_id_conversacion AND o.id_usuario <> p_id_usuario
          AND (fn__hay_bloqueo(p_id_usuario, o.id_usuario)
               OR EXISTS (SELECT 1 FROM usuario x WHERE x.id = o.id_usuario AND x.deleted_at IS NOT NULL))
    ) THEN
        RAISE EXCEPTION 'no se puede enviar a esta conversación' USING ERRCODE = 'CR403';
    END IF;

    INSERT INTO mensaje (id_conversacion, id_remitente, contenido, media_url)
    VALUES (p_id_conversacion, p_id_usuario, p_contenido, p_media_url)
    RETURNING mensaje.id, mensaje.created_at INTO v_id, v_at;

    INSERT INTO recibo_mensaje (id_mensaje, id_conversacion, id_usuario)
    SELECT v_id, p_id_conversacion, o.id_usuario FROM participante o
    WHERE o.id_conversacion = p_id_conversacion AND o.id_usuario <> p_id_usuario;

    UPDATE conversacion SET ultimo_mensaje_at = v_at WHERE id = p_id_conversacion;

    RETURN QUERY SELECT v_id, v_at;
EXCEPTION
    WHEN check_violation OR not_null_violation THEN
        RAISE EXCEPTION 'contenido (1..65536 bytes) o media_url inválidos' USING ERRCODE = 'CR422';
END
$$;

-- GET /conversations/{id}/messages?limit=&before=. Página hacia atrás en el
-- tiempo: devuelve los p_limite mensajes MÁS RECIENTES anteriores al cursor,
-- ordenados del más nuevo al más viejo. Primera página: cursor NULL.
-- entregado_at/visto_at: si el mensaje es mío, estado del destinatario;
-- si es recibido, mi propio recibo.
CREATE OR REPLACE FUNCTION fn_listar_mensajes(
    p_id_usuario      bigint,
    p_id_conversacion bigint,
    p_limite          int         DEFAULT 30,
    p_antes_at        timestamptz DEFAULT NULL,
    p_antes_id        bigint      DEFAULT NULL
)
RETURNS TABLE (id_mensaje bigint, id_remitente bigint, contenido bytea, media_url text,
               created_at timestamptz, editado_at timestamptz,
               entregado_at timestamptz, visto_at timestamptz)
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM fn__exigir_activo(p_id_usuario);
    PERFORM fn__validar_limite(p_limite);
    PERFORM fn__exigir_participante(p_id_usuario, p_id_conversacion);
    IF (p_antes_at IS NULL) <> (p_antes_id IS NULL) THEN
        RAISE EXCEPTION 'el cursor requiere fecha e id' USING ERRCODE = 'CR422';
    END IF;

    RETURN QUERY
    SELECT m.id, m.id_remitente, m.contenido, m.media_url, m.created_at, m.editado_at,
           r.entregado_at, r.visto_at
    FROM mensaje m
    LEFT JOIN LATERAL (
        -- 1:1 => exactamente un recibo relevante. (En grupos: el más lento.)
        SELECT CASE WHEN bool_and(x.entregado_at IS NOT NULL) THEN max(x.entregado_at) END AS entregado_at,
               CASE WHEN bool_and(x.visto_at     IS NOT NULL) THEN max(x.visto_at)     END AS visto_at
        FROM recibo_mensaje x
        WHERE x.id_mensaje = m.id
          AND CASE WHEN m.id_remitente = p_id_usuario
                   THEN x.id_usuario <> p_id_usuario
                   ELSE x.id_usuario = p_id_usuario END
    ) r ON true
    WHERE m.id_conversacion = p_id_conversacion
      AND m.deleted_at IS NULL
      AND (p_antes_id IS NULL OR (m.created_at, m.id) < (p_antes_at, p_antes_id))
    ORDER BY m.created_at DESC, m.id DESC
    LIMIT p_limite;
END
$$;

-- PATCH /messages/{id}. Solo el autor.
CREATE OR REPLACE FUNCTION fn_editar_mensaje(p_id_usuario bigint, p_id_mensaje bigint, p_contenido bytea)
RETURNS timestamptz
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_m mensaje%ROWTYPE;
    v_at timestamptz := now();
BEGIN
    PERFORM fn__exigir_activo(p_id_usuario);
    SELECT m.* INTO v_m FROM mensaje m
    JOIN participante p ON p.id_conversacion = m.id_conversacion AND p.id_usuario = p_id_usuario
    WHERE m.id = p_id_mensaje AND m.deleted_at IS NULL
    FOR UPDATE OF m;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'mensaje no encontrado' USING ERRCODE = 'CR404';
    END IF;
    IF v_m.id_remitente <> p_id_usuario THEN
        RAISE EXCEPTION 'solo el autor puede editar el mensaje' USING ERRCODE = 'CR403';
    END IF;
    UPDATE mensaje SET contenido = p_contenido, editado_at = v_at WHERE id = p_id_mensaje;
    RETURN v_at;
EXCEPTION
    WHEN check_violation OR not_null_violation THEN
        RAISE EXCEPTION 'contenido inválido (1..65536 bytes)' USING ERRCODE = 'CR422';
END
$$;

-- DELETE /messages/{id} (baja lógica, para todos). Solo el autor.
CREATE OR REPLACE FUNCTION fn_borrar_mensaje(p_id_usuario bigint, p_id_mensaje bigint) RETURNS void
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_remitente bigint;
BEGIN
    PERFORM fn__exigir_activo(p_id_usuario);
    SELECT m.id_remitente INTO v_remitente FROM mensaje m
    JOIN participante p ON p.id_conversacion = m.id_conversacion AND p.id_usuario = p_id_usuario
    WHERE m.id = p_id_mensaje AND m.deleted_at IS NULL
    FOR UPDATE OF m;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'mensaje no encontrado' USING ERRCODE = 'CR404';
    END IF;
    IF v_remitente <> p_id_usuario THEN
        RAISE EXCEPTION 'solo el autor puede borrar el mensaje' USING ERRCODE = 'CR403';
    END IF;
    UPDATE mensaje SET deleted_at = now() WHERE id = p_id_mensaje;
END
$$;

-- POST /conversations/{id}/delivered {hasta_id}. Marca como entregados todos mis
-- recibos de la conversación con id_mensaje <= p_hasta_id. Devuelve cuántos cambió.
CREATE OR REPLACE FUNCTION fn_marcar_entregado(p_id_usuario bigint, p_id_conversacion bigint, p_hasta_id bigint)
RETURNS int
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_n int;
BEGIN
    PERFORM fn__exigir_activo(p_id_usuario);
    PERFORM fn__exigir_participante(p_id_usuario, p_id_conversacion);
    UPDATE recibo_mensaje r SET entregado_at = now()
    WHERE r.id_usuario = p_id_usuario
      AND r.id_conversacion = p_id_conversacion
      AND r.id_mensaje <= p_hasta_id
      AND r.entregado_at IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END
$$;

-- POST /conversations/{id}/seen {hasta_id}. Visto implica entregado.
CREATE OR REPLACE FUNCTION fn_marcar_visto(p_id_usuario bigint, p_id_conversacion bigint, p_hasta_id bigint)
RETURNS int
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_n int;
BEGIN
    PERFORM fn__exigir_activo(p_id_usuario);
    PERFORM fn__exigir_participante(p_id_usuario, p_id_conversacion);
    UPDATE recibo_mensaje r
       SET visto_at = now(), entregado_at = coalesce(r.entregado_at, now())
    WHERE r.id_usuario = p_id_usuario
      AND r.id_conversacion = p_id_conversacion
      AND r.id_mensaje <= p_hasta_id
      AND r.visto_at IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END
$$;

-- -----------------------------------------------------------------------------
-- Privilegios
-- -----------------------------------------------------------------------------
-- Defensa en profundidad (los default privileges de 001 ya lo hacen): ninguna
-- función de migrator ejecutable por PUBLIC. No toca funciones de extensiones.
DO $$
DECLARE f regprocedure;
BEGIN
    FOR f IN SELECT p.oid::regprocedure FROM pg_proc p
             WHERE p.pronamespace = 'public'::regnamespace
               AND p.proowner = 'migrator'::regrole
    LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    END LOOP;
END
$$;

-- Auxiliares: las invocan las funciones públicas (SECURITY INVOKER => el rol
-- llamante necesita EXECUTE). No exponen datos.
GRANT EXECUTE ON FUNCTION
    fn__exigir_activo(bigint), fn__validar_limite(int),
    fn__exigir_participante(bigint, bigint), fn__hay_bloqueo(bigint, bigint)
TO app_rw, app_ro;

-- Lectura: disponibles en réplicas (app_ro, haproxy:5001) y en el líder.
GRANT EXECUTE ON FUNCTION
    fn_leer_perfil(bigint),
    fn_listar_contactos(bigint, text, int, text, bigint),
    fn_listar_conversaciones(bigint, int, timestamptz, bigint),
    fn_listar_mensajes(bigint, bigint, int, timestamptz, bigint)
TO app_rw, app_ro;

-- Escritura y autenticación: solo app_rw (haproxy:5000).
GRANT EXECUTE ON FUNCTION
    fn_registrar_usuario(text, text, text, text),
    fn_credenciales_login(text),
    fn_actualizar_usuario(bigint, text, text, text, text, text),
    fn_cambiar_pass_hash(bigint, text),
    fn_borrar_usuario(bigint),
    fn_reactivar_usuario(bigint),
    fn_crear_sesion(bigint, uuid, timestamptz, text),
    fn_rotar_sesion(bigint, uuid, uuid, timestamptz),
    fn_revocar_sesion(bigint, uuid),
    fn_revocar_sesiones(bigint),
    fn_crear_contacto(bigint, text, text),
    fn_actualizar_contacto(bigint, bigint, text),
    fn_borrar_contacto(bigint, bigint),
    fn_bloquear_usuario(bigint, bigint),
    fn_desbloquear_usuario(bigint, bigint),
    fn_crear_conversacion(bigint, bigint),
    fn_enviar_mensaje(bigint, bigint, bytea, text),
    fn_editar_mensaje(bigint, bigint, bytea),
    fn_borrar_mensaje(bigint, bigint),
    fn_marcar_entregado(bigint, bigint, bigint),
    fn_marcar_visto(bigint, bigint, bigint)
TO app_rw;
