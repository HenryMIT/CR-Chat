-- =============================================================================
-- Habilita LOGIN y asigna contraseñas a los roles creados NOLOGIN por la
-- migración 001. Se ejecuta una vez por despliegue (y al rotar credenciales)
-- con un superusuario; las contraseñas vienen de variables, nunca del repo:
--
--   psql "$SUPERUSER_URL" -v ON_ERROR_STOP=1 \
--        -v migrator_password="$DB_MIGRATOR_PASSWORD" \
--        -v app_rw_password="$DB_APP_RW_PASSWORD" \
--        -v app_ro_password="$DB_APP_RO_PASSWORD" \
--        -f Postgres/bootstrap/asignar-credenciales.sql
-- =============================================================================
\set ON_ERROR_STOP on
SET password_encryption = 'scram-sha-256';
ALTER ROLE migrator LOGIN PASSWORD :'migrator_password' CONNECTION LIMIT 5;
ALTER ROLE app_rw   LOGIN PASSWORD :'app_rw_password'   CONNECTION LIMIT 50;
ALTER ROLE app_ro   LOGIN PASSWORD :'app_ro_password'   CONNECTION LIMIT 50;
-- Los roles solo se conectan a la base de la app.
SELECT format('GRANT CONNECT ON DATABASE %I TO migrator, app_rw, app_ro', current_database()) \gexec
