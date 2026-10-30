-- =============================================================================
-- Pruebas del rol de lectura (CONECTADO COMO app_ro; funciones v1, 001-005).
--   psql -U app_ro -d cr_chat -v ON_ERROR_STOP=1 -f Postgres/pruebas/funciones_app_ro.sql
-- =============================================================================
\set ON_ERROR_STOP on
\set QUIET on
\pset tuples_only on
\pset format unaligned
-- Las funciones auxiliares de prueba van en pg_temp, que exige una transacción de
-- escritura. default_transaction_read_only es solo un valor por defecto del rol: la
-- protección real de app_ro son sus privilegios (y que las réplicas son de solo lectura).
SET default_transaction_read_only = off;

CREATE FUNCTION pg_temp.espera(p_sql text, p_estado text, p_caso text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE e text; m text;
BEGIN
    EXECUTE p_sql;
    RAISE EXCEPTION USING ERRCODE = 'XX999', MESSAGE = 'no hubo error';
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS e = RETURNED_SQLSTATE, m = MESSAGE_TEXT;
    IF e <> ALL (string_to_array(p_estado, '|')) THEN
        RAISE EXCEPTION 'FALLO %: esperado %, obtenido %: %', p_caso, p_estado, e, m;
    END IF;
    RAISE NOTICE 'OK % => %', p_caso, e;
END $$;
CREATE FUNCTION pg_temp.ok(p_cond boolean, p_caso text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_cond IS NOT TRUE THEN RAISE EXCEPTION 'FALLO %', p_caso; END IF;
    RAISE NOTICE 'OK %', p_caso;
END $$;

SET default_transaction_read_only = on;

SELECT public_id AS ana FROM usuario WHERE telefono = '+50670000001' \gset
SELECT public_id AS bruno FROM usuario WHERE telefono = '+50670000002' \gset
SELECT id AS conv FROM fn_listar_conversaciones(:'ana') LIMIT 1 \gset
SELECT id AS cto FROM fn_listar_contactos(:'ana') LIMIT 1 \gset

-- Funciones de lectura disponibles en réplicas
SELECT pg_temp.ok((SELECT count(*) = 1 FROM fn_leer_perfil(:'ana')), 'app_ro: fn_leer_perfil');
SELECT pg_temp.ok((SELECT count(*) = 1 FROM fn_perfil_publico(:'ana', :'bruno')), 'app_ro: fn_perfil_publico');
SELECT pg_temp.ok((SELECT count(*) >= 2 FROM fn_listar_contactos(:'ana')), 'app_ro: fn_listar_contactos');
SELECT pg_temp.ok((SELECT count(*) = 1 FROM fn_obtener_contacto(:'ana', :'cto')), 'app_ro: fn_obtener_contacto');
SELECT pg_temp.ok((SELECT count(*) >= 0 FROM fn_listar_bloqueos(:'ana')), 'app_ro: fn_listar_bloqueos');
SELECT pg_temp.ok((SELECT count(*) >= 1 FROM fn_listar_conversaciones(:'ana')), 'app_ro: fn_listar_conversaciones');
SELECT pg_temp.ok((SELECT count(*) = 1 FROM fn_obtener_conversacion(:'ana', :'conv')), 'app_ro: fn_obtener_conversacion');
SELECT pg_temp.ok((SELECT count(*) = 2 FROM fn_participantes_conversacion(:'ana', :'conv')), 'app_ro: fn_participantes_conversacion');
SELECT pg_temp.ok((SELECT count(*) >= 0 FROM fn_listar_mensajes(:'ana', :'conv', 10)), 'app_ro: fn_listar_mensajes');
SELECT pg_temp.ok((SELECT count(*) >= 1 FROM fn_filtrar_relacionados(:'ana', ARRAY[:'bruno']::uuid[])), 'app_ro: fn_filtrar_relacionados');
SELECT pg_temp.ok((SELECT count(*) >= 1 FROM fn_listar_relacionados(:'ana')), 'app_ro: fn_listar_relacionados');
SELECT pg_temp.espera(format('SELECT * FROM fn_obtener_media(%L, %L)', :'ana', gen_random_uuid()), 'CR404', 'app_ro: fn_obtener_media (inexistente)');

-- Lo que app_ro NO puede hacer
SELECT pg_temp.espera('SELECT pass_hash FROM usuario LIMIT 1', '42501', 'app_ro no lee pass_hash');
SELECT pg_temp.espera($$SELECT * FROM fn_credenciales_login('+50670000001')$$, '42501', 'app_ro sin fn_credenciales_login');
SELECT pg_temp.espera(format('SELECT * FROM fn_enviar_mensaje(%L, %L, %L::bytea)', :'ana', :'conv', '\x01'), '42501', 'app_ro sin funciones de escritura');
SELECT pg_temp.espera(format('SELECT * FROM fn_listar_sesiones(%L, NULL)', :'ana'), '42501', 'app_ro sin funciones de sesión');
SELECT pg_temp.espera('SELECT * FROM fn_listar_media_huerfana()', '42501', 'app_ro sin el job de media');
SELECT pg_temp.espera($$UPDATE contacto SET alias = 'x'$$, '42501|25006', 'app_ro no escribe');
SELECT pg_temp.espera('SELECT count(*) FROM sesion', '42501', 'app_ro no lee sesion');
SELECT pg_temp.espera('SELECT count(*) FROM sesion_refresh', '42501', 'app_ro no lee sesion_refresh');
\echo 'PRUEBAS app_ro: TODAS OK'
