# Recuperación de datos de CR_Chat (runbook)

Arquitectura: [`infraestructura.md`](infraestructura.md). Todos los comandos se ejecutan desde la raíz del repo
con el `.env` local; si usas un nombre de proyecto propio, añade `-p <proyecto>` a los scripts.

## Objetivos y mediciones

| Escenario | RPO (pérdida máxima) | RTO (tiempo sin servicio) | Medido (Fase 2) |
|---|---|---|---|
| Cae el líder (contenedor, proceso o nodo) | réplica asíncrona: lo no replicado; Patroni no promueve con más de 1 MiB de retraso (`maximum_lag_on_failover`) | automático; peor caso `ttl` = 20 s si el líder muere sin avisar | `docker stop` del líder: escrituras de nuevo en **4,3 s, 7,6 s y 4,6 s** (3 pruebas; la 2.ª y la 3.ª con CDC activo), lag 0 antes de cada prueba |
| El nodo caído vuelve | 0 | automático (pg_rewind) | réplica en streaming en **4,8 s, 3,2 s y 2,5 s** |
| Error lógico (borrado/actualización indebida): PITR a un instante | 0 respecto del instante elegido | restauración + recuperación del WAL | copia de verificación (≈ 112 MB): **13,7 s y 9,6 s**; clúster completo (pg1 + clonado de pg2 + full nueva): servicio de escritura en **24 s**, total **55 s** |
| Pérdida de los dos nodos | ≤ `archive_timeout` = **60 s** de WAL sin archivar (`archive-async`) | igual que PITR (al último WAL) | — (mismo procedimiento P4 con el instante más reciente) |
| Pérdida del host (con MinIO) | **todo**: el repositorio vive en el mismo host | — | **Pendiente**: copia fuera del host (ver "Pendientes") |

El RTO de PITR crece con el tamaño de la base y con el WAL a reproducir desde el último respaldo (≤ 1 día por el
diff diario).

## Qué se respalda, cuándo y cuánto se guarda

| Qué | Cómo | Calendario (cron de `backup`, `TZ`) | Retención |
|---|---|---|---|
| Base completa | `pgbackrest backup --type=full` desde el líder por TLS | domingo 02:00 | 2 full (`repo1-retention-full=2`) |
| Cambios desde la última full | `--type=diff` | lunes a sábado 02:00 | hasta 6 diff; caen con su full |
| WAL (PITR) | `archive_command` en cada nodo (`archive-push`, async, zstd) | continuo; `archive_timeout = 60s` | el necesario para las full retenidas → **ventana de PITR de 7 a 14 días** |
| Roles y objetos globales | `pg_dumpall --globals-only --no-role-passwords` como `migrator` | diario 02:30 | 30 días (regla de ciclo de vida de MinIO sobre `globals/`) |
| Verificación de archivado | `pgbackrest check` | cada hora | — |
| Mantenimiento | `fn_purgar_sesiones()` (diario 03:00), `fn_crear_particiones_auditoria(3)` (día 1, 03:15), como `migrator` | | |

- Repositorio: `s3://cr-chat-backups/pgbackrest` (MinIO), **cifrado aes-256-cbc** con `PGBACKREST_CIPHER_PASS`.
  **Sin esa clave los respaldos no sirven**: guárdala fuera del servidor.
- Los globales no llevan contraseñas: tras restaurarlos, aplicar `Postgres/bootstrap/asignar-credenciales.sql`
  (lo hace `db-init`). En un PITR del clúster los roles vienen dentro del respaldo físico, con sus hashes.
- No se respaldan `pg_replslot` ni la réplica MySQL: MySQL se reconstruye desde PostgreSQL.

Comandos de operación:

```bash
docker compose exec backup gosu postgres pgbackrest --stanza=crchat info      # estado del repositorio
docker compose exec backup /usr/local/lib/crchat/ejecutar.sh respaldo full     # full manual (también diff|incr)
docker compose exec backup /usr/local/lib/crchat/ejecutar.sh verificar         # archivado de WAL funcionando
docker compose exec backup /usr/local/lib/crchat/ejecutar.sh globales
docker compose logs -f backup                                                  # salida de todos los jobs
```

Salida real de `pgbackrest info` (Fase 2, tras un failover; nótese el WAL de las timelines 1 y 2):

```
stanza: crchat
    status: ok
    cipher: aes-256-cbc
    db (current)
        wal archive min/max (17): 000000010000000000000001/00000002000000000000000A
        full backup: 20261030-192123F
            database size: 30.9MB, database backup size: 30.9MB
            repo1: backup set size: 3.7MB, backup size: 3.7MB
        diff backup: 20261030-192123F_20261030-192358D
```

## Procedimientos

### P1. Failover (automático)

No hay que hacer nada: Patroni promueve la réplica y HAProxy (`GET /primary` cada 1 s) mueve `:5000`. Las
conexiones abiertas al ex líder se cortan (`shutdown-sessions`); la API debe reintentar la transacción si recibe
`57P01`/`08006`. Comprobar:

```bash
docker compose exec pg1 patronictl -c /etc/patroni/patroni.yml list     # (o pg2)
curl -s http://127.0.0.1:7000/ | grep -o 'escritura.*'                   # o abrir la página de stats
```

Prueba controlada (no en producción con tráfico): `infra/scripts/probar-failover.sh`.

### P2. Cambio de líder planificado (mantenimiento)

```bash
docker compose exec pg1 patronictl -c /etc/patroni/patroni.yml switchover --leader <actual> --candidate <otro> --force
```

### P3. Un nodo no vuelve o tiene los datos dañados

```bash
docker compose exec <nodo> patronictl -c /etc/patroni/patroni.yml reinit crchat <nodo> --force
```

Lo vuelve a clonar del líder (`pg_basebackup`). Si el contenedor no arranca: `docker compose stop <nodo>`,
vaciar su directorio de datos (`docker compose run --rm --no-deps --entrypoint bash <nodo> -c 'rm -rf
/var/lib/postgresql/data/pgdata'`) y `docker compose up -d <nodo>`.

### P4. Restaurar a un instante (PITR)

1. **Elegir y validar el instante** sin tocar el clúster. El script restaura en un contenedor desechable (sin
   volumen y con `archive_mode=off`, así que nunca escribe en el repositorio) y compara conteos:

   ```bash
   infra/scripts/probar-restauracion.sh                 # T = ahora; deja una fila de prueba en auditoria después de T
   infra/scripts/probar-restauracion.sh --sin-marca     # no escribe nada en la base
   ```

   Para inspeccionar un instante concreto se puede adaptar el script (variable `T`) o, a mano, restaurar con
   `pgbackrest --type=time --target='<instante>' restore` en un contenedor `crchat/patroni:17` desechable.
   Si solo hacen falta unas filas, extraerlas de esa copia (p. ej. `pg_dump -t`) y reinsertarlas: es menos
   invasivo que restaurar todo el clúster.

2. **Restaurar el clúster** (destructivo: borra los datos actuales de pg1 y pg2):

   ```bash
   infra/scripts/restaurar-cluster.sh --objetivo '2026-10-31 01:07:37+00' --confirmo-borrar-datos
   ```

   Detiene `backup`/`connect`, borra el estado del clúster en etcd, vacía ambos nodos, arranca pg1 con
   `CRCHAT_PITR_OBJETIVO` (Patroni usa el *custom bootstrap* `pgbackrest` en lugar de `initdb`: restore
   `--type=time`, recuperación hasta el instante y promoción), clona pg2 y lanza una full nueva. Probado en la
   Fase 2: volvió a 6 usuarios / 17 filas de auditoría (antes de T) y la fila escrita después de T no estaba.

3. **Después**: si el CDC estaba activo, re-sembrar MySQL (`infra/cdc/resembrar.sh`, ver P6). Avisar al
   backend: las sesiones y mensajes posteriores al instante ya no existen (los clientes deben volver a iniciar
   sesión si su refresh token no existe).

### P5. Restaurar roles (globales)

Solo hace falta si se reconstruye un clúster vacío (initdb) y se cargan datos lógicos:

```bash
docker compose exec backup s3cmd -c /etc/crchat/s3cfg ls s3://cr-chat-backups/globals/
docker compose exec backup s3cmd -c /etc/crchat/s3cfg get s3://cr-chat-backups/globals/<archivo> /tmp/g.sql.gz
# revisar y aplicar como superusuario; luego db-init (contraseñas):
docker compose up db-init
```

### P6. Réplica MySQL inconsistente o slot invalidado

```bash
infra/cdc/resembrar.sh
```

Detiene y borra los conectores con sus offsets, borra los tópicos `crchat.public.*`, recrea la base `crchat`
con `MysqlB/init/02-esquema.sql` y vuelve a ejecutar `cdc-init` (slot permanente + instantánea inicial).
Probado tras el PITR del clúster: MySQL volvió a 6 usuarios sin la fila posterior al instante.

### P7. Pérdida de etcd (no probado en la Fase 2)

`failsafe_mode` mantiene al líder escribiendo mientras vea a la réplica por REST. Para recuperar: `docker compose
up -d etcd`; si el volumen `etcd_data` se perdió, Patroni vuelve a publicar el clúster solo (el `sysid` está en
los datos). La configuración dinámica (parámetros, slot de CDC) vuelve a la de `bootstrap.dcs`: reejecutar
`docker compose --profile cdc up cdc-init` si el CDC está activo.

## Pendientes

- **Copia fuera del host** (regla 3-2-1): replicar `cr-chat-backups` a un S3 externo (`mc mirror --watch` o
  replicación de buckets de MinIO) y probar una restauración desde allí. Hoy el RPO ante pérdida del host es total.
- Alertas: hoy los fallos de jobs solo quedan en `docker compose logs backup` (exit ≠ 0). Conectar a un sistema
  de alertas (o al menos un healthcheck que mire la antigüedad del último respaldo).
- Probar una restauración mensual con `probar-restauracion.sh` y registrar el tiempo.
