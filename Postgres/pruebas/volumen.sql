-- Volumen sintético para docs/db/optimizacion.md. SOLO en bases desechables (superusuario, tras migraciones + seed demo).
\set ON_ERROR_STOP on
INSERT INTO usuario (nombre_usuario, telefono, email, pass_hash)
SELECT 'u'||g, '+5068'||lpad(g::text,7,'0'), 'u'||g||'@vol.test', '$argon2id$v=19$x'
FROM generate_series(1,20000) g;
INSERT INTO contacto (id_usuario, contact_user_id, alias)
SELECT u.id, v.id, 'alias '||md5(v.id::text)
FROM usuario u JOIN LATERAL (SELECT id FROM usuario w WHERE w.id <> u.id ORDER BY (w.id * 7919 + u.id) % 20003 LIMIT 10) v ON true
ON CONFLICT DO NOTHING;
INSERT INTO conversacion (id_usuario_menor, id_usuario_mayor)
SELECT DISTINCT least(id_usuario, contact_user_id), greatest(id_usuario, contact_user_id) FROM contacto
ON CONFLICT DO NOTHING;
INSERT INTO participante SELECT id, id_usuario_menor FROM conversacion UNION ALL SELECT id, id_usuario_mayor FROM conversacion ON CONFLICT DO NOTHING;
INSERT INTO mensaje (id_conversacion, id_remitente, contenido, created_at)
SELECT c.id, CASE WHEN g % 2 = 0 THEN c.id_usuario_menor ELSE c.id_usuario_mayor END,
       decode(md5(g::text), 'hex'), now() - make_interval(secs => g * 37 + c.id)
FROM conversacion c CROSS JOIN generate_series(1,5) g;
-- conversación "pesada" Ana <-> Bruno (id 1): 200 000 mensajes
INSERT INTO mensaje (id_conversacion, id_remitente, contenido, created_at)
SELECT 1, CASE WHEN g % 2 = 0 THEN 1 ELSE 2 END, decode(md5(g::text),'hex'), now() - make_interval(secs => g)
FROM generate_series(1,200000) g;
INSERT INTO recibo_mensaje (id_mensaje, id_conversacion, id_usuario, entregado_at, visto_at)
SELECT m.id, m.id_conversacion, p.id_usuario,
       CASE WHEN m.id % 3 = 0 THEN NULL ELSE now() END,
       CASE WHEN m.id % 3 <> 1 THEN NULL ELSE now() END
FROM mensaje m JOIN participante p ON p.id_conversacion = m.id_conversacion AND p.id_usuario <> m.id_remitente
ON CONFLICT DO NOTHING;
UPDATE conversacion c SET ultimo_mensaje_at = s.mx
FROM (SELECT id_conversacion, max(created_at) mx FROM mensaje GROUP BY 1) s WHERE s.id_conversacion = c.id;
VACUUM ANALYZE;
SELECT relname, n_live_tup FROM pg_stat_user_tables WHERE n_live_tup > 100 ORDER BY 2 DESC;
SELECT pg_size_pretty(pg_database_size(current_database())) AS tam_bd;
