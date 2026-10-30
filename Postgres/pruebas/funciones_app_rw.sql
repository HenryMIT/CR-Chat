-- =============================================================================
-- Pruebas de contrato de las funciones (ejecutar CONECTADO COMO app_rw sobre
-- una base recién migrada + seed demo). Cada bloque falla (ON_ERROR_STOP) si el
-- resultado no es el esperado; imprime "OK ..." si lo es.
--   psql -U app_rw -d cr_chat -v ON_ERROR_STOP=1 -f Postgres/pruebas/funciones_app_rw.sql
-- Deja datos de prueba: usar solo en bases desechables.
-- =============================================================================
\set ON_ERROR_STOP on
\set QUIET on
SET client_min_messages = notice;

SELECT id AS ana   FROM usuario WHERE telefono = '+50670000001' \gset
SELECT id AS bruno FROM usuario WHERE telefono = '+50670000002' \gset
SELECT id AS carla FROM usuario WHERE telefono = '+50670000003' \gset
SELECT id AS c_ana_bruno FROM contacto WHERE id_usuario = :ana AND contact_user_id = :bruno \gset
SELECT id AS c_bruno_ana FROM contacto WHERE id_usuario = :bruno AND contact_user_id = :ana \gset
SELECT id AS conv_ab FROM conversacion WHERE id_usuario_menor = least(:ana, :bruno) AND id_usuario_mayor = greatest(:ana, :bruno) \gset
SELECT set_config('t.ana', :'ana', false), set_config('t.bruno', :'bruno', false),
       set_config('t.carla', :'carla', false), set_config('t.c_ana_bruno', :'c_ana_bruno', false),
       set_config('t.c_bruno_ana', :'c_bruno_ana', false), set_config('t.conv_ab', :'conv_ab', false) \gset

-- Atajo: id desde la configuración de sesión
-- current_setting('t.ana')::bigint, etc.

-- ---------------------------------------------------------------- login
DO $$
DECLARE n int; e boolean;
BEGIN
    SELECT count(*) INTO n FROM fn_credenciales_login('+50670000001');
    ASSERT n = 1, 'login por teléfono';
    SELECT count(*) INTO n FROM fn_credenciales_login('ANA@Demo.CRCHAT.local');
    ASSERT n = 1, 'login por email sin distinguir mayúsculas';
    SELECT count(*) INTO n FROM fn_credenciales_login('+50679999999');
    ASSERT n = 0, 'identificador inexistente => 0 filas';
    SELECT eliminado INTO e FROM fn_credenciales_login('+50670000002');
    ASSERT e = false;
    RAISE NOTICE 'OK login: teléfono, email citext, inexistente';
END $$;

-- ---------------------------------------------------------------- registro / duplicados
DO $$ BEGIN
    PERFORM fn_registrar_usuario('X', '+50670000001', 'nuevo@x.com', '$argon2id$v=19$m=65536,t=4,p=1$abc$def');
    RAISE EXCEPTION 'FALLO: teléfono duplicado aceptado';
EXCEPTION WHEN SQLSTATE 'CR409' THEN RAISE NOTICE 'OK registro: teléfono duplicado => CR409';
END $$;
DO $$ BEGIN
    PERFORM fn_registrar_usuario('X', '+50671111111', 'BRUNO@demo.crchat.local', '$argon2id$v=19$m=65536,t=4,p=1$abc$def');
    RAISE EXCEPTION 'FALLO: email duplicado (otra capitalización) aceptado';
EXCEPTION WHEN SQLSTATE 'CR409' THEN RAISE NOTICE 'OK registro: email duplicado case-insensitive => CR409';
END $$;
DO $$ BEGIN
    PERFORM fn_registrar_usuario('X', '12ab', 'z@x.com', '$argon2id$v=19$m=65536,t=4,p=1$abc$def');
    RAISE EXCEPTION 'FALLO: teléfono inválido aceptado';
EXCEPTION WHEN SQLSTATE 'CR422' THEN RAISE NOTICE 'OK registro: teléfono inválido => CR422';
END $$;
DO $$ BEGIN
    PERFORM fn_registrar_usuario('X', '+50671111112', 'z2@x.com', 'texto-plano');
    RAISE EXCEPTION 'FALLO: pass no argon2id aceptado';
