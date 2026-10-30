-- migrate:up
-- =============================================================================
-- 001 - Roles y extensiones (bootstrap).
-- Esta es la ÚNICA migración que necesita un superusuario: crea roles a nivel de
-- clúster y extensiones. Las siguientes migraciones hacen `SET LOCAL ROLE migrator`
-- para que todos los objetos queden con dueño `migrator` (nunca `postgres`).
--
-- Contraseñas: NO hay ninguna en el repositorio. Los roles se crean NOLOGIN y se
-- habilitan al desplegar con Postgres/bootstrap/asignar-credenciales.sql, que toma
-- las contraseñas de variables de entorno (ver docs/db/README.md).
-- =============================================================================

-- Extensiones -----------------------------------------------------------------
-- citext: email sin distinción de mayúsculas con UNIQUE real.
CREATE EXTENSION IF NOT EXISTS citext;
-- pg_trgm: búsqueda ILIKE '%texto%' en alias de contacto con índice GIN.
CREATE EXTENSION IF NOT EXISTS pg_trgm;
-- pg_stat_statements: el objeto se crea aquí; para que recolecte datos el servidor
-- debe tener shared_preload_libraries = 'pg_stat_statements' (se configura en Fase 2).
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Roles -----------------------------------------------------------------------
DO $$
BEGIN
    -- Dueño del esquema y de todas las migraciones posteriores (DDL).
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'migrator') THEN
        CREATE ROLE migrator NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
    END IF;
    -- API (escritura, vía haproxy:5000): solo DML mínimo + EXECUTE de funciones.
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw') THEN
        CREATE ROLE app_rw NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
    END IF;
    -- API (lectura, vía haproxy:5001 / réplicas): SELECT sin pass_hash + funciones de lectura.
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_ro') THEN
        CREATE ROLE app_ro NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
    END IF;
END
$$;

-- Nadie fuera de los roles explícitos puede crear objetos en public (PG15+ ya lo hace,
-- se deja explícito por si la BD viene de una versión anterior).
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO migrator;
GRANT USAGE ON SCHEMA public TO app_rw, app_ro;

-- migrator debe poder registrar migraciones cuando dbmate se conecte con ese rol.
DO $$
BEGIN
    IF to_regclass('public.schema_migrations') IS NOT NULL THEN
        EXECUTE 'GRANT SELECT, INSERT, DELETE ON public.schema_migrations TO migrator';
    END IF;
END
$$;

-- Ninguna función nueva de migrator será ejecutable por PUBLIC por defecto.
ALTER DEFAULT PRIVILEGES FOR ROLE migrator REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- Límites defensivos para la app (no bloquean conexiones colgadas ni consultas largas).
ALTER ROLE app_rw SET statement_timeout = '5s';
ALTER ROLE app_rw SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE app_ro SET statement_timeout = '5s';
ALTER ROLE app_ro SET default_transaction_read_only = on;

-- migrate:down
-- DROP OWNED elimina los privilegios y default ACL de los roles en ESTA base de datos.
-- Si los roles tienen privilegios en otra base del clúster, DROP ROLE fallará (a propósito).
DROP OWNED BY app_ro, app_rw, migrator;
DROP ROLE IF EXISTS app_ro;
DROP ROLE IF EXISTS app_rw;
DROP ROLE IF EXISTS migrator;
DROP EXTENSION IF EXISTS pg_stat_statements;
DROP EXTENSION IF EXISTS pg_trgm;
DROP EXTENSION IF EXISTS citext;
