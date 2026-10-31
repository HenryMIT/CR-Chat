-- =============================================================================
-- Habilita LOGIN y asigna contraseñas a los roles creados NOLOGIN por la
-- migración 001. Se ejecuta en cada despliegue (idempotente; también sirve para
-- rotar credenciales) con un superusuario; las contraseñas vienen de variables,
-- nunca del repo. En docker-compose lo hace el servicio `db-init`:
--
--   psql "$SUPERUSER_URL" -v ON_ERROR_STOP=1 \
--        -v migrator_password="$DB_MIGRATOR_PASSWORD" \
--        -v app_rw_password="$DB_APP_RW_PASSWORD" \
--        -v app_ro_password="$DB_APP_RO_PASSWORD" \
--        [-v cdc_password="$DB_CDC_PASSWORD"] \
--        -f Postgres/bootstrap/asignar-credenciales.sql
--
-- cdc_password es opcional: sin ella cdc_lector queda NOLOGIN (CDC apagado).
-- =============================================================================
\set ON_ERROR_STOP on
SET password_encryption = 'scram-sha-256';
ALTER ROLE migrator LOGIN PASSWORD :'migrator_password' CONNECTION LIMIT 5;
ALTER ROLE app_rw   LOGIN PASSWORD :'app_rw_password'   CONNECTION LIMIT 50;
ALTER ROLE app_ro   LOGIN PASSWORD :'app_ro_password'   CONNECTION LIMIT 50;
\if :{?cdc_password}
ALTER ROLE cdc_lector LOGIN PASSWORD :'cdc_password' CONNECTION LIMIT 3;
SELECT format('GRANT CONNECT ON DATABASE %I TO cdc_lector', current_database()) \gexec
\else
ALTER ROLE cdc_lector NOLOGIN;
\endif
-- Solo los roles explícitos se conectan a la base de la app (y nadie a `postgres`
-- salvo superusuarios).
SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', current_database()) \gexec
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
SELECT format('GRANT CONNECT ON DATABASE %I TO migrator, app_rw, app_ro', current_database()) \gexec
