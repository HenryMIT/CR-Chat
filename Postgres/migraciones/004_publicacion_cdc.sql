-- migrate:up
-- =============================================================================
-- 004 - Publicación lógica para CDC (Debezium -> Kafka -> MySQL de solo lectura).
--
-- Se versiona con el esquema: si una migración futura agrega una columna a una
-- tabla publicada con lista de columnas (usuario), debe actualizarla aquí con
-- ALTER PUBLICATION. Sin consumidor no cuesta nada: el slot lógico solo se crea
-- al activar el profile `cdc` (infra/cdc/init.sh lo registra en Patroni).
--
-- Qué NO se publica (no sale de PostgreSQL):
--  * usuario.pass_hash (lista de columnas), sesion, sesion_refresh, auditoria.
-- mensaje.contenido/nonce se replican tal cual (bytes cifrados por la API).
-- =============================================================================
SET LOCAL ROLE migrator;

CREATE PUBLICATION crchat_cdc FOR TABLE
    usuario (id, public_id, nombre_usuario, telefono, email, descripcion, avatar_media_id,
             last_seen_at, created_at, updated_at, deleted_at),
    media, contacto, bloqueo, conversacion, participante, mensaje, recibo_mensaje
    WITH (publish = 'insert, update, delete, truncate');
COMMENT ON PUBLICATION crchat_cdc IS 'CDC hacia la réplica MySQL de solo lectura (Debezium pgoutput).';

-- El conector necesita SELECT para la instantánea inicial (mismas columnas).
GRANT SELECT (id, public_id, nombre_usuario, telefono, email, descripcion, avatar_media_id,
              last_seen_at, created_at, updated_at, deleted_at) ON usuario TO cdc_lector;
GRANT SELECT ON media, contacto, bloqueo, conversacion, participante, mensaje, recibo_mensaje TO cdc_lector;

-- migrate:down
SET LOCAL ROLE migrator;
REVOKE ALL ON usuario, media, contacto, bloqueo, conversacion, participante, mensaje, recibo_mensaje FROM cdc_lector;
DROP PUBLICATION IF EXISTS crchat_cdc;
