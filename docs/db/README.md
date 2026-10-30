# Base de datos de CR_Chat

PostgreSQL 17 es la fuente de verdad. MySQL 8 será una réplica de solo lectura alimentada por CDC (Fase 2).

| Documento | Contenido |
|---|---|
| [`modelo.md`](modelo.md) | Diagrama ER, normalización, `ON DELETE` e índices |
| [`optimizacion.md`](optimizacion.md) | EXPLAIN ANALYZE de las funciones principales |
| [`../contratos/db-funciones.md`](../contratos/db-funciones.md) | Contrato de funciones para el backend: firmas, errores y endpoints |

## Estructura

```
Postgres/
  migraciones/              # dbmate: -- migrate:up / -- migrate:down
    001_roles_extensiones.sql   # requiere superusuario (roles de clúster + extensiones)
    002_esquema.sql             # tablas, constraints, índices, auditoría particionada, GRANT
    003_funciones.sql           # funciones v0 (ids bigint); las reemplaza la 005
    004_esquema_api_v1.sql      # public_id uuid, media (MinIO), sesion por dispositivo,
                                #   nonce/key_id/client_id/lápida en mensaje (requiere superusuario: unaccent)
    005_funciones_api_v1.sql    # funciones de la API v1 (uuid), GRANT EXECUTE
  bootstrap/asignar-credenciales.sql   # LOGIN + contraseñas desde variables
  seed/demo.sql             # 3 usuarios demo (idempotente; requiere 001-005)
  pruebas/                  # pruebas de contrato (app_rw, app_ro), catálogo, volumen, explain
  postgres-init/            # ESQUEMA ANTERIOR (obsoleto); se retira en la Fase 2
```

## Roles

| Rol | Uso | Atributos |
|---|---|---|
| `migrator` | Es dueño de todos los objetos. dbmate lo usa a partir de la 002. | `NOLOGIN` en la migración. Sin SUPERUSER/CREATEROLE/CREATEDB. |
| `app_rw` | API por `haproxy:5000`. | `NOLOGIN` en la migración. `statement_timeout=5s`. Solo EXECUTE más el DML mínimo. |
| `app_ro` | API (lecturas) por `haproxy:5001`. | `NOLOGIN` en la migración. `default_transaction_read_only=on`. No ve `pass_hash`. |

**El repositorio no contiene contraseñas.** Al desplegar, un superusuario ejecuta:

```bash
psql "$SUPERUSER_URL" -v ON_ERROR_STOP=1 \
  -v migrator_password="$DB_MIGRATOR_PASSWORD" \
  -v app_rw_password="$DB_APP_RW_PASSWORD" \
  -v app_ro_password="$DB_APP_RO_PASSWORD" \
  -f Postgres/bootstrap/asignar-credenciales.sql
```

Las variables `DB_*_PASSWORD` vienen del `.env` local (ignorado por git) o de los secrets del orquestador. El
`.env.example` documenta los nombres sin valores. El rol `Clients` del esquema anterior, que tenía la contraseña en el repo,
desaparece: hay que **rotar o eliminar** esa credencial en cualquier entorno donde se haya creado.

## Aplicar desde cero

```bash
# 1) Migraciones. La primera vez (contiene 001 y 004, que crean extensiones) se ejecutan con el
#    superusuario de la imagen; ninguna tabla queda con dueño postgres porque 002+ hacen SET LOCAL ROLE migrator.
docker run --rm --network <red> -v "$PWD/Postgres/migraciones:/db/migrations:ro" \
  -e DATABASE_URL="postgres://postgres:${POSTGRES_PASSWORD}@<host>:5432/cr_chat?sslmode=disable" \
  ghcr.io/amacneil/dbmate:2 --no-dump-schema --wait up

# 2) Credenciales (ver arriba). 3) Seed de demo:
psql "$SUPERUSER_URL" -f Postgres/seed/demo.sql

# Migraciones posteriores, ya como migrator:
#   DATABASE_URL=postgres://migrator:${DB_MIGRATOR_PASSWORD}@haproxy:5000/cr_chat
```

Revertir todo: `dbmate rollback`, una vez por migración (005 → 004 → 003 → 002 → 001). La 005 restaura las
funciones de la 003 (copia literal en su `migrate:down`) y la 004 restaura el esquema de la 002 **con pérdida**:
las lápidas reciben un contenido de relleno, los contactos sin alias toman el nombre del usuario y se pierden
media, sesiones y `public_id`. Comprobado: el `pg_dump -s` tras `up` + 2 `rollback` es idéntico al de 001-003
salvo el orden de las columnas re-agregadas (`foto_perfil`, `media_url`). La 001 hace `DROP OWNED` y `DROP ROLE`
de los tres roles. Falla, a propósito, si alguno tiene privilegios en otra base del clúster.

## Usuarios de demo

**Solo para desarrollo y demo.** Los hashes argon2id del seed se generaron con PHP 8.4.27
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
psql -U app_rw -d cr_chat -f Postgres/pruebas/funciones_app_rw.sql   # 170 casos: login, registro, perfil público, contactos,
                                                                      # bloqueos, conversaciones, mensajes, recibos, media,
                                                                      # sesiones, presencia, baja, IDOR por public_id, privilegios
psql -U app_ro -d cr_chat -f Postgres/pruebas/funciones_app_ro.sql   # 20 casos: 12 funciones de lectura, sin pass_hash/sesiones/escritura
psql -U postgres -d cr_chat -f Postgres/pruebas/catalogo.sql         # SECURITY DEFINER, PUBLIC, FK sin índice, roles,
                                                                      # public_id en recursos, ningún id bigint en la API
```

Las pruebas dejan datos, así que solo se ejecutan en bases desechables.

## Notas operativas

- `fn_purgar_sesiones()` (solo `migrator`) borra sesiones revocadas o expiradas hace más de 30 días; programarla a diario (Fase 2).
- El job de huérfanos de media lo ejecuta la API (`app_rw`), porque además de la fila borra el objeto en MinIO.
- `pg_stat_statements` se crea en la 001, pero solo recolecta datos con `shared_preload_libraries` (Fase 2, Patroni).
- `auditoria` tiene particiones mensuales desde el mes anterior hasta 3 meses adelante, más `auditoria_default`. Hay que ejecutar
  `SELECT fn_crear_particiones_auditoria(3);` cada mes como `migrator`. Si llegan filas a `auditoria_default` de un mes
  que luego se quiere particionar, primero hay que moverlas.
- Recomendación para la Fase 2: `REVOKE CONNECT ON DATABASE cr_chat FROM PUBLIC` y, en `pg_hba.conf`, `scram-sha-256` solo desde la red interna.
