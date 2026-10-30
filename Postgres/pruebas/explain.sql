-- Captura los planes internos de las funciones con auto_explain (superusuario,
-- tras volumen.sql). Ver docs/db/optimizacion.md.
\set ON_ERROR_STOP on
SELECT public_id AS ana   FROM usuario WHERE id = 1 \gset
SELECT public_id AS bruno FROM usuario WHERE id = 2 \gset
SELECT public_id AS u5000 FROM usuario WHERE id = 5000 \gset
SELECT public_id AS conv  FROM conversacion WHERE id = 1 \gset
-- Cursor a ~150 000 mensajes de profundidad en la conversación pesada.
SELECT public_id AS profundo FROM mensaje WHERE id_conversacion = 1 ORDER BY created_at DESC, id DESC OFFSET 150000 LIMIT 1 \gset
SELECT public_id AS reciente FROM mensaje WHERE id_conversacion = 1 ORDER BY created_at DESC, id DESC OFFSET 40 LIMIT 1 \gset
-- Conversación normal de u5000 con su último mensaje.
SELECT cv.public_id AS conv5000, m.public_id AS ult5000
FROM participante p JOIN conversacion cv ON cv.id = p.id_conversacion
JOIN LATERAL (SELECT x.public_id FROM mensaje x WHERE x.id_conversacion = cv.id
              ORDER BY x.created_at DESC, x.id DESC LIMIT 1) m ON true
WHERE p.id_usuario = 5000 LIMIT 1 \gset
LOAD 'auto_explain';
SET auto_explain.log_min_duration = 0;
SET auto_explain.log_analyze = on;
SET auto_explain.log_buffers = on;
SET auto_explain.log_nested_statements = on;
SET client_min_messages = log;
\echo ===== Q1 credenciales_login
SELECT count(*) FROM fn_credenciales_login('ana@demo.crchat.local');
\echo ===== Q2 listar_contactos busqueda
SELECT count(*) FROM fn_listar_contactos(:'u5000', 'alias 3', 30);
\echo ===== Q3 listar_conversaciones (last_message + unread_count)
SELECT count(*) FROM fn_listar_conversaciones(:'ana', 50);
\echo ===== Q4 listar_mensajes pagina 1
SELECT count(*) FROM fn_listar_mensajes(:'ana', :'conv', 50);
\echo ===== Q5 listar_mensajes before profundo
SELECT count(*) FROM fn_listar_mensajes(:'ana', :'conv', 50, :'profundo');
\echo ===== Q6 listar_mensajes after (resincronizacion)
SELECT count(*) FROM fn_listar_mensajes(:'ana', :'conv', 50, NULL, :'reciente');
\echo ===== Q7a marcar_recibos seen caso típico (conversación normal, pocos pendientes)
BEGIN;
SELECT * FROM fn_marcar_recibos(:'u5000', :'conv5000', 'seen', :'ult5000');
ROLLBACK;
\echo ===== Q7b marcar_recibos seen patológico (~66 000 recibos pendientes)
BEGIN;
SELECT * FROM fn_marcar_recibos(:'bruno', :'conv', 'seen', :'reciente');
ROLLBACK;
\echo ===== Q8 perfil_publico
SELECT count(*) FROM fn_perfil_publico(:'ana', :'bruno');
\echo ===== Q9 listar_relacionados
SELECT count(*) FROM fn_listar_relacionados(:'ana');
