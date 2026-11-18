#!/bin/bash
# =============================================================================
# Activa el CDC (servicio `cdc-init`, profile `cdc`, una sola vez por arranque):
#  1. Registra en Patroni el slot lógico PERMANENTE debezium_crchat (pgoutput).
#     Patroni lo crea en el líder y lo copia a la réplica, así que sobrevive al
#     failover (requiere hot_standby_feedback=on, ya configurado).
#  2. Espera a que el slot exista en el líder.
#  3. Registra/actualiza (PUT idempotente) los conectores de Kafka Connect:
#     crchat-pg-source (Debezium Postgres) y crchat-mysql-sink (Debezium JDBC).
# Las contraseñas no viajan en el JSON: Connect las resuelve con ${env:...}.
# =============================================================================
set -euo pipefail
: "${PATRONI_RESTAPI_USERNAME:?}" "${PATRONI_RESTAPI_PASSWORD:?}" "${DB_CDC_PASSWORD:?}"
DB_NAME=${DB_NAME:-cr_chat}
CONNECT=${CONNECT_URL:-http://connect:8083}

slot='{"slots":{"debezium_crchat":{"type":"logical","database":"'"$DB_NAME"'","plugin":"pgoutput"}}}'
for n in pg1 pg2; do
    if curl -fsS -u "$PATRONI_RESTAPI_USERNAME:$PATRONI_RESTAPI_PASSWORD" -X PATCH \
            -H 'Content-Type: application/json' -d "$slot" "http://$n:8008/config" >/dev/null; then
        echo "cdc-init: slot permanente registrado en la DCS (vía $n)"; break
    fi
done

for i in $(seq 1 60); do
    if PGPASSWORD="$DB_CDC_PASSWORD" psql -X -At -h haproxy -p 5000 -U cdc_lector -d "$DB_NAME" \
         -c "SELECT 1 FROM pg_replication_slots WHERE slot_name = 'debezium_crchat'" 2>/dev/null | grep -q 1; then
        echo "cdc-init: slot debezium_crchat presente en el líder"; break
    fi
    [ "$i" = 60 ] && { echo "cdc-init: el slot no apareció" >&2; exit 1; }
    sleep 2
done

for i in $(seq 1 90); do
    curl -fsS "$CONNECT/connectors" >/dev/null 2>&1 && break
    [ "$i" = 90 ] && { echo "cdc-init: Kafka Connect no responde" >&2; exit 1; }
    sleep 2
done

registrar() {  # registrar <nombre> <archivo.json>
    curl -fsS -X PUT -H 'Content-Type: application/json' --data @"$2" "$CONNECT/connectors/$1/config" >/dev/null
    echo "cdc-init: conector $1 registrado"
}
registrar crchat-pg-source  /cdc/debezium-postgres.json
registrar crchat-mysql-sink /cdc/jdbc-mysql.json
sleep 5
curl -fsS "$CONNECT/connectors?expand=status" | sed 's/},/},\n/g' | grep -o '"name":"[^"]*","connector":{"state":"[A-Z]*"' || true
