#!/bin/bash
# =============================================================================
# Prueba de restauración a un instante (PITR) con pgBackRest.
#
#   infra/scripts/probar-restauracion.sh [-p <proyecto compose>] [--sin-marca]
#
# 1. Toma conteos de las tablas principales en el líder y fija el instante T.
# 2. Después de T inserta una fila marcada en auditoria (accion='prueba_pitr',
#    detalle.marca=<uuid>) que NO debe aparecer en la copia restaurada.
#    (--sin-marca: no escribe nada; solo valida los conteos en T.)
# 3. `pgbackrest check` fuerza el cambio de segmento y espera a que el WAL que
#    contiene T esté archivado en MinIO.
# 4. Restaura en un contenedor DESECHABLE (sin volumen, archive_mode=off para
#    no escribir nunca en el repositorio) con --type=time --target=T, arranca
#    Postgres, espera el fin de la recuperación y compara los conteos.
# 5. Informa el RTO medido (restauración + recuperación + verificación).
# No toca pg1/pg2 ni sus volúmenes. Requiere el clúster y `backup` arriba.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."
P=${COMPOSE_PROJECT_NAME:-$(basename "$PWD" | tr '[:upper:]' '[:lower:]')}
MARCAR=1
while [ $# -gt 0 ]; do
    case "$1" in
        -p) P=$2; shift 2 ;;
        --sin-marca) MARCAR=0; shift ;;
        *) echo "opción desconocida: $1" >&2; exit 2 ;;
    esac
done
dc() { docker compose -p "$P" "$@"; }
set -a; . ./.env; set +a
DB=${DB_NAME:-cr_chat}
ahora() { date +%s.%N; }
dif() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }

RED=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$(dc ps -q haproxy)")
VOL_CERTS=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/certs"}}{{.Name}}{{end}}{{end}}' "$(dc ps -q haproxy)")
psql_lider() {
    docker run --rm -i --network "$RED" -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" --entrypoint psql \
        crchat/patroni:17 -X -At -v ON_ERROR_STOP=1 -h haproxy -p 5000 -U postgres -d "$DB" "$@"
}
CONTEOS="SELECT string_agg(t || '=' || n, ' ' ORDER BY t) FROM (
    SELECT 'usuario' t, count(*) n FROM usuario UNION ALL
    SELECT 'contacto', count(*) FROM contacto UNION ALL
    SELECT 'conversacion', count(*) FROM conversacion UNION ALL
    SELECT 'mensaje', count(*) FROM mensaje UNION ALL
    SELECT 'recibo_mensaje', count(*) FROM recibo_mensaje UNION ALL
    SELECT 'sesion', count(*) FROM sesion UNION ALL
    SELECT 'auditoria', count(*) FROM auditoria) x"

echo "== Repositorio"
dc exec -T backup gosu postgres pgbackrest --stanza=crchat info --output=text | grep -E "full backup|diff backup|incr backup|wal archive" || true

echo "== 1) Conteos e instante T en el líder"
antes=$(psql_lider -c "$CONTEOS")
sleep 1
T=$(psql_lider -c "SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') || '+00'")
echo "   T = $T"
echo "   conteos(T) = $antes"
sleep 1

MARCA=""
if [ "$MARCAR" = 1 ]; then
    MARCA=$(cat /proc/sys/kernel/random/uuid)
    psql_lider -c "INSERT INTO auditoria (accion, entidad, detalle)
                   VALUES ('prueba_pitr', 'pitr', jsonb_build_object('marca', '$MARCA'))" >/dev/null
    echo "== 2) Cambio posterior a T: auditoria.prueba_pitr marca=$MARCA"
    echo "   conteos(ahora) = $(psql_lider -c "$CONTEOS")"
fi

echo "== 3) Archivar el WAL que contiene T"
dc exec -T backup gosu postgres pgbackrest --stanza=crchat check --log-level-console=warn
echo "   archivado OK"

echo "== 4) Restaurar en un contenedor desechable"
C=crchat-pitr-$$
trap 'docker rm -f "$C" >/dev/null 2>&1 || true' EXIT
t0=$(ahora)
docker run -d --name "$C" --network "$RED" --memory 512m --shm-size 128m \
    -v "$VOL_CERTS":/certs:ro \
    -e PGBACKREST_REPO1_S3_KEY="$MINIO_BACKUP_ACCESS_KEY" \
    -e PGBACKREST_REPO1_S3_KEY_SECRET="$MINIO_BACKUP_SECRET_KEY" \
    -e PGBACKREST_REPO1_CIPHER_PASS="$PGBACKREST_CIPHER_PASS" \
    --entrypoint sleep crchat/patroni:17 infinity >/dev/null
docker exec "$C" bash -c "
    set -e
    mkdir -p /var/lib/postgresql/data/pgdata /tmp/pgbackrest && chmod 700 /var/lib/postgresql/data/pgdata
    pgbackrest --stanza=crchat --log-level-console=info \
        --type=time --target='$T' --target-action=promote restore | grep -E 'restore backup set|restore size|restore command end' || { echo 'FALLO: pgbackrest restore'; exit 1; }
"
t1=$(ahora)
# archive_mode=off: la copia NUNCA archiva WAL en el repositorio real.
docker exec "$C" pg_ctl -D /var/lib/postgresql/data/pgdata -l /tmp/pg.log -w -t 300 \
    -o "-c archive_mode=off -c listen_addresses='' -c port=5432" start >/dev/null
for _ in $(seq 1 300); do
    r=$(docker exec "$C" psql -X -At -d "$DB" -c "SELECT pg_is_in_recovery()" 2>/dev/null || true)
    [ "$r" = f ] && break
    sleep 1
done
[ "$r" = f ] || { docker exec "$C" tail -20 /tmp/pg.log; echo "FALLO: la recuperación no terminó"; exit 1; }
t2=$(ahora)
docker exec "$C" grep -E "recovery stopping|starting point-in-time|archive recovery complete|database system is ready" /tmp/pg.log | sed 's/^/   pg: /' | tail -4

echo "== 5) Verificación"
despues=$(docker exec "$C" psql -X -At -d "$DB" -c "$CONTEOS")
echo "   conteos(restaurado) = $despues"
ok=1
[ "$antes" = "$despues" ] || { echo "   FALLO: los conteos no coinciden con los de T"; ok=0; }
if [ -n "$MARCA" ]; then
    n=$(docker exec "$C" psql -X -At -d "$DB" -c "SELECT count(*) FROM auditoria WHERE detalle->>'marca' = '$MARCA'")
    if [ "$n" = 0 ]; then echo "   la fila posterior a T no está (correcto)"; else echo "   FALLO: la fila posterior a T está en la copia"; ok=0; fi
fi
t3=$(ahora)
echo "   tiempos: restore $(dif "$t0" "$t1") s, recuperación+arranque $(dif "$t1" "$t2") s, total (RTO) $(dif "$t0" "$t3") s"
echo "   tamaño restaurado: $(docker exec "$C" du -sh /var/lib/postgresql/data/pgdata | cut -f1)"
if [ "$ok" = 1 ]; then echo "RESULTADO: PITR OK a $T (RTO $(dif "$t0" "$t3") s)"; else echo "RESULTADO: PITR FALLIDO"; exit 1; fi
