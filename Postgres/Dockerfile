FROM postgres:17

RUN apt-get update && apt-get install -y --no-install-recommends cron tzdata \
    && rm -rf /var/lib/apt/lists/*

ENV TZ=America/Costa_Rica

RUN mkdir -p /backup && touch /var/log/cron.log

COPY Postgres/script/backup.sh Postgres/script/restore.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/restore.sh

RUN echo "*/10 * * * * root bash /usr/local/bin/backup.sh >> /var/log/cron.log 2>&1" > /etc/cron.d/pg-backup \
    && chmod 0644 /etc/cron.d/pg-backup

# cron no hereda el entorno del contenedor: se escriben las variables al arrancar
CMD ["bash", "-c", "umask 077 && printf 'POSTGRES_USER=%q\\nPOSTGRES_DB=%q\\n' \"$POSTGRES_USER\" \"$POSTGRES_DB\" > /etc/backup.env && service cron start && exec docker-entrypoint.sh postgres"]
