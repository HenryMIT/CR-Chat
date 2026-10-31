#!/bin/bash
# =============================================================================
# Usuarios de la réplica MySQL (se ejecuta solo al crear el volumen de datos):
#   crchat_sink     Debezium JDBC sink: DDL/DML SOLO sobre la base crchat.
#   crchat_lectura  usuario de la app / reportes: SOLO SELECT.
# Contraseñas desde variables (MYSQL_SINK_PASSWORD, MYSQL_READER_PASSWORD).
# =============================================================================
set -euo pipefail
: "${MYSQL_SINK_PASSWORD:?}" "${MYSQL_READER_PASSWORD:?}"
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL
CREATE USER IF NOT EXISTS 'crchat_sink'@'%' IDENTIFIED BY '${MYSQL_SINK_PASSWORD}';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP ON crchat.* TO 'crchat_sink'@'%';
CREATE USER IF NOT EXISTS 'crchat_lectura'@'%' IDENTIFIED BY '${MYSQL_READER_PASSWORD}';
GRANT SELECT ON crchat.* TO 'crchat_lectura'@'%';
FLUSH PRIVILEGES;
SQL
echo "mysql-init: usuarios crchat_sink y crchat_lectura listos"
