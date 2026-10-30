-- =============================================================================
-- Pruebas de contrato de las funciones v1 (migraciones 001-005), CONECTADO COMO
-- app_rw sobre una base recién migrada + seed demo. Cada caso imprime "OK ..."
-- o aborta el script (ON_ERROR_STOP) con "FALLO ...".
--   psql -U app_rw -d cr_chat -v ON_ERROR_STOP=1 -f Postgres/pruebas/funciones_app_rw.sql
-- Deja datos de prueba y retrocede fechas con UPDATE directo (app_rw tiene DML
-- sobre las tablas): usar SOLO en bases desechables.
-- =============================================================================
\set ON_ERROR_STOP on
\set QUIET on
SET client_min_messages = notice;
\pset tuples_only on
\pset format unaligned

-- Ayudantes en pg_temp (no tocan el esquema). WHEN OTHERS aquí es solo de prueba.
CREATE FUNCTION pg_temp.espera(p_sql text, p_estado text, p_caso text, p_hint text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE e text; h text; m text;
BEGIN
    EXECUTE p_sql;
    RAISE EXCEPTION USING ERRCODE = 'XX999', MESSAGE = 'no hubo error';
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS e = RETURNED_SQLSTATE, h = PG_EXCEPTION_HINT, m = MESSAGE_TEXT;
    IF e <> p_estado OR (p_hint IS NOT NULL AND h IS DISTINCT FROM p_hint) THEN
        RAISE EXCEPTION 'FALLO %: esperado % (hint %), obtenido % (hint %): %', p_caso, p_estado, p_hint, e, h, m;
    END IF;
    RAISE NOTICE 'OK % => %', p_caso, p_estado || coalesce(' ' || p_hint, '');
END $$;
CREATE FUNCTION pg_temp.ok(p_cond boolean, p_caso text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_cond IS NOT TRUE THEN RAISE EXCEPTION 'FALLO %', p_caso; END IF;
    RAISE NOTICE 'OK %', p_caso;
END $$;

-- Datos base -----------------------------------------------------------------
SELECT public_id AS ana   FROM usuario WHERE telefono = '+50670000001' \gset
SELECT public_id AS bruno FROM usuario WHERE telefono = '+50670000002' \gset
SELECT public_id AS carla FROM usuario WHERE telefono = '+50670000003' \gset
SELECT id AS c_ana_bruno FROM fn_listar_contactos(:'ana', 'bruno') \gset
SELECT id AS c_ana_carla FROM fn_listar_contactos(:'ana', 'carla') \gset
SELECT id AS c_bruno_ana FROM fn_listar_contactos(:'bruno', 'ana') \gset
SELECT id AS conv_ab FROM fn_crear_conversacion(:'ana', :'c_ana_bruno') \gset
SELECT id AS conv_ac FROM fn_crear_conversacion(:'ana', :'c_ana_carla') \gset
\set N24 'decode(repeat(''ab'', 24), ''hex'')'

\echo '--- login / registro'
SELECT pg_temp.ok((SELECT count(*) = 1 AND bool_and(id_usuario = :'ana') FROM fn_credenciales_login('+50670000001')), 'login por teléfono devuelve public_id');
SELECT pg_temp.ok((SELECT count(*) = 1 FROM fn_credenciales_login('ANA@Demo.CRCHAT.local')), 'login por email sin distinguir mayúsculas');
SELECT pg_temp.ok((SELECT count(*) = 0 FROM fn_credenciales_login('+50679999999')), 'identificador inexistente => 0 filas');
SELECT pg_temp.espera($$SELECT fn_registrar_usuario('X', '+50670000001', 'nuevo@x.com', '$argon2id$v=19$m=65536,t=4,p=1$abc$def')$$, 'CR409', 'registro teléfono duplicado');
SELECT pg_temp.espera($$SELECT fn_registrar_usuario('X', '+50671111111', 'BRUNO@demo.crchat.local', '$argon2id$v=19$m=65536,t=4,p=1$abc$def')$$, 'CR409', 'registro email duplicado (citext)');
SELECT pg_temp.espera($$SELECT fn_registrar_usuario('X', '50671111111', 'z@x.com', '$argon2id$v=19$m=65536,t=4,p=1$abc$def')$$, 'CR422', 'registro teléfono sin + (E.164 estricto)');
SELECT pg_temp.espera($$SELECT fn_registrar_usuario('X', '+05671111111', 'z@x.com', '$argon2id$v=19$m=65536,t=4,p=1$abc$def')$$, 'CR422', 'registro teléfono con 0 inicial');
SELECT pg_temp.espera($$SELECT fn_registrar_usuario('X', '+50671111112', 'z2@x.com', 'texto-plano')$$, 'CR422', 'registro pass_hash no argon2id');
-- Diego: usuario sin relación con nadie (para IDOR y relación)
SELECT fn_registrar_usuario('Diego Ñandú', '+50670000004', 'diego@demo.crchat.local',
       '$argon2id$v=19$m=65536,t=4,p=1$abc$def') AS diego \gset
SELECT pg_temp.ok(:'diego' ~ '^[0-9a-f-]{36}$', 'registro devuelve uuid');

\echo '--- perfil propio y público'
SELECT pg_temp.ok((SELECT count(*) = 1 AND bool_and(email = 'ana@demo.crchat.local' AND avatar IS NULL) FROM fn_leer_perfil(:'ana')), 'leer_perfil propio');
SELECT pg_temp.ok((SELECT nombre_usuario = 'Ana R.' AND descripcion IS NULL FROM fn_actualizar_usuario(:'ana', p_nombre_usuario => '  Ana R. ', p_quitar_descripcion => true)), 'PATCH /me: nombre recortado y about NULL');
SELECT pg_temp.espera(format('SELECT * FROM fn_actualizar_usuario(%L, p_nombre_usuario => %L)', :'ana', '   '), 'CR422', 'PATCH /me nombre vacío');
SELECT pg_temp.espera(format('SELECT * FROM fn_actualizar_usuario(%L, p_descripcion => %L)', :'ana', repeat('x', 141)), 'CR422', 'PATCH /me about > 140');
SELECT pg_temp.ok((SELECT telefono = '+50670000002' AND es_contacto FROM fn_perfil_publico(:'ana', :'bruno')), 'perfil público de un contacto: con teléfono');
SELECT pg_temp.ok((SELECT telefono IS NULL AND NOT es_contacto FROM fn_perfil_publico(:'carla', :'ana')), 'perfil público por conversación compartida: sin teléfono');
SELECT pg_temp.ok((SELECT count(*) = 1 FROM fn_perfil_publico(:'bruno', :'ana')), 'perfil público: contacto inverso cuenta como relación');
SELECT pg_temp.espera(format('SELECT * FROM fn_perfil_publico(%L, %L)', :'diego', :'ana'), 'CR404', 'IDOR perfil público sin relación');
SELECT pg_temp.espera(format('SELECT * FROM fn_perfil_publico(%L, %L)', :'ana', gen_random_uuid()), 'CR404', 'perfil público inexistente');
SELECT pg_temp.ok(fn_bloquear_usuario(:'bruno', :'ana'), 'Bruno bloquea a Ana (nuevo)');
SELECT pg_temp.espera(format('SELECT * FROM fn_perfil_publico(%L, %L)', :'ana', :'bruno'), 'CR404', 'perfil de quien me bloqueó');
SELECT pg_temp.espera(format('SELECT * FROM fn_perfil_publico(%L, %L)', :'bruno', :'ana'), 'CR404', 'perfil de quien bloqueé');
SELECT pg_temp.ok(fn_desbloquear_usuario(:'bruno', :'ana'), 'desbloqueo');

\echo '--- contactos'
SELECT pg_temp.ok((SELECT id = :'c_ana_bruno' AND NOT creado FROM fn_crear_contacto(:'ana', '+50670000002', 'Otro alias')), 'crear contacto existente: idempotente (mismo id, creado=false)');
SELECT pg_temp.ok((SELECT alias = 'Bruno' FROM fn_obtener_contacto(:'ana', :'c_ana_bruno')), 'idempotente no cambia el alias');
SELECT pg_temp.espera(format('SELECT * FROM fn_crear_contacto(%L, %L)', :'ana', '+50670000001'), 'CR404', 'contacto a uno mismo (mismo 404)');
SELECT pg_temp.espera(format('SELECT * FROM fn_crear_contacto(%L, %L)', :'ana', '+50679999999'), 'CR404', 'contacto a no registrado (mismo 404)');
SELECT id AS c_ana_diego FROM fn_crear_contacto(:'ana', '+50670000004', 'Diego') \gset
SELECT pg_temp.ok(fn_bloquear_usuario(:'diego', :'ana'), 'Diego bloquea a Ana (relación: Ana lo tiene en contactos)');
SELECT fn_borrar_contacto(:'ana', :'c_ana_diego');
SELECT pg_temp.espera(format('SELECT * FROM fn_crear_contacto(%L, %L)', :'ana', '+50670000004'), 'CR404', 'contacto a quien me bloqueó (mismo 404)');
SELECT pg_temp.ok(fn_desbloquear_usuario(:'diego', :'ana'), 'Diego desbloquea');
SELECT pg_temp.ok((SELECT id = :'c_ana_diego' AND creado AND alias IS NULL FROM fn_crear_contacto(:'ana', '+50670000004')), 'recrear contacto borrado: reactiva el mismo id (creado=true)');
SELECT pg_temp.espera(format('SELECT * FROM fn_crear_contacto(%L, %L, %L)', :'carla', '+50670000001', repeat('a', 51)), 'CR422', 'alias > 50', 'alias');
SELECT pg_temp.espera(format('SELECT * FROM fn_obtener_contacto(%L, %L)', :'bruno', :'c_ana_bruno'), 'CR404', 'IDOR obtener contacto ajeno');
SELECT pg_temp.espera(format('SELECT * FROM fn_actualizar_contacto(%L, %L, %L)', :'bruno', :'c_ana_bruno', 'hackeado'), 'CR404', 'IDOR actualizar contacto ajeno');
SELECT pg_temp.espera(format('SELECT fn_borrar_contacto(%L, %L)', :'bruno', :'c_ana_bruno'), 'CR404', 'IDOR borrar contacto ajeno');
SELECT pg_temp.ok((SELECT alias IS NULL AND orden = 'diego nandu' FROM fn_actualizar_contacto(:'ana', :'c_ana_diego', NULL)), 'alias NULL => orden por nombre sin acentos');
SELECT pg_temp.ok((SELECT count(*) = 1 FROM fn_listar_contactos(:'ana', 'ÑAND')), 'búsqueda por nombre sin acentos ni mayúsculas');
SELECT pg_temp.ok((SELECT count(*) = 1 FROM fn_listar_contactos(:'ana', 'TRABAJO')), 'búsqueda por alias');
SELECT pg_temp.ok((SELECT count(*) = 3 FROM fn_listar_contactos(:'ana', '5067000000')), 'búsqueda por prefijo de teléfono sin +');
SELECT pg_temp.ok((SELECT count(*) = 0 FROM fn_listar_contactos(:'ana', '%')), 'comodín % escapado');
SELECT pg_temp.ok((SELECT conversacion_ok FROM (SELECT bool_and((id_conversacion IS NOT NULL) = (alias IN ('Bruno', 'Carla (trabajo)'))) AS conversacion_ok FROM fn_listar_contactos(:'ana')) x), 'contacto trae conversation_id si existe');
SELECT orden AS o1, id AS i1 FROM fn_listar_contactos(:'ana', NULL, 1) \gset
SELECT pg_temp.ok(:'o1' = 'bruno', 'página 1 (orden alfabético)');
SELECT orden AS o2, id AS i2 FROM fn_listar_contactos(:'ana', NULL, 1, :'o1', :'i1') \gset
SELECT pg_temp.ok(:'o2' = 'carla (trabajo)', 'página 2 por cursor');
SELECT pg_temp.ok((SELECT count(*) = 1 AND bool_and(orden = 'diego nandu') FROM fn_listar_contactos(:'ana', NULL, 5, :'o2', :'i2')), 'página 3 y fin');
SELECT pg_temp.espera(format('SELECT * FROM fn_listar_contactos(%L, NULL, 50, %L, NULL)', :'ana', 'x'), 'CR422', 'cursor incompleto', 'cursor');
SELECT pg_temp.espera(format('SELECT * FROM fn_listar_contactos(%L, NULL, 1000)', :'ana'), 'CR422', 'límite fuera de rango');

\echo '--- bloqueos'
SELECT pg_temp.espera(format('SELECT fn_bloquear_usuario(%L, %L)', :'ana', :'ana'), 'CR422', 'bloquearse a sí mismo');
SELECT pg_temp.espera(format('SELECT fn_bloquear_usuario(%L, %L)', :'diego', :'carla'), 'CR404', 'bloquear sin relación');
SELECT pg_temp.espera(format('SELECT fn_bloquear_usuario(%L, %L)', :'ana', gen_random_uuid()), 'CR404', 'bloquear inexistente');
SELECT pg_temp.ok(fn_bloquear_usuario(:'ana', :'diego') AND NOT fn_bloquear_usuario(:'ana', :'diego'), 'bloquear idempotente (true, luego false)');
SELECT pg_temp.ok((SELECT count(*) = 1 AND bool_and(id_usuario = :'diego') FROM fn_listar_bloqueos(:'ana')), 'listar bloqueos');
SELECT pg_temp.ok((SELECT bloqueado FROM fn_obtener_contacto(:'ana', :'c_ana_diego')), 'contacto marca blocked=true');
SELECT pg_temp.ok(fn_desbloquear_usuario(:'ana', :'diego') AND NOT fn_desbloquear_usuario(:'ana', :'diego'), 'desbloquear idempotente');
SELECT pg_temp.ok(NOT fn_desbloquear_usuario(:'ana', gen_random_uuid()), 'desbloquear desconocido => false sin error');

\echo '--- conversaciones'
SELECT pg_temp.espera(format('SELECT * FROM fn_crear_conversacion(%L, %L)', :'bruno', :'c_ana_bruno'), 'CR404', 'IDOR crear conversación con contacto ajeno');
SELECT pg_temp.ok((SELECT id = :'conv_ab' AND NOT creada FROM fn_crear_conversacion(:'ana', :'c_ana_bruno')), 'get-or-create desde Ana');
SELECT pg_temp.ok((SELECT id = :'conv_ab' AND NOT creada FROM fn_crear_conversacion(:'bruno', :'c_bruno_ana')), 'misma conversación desde Bruno');
SELECT pg_temp.ok((SELECT count(*) = 1 AND bool_and(id_peer = :'ana' AND NOT es_contacto) FROM fn_obtener_conversacion(:'carla', :'conv_ac')), 'Carla ve la conversación con is_contact=false');
SELECT pg_temp.espera(format('SELECT * FROM fn_obtener_conversacion(%L, %L)', :'carla', :'conv_ab'), 'CR404', 'IDOR obtener conversación ajena');
SELECT pg_temp.ok((SELECT count(*) = 2 FROM fn_participantes_conversacion(:'ana', :'conv_ab')), 'participantes (2, incluido el llamante)');
SELECT pg_temp.espera(format('SELECT * FROM fn_participantes_conversacion(%L, %L)', :'carla', :'conv_ab'), 'CR404', 'IDOR participantes de conversación ajena');
SELECT fn_bloquear_usuario(:'ana', :'diego');
SELECT pg_temp.espera(format('SELECT * FROM fn_crear_conversacion(%L, %L)', :'ana', :'c_ana_diego'), 'CR403', 'crear conversación con bloqueo', 'bloqueado');
SELECT fn_desbloquear_usuario(:'ana', :'diego');

\echo '--- mensajes'
SELECT gen_random_uuid() AS cid1 \gset
SELECT id AS m1, creado AS m1_creado, estado AS m1_estado FROM fn_enviar_mensaje(:'ana', :'conv_ab', '\x0102'::bytea, :N24, 1::smallint, NULL, :'cid1') \gset
SELECT pg_temp.ok(:'m1_creado'::boolean AND :'m1_estado' = 'sent', 'enviar: creado, estado sent');
SELECT pg_temp.ok((SELECT id = :'m1' AND NOT creado AND client_id = :'cid1' FROM fn_enviar_mensaje(:'ana', :'conv_ab', '\x0102'::bytea, :N24, 1::smallint, NULL, :'cid1')), 'reenvío con el mismo client_id: mismo mensaje, creado=false');
SELECT pg_temp.espera(format('SELECT * FROM fn_enviar_mensaje(%L, %L, %L::bytea, %s, 1::smallint, NULL, %L)', :'ana', :'conv_ac', '\x01', :'N24', :'cid1'), 'CR409', 'client_id reutilizado en otra conversación', 'client_id');
SELECT pg_temp.ok((SELECT client_id IS NULL FROM fn_listar_mensajes(:'bruno', :'conv_ab') WHERE id = :'m1'), 'client_id no se expone al receptor');
SELECT pg_temp.espera(format('SELECT * FROM fn_enviar_mensaje(%L, %L, %L::bytea, %L::bytea, 1::smallint)', :'ana', :'conv_ab', '\x01', '\x0102'), 'CR422', 'nonce de longitud incorrecta');
SELECT pg_temp.espera(format('SELECT * FROM fn_enviar_mensaje(%L, %L, %L::bytea)', :'ana', :'conv_ab', '\x01'), 'CR422', 'contenido sin nonce/key_id');
SELECT pg_temp.espera(format('SELECT * FROM fn_enviar_mensaje(%L, %L)', :'ana', :'conv_ab'), 'CR422', 'mensaje sin texto ni adjunto', 'text');
SELECT pg_temp.espera(format('SELECT * FROM fn_enviar_mensaje(%L, %L, %L::bytea, %s, 1::smallint)', :'carla', :'conv_ab', '\x01', :'N24'), 'CR404', 'IDOR enviar a conversación ajena');
SELECT count(*) FROM (SELECT fn_enviar_mensaje(CASE WHEN g % 2 = 0 THEN :'ana'::uuid ELSE :'bruno'::uuid END, :'conv_ab', convert_to('c' || g, 'UTF8'), :N24, 1::smallint) FROM generate_series(1, 6) g) x \gset
-- 7 mensajes: m1 (Ana) + Bruno, Ana, Bruno, Ana, Bruno, Ana
SELECT pg_temp.ok((SELECT no_leidos = 4 FROM fn_obtener_conversacion(:'bruno', :'conv_ab')), 'unread_count de Bruno = 4');
SELECT pg_temp.ok((SELECT ult_id_remitente = :'ana' AND ult_contenido = convert_to('c6', 'UTF8') AND ult_nonce IS NOT NULL AND ult_key_id = 1 AND ult_estado = 'sent' FROM fn_listar_conversaciones(:'ana') WHERE id = :'conv_ab'), 'listado con last_message (cifrado, nonce, key_id, estado)');
SELECT pg_temp.ok((SELECT array_agg(id ORDER BY created_at) = array_agg(id) AND count(*) = 7 FROM fn_listar_mensajes(:'bruno', :'conv_ab')), 'listar sin cursor: 7, orden ascendente');
SELECT id AS ult3_primero FROM fn_listar_mensajes(:'bruno', :'conv_ab', 3) LIMIT 1 \gset
SELECT pg_temp.ok((SELECT count(*) = 3 AND bool_and(id <> :'ult3_primero') FROM fn_listar_mensajes(:'bruno', :'conv_ab', 3, :'ult3_primero')), 'before: 3 anteriores sin solape');
SELECT pg_temp.ok((SELECT count(*) = 1 AND bool_and(id = :'m1') FROM fn_listar_mensajes(:'bruno', :'conv_ab', 10, (SELECT id FROM fn_listar_mensajes(:'bruno', :'conv_ab') LIMIT 1 OFFSET 1))), 'before llega al más viejo');
SELECT pg_temp.ok((SELECT count(*) = 6 AND bool_and(id <> :'m1') FROM fn_listar_mensajes(:'bruno', :'conv_ab', 50, NULL, :'m1')), 'after: los 6 posteriores (resincronización)');
SELECT pg_temp.espera(format('SELECT * FROM fn_listar_mensajes(%L, %L, 10, %L, %L)', :'bruno', :'conv_ab', :'m1', :'m1'), 'CR422', 'before y after juntos', 'cursor');
SELECT pg_temp.espera(format('SELECT * FROM fn_listar_mensajes(%L, %L, 10, %L)', :'ana', :'conv_ac', :'m1'), 'CR422', 'cursor de otra conversación', 'cursor');
SELECT pg_temp.espera(format('SELECT * FROM fn_listar_mensajes(%L, %L)', :'carla', :'conv_ab'), 'CR404', 'IDOR listar mensajes ajenos');

\echo '--- recibos'
SELECT id AS m_ultimo FROM fn_listar_mensajes(:'bruno', :'conv_ab', 1) \gset
SELECT pg_temp.ok((SELECT actualizados = 1 AND no_leidos = 4 FROM fn_marcar_recibos(:'bruno', :'conv_ab', 'delivered', :'m1')), 'delivered hasta m1: 1 recibo, unread sigue 4');
SELECT pg_temp.ok((SELECT estado = 'delivered' FROM fn_listar_mensajes(:'ana', :'conv_ab') WHERE id = :'m1'), 'Ana ve m1 delivered');
SELECT pg_temp.ok((SELECT actualizados = 4 AND no_leidos = 0 FROM fn_marcar_recibos(:'bruno', :'conv_ab', 'seen', :'m_ultimo')), 'seen hasta el último: 4 recibos, unread 0');
SELECT pg_temp.ok((SELECT actualizados = 0 AND no_leidos = 0 FROM fn_marcar_recibos(:'bruno', :'conv_ab', 'seen', :'m1')), 'marcador monótono: no retrocede');
SELECT pg_temp.ok((SELECT estado = 'seen' FROM fn_listar_mensajes(:'ana', :'conv_ab') WHERE id = :'m1'), 'Ana ve m1 seen');
SELECT pg_temp.espera(format('SELECT * FROM fn_marcar_recibos(%L, %L, %L, %L)', :'bruno', :'conv_ab', 'leido', :'m1'), 'CR422', 'estado de recibo inválido', 'status');
SELECT pg_temp.espera(format('SELECT * FROM fn_marcar_recibos(%L, %L, %L, %L)', :'ana', :'conv_ac', 'seen', :'m1'), 'CR404', 'up_to de otra conversación');
SELECT pg_temp.espera(format('SELECT * FROM fn_marcar_recibos(%L, %L, %L, %L)', :'carla', :'conv_ab', 'seen', :'m1'), 'CR404', 'IDOR recibos en conversación ajena');

\echo '--- editar / borrar'
SELECT pg_temp.ok((SELECT contenido = '\x0a0b'::bytea AND editado_at IS NOT NULL FROM fn_editar_mensaje(:'ana', :'m1', '\x0a0b'::bytea, :N24, 2::smallint)), 'autor edita dentro de 15 min');
SELECT pg_temp.espera(format('SELECT * FROM fn_editar_mensaje(%L, %L, %L::bytea, %s, 1::smallint)', :'bruno', :'m1', '\x09', :'N24'), 'CR403', 'editar mensaje de otro participante', 'no-autor');
SELECT pg_temp.espera(format('SELECT * FROM fn_editar_mensaje(%L, %L, %L::bytea, %s, 1::smallint)', :'carla', :'m1', '\x09', :'N24'), 'CR404', 'IDOR editar (no participante)');
UPDATE mensaje SET created_at = created_at - interval '16 minutes' WHERE public_id = :'m1';
SELECT pg_temp.espera(format('SELECT * FROM fn_editar_mensaje(%L, %L, %L::bytea, %s, 1::smallint)', :'ana', :'m1', '\x09', :'N24'), 'CR422', 'editar fuera de plazo', 'edicion-expirada');
SELECT pg_temp.espera(format('SELECT * FROM fn_borrar_mensaje(%L, %L)', :'bruno', :'m1'), 'CR403', 'borrar mensaje de otro participante', 'no-autor');
SELECT pg_temp.espera(format('SELECT * FROM fn_borrar_mensaje(%L, %L)', :'carla', :'m1'), 'CR404', 'IDOR borrar (no participante)');
SELECT pg_temp.ok((SELECT borrado AND id_conversacion = :'conv_ab' FROM fn_borrar_mensaje(:'ana', :'m1')), 'autor borra (lápida)');
SELECT pg_temp.ok((SELECT NOT borrado FROM fn_borrar_mensaje(:'ana', :'m1')), 'borrar de nuevo: idempotente (borrado=false)');
SELECT pg_temp.ok((SELECT deleted_at IS NOT NULL AND contenido IS NULL AND nonce IS NULL AND media IS NULL FROM fn_listar_mensajes(:'bruno', :'conv_ab') WHERE id = :'m1'), 'la lápida se lista sin contenido');
SELECT pg_temp.espera(format('SELECT * FROM fn_editar_mensaje(%L, %L, %L::bytea, %s, 1::smallint)', :'ana', :'m1', '\x09', :'N24'), 'CR404', 'editar mensaje borrado');

\echo '--- bloqueo y envío'
SELECT gen_random_uuid() AS cid2 \gset
SELECT id AS m2 FROM fn_enviar_mensaje(:'ana', :'conv_ab', '\x01'::bytea, :N24, 1::smallint, NULL, :'cid2') \gset
SELECT fn_bloquear_usuario(:'bruno', :'ana');
SELECT pg_temp.espera(format('SELECT * FROM fn_enviar_mensaje(%L, %L, %L::bytea, %s, 1::smallint)', :'ana', :'conv_ab', '\x01', :'N24'), 'CR403', 'enviar a quien me bloqueó', 'bloqueado');
SELECT pg_temp.espera(format('SELECT * FROM fn_enviar_mensaje(%L, %L, %L::bytea, %s, 1::smallint)', :'bruno', :'conv_ab', '\x01', :'N24'), 'CR403', 'enviar a quien bloqueé', 'bloqueado');
SELECT pg_temp.ok((SELECT id = :'m2' AND NOT creado FROM fn_enviar_mensaje(:'ana', :'conv_ab', '\x01'::bytea, :N24, 1::smallint, NULL, :'cid2')), 'reintento idempotente devuelve el original aunque haya bloqueo');
SELECT pg_temp.espera(format('SELECT * FROM fn_editar_mensaje(%L, %L, %L::bytea, %s, 1::smallint)', :'ana', :'m2', '\x09', :'N24'), 'CR403', 'editar con bloqueo', 'bloqueado');
SELECT fn_desbloquear_usuario(:'bruno', :'ana');

\echo '--- media'
SELECT id AS av1, clave_objeto AS av1_clave FROM fn_registrar_media(:'ana', 'avatar', 'image/png', 1000, 'cr-chat-media') \gset
SELECT pg_temp.ok(:'av1_clave' ~ ('^avatar/[0-9]{4}/[0-9]{2}/' || :'av1' || '$'), 'clave de objeto generada por la BD');
SELECT pg_temp.espera(format('SELECT * FROM fn_registrar_media(%L, %L, %L, 1000, %L)', :'ana', 'avatar', 'image/gif', 'cr-chat-media'), 'CR422', 'avatar con tipo no permitido');
SELECT pg_temp.espera(format('SELECT * FROM fn_registrar_media(%L, %L, %L, 3000000, %L)', :'ana', 'avatar', 'image/png', 'cr-chat-media'), 'CR422', 'avatar > 2 MiB');
SELECT pg_temp.espera(format('SELECT * FROM fn_registrar_media(%L, %L, %L, 25000000, %L)', :'ana', 'mensaje', 'video/mp4', 'cr-chat-media'), 'CR422', 'adjunto > 20 MiB');
SELECT pg_temp.espera(format('SELECT * FROM fn_registrar_media(%L, %L, %L, 10, %L)', :'ana', 'mensaje', 'text/html', 'cr-chat-media'), 'CR422', 'MIME no permitido');
SELECT pg_temp.espera(format('SELECT * FROM fn_registrar_media(%L, %L, %L, 10, %L)', :'ana', 'mensaje', 'image/png', '../etc'), 'CR422', 'bucket inválido');
SELECT pg_temp.ok((SELECT estado = 'pendiente' FROM fn_obtener_media(:'ana', :'av1')), 'obtener media propia (pendiente)');
SELECT pg_temp.espera(format('SELECT * FROM fn_obtener_media(%L, %L)', :'bruno', :'av1'), 'CR404', 'IDOR obtener media ajena');
SELECT pg_temp.espera(format('SELECT * FROM fn_actualizar_usuario(%L, p_avatar => %L)', :'bruno', :'av1'), 'CR422', 'IDOR usar media ajena como avatar', 'avatar_media_id');
SELECT pg_temp.ok((SELECT (avatar->>'id')::uuid = :'av1' FROM fn_actualizar_usuario(:'ana', p_avatar => :'av1')), 'avatar asignado y confirmado');
SELECT pg_temp.ok((SELECT (avatar->>'id')::uuid = :'av1' FROM fn_actualizar_usuario(:'ana', p_avatar => :'av1')), 'reasignar el mismo avatar: sin cambios');
SELECT pg_temp.ok((SELECT (avatar->>'id')::uuid = :'av1' FROM fn_perfil_publico(:'bruno', :'ana')), 'Bruno ve el avatar de Ana');
SELECT fn_bloquear_usuario(:'ana', :'bruno');
SELECT pg_temp.ok((SELECT peer_avatar IS NULL FROM fn_obtener_conversacion(:'bruno', :'conv_ab')), 'avatar oculto para quien está bloqueado');
SELECT pg_temp.ok((SELECT bloqueado FROM fn_obtener_conversacion(:'ana', :'conv_ab')), 'conversación marca blocked=true para quien bloqueó');
SELECT fn_desbloquear_usuario(:'ana', :'bruno');
SELECT id AS av2 FROM fn_registrar_media(:'ana', 'avatar', 'image/webp', 2000, 'cr-chat-media') \gset
SELECT pg_temp.ok((SELECT (avatar->>'id')::uuid = :'av2' FROM fn_actualizar_usuario(:'ana', p_avatar => :'av2')), 'cambiar avatar');
SELECT pg_temp.ok((SELECT estado = 'borrado' FROM fn_obtener_media(:'ana', :'av1')), 'el avatar anterior queda borrado');
SELECT pg_temp.espera(format('SELECT * FROM fn_actualizar_usuario(%L, p_avatar => %L)', :'ana', :'av1'), 'CR422', 'reutilizar media borrada como avatar', 'avatar_media_id');
SELECT id AS adj1 FROM fn_registrar_media(:'ana', 'mensaje', 'application/pdf', 5000, 'cr-chat-media') \gset
SELECT pg_temp.espera(format('SELECT * FROM fn_actualizar_usuario(%L, p_avatar => %L)', :'ana', :'adj1'), 'CR422', 'media de mensaje como avatar', 'avatar_media_id');
SELECT pg_temp.espera(format('SELECT * FROM fn_enviar_mensaje(%L, %L, p_media => %L)', :'bruno', :'conv_ab', :'adj1'), 'CR422', 'IDOR adjuntar media ajena', 'media_id');
SELECT id AS m3 FROM fn_enviar_mensaje(:'ana', :'conv_ab', p_media => :'adj1') \gset
SELECT pg_temp.ok((SELECT contenido IS NULL AND (media->>'id')::uuid = :'adj1' AND media->>'mime' = 'application/pdf' FROM fn_listar_mensajes(:'bruno', :'conv_ab') WHERE id = :'m3'), 'mensaje solo con adjunto, visible para el receptor');
SELECT pg_temp.espera(format('SELECT * FROM fn_enviar_mensaje(%L, %L, p_media => %L)', :'ana', :'conv_ab', :'adj1'), 'CR422', 'reutilizar un adjunto ya enviado', 'media_id');
SELECT pg_temp.ok((SELECT borrado FROM fn_borrar_mensaje(:'ana', :'m3')), 'borrar mensaje con adjunto');
SELECT pg_temp.ok((SELECT estado = 'borrado' FROM fn_obtener_media(:'ana', :'adj1')), 'el adjunto del mensaje borrado queda borrado');
SELECT id AS pend_viejo FROM fn_registrar_media(:'bruno', 'mensaje', 'image/jpeg', 100, 'cr-chat-media') \gset
SELECT id AS pend_nuevo FROM fn_registrar_media(:'bruno', 'mensaje', 'image/jpeg', 100, 'cr-chat-media') \gset
UPDATE media SET created_at = now() - interval '25 hours' WHERE public_id = :'pend_viejo';
SELECT pg_temp.ok((SELECT array_agg(id ORDER BY id) = (SELECT array_agg(x ORDER BY x) FROM unnest(ARRAY[:'av1', :'adj1', :'pend_viejo']::uuid[]) x) FROM fn_listar_media_huerfana()), 'huérfanos: borrados + pendientes > 24 h (no el pendiente reciente ni el avatar vigente)');
SELECT pg_temp.ok(fn_purgar_media(ARRAY[:'av1', :'adj1', :'pend_viejo', :'pend_nuevo', :'av2']::uuid[]) = 3, 'purga solo los huérfanos (revalida estado)');
SELECT pg_temp.ok((SELECT count(*) = 0 FROM fn_listar_media_huerfana()), 'sin huérfanos tras la purga');

\echo '--- sesiones'
SELECT gen_random_uuid() AS j1, gen_random_uuid() AS j2 \gset
SELECT id_sesion AS s1 FROM fn_crear_sesion(:'ana', :'j1', sha256('r1'::bytea), 'Firefox en Linux', 'Mozilla/5.0', '203.0.113.77') \gset
SELECT id_sesion AS s2 FROM fn_crear_sesion(:'ana', :'j2', sha256('r2'::bytea), 'Android', NULL, '2001:db8:abcd:12::1') \gset
SELECT pg_temp.ok((SELECT array_agg(ip_hint ORDER BY ip_hint) = ARRAY['2001:db8:abcd::/48', '203.0.113.0/24'] FROM fn_listar_sesiones(:'ana', :'s1')), 'IP truncada por la BD (/24 y /48)');
SELECT pg_temp.ok((SELECT count(*) = 2 AND count(*) FILTER (WHERE actual) = 1 AND bool_or(actual AND id = :'s1') FROM fn_listar_sesiones(:'ana', :'s1')), 'listar sesiones con la actual marcada');
SELECT pg_temp.espera(format('SELECT * FROM fn_crear_sesion(%L, %L, %L::bytea, %L)', :'ana', gen_random_uuid(), '\x01', 'x'), 'CR422', 'hash de refresh que no es SHA-256');
SELECT pg_temp.espera(format('SELECT * FROM fn_crear_sesion(%L, %L, sha256(%L::bytea), %L)', :'ana', :'j1', 'otro', 'x'), 'CR409', 'jti duplicado');
SELECT pg_temp.ok((SELECT estado = 'ok' AND id_sesion = :'s1' AND id_usuario = :'ana' FROM fn_rotar_sesion(sha256('r1'::bytea), gen_random_uuid(), sha256('r1b'::bytea))), 'rotar: misma sesión (sid estable)');
SELECT pg_temp.ok((SELECT estado = 'ok' FROM fn_rotar_sesion(sha256('r1b'::bytea), gen_random_uuid(), sha256('r1c'::bytea))), 'rotar de nuevo con el refresh nuevo');
SELECT pg_temp.espera($$SELECT * FROM fn_rotar_sesion(sha256('desconocido'::bytea), gen_random_uuid(), sha256('x1'::bytea))$$, 'CR401', 'refresh desconocido', 'desconocido');
SELECT pg_temp.ok((SELECT estado = 'reutilizacion' AND id_sesion = :'s1' FROM fn_rotar_sesion(sha256('r1'::bytea), gen_random_uuid(), sha256('x2'::bytea))), 'reutilizar un refresh rotado => estado reutilizacion (sin error)');
SELECT pg_temp.espera($$SELECT * FROM fn_rotar_sesion(sha256('r1c'::bytea), gen_random_uuid(), sha256('x3'::bytea))$$, 'CR401', 'tras la reutilización la sesión queda revocada (también el refresh vigente)', 'revocada');
SELECT pg_temp.ok(NOT fn_tocar_sesion(:'ana', :'s1'), 'tocar sesión revocada => false');
SELECT pg_temp.ok(fn_tocar_sesion(:'ana', :'s2'), 'tocar sesión activa => true');
SELECT pg_temp.ok(NOT fn_tocar_sesion(:'bruno', :'s2'), 'IDOR tocar sesión ajena => false');
UPDATE sesion SET last_used_at = now() - interval '5 minutes' WHERE public_id = :'s2';
SELECT fn_tocar_sesion(:'ana', :'s2');
SELECT pg_temp.ok((SELECT last_used_at > now() - interval '1 minute' FROM fn_listar_sesiones(:'ana', :'s2') WHERE id = :'s2'), 'tocar actualiza last_used_at (como mucho 1/min)');
SELECT pg_temp.espera(format('SELECT fn_revocar_sesion(%L, %L)', :'bruno', :'s2'), 'CR404', 'IDOR revocar sesión ajena');
SELECT pg_temp.espera(format('SELECT fn_revocar_sesion(%L, %L, %L)', :'ana', :'s2', 'baja'), 'CR422', 'motivo de revocación inválido');
SELECT id_sesion AS s3 FROM fn_crear_sesion(:'ana', gen_random_uuid(), sha256('r3'::bytea), 'iPad') \gset
SELECT id_sesion AS s4 FROM fn_crear_sesion(:'ana', gen_random_uuid(), sha256('r4'::bytea), 'Chrome') \gset
SELECT pg_temp.ok((SELECT array_agg(id_sesion ORDER BY id_sesion) = (SELECT array_agg(x ORDER BY x) FROM unnest(ARRAY[:'s3', :'s4']::uuid[]) x) FROM fn_revocar_sesiones(:'ana', :'s2')), 'revocar todas menos la actual (devuelve los sid)');
SELECT pg_temp.ok(fn_revocar_sesion(:'ana', :'s2', 'logout') AND NOT fn_revocar_sesion(:'ana', :'s2'), 'logout idempotente');
SELECT id_sesion AS s5 FROM fn_crear_sesion(:'ana', gen_random_uuid(), sha256('r5'::bytea), 'Móvil') \gset
SELECT id_sesion AS s6 FROM fn_crear_sesion(:'ana', gen_random_uuid(), sha256('r6'::bytea), 'Portátil') \gset
SELECT pg_temp.ok((SELECT array_agg(id_sesion) = ARRAY[:'s6']::uuid[] FROM fn_cambiar_pass_hash(:'ana', '$argon2id$v=19$m=65536,t=4,p=1$bnVldm8$aGFzaA', :'s5')), 'cambio de contraseña revoca las demás y conserva la actual');
SELECT pg_temp.espera(format('SELECT * FROM fn_cambiar_pass_hash(%L, %L, NULL)', :'ana', 'plano'), 'CR422', 'cambio de contraseña con hash no argon2id');
SELECT pg_temp.espera(format('SELECT * FROM fn_cambiar_telefono(%L, %L, %L)', :'ana', '+50670000002', :'s5'), 'CR409', 'cambiar a un teléfono ajeno (409 genérico)');
SELECT pg_temp.espera(format('SELECT * FROM fn_cambiar_telefono(%L, %L, %L)', :'ana', '8888-0000', :'s5'), 'CR422', 'cambiar a un teléfono no E.164', 'phone');
SELECT pg_temp.ok((SELECT count(*) = 0 FROM fn_cambiar_telefono(:'ana', '+50670000011', :'s5')), 'cambiar teléfono (sin otras sesiones que revocar)');
SELECT pg_temp.ok((SELECT telefono = '+50670000011' FROM fn_leer_perfil(:'ana')), 'teléfono nuevo visible en /me');
SELECT fn_cambiar_telefono(:'ana', '+50670000001', :'s5');
UPDATE sesion SET expira_at = now() - interval '1 second', created_at = now() - interval '1 day' WHERE public_id = :'s5';
SELECT pg_temp.espera($$SELECT * FROM fn_rotar_sesion(sha256('r5'::bytea), gen_random_uuid(), sha256('x5'::bytea))$$, 'CR401', 'refresh de sesión expirada', 'expirada');

\echo '--- presencia'
SELECT pg_temp.ok((SELECT array_agg(id_usuario ORDER BY id_usuario) = (SELECT array_agg(x ORDER BY x) FROM unnest(ARRAY[:'bruno', :'carla', :'diego']::uuid[]) x) FROM fn_filtrar_relacionados(:'ana', ARRAY[:'bruno', :'carla', :'diego', :'ana', gen_random_uuid()::text]::uuid[])), 'presence.query: solo relacionados');
SELECT pg_temp.ok((SELECT count(*) = 0 FROM fn_filtrar_relacionados(:'diego', ARRAY[:'carla']::uuid[])), 'presence.query sin relación => vacío');
SELECT fn_bloquear_usuario(:'diego', :'ana');
SELECT pg_temp.ok((SELECT count(*) = 2 FROM fn_listar_relacionados(:'ana')), 'relacionados excluye bloqueos');
SELECT fn_desbloquear_usuario(:'diego', :'ana');
SELECT fn_registrar_last_seen(:'bruno');
SELECT pg_temp.ok((SELECT last_seen_at IS NOT NULL FROM fn_filtrar_relacionados(:'ana', ARRAY[:'bruno']::uuid[])), 'last_seen registrado');
SELECT pg_temp.espera(format('SELECT * FROM fn_filtrar_relacionados(%L, (SELECT array_agg(gen_random_uuid()) FROM generate_series(1, 101)))', :'ana'), 'CR422', 'presence.query con más de 100 ids', 'user_ids');

\echo '--- baja / reactivación'
SELECT id_sesion AS sc FROM fn_crear_sesion(:'carla', gen_random_uuid(), sha256('rc'::bytea), 'Web') \gset
SELECT pg_temp.ok((SELECT array_agg(id_sesion) = ARRAY[:'sc']::uuid[] FROM fn_borrar_usuario(:'carla')), 'baja revoca todas las sesiones y las devuelve');
SELECT pg_temp.ok((SELECT eliminado FROM fn_credenciales_login('carla@demo.crchat.local')), 'login informa eliminado');
SELECT pg_temp.espera(format('SELECT * FROM fn_listar_conversaciones(%L)', :'carla'), 'CR401', 'usuario dado de baja no opera');
SELECT pg_temp.espera(format('SELECT * FROM fn_perfil_publico(%L, %L)', :'ana', :'carla'), 'CR404', 'perfil de usuario dado de baja');
SELECT pg_temp.espera(format('SELECT * FROM fn_enviar_mensaje(%L, %L, %L::bytea, %s, 1::smallint)', :'ana', :'conv_ac', '\x01', :'N24'), 'CR403', 'enviar a usuario dado de baja', 'bloqueado');
SELECT fn_reactivar_usuario(:'carla');
SELECT pg_temp.ok((SELECT NOT eliminado FROM fn_credenciales_login('+50670000003')), 'reactivación dentro del plazo');
SELECT pg_temp.espera(format('SELECT fn_reactivar_usuario(%L)', :'carla'), 'CR404', 'reactivar cuenta activa');
SELECT fn_borrar_usuario(:'diego');
UPDATE usuario SET deleted_at = now() - interval '31 days' WHERE public_id = :'diego';
SELECT pg_temp.espera(format('SELECT fn_reactivar_usuario(%L)', :'diego'), 'CR404', 'reactivar fuera del plazo de gracia');

\echo '--- privilegios de app_rw'
SELECT pg_temp.espera('DELETE FROM usuario', '42501', 'app_rw sin DELETE en usuario');
SELECT pg_temp.espera('DELETE FROM sesion', '42501', 'app_rw sin DELETE en sesion');
SELECT pg_temp.espera('TRUNCATE mensaje', '42501', 'app_rw sin TRUNCATE');
SELECT pg_temp.espera('CREATE TABLE public.intrusa (x int)', '42501', 'app_rw sin DDL en public');
SELECT pg_temp.espera('SELECT fn_crear_particiones_auditoria(1)', '42501', 'app_rw sin EXECUTE en mantenimiento (particiones)');
SELECT pg_temp.espera('SELECT fn_purgar_sesiones()', '42501', 'app_rw sin EXECUTE en mantenimiento (sesiones)');
SELECT pg_temp.espera('SELECT count(*) FROM auditoria', '42501', 'app_rw no lee auditoría (solo INSERT)');

\echo 'PRUEBAS app_rw: TODAS OK'
