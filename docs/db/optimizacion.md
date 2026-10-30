# Optimización: EXPLAIN ANALYZE de las funciones principales

Medido el 2026-10-29 en un contenedor desechable (imagen `cr_chat_postgresql`, PostgreSQL 17, configuración
por defecto: `shared_buffers=128MB`). Los planes **internos** de cada función se capturaron con
`auto_explain` (`log_nested_statements=on`, `log_analyze=on`).

Volumen sintético (`Postgres/pruebas/volumen.sql`; planes con `Postgres/pruebas/explain.sql`):

| Tabla | Filas |
|---|---|
| usuario | 20 003 |
| contacto | 200 034 |
| conversacion | 199 988 |
| participante | 399 976 |
| mensaje | 1 199 952, incluida una conversación "pesada" (Ana↔Bruno) con 200 000 mensajes |
| recibo_mensaje | 1 199 952 (1/3 sin ver) |
| Tamaño total de la BD | 682 MB |

## Resultados

| Función (caso) | Plan principal | Tiempo de la consulta interna | Total de la función |
|---|---|---|---|
| `fn_credenciales_login` (email) | Index Scan `usuario_email_uq` | 0,8 ms | 3,8 ms |
| `fn_listar_contactos` (búsqueda) | Index Scan `contacto_listado_ix` → `usuario_pkey` | 3,2 ms | 9,2 ms (en frío) |
| `fn_listar_conversaciones` (Ana, 22 conv., una con 200k mensajes) | Index Only Scan `participante_id_usuario_ix`; no leídos con Index Only Scan `recibo_no_visto_ix` + LIMIT 100 | 8,2 ms | 14,7 ms |
| `fn_listar_mensajes` primera página (conv. de 200k) | Index Scan `mensaje_cursor_ix` + LIMIT 30, sin Sort | 0,6 ms | 1,9 ms |
| `fn_listar_mensajes` página profunda (cursor a ~150k msgs) | Index Scan `mensaje_cursor_ix` (Index Cond sobre el cursor) | 1,0 ms | 1,8 ms |
| `fn_marcar_visto` caso típico (2 recibos) | Index Scan `recibo_no_visto_ix` | 1,0 ms | 4,6 ms |
| `fn_enviar_mensaje` | Inserciones + Index Scan `conversacion_pkey` | — | 9,7 ms (en frío, incluye validación de FK) |
| `fn_marcar_visto` patológico (66 668 recibos pendientes) | Bitmap `recibo_participante_ix` | 681 ms | — |

## Hallazgos y correcciones aplicadas

1. **Login con Seq Scan (15 ms con 20k usuarios; crecería linealmente).** La primera versión de
   `fn_credenciales_login` era SQL con `WHERE CASE WHEN '@' … THEN email = … ELSE telefono = … END`, y el
   planificador no puede usar índices a través de ese `CASE`. Se reescribió en plpgsql con dos ramas
   `RETURN QUERY` y ahora hace un Index Scan sobre el UNIQUE correspondiente.

2. **Contador de no leídos de 342 ms.** La primera versión contaba con
   `recibo JOIN mensaje WHERE m.id_conversacion = cv.id`. El plan recorría *todos* los mensajes de la conversación
   (`mensaje_cursor_ix`, unas 9 000 filas por conversación en promedio y 200k en la pesada) y probaba un recibo por cada uno.
   Corrección:
   - `recibo_mensaje.id_conversacion` (redundancia amarrada por FK compuestas, ver `modelo.md`);
   - índice parcial `recibo_no_visto_ix (id_usuario, id_conversacion, id_mensaje) WHERE visto_at IS NULL`;
   - un tope `LIMIT 100` en el conteo (la UI muestra "99+").

   Resultado: 342 ms → **8 ms**. Ahora el costo es O(min(no leídos, 100)) por conversación.

3. **`fn_marcar_entregado` / `fn_marcar_visto`** dejaron de hacer `JOIN mensaje` gracias al mismo cambio. En el caso
   típico tardan alrededor de 1 ms. En el caso patológico de 66k recibos pendientes en una sola llamada, el tiempo lo domina la escritura
   (66k tuplas nuevas + índices). No es un caso real: el cliente marca como visto lo que tiene en pantalla. Si
   apareciera, la API puede marcar en lotes acotando `p_hasta_id`.

4. **Paginación de mensajes:** el keyset `(created_at, id) < cursor` usa `mensaje_cursor_ix` sin Sort y con el mismo
   costo en la primera página que en una profunda (≈1 ms). El esquema anterior usaba `LIMIT 15` sin offset y devolvía los más viejos.

## Pendientes (Fase 2)

- Habilitar `shared_preload_libraries = 'pg_stat_statements,auto_explain'` en Patroni
  (`auto_explain.log_min_duration = '250ms'`) para observar en producción.
- Ajustar `shared_buffers`, `work_mem` y `effective_cache_size` según los límites de memoria del compose.
- Programar `fn_crear_particiones_auditoria(3)` mensualmente.
