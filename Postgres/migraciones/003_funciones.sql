-- migrate:up
-- =============================================================================
-- 003 - Funciones de la API (contrato: docs/contratos/db-funciones.md).
--
-- Reglas comunes:
--  * Todas son SECURITY INVOKER con SET search_path = public, pg_temp.
--  * Reciben como primer parámetro p_id_usuario = id del usuario AUTENTICADO
--    (sale del JWT validado por la API, nunca del cuerpo de la petición) y validan
--    la propiedad del recurso dentro de la BD.
--  * Un recurso ajeno o inexistente produce el MISMO error (CR404) para no
--    revelar existencia (anti-enumeración / IDOR).
--  * Errores con SQLSTATE propios (clase CR, código ~ HTTP):
--      CR401 sesión/usuario autenticado inválido, inactivo o refresh revocado/expirado
--      CR403 operación prohibida (bloqueo, no es el autor)
--      CR404 recurso inexistente o ajeno
--      CR409 duplicado / conflicto de unicidad
--      CR422 parámetros inválidos
--    Las violaciones de CHECK (23514) que no se validan antes también se
--    traducen a CR422. No hay ningún WHEN OTHERS.
-- =============================================================================
SET LOCAL ROLE migrator;

-- -----------------------------------------------------------------------------
-- Auxiliares internas
-- -----------------------------------------------------------------------------

-- Exige que el usuario autenticado exista y esté activo.
CREATE FUNCTION fn__exigir_activo(p_id_usuario bigint) RETURNS void
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
CREATE FUNCTION fn__validar_limite(p_limite int) RETURNS void
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
CREATE FUNCTION fn__exigir_participante(p_id_usuario bigint, p_id_conversacion bigint) RETURNS void
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
CREATE FUNCTION fn__hay_bloqueo(p_a bigint, p_b bigint) RETURNS boolean
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
CREATE FUNCTION fn_registrar_usuario(
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
CREATE FUNCTION fn_credenciales_login(p_identificador text)
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
CREATE FUNCTION fn_leer_perfil(p_id_usuario bigint)
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
CREATE FUNCTION fn_actualizar_usuario(
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
CREATE FUNCTION fn_cambiar_pass_hash(p_id_usuario bigint, p_pass_hash text) RETURNS void
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
CREATE FUNCTION fn_borrar_usuario(p_id_usuario bigint) RETURNS void
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
CREATE FUNCTION fn_reactivar_usuario(p_id_usuario bigint) RETURNS void
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
CREATE FUNCTION fn_crear_sesion(
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
CREATE FUNCTION fn_rotar_sesion(
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
CREATE FUNCTION fn_revocar_sesion(p_id_usuario bigint, p_jti uuid) RETURNS void
LANGUAGE sql
SET search_path = public, pg_temp
AS $$
    UPDATE sesion SET revocada_at = now()
    WHERE jti = p_jti AND id_usuario = p_id_usuario AND revocada_at IS NULL;
$$;

-- POST /auth/logout-all y respuesta a reutilización de refresh. Devuelve cuántas revocó.
CREATE FUNCTION fn_revocar_sesiones(p_id_usuario bigint) RETURNS int
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
CREATE FUNCTION fn_crear_contacto(p_id_usuario bigint, p_telefono text, p_alias text)
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
CREATE FUNCTION fn_listar_contactos(
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
CREATE FUNCTION fn_actualizar_contacto(p_id_usuario bigint, p_id_contacto bigint, p_alias text)
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
CREATE FUNCTION fn_borrar_contacto(p_id_usuario bigint, p_id_contacto bigint) RETURNS void
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
CREATE FUNCTION fn_bloquear_usuario(p_id_usuario bigint, p_id_bloqueado bigint) RETURNS void
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
CREATE FUNCTION fn_desbloquear_usuario(p_id_usuario bigint, p_id_bloqueado bigint) RETURNS void
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
CREATE FUNCTION fn_crear_conversacion(p_id_usuario bigint, p_id_contacto bigint)
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
CREATE FUNCTION fn_listar_conversaciones(
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
CREATE FUNCTION fn_enviar_mensaje(
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
CREATE FUNCTION fn_listar_mensajes(
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
CREATE FUNCTION fn_editar_mensaje(p_id_usuario bigint, p_id_mensaje bigint, p_contenido bytea)
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
CREATE FUNCTION fn_borrar_mensaje(p_id_usuario bigint, p_id_mensaje bigint) RETURNS void
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
CREATE FUNCTION fn_marcar_entregado(p_id_usuario bigint, p_id_conversacion bigint, p_hasta_id bigint)
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
CREATE FUNCTION fn_marcar_visto(p_id_usuario bigint, p_id_conversacion bigint, p_hasta_id bigint)
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

-- migrate:down
SET LOCAL ROLE migrator;
DROP FUNCTION IF EXISTS
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
    fn__hay_bloqueo(bigint, bigint),
    fn__exigir_participante(bigint, bigint),
    fn__validar_limite(int),
    fn__exigir_activo(bigint);
