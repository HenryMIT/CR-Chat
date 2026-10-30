#!/bin/bash
# Uso: restore.sh /backup/mysql_AAAA-MM-DD_HHMM.sql.gz
source /etc/backup.env

ARCHIVO="$1"
if [ ! -f "$ARCHIVO" ]; then
    echo "Uso: restore.sh <archivo .sql.gz>" >&2
    ls -1t /backup/mysql_*.sql.gz 2>/dev/null | head -7 >&2
    exit 1
fi

set -o pipefail
mysql -e "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\`;"
if gunzip < "$ARCHIVO" | mysql "$MYSQL_DATABASE"; then
    echo "Restauración exitosa"
else
    echo "Error en la restauración" >&2
    exit 1
fi