EXCEPTION WHEN SQLSTATE 'CR422' THEN RAISE NOTICE 'OK registro: pass_hash no argon2id => CR422';
END $$;

-- ---------------------------------------------------------------- contactos
DO $$ BEGIN
    PERFORM fn_crear_contacto(current_setting('t.ana')::bigint, '+50670000002', 'Otra vez Bruno');
    RAISE EXCEPTION 'FALLO: contacto duplicado aceptado';
EXCEPTION WHEN SQLSTATE 'CR409' THEN RAISE NOTICE 'OK contacto duplicado => CR409';
END $$;
DO $$ BEGIN
    PERFORM fn_crear_contacto(current_setting('t.ana')::bigint, '+50670000001', 'Yo');
    RAISE EXCEPTION 'FALLO: auto-contacto aceptado';
EXCEPTION WHEN SQLSTATE 'CR422' THEN RAISE NOTICE 'OK auto-contacto => CR422';
END $$;
DO $$ BEGIN
    PERFORM fn_crear_contacto(current_setting('t.ana')::bigint, '+50679999999', 'Nadie');
    RAISE EXCEPTION 'FALLO: contacto a teléfono inexistente';
EXCEPTION WHEN SQLSTATE 'CR404' THEN RAISE NOTICE 'OK contacto a teléfono inexistente => CR404';
END $$;
DO $$ BEGIN   -- IDOR: Bruno modifica un contacto de Ana
    PERFORM fn_actualizar_contacto(current_setting('t.bruno')::bigint, current_setting('t.c_ana_bruno')::bigint, 'hackeado');
    RAISE EXCEPTION 'FALLO IDOR: Bruno editó un contacto de Ana';
EXCEPTION WHEN SQLSTATE 'CR404' THEN RAISE NOTICE 'OK IDOR actualizar_contacto ajeno => CR404';
END $$;
DO $$ BEGIN   -- IDOR: Bruno borra un contacto de Ana
    PERFORM fn_borrar_contacto(current_setting('t.bruno')::bigint, current_setting('t.c_ana_bruno')::bigint);
    RAISE EXCEPTION 'FALLO IDOR: Bruno borró un contacto de Ana';
EXCEPTION WHEN SQLSTATE 'CR404' THEN RAISE NOTICE 'OK IDOR borrar_contacto ajeno => CR404';
END $$;
DO $$
DECLARE n int; a text; i bigint;
BEGIN
    SELECT count(*) INTO n FROM fn_listar_contactos(current_setting('t.ana')::bigint, 'carl');
    ASSERT n = 1, 'búsqueda por alias';
    SELECT count(*) INTO n FROM fn_listar_contactos(current_setting('t.ana')::bigint, '+5067000000');
    ASSERT n = 2, 'búsqueda por prefijo de teléfono';
    SELECT count(*) INTO n FROM fn_listar_contactos(current_setting('t.ana')::bigint, '%');
    ASSERT n = 0, 'comodín escapado';
    SELECT alias, id_contacto INTO a, i FROM fn_listar_contactos(current_setting('t.ana')::bigint, NULL, 1);
    ASSERT a = 'Bruno', 'primera página ordenada por alias';
    SELECT alias INTO a FROM fn_listar_contactos(current_setting('t.ana')::bigint, NULL, 1, a, i);
    ASSERT a = 'Carla (trabajo)', 'segunda página por cursor';
    -- Borrar y volver a crear reactiva el MISMO contacto
    PERFORM fn_borrar_contacto(current_setting('t.ana')::bigint, current_setting('t.c_ana_bruno')::bigint);
    ASSERT fn_crear_contacto(current_setting('t.ana')::bigint, '+50670000002', 'Bruno') = current_setting('t.c_ana_bruno')::bigint;
    RAISE NOTICE 'OK listar_contactos: búsqueda, escape, keyset; borrar+crear reactiva';
END $$;
DO $$ BEGIN
    PERFORM fn_listar_contactos(current_setting('t.ana')::bigint, NULL, 1000);
    RAISE EXCEPTION 'FALLO: límite 1000 aceptado';
EXCEPTION WHEN SQLSTATE 'CR422' THEN RAISE NOTICE 'OK límite fuera de rango => CR422';
END $$;

