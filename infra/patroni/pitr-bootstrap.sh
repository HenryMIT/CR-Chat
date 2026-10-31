#!/bin/bash
# =============================================================================
# Método de bootstrap `pgbackrest` de Patroni (lo invoca Patroni, no un operador):
# restaura el último respaldo anterior al instante objetivo en el directorio de
# datos vacío y deja la recuperación configurada para detenerse en ese instante
# y promover. Patroni arranca Postgres, espera el fin de la recuperación y toma
# el liderazgo. Ver infra/scripts/restaurar-cluster.sh.
# =============================================================================
set -euo pipefail
objetivo=${1:?falta el instante objetivo}
datos=/var/lib/postgresql/data/pgdata
echo "crchat-pitr-bootstrap: restaurando a '$objetivo' en $datos" >&2
pgbackrest --stanza=crchat --log-level-console=info --pg1-path="$datos" \
    --type=time --target="$objetivo" --target-action=promote --target-timeline=latest restore
