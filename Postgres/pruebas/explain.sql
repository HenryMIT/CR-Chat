-- Captura los planes internos de las funciones con auto_explain (superusuario). Ver docs/db/optimizacion.md.
LOAD 'auto_explain';
SET auto_explain.log_min_duration = 0;
SET auto_explain.log_analyze = on;
SET auto_explain.log_buffers = on;
SET auto_explain.log_nested_statements = on;
SET client_min_messages = log;
\echo ===== Q1 credenciales_login
SELECT * FROM fn_credenciales_login('ana@demo.crchat.local');
\echo ===== Q2 listar_contactos busqueda
SELECT count(*) FROM fn_listar_contactos(5000, 'alias 3', 30);
\echo ===== Q3 listar_conversaciones
SELECT count(*) FROM fn_listar_conversaciones(1, 30);
\echo ===== Q4 listar_mensajes pagina 1
SELECT count(*) FROM fn_listar_mensajes(1, 1, 30);
\echo ===== Q5 listar_mensajes pagina profunda
SELECT count(*) FROM fn_listar_mensajes(1, 1, 30, now() - interval '150000 seconds', 999999999);
\echo ===== Q6 marcar_visto
BEGIN;
SELECT fn_marcar_visto(2, 1, 1000000000);
ROLLBACK;