-- ---------------------------------------------------------------- conversaciones
DO $$ BEGIN   -- IDOR: Bruno usa el id de contacto de Ana
    PERFORM fn_crear_conversacion(current_setting('t.bruno')::bigint, current_setting('t.c_ana_bruno')::bigint);
    RAISE EXCEPTION 'FALLO IDOR: Bruno usó un contacto de Ana';
EXCEPTION WHEN SQLSTATE 'CR404' THEN RAISE NOTICE 'OK IDOR crear_conversacion con contacto ajeno => CR404';
END $$;
DO $$
DECLARE r record;
BEGIN
    SELECT * INTO r FROM fn_crear_conversacion(current_setting('t.ana')::bigint, current_setting('t.c_ana_bruno')::bigint);
    ASSERT r.id_conversacion = current_setting('t.conv_ab')::bigint AND NOT r.creada, 'get-or-create (Ana)';
    SELECT * INTO r FROM fn_crear_conversacion(current_setting('t.bruno')::bigint, current_setting('t.c_bruno_ana')::bigint);
    ASSERT r.id_conversacion = current_setting('t.conv_ab')::bigint AND NOT r.creada, 'misma conversación desde Bruno';
    RAISE NOTICE 'OK conversación única por par (sin duplicados, desde ambos lados)';
END $$;

-- ---------------------------------------------------------------- mensajes
DO $$
DECLARE
    a bigint := current_setting('t.ana')::bigint;
    b bigint := current_setting('t.bruno')::bigint;
    cv bigint := current_setting('t.conv_ab')::bigint;
    m1 bigint; n int; r record; ult timestamptz; ult_id bigint;
BEGIN
    SELECT id_mensaje INTO m1 FROM fn_enviar_mensaje(a, cv, '\x0102030405'::bytea);
    FOR i IN 1..5 LOOP
        PERFORM fn_enviar_mensaje(CASE WHEN i % 2 = 0 THEN a ELSE b END, cv, convert_to('cifrado-' || i, 'UTF8'));
    END LOOP;
    PERFORM set_config('t.m1', m1::text, false);

    -- Paginación: 3 + 3 sin solapes, del más nuevo al más viejo
    SELECT count(*), min(created_at) INTO n, ult FROM fn_listar_mensajes(b, cv, 3);
    ASSERT n = 3;
    SELECT x.created_at, x.id_mensaje INTO ult, ult_id FROM fn_listar_mensajes(b, cv, 3) x
        ORDER BY x.created_at, x.id_mensaje LIMIT 1;
    SELECT count(*) INTO n FROM fn_listar_mensajes(b, cv, 3, ult, ult_id);
    ASSERT n = 3, 'segunda página';
    SELECT min(id_mensaje) INTO ult_id FROM fn_listar_mensajes(b, cv, 3, ult, ult_id);
    ASSERT ult_id = m1, 'la última página contiene el mensaje más viejo';

    -- No leídos de Bruno = 3 (los que envió Ana: m1, i=2, i=4)
    SELECT no_leidos INTO n FROM fn_listar_conversaciones(b) WHERE id_conversacion = cv;
    ASSERT n = 3, format('no_leidos esperado 3, obtenido %s', n);

    -- Entregado / visto
    ASSERT fn_marcar_entregado(b, cv, m1) = 1;
    SELECT * INTO r FROM fn_listar_mensajes(a, cv, 100) WHERE id_mensaje = m1;
    ASSERT r.entregado_at IS NOT NULL AND r.visto_at IS NULL, 'Ana ve entregado';
    ASSERT fn_marcar_visto(b, cv, 9223372036854775807) = 3;
    SELECT no_leidos INTO n FROM fn_listar_conversaciones(b) WHERE id_conversacion = cv;
    ASSERT n = 0;
    SELECT * INTO r FROM fn_listar_mensajes(a, cv, 100) WHERE id_mensaje = m1;
    ASSERT r.visto_at IS NOT NULL, 'Ana ve visto';
    RAISE NOTICE 'OK mensajes: envío, keyset sin solapes, no_leidos, entregado/visto';
END $$;

