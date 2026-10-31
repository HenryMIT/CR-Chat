-- =============================================================================
-- Seed de DEMO de CR_Chat (NO usar en producción). Requiere migraciones 001-004.
-- Contraseñas en texto plano documentadas en docs/db/README.md; aquí solo están
-- los hashes argon2id generados con PHP 8.4 (password_hash(..., PASSWORD_ARGON2ID)).
-- No se insertan mensajes ni avatares:
--  * el contenido va cifrado por la API con una clave que la BD no conoce;
--  * un avatar exige un objeto real en MinIO (subida prefirmada por la API).
-- Idempotente: si ya existe el usuario demo de Ana no hace nada.
-- Ejecutar con un rol que pueda ejecutar las funciones (superusuario, migrator o app_rw).
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE
    v_ana uuid; v_bruno uuid; v_carla uuid;
    v_c uuid;
BEGIN
    IF EXISTS (SELECT 1 FROM usuario WHERE telefono = '+50670000001') THEN
        RAISE NOTICE 'seed demo ya aplicado; se omite';
        RETURN;
    END IF;

    v_ana := fn_registrar_usuario('Ana Demo', '+50670000001', 'ana@demo.crchat.local',
        '$argon2id$v=19$m=65536,t=4,p=1$Yngyd2hjbS84cWZJS0doSg$GoDVJCT/yLeifHpbOJaYvi7SEtvLqQ+FbkPKQTPzqEg');
    v_bruno := fn_registrar_usuario('Bruno Demo', '+50670000002', 'bruno@demo.crchat.local',
        '$argon2id$v=19$m=65536,t=4,p=1$ZFl2cncvQXJybXdEVHpVQg$inb19X02cjwB8Ud4SesgVQFWulaFh0dOX8Dxny28B6M');
    v_carla := fn_registrar_usuario('Carla Demo', '+50670000003', 'carla@demo.crchat.local',
        '$argon2id$v=19$m=65536,t=4,p=1$VU5NcnREM1VoaU1WcFFwSg$RhDo2lVWUR9ybUplCCBqrZ+9BuPsRNCv8cMa48ITw74');

    PERFORM fn_actualizar_usuario(v_ana, p_descripcion => 'Probando CR_Chat');

    -- Contactos y conversaciones
    SELECT id INTO v_c FROM fn_crear_contacto(v_ana, '+50670000002', 'Bruno');
    PERFORM fn_crear_conversacion(v_ana, v_c);            -- conversación Ana <-> Bruno
    SELECT id INTO v_c FROM fn_crear_contacto(v_ana, '+50670000003', 'Carla (trabajo)');
    PERFORM fn_crear_conversacion(v_ana, v_c);            -- conversación Ana <-> Carla
    PERFORM fn_crear_contacto(v_bruno, '+50670000001', 'Ana');
    PERFORM fn_crear_contacto(v_carla, '+50670000002', NULL);   -- sin alias: se muestra "Bruno Demo"
    -- Carla no tiene a Ana en su agenda: la conversación le aparece con
    -- es_contacto = false (solicitud de mensaje, U-06).
END
$$;
COMMIT;
