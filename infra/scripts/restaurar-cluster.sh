#!/bin/bash
# =============================================================================
# RESTAURA TODO EL CLÚSTER (pg1 + pg2) a un instante con pgBackRest.
# DESTRUCTIVO: borra el contenido de pg1_data y pg2_data. Úsalo solo tras
# validar el instante con infra/scripts/probar-restauracion.sh.
#
#   infra/scripts/restaurar-cluster.sh [-p <proyecto>] --objetivo '2026-10-31 01:00:00+00' --confirmo-borrar-datos
#
# Pasos (docs/db/recuperacion.md, procedimiento P4):
#  1. Detiene `backup` y `connect` (si están) y luego pg2 y pg1.
#  2. Borra el estado del clúster en etcd (/service/crchat/).
#  3. Vacía los directorios de datos de ambos nodos.
#  4. Arranca pg1 con CRCHAT_PITR_OBJETIVO: Patroni ejecuta el bootstrap
#     `pgbackrest` (restore --type=time) en vez de initdb, recupera hasta el
#     instante, promueve y toma el liderazgo.
#  5. Arranca pg2, que se clona del nuevo líder.
#  6. Reactiva `backup` y lanza una full nueva (nueva línea de tiempo).
# El CDC NO se reanuda solo: la réplica MySQL tiene datos posteriores al
# instante; re-sembrarla según docs/db/infraestructura.md.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."
P=${COMPOSE_PROJECT_NAME:-$(basename "$PWD" | tr '[:upper:]' '[:lower:]')}
OBJ="" OK=0
while [ $# -gt 0 ]; do
    case "$1" in
        -p) P=$2; shift 2 ;;
        --objetivo) OBJ=$2; shift 2 ;;
        --confirmo-borrar-datos) OK=1; shift ;;
        *) echo "opción desconocida: $1" >&2; exit 2 ;;
    esac
done
[ -n "$OBJ" ] || { echo "falta --objetivo '<timestamptz>'" >&2; exit 2; }
[ "$OK" = 1 ] || { echo "operación destructiva: añade --confirmo-borrar-datos" >&2; exit 2; }
dc() { docker compose -p "$P" "$@"; }
ahora() { date +%s.%N; }
dif() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }
lista() { dc exec -T "$1" patronictl -c /etc/patroni/patroni.yml list -f json 2>/dev/null || echo '[]'; }
estado() {  # estado <nodo> <rol> -> 0 si el nodo tiene ese rol y está running/streaming
    lista "$1" | python3 -c '
import json,sys
m={x["Member"]:x for x in json.load(sys.stdin)}.get(sys.argv[1],{})
ok = m.get("Role")==sys.argv[2] and m.get("State") in ("running","streaming")
sys.exit(0 if ok else 1)' "$1" "$2"
}

t0=$(ahora)
echo "== 1) Detener consumidores y nodos"
dc --profile cdc stop connect cdc-init >/dev/null 2>&1 || true
dc stop backup pg2 pg1

echo "== 2) Borrar el estado del clúster en etcd"
dc exec -T etcd etcdctl del --prefix /service/crchat/

echo "== 3) Vaciar los directorios de datos"
for n in pg1 pg2; do
    dc run --rm --no-deps -T --entrypoint bash "$n" -c \
        'rm -rf /var/lib/postgresql/data/pgdata /var/lib/postgresql/data/pgbackrest-spool'
done

echo "== 4) pg1: bootstrap desde pgBackRest hasta $OBJ"
CRCHAT_PITR_OBJETIVO="$OBJ" dc up -d --no-deps pg1
for _ in $(seq 1 600); do estado pg1 Leader && break; sleep 2; done
estado pg1 Leader || { dc logs --tail 40 pg1; echo "FALLO: pg1 no llegó a líder"; exit 1; }
t1=$(ahora)
echo "   pg1 líder en $(dif "$t0" "$t1") s"
# La variable queda en el contenedor de pg1 hasta el próximo `docker compose up`
# (que lo recrea sin ella). Es inocua: solo actúa si el clúster no existe en la DCS.

echo "== 5) pg2: clonar del nuevo líder"
dc up -d --no-deps pg2
for _ in $(seq 1 600); do estado pg2 Replica && break; sleep 2; done
estado pg2 Replica || { echo "FALLO: pg2 no volvió como réplica"; exit 1; }
dc exec -T pg1 patronictl -c /etc/patroni/patroni.yml list

echo "== 6) Respaldos: reactivar y full nueva"
dc up -d --no-deps backup
dc exec -T backup /usr/local/lib/crchat/ejecutar.sh respaldo full | tail -3
echo "RESULTADO: clúster restaurado a $OBJ; servicio de escritura en $(dif "$t0" "$t1") s; total $(dif "$t0" "$(ahora)") s"
echo "Siguiente: re-sembrar la réplica MySQL si el CDC estaba activo (docs/db/infraestructura.md)."
