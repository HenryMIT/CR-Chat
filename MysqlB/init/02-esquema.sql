-- =============================================================================
-- Esquema destino de la réplica MySQL (SOLO LECTURA) alimentada por CDC.
-- Fuente de verdad: PostgreSQL (Postgres/migraciones). Lo escribe únicamente el
-- Debezium JDBC sink (usuario crchat_sink, schema.evolution=none): si una
-- migración agrega columnas publicadas, hay que agregarlas aquí también.
--
-- Decisiones:
--  * Mismos nombres de tabla/columna que en PostgreSQL; PK = clave del evento.
--  * SIN claves foráneas ni UNIQUE de negocio (teléfono, email, par de contactos):
--    el sink aplica cada tabla por separado (un tópico por tabla), así que el
--    orden entre tablas no está garantizado y una FK o un UNIQUE transitorio
--    detendría la réplica. La integridad la garantiza PostgreSQL. Solo
--    public_id (inmutable) es UNIQUE.
--  * timestamptz -> DATETIME(6) en UTC (el sink usa use.time.zone=UTC).
--  * uuid -> CHAR(36); bytea -> VARBINARY/MEDIUMBLOB (contenido cifrado tal cual).
--  * No se replican pass_hash, sesion, sesion_refresh ni auditoria.
--  * Índices para las lecturas típicas (listados por usuario/conversación).
-- =============================================================================
USE crchat;

CREATE TABLE IF NOT EXISTS usuario (
    id               BIGINT        NOT NULL,
    public_id        CHAR(36)      NOT NULL,
    nombre_usuario   VARCHAR(100)  NOT NULL,
    telefono         VARCHAR(16)   NOT NULL,
    email            VARCHAR(254)  NOT NULL,
    descripcion      VARCHAR(140)  NULL,
    avatar_media_id  BIGINT        NULL,
    last_seen_at     DATETIME(6)   NULL,
    created_at       DATETIME(6)   NOT NULL,
    updated_at       DATETIME(6)   NOT NULL,
    deleted_at       DATETIME(6)   NULL,
    PRIMARY KEY (id),
    UNIQUE KEY usuario_public_id_uq (public_id),
    KEY usuario_telefono_ix (telefono),
    KEY usuario_email_ix (email)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS media (
    id             BIGINT        NOT NULL,
    public_id      CHAR(36)      NOT NULL,
    id_dueno       BIGINT        NOT NULL,
    proposito      VARCHAR(20)   NOT NULL,
    bucket         VARCHAR(63)   NOT NULL,
    clave_objeto   VARCHAR(512)  NOT NULL,
    mime           VARCHAR(100)  NOT NULL,
    tamano_bytes   BIGINT        NOT NULL,
    ancho          INT           NULL,
    alto           INT           NULL,
    estado         VARCHAR(20)   NOT NULL,
    created_at     DATETIME(6)   NOT NULL,
    confirmado_at  DATETIME(6)   NULL,
    borrado_at     DATETIME(6)   NULL,
    PRIMARY KEY (id),
    UNIQUE KEY media_public_id_uq (public_id),
    KEY media_id_dueno_ix (id_dueno, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS contacto (
    id               BIGINT        NOT NULL,
    id_usuario       BIGINT        NOT NULL,
    contact_user_id  BIGINT        NOT NULL,
    alias            VARCHAR(50)   NULL,
    created_at       DATETIME(6)   NOT NULL,
    updated_at       DATETIME(6)   NOT NULL,
    deleted_at       DATETIME(6)   NULL,
    public_id        CHAR(36)      NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY contacto_public_id_uq (public_id),
    KEY contacto_par_ix (id_usuario, contact_user_id),
    KEY contacto_contact_user_id_ix (contact_user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS bloqueo (
    id_usuario    BIGINT       NOT NULL,
    id_bloqueado  BIGINT       NOT NULL,
    created_at    DATETIME(6)  NOT NULL,
    PRIMARY KEY (id_usuario, id_bloqueado),
    KEY bloqueo_id_bloqueado_ix (id_bloqueado)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS conversacion (
    id                 BIGINT       NOT NULL,
    tipo               VARCHAR(20)  NOT NULL,
    id_usuario_menor   BIGINT       NOT NULL,
    id_usuario_mayor   BIGINT       NOT NULL,
    created_at         DATETIME(6)  NOT NULL,
    ultimo_mensaje_at  DATETIME(6)  NOT NULL,
    public_id          CHAR(36)     NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY conversacion_public_id_uq (public_id),
    KEY conversacion_par_ix (id_usuario_menor, id_usuario_mayor),
    KEY conversacion_id_usuario_mayor_ix (id_usuario_mayor)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS participante (
    id_conversacion  BIGINT       NOT NULL,
    id_usuario       BIGINT       NOT NULL,
    unido_at         DATETIME(6)  NOT NULL,
    PRIMARY KEY (id_conversacion, id_usuario),
    KEY participante_id_usuario_ix (id_usuario, id_conversacion)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS mensaje (
    id               BIGINT         NOT NULL,
    id_conversacion  BIGINT         NOT NULL,
    id_remitente     BIGINT         NOT NULL,
    contenido        MEDIUMBLOB     NULL,       -- ciphertext+tag (hasta 64 KiB), tal cual
    created_at       DATETIME(6)    NOT NULL,
    editado_at       DATETIME(6)    NULL,
    deleted_at       DATETIME(6)    NULL,
    public_id        CHAR(36)       NOT NULL,
    nonce            VARBINARY(24)  NULL,
    key_id           SMALLINT       NULL,
    client_id        CHAR(36)       NULL,
    id_media         BIGINT         NULL,
    PRIMARY KEY (id),
    UNIQUE KEY mensaje_public_id_uq (public_id),
    KEY mensaje_cursor_ix (id_conversacion, created_at, id),
    KEY mensaje_id_remitente_ix (id_remitente)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS recibo_mensaje (
    id_mensaje       BIGINT       NOT NULL,
    id_conversacion  BIGINT       NOT NULL,
    id_usuario       BIGINT       NOT NULL,
    entregado_at     DATETIME(6)  NULL,
    visto_at         DATETIME(6)  NULL,
    PRIMARY KEY (id_mensaje, id_usuario),
    KEY recibo_usuario_conv_ix (id_usuario, id_conversacion, id_mensaje)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
