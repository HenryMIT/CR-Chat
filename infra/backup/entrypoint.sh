#!/bin/bash
# =============================================================================
# Contenedor `backup`: crea/valida la stanza de pgBackRest, hace la primera
# full si el repositorio está vacío y deja cron en primer plano.
# =============================================================================
set -euo pipefail
: "${PGBACKREST_REPO1_S3_KEY:?}" "${PGBACKREST_REPO1_S3_KEY_SECRET:?}" "${PGBACKREST_REPO1_CIPHER_PASS:?}"
: "${DB_MIGRATOR_PASSWORD:?}"

# Entorno para cron (no hereda el del contenedor). Solo root lo lee.
install -d -m 700 /etc/crchat
{
    for v in TZ DB_NAME DB_MIGRATOR_PASSWORD PGHOST_ESCRITURA PGPORT_ESCRITURA \
             PGBACKREST_REPO1_S3_KEY PGBACKREST_REPO1_S3_KEY_SECRET PGBACKREST_REPO1_CIPHER_PASS; do
        [ -n "${!v:-}" ] && printf 'export %s=%q\n' "$v" "${!v}"
    done
} > /etc/crchat/entorno
chmod 600 /etc/crchat/entorno
# s3cmd (globales) contra el mismo endpoint TLS que pgBackRest.
cat > /etc/crchat/s3cfg <<CFG
[default]
access_key = ${PGBACKREST_REPO1_S3_KEY}
secret_key = ${PGBACKREST_REPO1_S3_KEY_SECRET}
host_base = haproxy:9443
host_bucket = haproxy:9443
bucket_location = us-east-1
use_https = True
ca_certs_file = /certs/ca.crt
check_ssl_certificate = True
signature_v2 = False
CFG
chmod 600 /etc/crchat/s3cfg
install -d -o postgres -g postgres /tmp/pgbackrest

echo "backup: esperando a la stanza (líder, MinIO y servidores TLS de pgBackRest)..."
for i in $(seq 1 60); do
    if gosu postgres pgbackrest --stanza=crchat --log-level-console=warn stanza-create; then break; fi
    [ "$i" = 60 ] && { echo "backup: no se pudo crear la stanza" >&2; exit 1; }
    sleep 5
done
gosu postgres pgbackrest --stanza=crchat --log-level-console=warn check
if ! gosu postgres pgbackrest --stanza=crchat info --output=json | grep -q '"label"'; then
    echo "backup: repositorio vacío, primera full"
    /usr/local/lib/crchat/ejecutar.sh respaldo full
    /usr/local/lib/crchat/ejecutar.sh globales
fi
touch /tmp/backup-listo
echo "backup: listo; cron en primer plano (TZ=${TZ:-UTC})"
exec cron -f
