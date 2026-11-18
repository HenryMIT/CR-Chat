# Base de datos de CR_Chat

PostgreSQL 17 es la fuente de verdad, en alta disponibilidad con Patroni (2 nodos) + etcd + HAProxy, con
respaldos continuos y PITR (pgBackRest → MinIO). MySQL 8.4 es una réplica de **solo lectura** alimentada por CDC
(Debezium + Kafka, profile `cdc`); ya no tiene procedimientos ni es fallback de escritura.

| Documento | Contenido |
|---|---|
| [`infraestructura.md`](infraestructura.md) | Diagrama de contenedores, puertos, flujos, Patroni, MinIO, CDC, consumo |
| [`recuperacion.md`](recuperacion.md) | Runbook: respaldos, retención, failover, PITR, re-sembrado de MySQL, RPO/RTO medidos |
| [`modelo.md`](modelo.md) | Diagrama ER, normalización, `ON DELETE` e índices |
| [`optimizacion.md`](optimizacion.md) | EXPLAIN ANALYZE de las funciones principales y ajustes de la Fase 2 |
| [`../contratos/db-funciones.md`](../contratos/db-funciones.md) | Contrato de funciones para el backend: firmas, errores, conexión |

## Estructura

```
Postgres/
  migraciones/                     # dbmate: -- migrate:up / -- migrate:down
    001_roles_extensiones.sql      # superusuario: roles (migrator, app_rw, app_ro, cdc_lector) y extensiones
    002_esquema.sql                # tablas, constraints, índices, auditoría particionada, GRANT (como migrator)
    003_funciones.sql              # funciones de la API v1 (uuid), GRANT EXECUTE (como migrator)
    004_publicacion_cdc.sql        # publicación lógica crchat_cdc (sin pass_hash ni sesiones)
  bootstrap/asignar-credenciales.sql   # LOGIN + contraseñas desde variables, REVOKE CONNECT FROM PUBLIC
  seed/demo.sql                    # usuarios demo (idempotente)
  pruebas/                         # contrato (app_rw, app_ro), catálogo, volumen, explain
MysqlB/
  conf/crchat.cnf                  # MySQL de solo lectura (512 MiB, sin binlog)
  init/01-usuarios.sh              # crchat_sink (DDL/DML) y crchat_lectura (solo SELECT)
  init/02-esquema.sql              # esquema destino del CDC
infra/
  patroni/                         # Dockerfile (targets patroni y backup), patroni.yml, pgbackrest.conf, entrypoint, bootstrap PITR
  backup/                          # pgbackrest.conf del repo host, crontab, jobs/ejecutar.sh, entrypoint
  certs/generar.sh                 # CA interna y certificados (TLS de pgBackRest y del endpoint S3)
  haproxy/haproxy.cfg              # 5000 escritura, 5001 lectura, 9443 TLS S3, 7000 stats
  minio/                           # init.sh y políticas de los buckets
  cdc/                             # conectores Debezium, init.sh, resembrar.sh, desactivar.sh
  scripts/                         # probar-failover.sh, probar-restauracion.sh, restaurar-cluster.sh
```

### Historial de migraciones (decisión de la Fase 2)

Las antiguas 002+004 (esquema) y 003+005 (funciones) se **consolidaron** en 002 y 003: nada se había desplegado,
la 005 duplicaba en su `migrate:down` ~800 líneas de la 003, y la 004 tenía un `down` con pérdida. Validación:
el `pg_dump -s` tras 001-003 consolidadas es **idéntico** al de 001-005 originales (incluidos GRANT y orden de
columnas), las 190 pruebas pasaron igual, y `dbmate rollback` ×4 deja la base vacía (solo `schema_migrations`).
`unaccent` pasó a la 001, así que solo la 001 requiere superusuario. Después se agregaron, a pedido del backend,
`fn_crear_contacto_usuario` y la columna `contacto_alias` en las conversaciones (213 pruebas).

## Roles

| Rol | Uso | Atributos |
|---|---|---|
| `migrator` | Dueño de todos los objetos y de la publicación; jobs de mantenimiento. | `NOLOGIN` en la 001. Sin SUPERUSER/CREATEROLE/CREATEDB; `CREATE` sobre la base (publicación). |
| `app_rw` | API por `haproxy:5000`. | `statement_timeout=5s`. Solo EXECUTE más el DML mínimo. |
| `app_ro` | API (lecturas) por `haproxy:5001`. | `default_transaction_read_only=on`. No ve `pass_hash`. |
| `cdc_lector` | Debezium (profile `cdc`). | `REPLICATION` sin superusuario; SELECT solo de lo publicado (sin `pass_hash`). |

