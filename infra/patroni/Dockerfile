# =============================================================================
# Imagen de los nodos PostgreSQL 17 + Patroni + pgBackRest de CR_Chat, y del
# contenedor `backup` (host de repositorio de pgBackRest + cron de jobs).
# Contexto de build: infra/.  Targets: `patroni` (pg1/pg2) y `backup`.
# Paquetes del repositorio PGDG que ya trae postgres:17 (firmado), sin pip.
# =============================================================================
FROM postgres:17-bookworm AS base
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        patroni python3-etcd pgbackrest curl ca-certificates openssl; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /etc/patroni /etc/pgbackrest /var/lib/postgresql/data /certs; \
    chown -R postgres:postgres /etc/patroni /etc/pgbackrest /var/lib/postgresql/data; \
    chmod 700 /var/lib/postgresql/data
COPY certs/generar.sh /usr/local/bin/crchat-generar-certs
RUN chmod 755 /usr/local/bin/crchat-generar-certs

# --- Nodos PostgreSQL (pg1, pg2) ---------------------------------------------
FROM base AS patroni
COPY --chown=postgres:postgres patroni/patroni.yml /etc/patroni/patroni.yml
COPY --chown=postgres:postgres patroni/pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
COPY patroni/entrypoint.sh /usr/local/bin/crchat-patroni
COPY patroni/pitr-bootstrap.sh /usr/local/bin/crchat-pitr-bootstrap
RUN chmod 755 /usr/local/bin/crchat-patroni /usr/local/bin/crchat-pitr-bootstrap
USER postgres
EXPOSE 5432 8008 8432
ENTRYPOINT ["/usr/local/bin/crchat-patroni"]

# --- Host de respaldo (pgBackRest repo host + cron) ---------------------------
FROM base AS backup
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends cron s3cmd; \
    rm -rf /var/lib/apt/lists/* /etc/cron.d/* /etc/cron.daily/*
COPY --chown=postgres:postgres backup/pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
COPY backup/crontab /etc/cron.d/crchat
COPY backup/jobs/ /usr/local/lib/crchat/
COPY backup/entrypoint.sh /usr/local/bin/crchat-backup
RUN chmod 644 /etc/cron.d/crchat && chmod 755 /usr/local/lib/crchat/*.sh /usr/local/bin/crchat-backup
ENTRYPOINT ["/usr/local/bin/crchat-backup"]
