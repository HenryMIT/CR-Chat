#!/bin/bash
# =============================================================================
# Arranque de un nodo pg1/pg2: servidor TLS de pgBackRest (para que el
# contenedor `backup` haga respaldos remotos) y Patroni en primer plano.
# Se ejecuta con `init: true` (tini) para recoger procesos huérfanos.
# =============================================================================
set -euo pipefail

: "${PATRONI_NAME:?falta PATRONI_NAME}"
mkdir -p /var/lib/postgresql/data/pgbackrest-spool /tmp/pgbackrest
chmod 700 /var/lib/postgresql/data

# Certificado de este nodo para el servidor TLS de pgBackRest (lo genera el
# servicio `certs`). CN = nombre del nodo; solo acepta al cliente CN=backup.
export PGBACKREST_TLS_SERVER_CERT_FILE="/certs/${PATRONI_NAME}.crt"
export PGBACKREST_TLS_SERVER_KEY_FILE="/certs/${PATRONI_NAME}.key"

(
    while true; do
        pgbackrest server || true
        echo "pgbackrest server terminó; se reinicia en 5 s" >&2
        sleep 5
    done
) &

CONF=/etc/patroni/patroni.yml
# Restauración del clúster a un instante (docs/db/recuperacion.md): solo actúa
# si el clúster NO existe en la DCS y el directorio de datos está vacío; en ese
# caso Patroni no hace initdb sino `crchat-pitr-bootstrap` (pgbackrest restore).
if [ -n "${CRCHAT_PITR_OBJETIVO:-}" ]; then
    CONF=/tmp/patroni-pitr.yml
    python3 - "$CRCHAT_PITR_OBJETIVO" <<'PY'
import sys, yaml
c = yaml.safe_load(open('/etc/patroni/patroni.yml'))
c['bootstrap']['method'] = 'pgbackrest'
c['bootstrap']['pgbackrest'] = {
    'command': '/usr/local/bin/crchat-pitr-bootstrap "%s"' % sys.argv[1],
    'keep_existing_recovery_conf': True,
    'no_params': True,
}
yaml.safe_dump(c, open('/tmp/patroni-pitr.yml', 'w'), default_flow_style=False)
PY
    echo "crchat: CRCHAT_PITR_OBJETIVO=$CRCHAT_PITR_OBJETIVO (solo se usa si el clúster se inicializa)" >&2
fi

exec patroni "$CONF"
