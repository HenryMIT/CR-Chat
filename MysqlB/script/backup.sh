#!/bin/bash
# Respaldo lógico comprimido; conserva los 7 más recientes.
# Credenciales en /root/.my.cnf y variables en /etc/backup.env (los genera el CMD del Dockerfile).
source /etc/backup.env

BACKUP_DIR="/backup"
ARCHIVO="$BACKUP_DIR/mysql_$(date +%F_%H%M).sql.gz"

# Esperar a que MySQL esté listo (máximo 60 segundos)
for i in $(seq 1 12); do
    mysqladmin ping --silent >/dev/null 2>&1 && break
    echo "Esperando a que MySQL inicie... intento $i"
    sleep 5
done

if ! mysqladmin ping --silent >/dev/null 2>&1; then
    echo "MySQL no está disponible. Abortando backup." >&2
    exit 1
fi

set -o pipefail
if mysqldump --single-transaction --routines "$MYSQL_DATABASE" | gzip > "$ARCHIVO"; then
    echo "Backup realizado: $ARCHIVO"
else
    echo "Error al realizar el backup" >&2
    rm -f "$ARCHIVO"
    exit 1
fi

cd "$BACKUP_DIR" || exit 1
ls -1t mysql_*.sql.gz | tail -n +8 | xargs -r rm --
