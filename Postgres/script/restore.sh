#!/bin/bash
# Uso: restore.sh /backup/pg_AAAA-MM-DD_HHMM.sql.gz
source /etc/backup.env

ARCHIVO="$1"
if [ ! -f "$ARCHIVO" ]; then
    echo "Uso: restore.sh <archivo .sql.gz>" >&2
    ls -1t /backup/pg_*.sql.gz 2>/dev/null | head -7 >&2
    exit 1
fi

set -o pipefail
if gunzip < "$ARCHIVO" | psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"; then
    echo "Restauración exitosa"
else
    echo "Error en la restauración" >&2
    exit 1
fi
