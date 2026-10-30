FROM mysql:8.0-debian

RUN apt-get update && apt-get install -y --no-install-recommends tzdata cron gzip \
    && rm -rf /var/lib/apt/lists/*

ENV TZ=America/Costa_Rica

RUN mkdir -p /backup /var/log/mysqlbackup && touch /var/log/mysqlbackup/cron.log

COPY script/backup.sh script/restore.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/restore.sh

RUN echo "*/10 * * * * root bash /usr/local/bin/backup.sh >> /var/log/mysqlbackup/cron.log 2>&1" > /etc/cron.d/mysql-backup \
    && chmod 0644 /etc/cron.d/mysql-backup

# cron no hereda el entorno del contenedor: se escriben las credenciales y variables al arrancar
CMD ["bash", "-c", "umask 077 && printf '[client]\\nuser=root\\npassword=%s\\n' \"$MYSQL_ROOT_PASSWORD\" > /root/.my.cnf && printf 'MYSQL_DATABASE=%q\\n' \"$MYSQL_DATABASE\" > /etc/backup.env && cron && exec docker-entrypoint.sh mysqld"]
