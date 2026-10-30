-- =============================================================================
-- Comprobaciones de catálogo (ejecutar como superusuario o migrator).
-- Cada consulta debe devolver 0 filas.
-- =============================================================================
\set ON_ERROR_STOP on
\echo '1) Funciones de migrator SECURITY DEFINER o sin search_path fijo (esperado: 0 filas)'
SELECT p.oid::regprocedure
FROM pg_proc p
WHERE p.pronamespace = 'public'::regnamespace AND p.proowner = 'migrator'::regrole
  AND (p.prosecdef OR NOT coalesce(p.proconfig, '{}') @> ARRAY['search_path=public, pg_temp']);

\echo '2) Funciones de migrator ejecutables por PUBLIC (esperado: 0 filas)'
SELECT p.oid::regprocedure
FROM pg_proc p
WHERE p.pronamespace = 'public'::regnamespace AND p.proowner = 'migrator'::regrole
  AND (p.proacl IS NULL OR EXISTS (
        SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'));

\echo '3) FK sin índice completo utilizable (esperado: 0 filas)'
-- Válido si un índice no parcial empieza por TODAS las columnas de la FK (en
-- cualquier orden), o si es UNIQUE/PK y su primera columna es una columna de la
-- FK de unicidad propia (caso recibo_mensaje PK (id_mensaje, id_usuario) para la
-- FK (id_mensaje, id_conversacion): id_mensaje ya es casi único).
SELECT c.conrelid::regclass AS tabla, c.conname
FROM pg_constraint c
WHERE c.contype = 'f' AND c.connamespace = 'public'::regnamespace
  AND c.conrelid IN (SELECT oid FROM pg_class WHERE relispartition = false)
  AND NOT EXISTS (
      SELECT 1 FROM pg_index i
      WHERE i.indrelid = c.conrelid
        AND i.indpred IS NULL
        AND (
             ((i.indkey::int2[])[0:array_length(c.conkey, 1) - 1] @> c.conkey
              AND (i.indkey::int2[])[0:array_length(c.conkey, 1) - 1] <@ c.conkey)
          OR (i.indisunique AND (i.indkey::int2[])[0] = c.conkey[1])
        ));

\echo '4) Roles de la app con atributos peligrosos (esperado: 0 filas)'
SELECT rolname FROM pg_roles
WHERE rolname IN ('migrator', 'app_rw', 'app_ro')
  AND (rolsuper OR rolcreaterole OR rolcreatedb OR rolbypassrls OR rolreplication);

\echo '5) Recursos expuestos por la API sin public_id uuid NOT NULL UNIQUE (esperado: 0 filas)'
SELECT t.relname
FROM unnest(ARRAY['usuario', 'contacto', 'conversacion', 'mensaje', 'sesion', 'media']) AS r(nombre)
JOIN pg_class t ON t.relname = r.nombre AND t.relnamespace = 'public'::regnamespace
WHERE NOT EXISTS (
    SELECT 1 FROM pg_attribute a
    JOIN pg_index i ON i.indrelid = t.oid AND i.indisunique AND i.indnatts = 1 AND i.indkey[0] = a.attnum
    WHERE a.attrelid = t.oid AND a.attname = 'public_id' AND a.atttypid = 'uuid'::regtype AND a.attnotnull);

\echo '6) Funciones de la API (no auxiliares) con un id bigint de entrada o salida (esperado: 0 filas)'
-- Los bigint son internos: solo las auxiliares fn__* los reciben o devuelven.
SELECT p.oid::regprocedure, x.nombre
FROM pg_proc p
CROSS JOIN LATERAL unnest(coalesce(p.proallargtypes, p.proargtypes::oid[]), p.proargnames) AS x(tipo, nombre)
WHERE p.pronamespace = 'public'::regnamespace AND p.proowner = 'migrator'::regrole
  AND p.proname LIKE 'fn\_%' AND p.proname NOT LIKE 'fn\_\_%'
  AND x.tipo = 'int8'::regtype AND x.nombre ~ '^(p_)?id';

\echo '7) FK sin ON DELETE explícito distinto de NO ACTION, salvo las justificadas (esperado: solo mensaje_media_fk)'
SELECT conrelid::regclass, conname FROM pg_constraint
WHERE contype = 'f' AND connamespace = 'public'::regnamespace AND confdeltype = 'a';
