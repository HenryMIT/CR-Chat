-- =============================================================================
-- Pruebas del rol de lectura (ejecutar CONECTADO COMO app_ro).
--   psql -U app_ro -d cr_chat -v ON_ERROR_STOP=1 -f Postgres/pruebas/funciones_app_ro.sql
-- =============================================================================
\set ON_ERROR_STOP on
\set QUIET on
SELECT id AS ana FROM usuario WHERE telefono = '+50670000001' \gset
SELECT set_config('t.ana', :'ana', false) AS _ \gset

DO $$
DECLARE n int; a bigint := current_setting('t.ana')::bigint; cv bigint;
BEGIN
    SELECT count(*) INTO n FROM fn_leer_perfil(a);                ASSERT n = 1;
    SELECT count(*) INTO n FROM fn_listar_contactos(a);           ASSERT n >= 2;
    SELECT id_conversacion INTO cv FROM fn_listar_conversaciones(a) LIMIT 1;
    SELECT count(*) INTO n FROM fn_listar_mensajes(a, cv, 10);
    RAISE NOTICE 'OK app_ro ejecuta las 4 funciones de lectura';
END $$;
DO $$ BEGIN
    PERFORM pass_hash FROM usuario LIMIT 1;
    RAISE EXCEPTION 'FALLO: app_ro lee pass_hash';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK app_ro no puede leer pass_hash';
END $$;
DO $$ BEGIN
    PERFORM * FROM fn_credenciales_login('+50670000001');
    RAISE EXCEPTION 'FALLO: app_ro ejecuta credenciales_login';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK app_ro sin EXECUTE en fn_credenciales_login';
END $$;
DO $$ BEGIN
    PERFORM fn_enviar_mensaje(current_setting('t.ana')::bigint, 1, '\x01'::bytea);
    RAISE EXCEPTION 'FALLO: app_ro ejecuta escritura';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK app_ro sin EXECUTE en funciones de escritura';
END $$;
DO $$ BEGIN
    UPDATE contacto SET alias = 'x';
    RAISE EXCEPTION 'FALLO: app_ro escribe';
EXCEPTION WHEN insufficient_privilege OR read_only_sql_transaction THEN RAISE NOTICE 'OK app_ro no escribe';
END $$;
DO $$ BEGIN
    PERFORM count(*) FROM sesion;
    RAISE EXCEPTION 'FALLO: app_ro lee sesiones';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK app_ro no lee sesiones';
END $$;
\echo 'PRUEBAS app_ro: TODAS OK'
