# Optimización: EXPLAIN ANALYZE de las funciones principales

Medido el 2026-10-29 en un contenedor desechable (imagen `cr_chat_postgresql`, PostgreSQL 17, configuración
por defecto: `shared_buffers=128MB`, límite de 1 GiB de RAM). Los planes **internos** de cada función se
capturaron con `auto_explain` (`log_nested_statements=on`, `log_analyze=on`, `log_buffers=on`). Los tiempos son
de la **segunda** ejecución (caché caliente); la primera ejecución en frío fue de 1,5x a 6x más lenta.

Volumen sintético (`Postgres/pruebas/volumen.sql`; planes con `Postgres/pruebas/explain.sql`), con las
migraciones 001-004:

| Tabla | Filas |
|---|---|
| usuario | 20 003 |
| contacto | 200 034 (1/4 sin alias) |
| conversacion | 199 988 |
| participante | 399 976 |
| mensaje | 1 199 940, incluida una conversación "pesada" (Ana↔Bruno) con 200 000 mensajes |
| recibo_mensaje | 1 199 940 (1/3 sin ver) |
| Tamaño total de la BD | 831 MB (682 MB en la Fase 1; la diferencia son los `public_id`, `nonce` e índices nuevos) |

## Resultados (API v1, migración 003)

| Función (caso) | Plan principal | Total de la función |
|---|---|---|
| `fn_credenciales_login` (email) | Index Scan `usuario_email_uq` | 1,2 ms |
| Traducción uuid → id (todas) | Index Scan `usuario_public_id_uq` / `conversacion_public_id_uq` | < 0,05 ms |
| `fn_listar_contactos` (búsqueda `q`) | Index Scan `contacto_activo_ix` → `usuario_pkey`; Sort en memoria por `orden` (10 filas) | 5,8 ms |
| `fn_listar_conversaciones` (Ana: 22 conversaciones, una de 200k mensajes) | ids: Index Only Scan `participante_id_usuario_ix` + `conversacion_pkey`; detalle: último mensaje con Index Scan `mensaje_cursor_ix` + LIMIT 1 por conversación; no leídos con Index Only Scan `recibo_no_visto_ix` + LIMIT 100 | 10,6 ms |
| `fn_listar_mensajes` primera página (50, conv. de 200k) | Index Only Scan `mensaje_cursor_ix` + LIMIT, sin Sort | 5,2 ms |
| `fn_listar_mensajes` `before` profundo (cursor a ~150k) | Index Only Scan `mensaje_cursor_ix` (Index Cond sobre el cursor) | 4,9 ms |
| `fn_listar_mensajes` `after` (resincronización) | Index Only Scan **Backward** `mensaje_cursor_ix` | 5,0 ms |
| `fn_marcar_recibos` `seen` caso típico (2 pendientes) | Nested Loop: Index Scan `recibo_no_visto_ix` → `mensaje_id_conv_uq` | 2,1 ms |
| `fn_perfil_publico` | PK + `contacto_par_uq` + `conversacion_par_uq` + PK de `bloqueo` | 1,6 ms |
| `fn_listar_relacionados` | `contacto_activo_ix` ∪ `contacto_contact_user_id_ix` ∪ `participante_id_usuario_ix` | 2,0 ms |
| `fn_marcar_recibos` patológico (66 668 recibos pendientes en una llamada) | Hash Join con Seq Scan de `mensaje` (correcto para ese volumen) | 870 ms |

En `fn_listar_mensajes`, de los ~5 ms, ~4 ms son la "vista" `fn__mensajes` para 50 filas: llama por fila a
`fn__estado_mensaje` (recibos del mensaje por PK) y `fn__media_json`. Es lineal en el tamaño de página y no
en el de la conversación.

## Hallazgos y correcciones aplicadas

### Fase 1 (siguen vigentes)

1. **Login con Seq Scan** cuando la búsqueda por email o teléfono iba en un `CASE` dentro del `WHERE`. Se
   reescribió en dos ramas `RETURN QUERY` (Index Scan sobre el UNIQUE correspondiente).
2. **Contador de no leídos de 342 ms** recorriendo todos los mensajes. Corrección: `recibo_mensaje.id_conversacion`
   (redundancia amarrada por FK compuestas), índice parcial `recibo_no_visto_ix` y tope `LIMIT 100`.
   Resultado: O(min(no leídos, 100)) por conversación.

