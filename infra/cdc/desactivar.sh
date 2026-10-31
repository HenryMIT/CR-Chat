#!/bin/bash
# =============================================================================
# Apaga el CDC SIN dejar un slot lógico reteniendo WAL en PostgreSQL.
# Ejecutar desde la raíz del repo (usa docker compose y el .env local):
#   infra/cdc/desactivar.sh [-p <proyecto>]
# 1. Borra los conectores de Kafka Connect (si está arriba).
# 2. Quita el slot permanente de la DCS de Patroni y lo elimina del líder.
# 3. Detiene los servicios del profile `cdc` (los volúmenes se conservan).
# =============================================================================
set -euo pipefail
dc() { docker compose "$@"; }
[ "${1:-}" = "-p" ] && { P=$2; dc() { docker compose -p "$P" "$@"; }; }

for c in crchat-pg-source crchat-mysql-sink; do
    dc exec -T connect curl -fsS -X DELETE "http://localhost:8083/connectors/$c" >/dev/null 2>&1 \
        && echo "conector $c eliminado" || true
done
dc exec -T pg1 bash -c 'curl -fsS -u "$PATRONI_RESTAPI_USERNAME:$PATRONI_RESTAPI_PASSWORD" -X PATCH \
    -H "Content-Type: application/json" -d "{\"slots\":{\"debezium_crchat\":null}}" http://localhost:8008/config' >/dev/null
echo "slot quitado de la DCS"
sleep 8
for n in pg1 pg2; do
    dc exec -T "$n" psql -X -At -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots
        WHERE slot_name = 'debezium_crchat' AND NOT active" 2>/dev/null || true
done
dc --profile cdc stop connect kafka mysql
echo "CDC desactivado"
