#!/bin/sh
# =============================================================================
# Inicialización idempotente de MinIO (servicio `minio-init`, una sola vez):
#   * buckets privados cr-chat-backups (pgBackRest + globales) y cr-chat-media (API)
#   * política y usuario separados para cada uno:
#       cr-chat-backups-rw -> $MINIO_BACKUP_ACCESS_KEY (contenedores pg1/pg2/backup)
#       cr-chat-media-rw   -> $MINIO_API_ACCESS_KEY    (web-datos / ws)
#   * ciclo de vida: globals/ expira a los 30 días.
# El usuario root de MinIO solo lo usa este script.
# =============================================================================
set -eu
: "${MINIO_ROOT_USER:?}" "${MINIO_ROOT_PASSWORD:?}"
: "${MINIO_BACKUP_ACCESS_KEY:?}" "${MINIO_BACKUP_SECRET_KEY:?}"
: "${MINIO_API_ACCESS_KEY:?}" "${MINIO_API_SECRET_KEY:?}"

export MC_CONFIG_DIR=/tmp/mc
i=0
until mc alias set crchat http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -ge 60 ] && { echo "minio-init: MinIO no responde" >&2; exit 1; }
    sleep 2
done

for b in cr-chat-backups cr-chat-media; do
    mc mb --ignore-existing "crchat/$b"
    mc anonymous set none "crchat/$b"
done

mc admin policy create crchat cr-chat-backups-rw /politicas/politica-backups.json
mc admin policy create crchat cr-chat-media-rw   /politicas/politica-media.json

mc admin user add crchat "$MINIO_BACKUP_ACCESS_KEY" "$MINIO_BACKUP_SECRET_KEY"
mc admin user add crchat "$MINIO_API_ACCESS_KEY"    "$MINIO_API_SECRET_KEY"
# attach falla si ya estaba adjunta: se ignora solo ese caso.
mc admin policy attach crchat cr-chat-backups-rw --user "$MINIO_BACKUP_ACCESS_KEY" 2>/dev/null || true
mc admin policy attach crchat cr-chat-media-rw   --user "$MINIO_API_ACCESS_KEY"    2>/dev/null || true

# Ciclo de vida (se reemplazan las reglas para que sea idempotente).
mc ilm rule rm --all --force crchat/cr-chat-backups >/dev/null 2>&1 || true
mc ilm rule add --prefix globals/ --expire-days 30 crchat/cr-chat-backups

echo "minio-init: estado"
mc admin user list crchat
mc ls crchat