DO $$ BEGIN   -- IDOR: Carla envía a una conversación ajena
    PERFORM fn_enviar_mensaje(current_setting('t.carla')::bigint, current_setting('t.conv_ab')::bigint, '\x01'::bytea);
    RAISE EXCEPTION 'FALLO IDOR: Carla escribió en conversación ajena';
EXCEPTION WHEN SQLSTATE 'CR404' THEN RAISE NOTICE 'OK IDOR enviar_mensaje en conversación ajena => CR404';
END $$;
DO $$ BEGIN   -- IDOR: Carla lee una conversación ajena
    PERFORM fn_listar_mensajes(current_setting('t.carla')::bigint, current_setting('t.conv_ab')::bigint, 10);
    RAISE EXCEPTION 'FALLO IDOR: Carla leyó conversación ajena';
EXCEPTION WHEN SQLSTATE 'CR404' THEN RAISE NOTICE 'OK IDOR listar_mensajes ajenos => CR404';
END $$;
DO $$ BEGIN   -- IDOR: Carla marca visto en conversación ajena
    PERFORM fn_marcar_visto(current_setting('t.carla')::bigint, current_setting('t.conv_ab')::bigint, 1);
    RAISE EXCEPTION 'FALLO IDOR';
EXCEPTION WHEN SQLSTATE 'CR404' THEN RAISE NOTICE 'OK IDOR marcar_visto ajeno => CR404';
END $$;
DO $$ BEGIN   -- IDOR: Carla edita mensaje de Ana
    PERFORM fn_editar_mensaje(current_setting('t.carla')::bigint, current_setting('t.m1')::bigint, '\x09'::bytea);
    RAISE EXCEPTION 'FALLO IDOR';
EXCEPTION WHEN SQLSTATE 'CR404' THEN RAISE NOTICE 'OK IDOR editar_mensaje (no participante) => CR404';
END $$;
DO $$ BEGIN   -- Bruno (participante) edita mensaje de Ana
    PERFORM fn_editar_mensaje(current_setting('t.bruno')::bigint, current_setting('t.m1')::bigint, '\x09'::bytea);
    RAISE EXCEPTION 'FALLO: Bruno editó mensaje de Ana';
EXCEPTION WHEN SQLSTATE 'CR403' THEN RAISE NOTICE 'OK editar_mensaje de otro participante => CR403';
END $$;
DO $$ BEGIN
    PERFORM fn_borrar_mensaje(current_setting('t.bruno')::bigint, current_setting('t.m1')::bigint);
    RAISE EXCEPTION 'FALLO: Bruno borró mensaje de Ana';
EXCEPTION WHEN SQLSTATE 'CR403' THEN RAISE NOTICE 'OK borrar_mensaje de otro participante => CR403';
END $$;
DO $$ BEGIN
    PERFORM fn_enviar_mensaje(current_setting('t.ana')::bigint, current_setting('t.conv_ab')::bigint, ''::bytea);
    RAISE EXCEPTION 'FALLO: contenido vacío aceptado';
EXCEPTION WHEN SQLSTATE 'CR422' THEN RAISE NOTICE 'OK contenido vacío => CR422';
END $$;
DO $$
DECLARE a bigint := current_setting('t.ana')::bigint; m bigint := current_setting('t.m1')::bigint; n int;
BEGIN
    ASSERT fn_editar_mensaje(a, m, '\x0a0b'::bytea) IS NOT NULL;
    PERFORM fn_borrar_mensaje(a, m);
    SELECT count(*) INTO n FROM fn_listar_mensajes(a, current_setting('t.conv_ab')::bigint, 100) WHERE id_mensaje = m;
    ASSERT n = 0, 'borrado no se lista';
    RAISE NOTICE 'OK autor edita y borra; borrado no aparece';
END $$;
DO $$ BEGIN
    PERFORM fn_borrar_mensaje(current_setting('t.ana')::bigint, current_setting('t.m1')::bigint);
    RAISE EXCEPTION 'FALLO: doble borrado';
EXCEPTION WHEN SQLSTATE 'CR404' THEN RAISE NOTICE 'OK borrar mensaje ya borrado => CR404';
END $$;

