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
