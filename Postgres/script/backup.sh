#!/bin/bash
# Respaldo lógico comprimido; conserva los 7 más recientes.
# Usa el socket local (confianza en pg_hba), así que no necesita contraseña.
source /etc/backup.env

BACKUP_DIR="/backup"
ARCHIVO="$BACKUP_DIR/pg_$(date +%F_%H%M).sql.gz"

set -o pipefail
if pg_dump --clean --if-exists -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip > "$ARCHIVO"; then
    echo "Backup realizado: $ARCHIVO"
else
    echo "Error al realizar el backup" >&2
    rm -f "$ARCHIVO"
    exit 1
fi

ls -1t "$BACKUP_DIR"/pg_*.sql.gz | tail -n +8 | xargs -r rm --