-- ---------------------------------------------------------------- bloqueo
SELECT fn_bloquear_usuario(current_setting('t.bruno')::bigint, current_setting('t.ana')::bigint);
DO $$ BEGIN
    PERFORM fn_enviar_mensaje(current_setting('t.ana')::bigint, current_setting('t.conv_ab')::bigint, '\x01'::bytea);
    RAISE EXCEPTION 'FALLO: envío a quien me bloqueó';
EXCEPTION WHEN SQLSTATE 'CR403' THEN RAISE NOTICE 'OK bloqueo => enviar CR403';
END $$;
SELECT fn_desbloquear_usuario(current_setting('t.bruno')::bigint, current_setting('t.ana')::bigint);

-- ---------------------------------------------------------------- sesiones
DO $$
DECLARE a bigint := current_setting('t.ana')::bigint;
        j1 uuid := gen_random_uuid(); j2 uuid := gen_random_uuid(); h text;
BEGIN
    PERFORM fn_crear_sesion(a, j1, now() + interval '7 days', 'pruebas');
    PERFORM fn_rotar_sesion(a, j1, j2, now() + interval '7 days');
    BEGIN
        PERFORM fn_rotar_sesion(a, j1, gen_random_uuid(), now() + interval '7 days');
        RAISE EXCEPTION 'FALLO: reutilización de refresh aceptada';
    EXCEPTION WHEN SQLSTATE 'CR401' THEN
        GET STACKED DIAGNOSTICS h = PG_EXCEPTION_HINT;
        ASSERT h = 'reutilizacion', 'hint de reutilización';
    END;
    BEGIN   -- IDOR: Bruno intenta rotar el refresh vigente de Ana
        PERFORM fn_rotar_sesion(current_setting('t.bruno')::bigint, j2, gen_random_uuid(), now() + interval '7 days');
        RAISE EXCEPTION 'FALLO IDOR: Bruno rotó sesión de Ana';
    EXCEPTION WHEN SQLSTATE 'CR401' THEN NULL;
    END;
    ASSERT fn_revocar_sesiones(a) = 1, 'solo j2 seguía activa';
    RAISE NOTICE 'OK sesiones: rotación, detección de reutilización, IDOR, revocación';
END $$;

-- ---------------------------------------------------------------- baja / reactivación
DO $$
DECLARE c bigint := current_setting('t.carla')::bigint; e boolean;
BEGIN
    PERFORM fn_borrar_usuario(c);
    SELECT eliminado INTO e FROM fn_credenciales_login('carla@demo.crchat.local');
    ASSERT e, 'login reporta eliminado';
    BEGIN
        PERFORM fn_listar_conversaciones(c);
        RAISE EXCEPTION 'FALLO: usuario borrado opera';
    EXCEPTION WHEN SQLSTATE 'CR401' THEN NULL;
    END;
    PERFORM fn_reactivar_usuario(c);
    SELECT eliminado INTO e FROM fn_credenciales_login('+50670000003');
    ASSERT NOT e;
    RAISE NOTICE 'OK baja lógica => CR401; reactivación';
END $$;

-- ---------------------------------------------------------------- privilegios de app_rw
DO $$ BEGIN
    DELETE FROM usuario;
    RAISE EXCEPTION 'FALLO: app_rw puede borrar usuarios';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK app_rw sin DELETE en usuario';
END $$;
DO $$ BEGIN
    EXECUTE 'TRUNCATE mensaje';
    RAISE EXCEPTION 'FALLO: app_rw puede TRUNCATE';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK app_rw sin TRUNCATE';
END $$;
DO $$ BEGIN
    EXECUTE 'CREATE TABLE intrusa (x int)';
    RAISE EXCEPTION 'FALLO: app_rw puede crear tablas';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK app_rw sin DDL en public';
END $$;
DO $$ BEGIN
    PERFORM fn_crear_particiones_auditoria(1);
    RAISE EXCEPTION 'FALLO: app_rw ejecuta mantenimiento';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK app_rw sin EXECUTE en mantenimiento';
END $$;
DO $$ BEGIN
    PERFORM count(*) FROM auditoria;
    RAISE EXCEPTION 'FALLO: app_rw lee auditoría';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK app_rw no lee auditoría (solo INSERT)';
END $$;

\echo 'PRUEBAS app_rw: TODAS OK'