### Fase 1b (API v1)

3. **Último mensaje del listado con lápidas.** `mensaje_cursor_ix` era parcial (`WHERE deleted_at IS NULL`) y la
   API ahora lista las lápidas y las usa como `last_message`; con el índice parcial el `ORDER BY … LIMIT 1` de un
   mensaje borrado no podía usarlo. El índice pasa a ser completo; el `LATERAL … LIMIT 1` cuesta ~0,01 ms por
   conversación.
4. **Marcador de recibos por orden real `(created_at, id)`.** La versión de la Fase 1 marcaba `id_mensaje <= n`,
   que no coincide con el orden visible si dos inserciones concurrentes reciben `id` y `created_at` en orden
   distinto. Ahora se une cada recibo **pendiente** con su mensaje por PK (Nested Loop desde el índice parcial).
   Para que `delivered` también recorra solo pendientes se añadió `recibo_no_entregado_ix`.
5. **Cursor de mensajes por `public_id`.** El cursor es el uuid del mensaje; la función obtiene su
   `(created_at, id)` con `mensaje_public_id_uq` validando que sea de la conversación. Costo: un Index Scan extra
   (< 0,05 ms) y ningún `bigint` en el cursor.
6. **Búsqueda de contactos sin acentos.** El orden y el filtro usan `fn_normalizar(coalesce(alias, nombre))`
   (cruza dos tablas, no es indexable). Se descartó un índice trigram: la búsqueda siempre está acotada a la agenda
   de un usuario (`contacto_activo_ix`), y ordenar decenas o cientos de filas en memoria cuesta < 1 ms. Se
   retiraron `contacto_listado_ix` y el GIN trigram de la Fase 1 (ya no los usa ninguna consulta).
7. **Índice redundante retirado:** `mensaje_id_remitente_ix` (lo cubre `mensaje_client_id_uq (id_remitente, client_id)`).
8. **Caso patológico de recibos (870 ms, 66k filas).** Lo domina la escritura (66k tuplas nuevas + índices); el
   planificador elige correctamente Hash Join. No es un caso real (el cliente marca lo que tiene en pantalla); si
   apareciera, la API puede marcar por lotes acotando `up_to_message_id`.

## Fase 2 (aplicado)

- `shared_preload_libraries = 'pg_stat_statements,auto_explain'` en la DCS de Patroni (`infra/patroni/patroni.yml`):
  `auto_explain.log_min_duration = 500ms` (sin `log_analyze`, para no penalizar todas las consultas),
  `log_min_duration_statement = 1s`, `track_io_timing = on`. `pg_stat_statements` ya recolecta en el líder:
  tras las pruebas, la función más costosa por llamada fue `fn_registrar_usuario` (≈ 9 ms, dominada por los
  triggers de auditoría y los UNIQUE), y las lecturas de listado quedan en 1-4 ms con el seed.
- Memoria por nodo (límite 640 MiB): `shared_buffers = 128MB`, `effective_cache_size = 320MB`, `work_mem = 4MB`,
  `maintenance_work_mem = 64MB`, `max_connections = 150` (50 `app_rw` + 50 `app_ro` + 5 `migrator` + 3 `cdc_lector`
  + replicación y reserva).
- Jobs como `migrator` en el contenedor `backup`: `fn_crear_particiones_auditoria(3)` mensual y
  `fn_purgar_sesiones()` diario (ver `docs/db/recuperacion.md`).
- Funciones nuevas a pedido del backend, sin índices nuevos:
  - `fn_crear_contacto_usuario`: `usuario_public_id_uq` (objetivo), `fn__hay_relacion` usa `contacto_par_uq` en
    ambos sentidos y `conversacion_par_uq`; `fn__hay_bloqueo` usa la PK de `bloqueo` y `bloqueo_id_bloqueado_ix`.
    Todo son Index Scan por igualdad (< 0,1 ms con el volumen de la Fase 1b).
  - `contacto_alias` en `fn__conversaciones`: sale del `LEFT JOIN contacto` que ya existía para `es_contacto`
    (`contacto_par_uq`); no agrega trabajo al plan.
