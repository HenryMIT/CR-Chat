#!/bin/bash
# =============================================================================
# Prueba de failover de Patroni + HAProxy (NO usar en producción con tráfico real).
#
#   infra/scripts/probar-failover.sh [-p <proyecto compose>]
#
# 1. Lanza un cliente que cada 0,5 s escribe por haproxy:5000 (txid_current()
#    asigna un xid y deja un COMMIT en el WAL; falla en una réplica, así que
#    solo tiene éxito contra un líder real; no deja datos).
# 2. `docker stop` del líder actual y mide cuánto tarda en volver a haber
#    escrituras OK (ahora en el otro nodo).
# 3. Arranca el nodo detenido y mide cuánto tarda en volver como réplica en
#    streaming (pg_rewind si hace falta).
# Requiere: docker compose, .env en la raíz del repo y el clúster arriba.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."
P=${COMPOSE_PROJECT_NAME:-$(basename "$PWD" | tr '[:upper:]' '[:lower:]')}
[ "${1:-}" = "-p" ] && P=$2
dc() { docker compose -p "$P" "$@"; }
set -a; . ./.env; set +a
ahora() { date +%s.%N; }
dif() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }

lista() { dc exec -T pg1 patronictl -c /etc/patroni/patroni.yml list -f json 2>/dev/null \
          || dc exec -T pg2 patronictl -c /etc/patroni/patroni.yml list -f json; }
lider() { lista | python3 -c 'import json,sys; print(next(m["Member"] for m in json.load(sys.stdin) if m["Role"]=="Leader"))'; }

L=$(lider); case "$L" in pg1) R=pg2 ;; pg2) R=pg1 ;; *) echo "sin líder" >&2; exit 1 ;; esac
echo "== Estado inicial (líder: $L)"; dc exec -T "$L" patronictl -c /etc/patroni/patroni.yml list

RED=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$(dc ps -q haproxy)")
CLI=crchat-failover-cliente-$$
docker run -d --rm --name "$CLI" --network "$RED" -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" \
    --entrypoint bash crchat/patroni:17 -c '
    while true; do
      r=$(psql -X -At -F " xid=" "host=haproxy port=5000 user=postgres dbname=postgres connect_timeout=2" \
            -c "SELECT inet_server_addr(), txid_current()" 2>&1 | tr "\n" " ")
      echo "$(date +%s.%N) $r"
      sleep 0.5
    done' >/dev/null
trap 'docker rm -f "$CLI" >/dev/null 2>&1 || true' EXIT
sleep 3

echo "== docker stop $L"
t0=$(ahora)
docker stop -t 40 "$(dc ps -q "$L")" >/dev/null &
# Primera escritura OK contra un servidor distinto del líder anterior.
ip_l=$(docker logs "$CLI" 2>/dev/null | grep ' xid=' | tail -1 | awk '{print $2}')
t1=""
for _ in $(seq 1 120); do
    linea=$(docker logs "$CLI" 2>/dev/null | awk -v t="$t0" '$1 > t' | grep ' xid=' | grep -v " $ip_l " | head -1 || true)
    if [ -n "$linea" ]; then t1=$(echo "$linea" | awk '{print $1}'); break; fi
    sleep 0.5
done
wait
[ -z "$t1" ] && { echo "FALLO: no hubo escrituras en 60 s"; exit 1; }
fallidas=$(docker logs "$CLI" 2>/dev/null | awk -v a="$t0" -v b="$t1" '$1 > a && $1 < b' | grep -vc ' xid=' || true)
echo "   escrituras OK de nuevo en $(dif "$t0" "$t1") s (intentos fallidos durante el corte: $fallidas)"
echo "   primera escritura tras el failover: $linea"
dc exec -T "$R" patronictl -c /etc/patroni/patroni.yml list

echo "== docker start $L (debe volver como réplica)"
t2=$(ahora)
docker start "$(dc ps -aq "$L")" >/dev/null
t3=""
for _ in $(seq 1 120); do
    if lista | python3 -c '
import json,sys
m={x["Member"]:x for x in json.load(sys.stdin)}
x=m.get(sys.argv[1],{})
sys.exit(0 if x.get("Role") in ("Replica","Sync Standby") and x.get("State")=="streaming" else 1)' "$L"; then
        t3=$(ahora); break
    fi
    sleep 1
done
[ -z "$t3" ] && { echo "FALLO: $L no volvió como réplica en 120 s"; exit 1; }
echo "   $L en streaming como réplica en $(dif "$t2" "$t3") s"
dc exec -T "$R" patronictl -c /etc/patroni/patroni.yml list
echo "== Escrituras posteriores (últimas 3)"
docker logs "$CLI" 2>/dev/null | tail -3
echo "RESULTADO: failover $(dif "$t0" "$t1") s, reincorporación $(dif "$t2" "$t3") s"
