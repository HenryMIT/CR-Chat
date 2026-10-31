#!/bin/bash
# =============================================================================
# Despachador de jobs del contenedor `backup` (lo llama cron o un operador:
#   docker compose exec backup /usr/local/lib/crchat/ejecutar.sh <job> [args]).
# Jobs:
#   respaldo full|diff|incr   pgbackrest backup (desde el líder, por TLS)
#   globales                  pg_dumpall --globals-only (sin contraseñas) -> s3://cr-chat-backups/globals/
#   purgar-sesiones           SELECT fn_purgar_sesiones()           (como migrator)
#   particiones               SELECT fn_crear_particiones_auditoria(3) (como migrator)
#   verificar                 pgbackrest check (archivado de WAL funcionando)
# =============================================================================
set -euo pipefail
# cron arranca con un PATH mínimo: psql/pg_dumpall están en el bin de PG 17.
export PATH=/usr/lib/postgresql/17/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Variables que cron no hereda: las deja el entrypoint (0600, root).
# shellcheck disable=SC1091
[ -r /etc/crchat/entorno ] && . /etc/crchat/entorno

job=${1:?uso: ejecutar.sh <job>}; shift || true
como_pg() { gosu postgres "$@"; }
log() { echo "$(date -Is) [job:$job] $*"; }
psql_migrator() {
    PGPASSWORD="$DB_MIGRATOR_PASSWORD" como_pg psql -X -v ON_ERROR_STOP=1 -At \
        -h "${PGHOST_ESCRITURA:-haproxy}" -p "${PGPORT_ESCRITURA:-5000}" -U migrator -d "${DB_NAME:-cr_chat}" "$@"
}

inicio=$(date +%s)
case "$job" in
    respaldo)
        tipo=${1:-diff}
        log "inicio pgbackrest backup --type=$tipo"
        como_pg pgbackrest --stanza=crchat backup --type="$tipo"
        como_pg pgbackrest --stanza=crchat info --output=text | sed 's/^/  /' | tail -n 12
        ;;
    globales)
        f="globals-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
        log "pg_dumpall --globals-only -> s3://cr-chat-backups/globals/$f"
        # --no-role-passwords: lee pg_roles (no requiere superusuario) y no
        # guarda hashes; al restaurar se reaplica Postgres/bootstrap/asignar-credenciales.sql.
        tmp=$(mktemp /tmp/globales.XXXXXX.sql.gz); trap 'rm -f "$tmp"' EXIT
        PGPASSWORD="$DB_MIGRATOR_PASSWORD" como_pg pg_dumpall --globals-only --no-role-passwords \
            -h "${PGHOST_ESCRITURA:-haproxy}" -p "${PGPORT_ESCRITURA:-5000}" -U migrator -l "${DB_NAME:-cr_chat}" \
            | gzip -9 > "$tmp"
        # Un volcado sin CREATE ROLE es un error (no se sube un archivo vacío).
        zcat "$tmp" | grep -q '^CREATE ROLE migrator;' || { log "ERROR: volcado de globales vacío"; exit 1; }
        s3cmd -c /etc/crchat/s3cfg --no-progress put "$tmp" "s3://cr-chat-backups/globals/$f"
        ;;
    purgar-sesiones)
        n=$(psql_migrator -c 'SELECT fn_purgar_sesiones()')   # si falla, set -e aborta el job
        log "fn_purgar_sesiones => $n filas"
        ;;
    particiones)
        n=$(psql_migrator -c 'SELECT fn_crear_particiones_auditoria(3)')
        log "fn_crear_particiones_auditoria(3) => $n nuevas"
        ;;
    verificar)
        como_pg pgbackrest --stanza=crchat check --log-level-console=warn
        log "archivado OK"
        ;;
    *)
        echo "job desconocido: $job" >&2; exit 2 ;;
esac
log "fin ($(( $(date +%s) - inicio )) s)"
