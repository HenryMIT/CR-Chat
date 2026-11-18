#!/bin/bash
# =============================================================================
# Reconstruye la réplica MySQL desde cero a partir de PostgreSQL.
# Úsalo tras una restauración PITR del clúster, si el slot se invalidó
# (max_slot_wal_keep_size) o si MySQL divergió. Desde la raíz del repo:
#   infra/cdc/resembrar.sh [-p <proyecto>]
# 1. Detiene los conectores y borra sus offsets (REST de Connect, KIP-875).
# 2. Borra los tópicos crchat.public.* (pueden tener filas que ya no existen en PG).
# 3. Recrea la base `crchat` de MySQL con MysqlB/init/02-esquema.sql.
# 4. Ejecuta cdc-init: slot permanente + conectores; Debezium hace una
#    instantánea inicial (snapshot.mode=initial) porque ya no hay offsets.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."
P=${COMPOSE_PROJECT_NAME:-$(basename "$PWD" | tr '[:upper:]' '[:lower:]')}
[ "${1:-}" = "-p" ] && P=$2
dc() { docker compose -p "$P" --profile cdc "$@"; }
set -a; . ./.env; set +a

dc up -d --wait mysql kafka connect >/dev/null
api() { dc exec -T connect curl -fsS -X "$1" "http://localhost:8083/connectors$2"; }
for _ in $(seq 1 60); do api GET "" >/dev/null 2>&1 && break; sleep 2; done
for c in crchat-pg-source crchat-mysql-sink; do
    api GET "/$c" >/dev/null 2>&1 || continue          # no existe: nada que borrar
    api PUT "/$c/stop" >/dev/null
    for _ in $(seq 1 30); do
        api GET "/$c/status" 2>/dev/null | grep -q '"connector":{"state":"STOPPED"' && break; sleep 2
    done
    api DELETE "/$c/offsets" >/dev/null || { echo "no se pudieron borrar los offsets de $c" >&2; exit 1; }
    api DELETE "/$c" >/dev/null
    echo "conector $c: offsets y conector borrados"
done

dc exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
    --delete --topic 'crchat\.public\..*' 2>/dev/null && echo "tópicos crchat.public.* borrados" || true
# El slot viejo (si quedó) apunta a un WAL que ya no corresponde: se elimina.
for n in pg1 pg2; do
    dc exec -T "$n" psql -X -At -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots
        WHERE slot_name = 'debezium_crchat' AND NOT active AND pg_is_in_recovery() = false" >/dev/null 2>&1 || true
done

dc exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mysql -uroot -e "DROP DATABASE IF EXISTS crchat; CREATE DATABASE crchat;"
dc exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql sh -c 'mysql -uroot < /docker-entrypoint-initdb.d/02-esquema.sql'
echo "esquema MySQL recreado"

dc up --no-deps cdc-init