**El repositorio no contiene contraseñas.** El servicio `db-init` aplica `asignar-credenciales.sql` con las
variables del `.env` raíz (`DB_MIGRATOR_PASSWORD`, `DB_APP_RW_PASSWORD`, `DB_APP_RO_PASSWORD`, `DB_CDC_PASSWORD`;
esta última opcional: vacía = `cdc_lector` sin LOGIN). Ver [`.env.example`](../../.env.example).

## Arranque

```bash
cp .env.example .env                                   # completar los secretos
docker compose up -d --wait haproxy backup             # HA + migraciones (dbmate) + credenciales + respaldos
docker compose --profile demo up db-seed               # usuarios de demo (opcional)
docker compose --profile cdc up -d --wait mysql kafka connect && docker compose --profile cdc up cdc-init
```

Migraciones nuevas: agregar `Postgres/migraciones/NNN_descripcion.sql` y `docker compose up dbmate`.
Conexión manual: `psql -h 127.0.0.1 -p 5000 -U app_rw -d cr_chat` (puertos publicados solo en `127.0.0.1`).

## Usuarios de demo

**Solo para desarrollo y demo.** Se cargan con `docker compose --profile demo up db-seed`. Los hashes argon2id del seed se generaron con PHP 8.4.27
(`password_hash(..., PASSWORD_ARGON2ID)`, m=65536, t=4, p=1).

| Usuario | Teléfono | Email | Contraseña |
|---|---|---|---|
| Ana Demo | `+50670000001` | `ana@demo.crchat.local` | `Demo-Ana-2026!` |
| Bruno Demo | `+50670000002` | `bruno@demo.crchat.local` | `Demo-Bruno-2026!` |
| Carla Demo | `+50670000003` | `carla@demo.crchat.local` | `Demo-Carla-2026!` |

Login por teléfono **o** email (ambos funcionan en `fn_credenciales_login`).

Datos que crea el seed:
- Contactos: Ana tiene a Bruno ("Bruno") y a Carla ("Carla (trabajo)"); Bruno tiene a Ana ("Ana"); Carla tiene a Bruno **sin alias** (se muestra "Bruno Demo").
- Conversaciones: Ana↔Bruno y Ana↔Carla. Carla ve la conversación con Ana con `es_contacto = false` (solicitud de mensaje).
- Ana tiene la descripción "Probando CR_Chat".
- Los `public_id` se generan al sembrar (no son fijos): consúltalos con `fn_credenciales_login('<email>')`.
- **Sin mensajes ni avatares:** el contenido se cifra en la API con una clave que la BD no conoce, y un avatar necesita un
  objeto real en MinIO. Ambos se crean a través de la API (`POST /conversations/{id}/messages`, `POST /uploads` + `PATCH /me`).

## Pruebas

```bash
# contra el clúster (el cliente corre en la red de compose):
psql -h haproxy -p 5000 -U app_rw -d cr_chat -f Postgres/pruebas/funciones_app_rw.sql  # 191 casos (líder)
psql -h haproxy -p 5001 -U app_ro -d cr_chat -f Postgres/pruebas/funciones_app_ro.sql  # 22 casos, EN LA RÉPLICA:
                                                                                       # sin objetos temporales
psql -h haproxy -p 5000 -U postgres -d cr_chat -f Postgres/pruebas/catalogo.sql        # 9 chequeos (el 7 devuelve
                                                                                       # solo mensaje_media_fk)
infra/scripts/probar-failover.sh && infra/scripts/probar-restauracion.sh
```

Las pruebas de funciones dejan datos: solo en bases desechables.

## Notas operativas

- Jobs (cron del contenedor `backup`, como `migrator`): `fn_purgar_sesiones()` diario y
  `fn_crear_particiones_auditoria(3)` mensual. Si llegan filas a `auditoria_default` de un mes que luego se
  quiere particionar, primero hay que moverlas.
- El job de huérfanos de media lo ejecuta la API (`app_rw`, servicio `ws`), porque además borra el objeto en MinIO.
- `pg_stat_statements` y `auto_explain` están activos (`shared_preload_libraries` en Patroni).
- `REVOKE CONNECT ON DATABASE cr_chat, postgres FROM PUBLIC` (db-init) y `pg_hba` con `scram-sha-256` solo desde la
  red de Docker (`samenet`); todo lo demás `reject`.
- El rol `Clients` del esquema anterior (con contraseña en el repo) desaparece: **rotar o eliminar** esa credencial
  donde se haya creado.
