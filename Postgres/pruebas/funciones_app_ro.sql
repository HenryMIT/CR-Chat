-- =============================================================================
-- Pruebas del rol de lectura (CONECTADO COMO app_ro; funciones v1, 001-004).
-- Pensadas para correr EN UNA RÉPLICA (haproxy:5001, hot standby): no crean
-- objetos (ni siquiera en pg_temp), solo un bloque DO con los casos en una tabla
-- VALUES. Cada caso imprime "OK ..." o aborta con "FALLO ...".
--   psql -h haproxy -p 5001 -U app_ro -d cr_chat -v ON_ERROR_STOP=1 -f Postgres/pruebas/funciones_app_ro.sql
-- Requiere el seed de demo (Postgres/seed/demo.sql).
-- =============================================================================
\set ON_ERROR_STOP on
\set QUIET on
\pset tuples_only on
\pset format unaligned

SELECT public_id AS ana FROM usuario WHERE telefono = '+50670000001' \gset
SELECT public_id AS bruno FROM usuario WHERE telefono = '+50670000002' \gset
SELECT id AS conv FROM fn_listar_conversaciones(:'ana') LIMIT 1 \gset
SELECT id AS cto FROM fn_listar_contactos(:'ana') LIMIT 1 \gset
-- Variables de psql -> GUC de sesión (set_config funciona en réplicas).
SELECT set_config('prueba.ana', :'ana', false), set_config('prueba.bruno', :'bruno', false),
       set_config('prueba.conv', :'conv', false), set_config('prueba.cto', :'cto', false) \g /dev/null

-- %1$L = ana, %2$L = bruno, %3$L = conversación, %4$L = contacto.
-- estado NULL: la consulta debe devolver true. estado 'X|Y': debe fallar con ese SQLSTATE.
DO $$
DECLARE
    c record; v_ok boolean; e text; m text; v_fallo text;
    a text := current_setting('prueba.ana');  b text := current_setting('prueba.bruno');
    cv text := current_setting('prueba.conv'); ct text := current_setting('prueba.cto');
BEGIN
    FOR c IN SELECT * FROM (VALUES
        -- Funciones de lectura disponibles en réplicas
        ('SELECT count(*) = 1 FROM fn_leer_perfil(%1$L)', NULL, 'app_ro: fn_leer_perfil'),
        ('SELECT count(*) = 1 FROM fn_perfil_publico(%1$L, %2$L)', NULL, 'app_ro: fn_perfil_publico'),
        ('SELECT count(*) >= 2 FROM fn_listar_contactos(%1$L)', NULL, 'app_ro: fn_listar_contactos'),
        ('SELECT count(*) = 1 FROM fn_obtener_contacto(%1$L, %4$L)', NULL, 'app_ro: fn_obtener_contacto'),
        ('SELECT count(*) >= 0 FROM fn_listar_bloqueos(%1$L)', NULL, 'app_ro: fn_listar_bloqueos'),
        ('SELECT count(*) >= 1 FROM fn_listar_conversaciones(%1$L)', NULL, 'app_ro: fn_listar_conversaciones'),
        ('SELECT count(*) = 1 FROM fn_obtener_conversacion(%1$L, %3$L)', NULL, 'app_ro: fn_obtener_conversacion'),
        ('SELECT bool_and(contacto_alias IS NOT NULL) FROM fn_listar_conversaciones(%1$L)', NULL, 'app_ro: contacto_alias en el listado'),
        ('SELECT count(*) = 2 FROM fn_participantes_conversacion(%1$L, %3$L)', NULL, 'app_ro: fn_participantes_conversacion'),
        ('SELECT count(*) >= 0 FROM fn_listar_mensajes(%1$L, %3$L, 10)', NULL, 'app_ro: fn_listar_mensajes'),
        ('SELECT count(*) >= 1 FROM fn_filtrar_relacionados(%1$L, ARRAY[%2$L]::uuid[])', NULL, 'app_ro: fn_filtrar_relacionados'),
        ('SELECT count(*) >= 1 FROM fn_listar_relacionados(%1$L)', NULL, 'app_ro: fn_listar_relacionados'),
        ('SELECT * FROM fn_obtener_media(%1$L, gen_random_uuid())', 'CR404', 'app_ro: fn_obtener_media (inexistente)'),
        -- Lo que app_ro NO puede hacer
        ('SELECT pass_hash FROM usuario LIMIT 1', '42501', 'app_ro no lee pass_hash'),
        ($q$SELECT * FROM fn_credenciales_login('+50670000001')$q$, '42501', 'app_ro sin fn_credenciales_login'),
        ($q$SELECT * FROM fn_enviar_mensaje(%1$L, %3$L, '\x01'::bytea)$q$, '42501', 'app_ro sin funciones de escritura'),
        ('SELECT * FROM fn_listar_sesiones(%1$L, NULL)', '42501', 'app_ro sin funciones de sesión'),
        ('SELECT * FROM fn_crear_contacto_usuario(%1$L, %2$L)', '42501', 'app_ro sin fn_crear_contacto_usuario'),
        ('SELECT * FROM fn_listar_media_huerfana()', '42501', 'app_ro sin el job de media'),
        -- 42501 sin privilegio; 25006 en una réplica o transacción de solo lectura
        ($q$UPDATE contacto SET alias = 'x'$q$, '42501|25006', 'app_ro no escribe'),
        ('SELECT count(*) FROM sesion', '42501', 'app_ro no lee sesion'),
        ('SELECT count(*) FROM sesion_refresh', '42501', 'app_ro no lee sesion_refresh')
    ) AS t(consulta, estado, caso) LOOP
        v_fallo := NULL;
        IF c.estado IS NULL THEN
            EXECUTE format(c.consulta, a, b, cv, ct) INTO v_ok;
            IF v_ok IS NOT TRUE THEN v_fallo := 'condición falsa'; END IF;
        ELSE
            BEGIN
                EXECUTE format(c.consulta, a, b, cv, ct);
                v_fallo := 'no hubo error';
            EXCEPTION WHEN OTHERS THEN   -- solo en pruebas
                GET STACKED DIAGNOSTICS e = RETURNED_SQLSTATE, m = MESSAGE_TEXT;
                IF e <> ALL (string_to_array(c.estado, '|')) THEN
                    v_fallo := format('esperado %s, obtenido %s: %s', c.estado, e, m);
                END IF;
            END;
        END IF;
        IF v_fallo IS NOT NULL THEN
            RAISE EXCEPTION 'FALLO %: %', c.caso, v_fallo;
        END IF;
        RAISE NOTICE 'OK %', c.caso || coalesce(' => ' || c.estado, '');
    END LOOP;
END
$$;
\echo 'PRUEBAS app_ro: TODAS OK'
