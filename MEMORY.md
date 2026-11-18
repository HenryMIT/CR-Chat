# MEMORY.md — CR_Chat

Memoria del proyecto entre sesiones. Máximo ~50 líneas: resume o elimina lo que ya no aporte. Nunca datos sensibles.

## Estado actual
- Fase 1 (contratos) y Fase 2 (implementación) terminadas y fusionadas en `main`. Sesión 2026-11-18: docs obsoletas corregidas y frontend probado de extremo a extremo contra la API/WS reales (todo ✅ tras 3 correcciones).
- Backend: PHPUnit 41 OK, `api_test.py` 185/0, `ws_test.py` 34/0. Frontend: lint limpio, Vitest 48 OK, build OK.
- BD: migraciones 001-004, HA con Patroni, PITR con pgBackRest, CDC a MySQL (profile `cdc`); 213 pruebas SQL.
- Arnés: `AGENTS.md`, este archivo, subagentes en `.opencode/agents/` (backend, dba, frontend, reviewer; permisos por carpeta verificados), comandos `/feature` y `/pruebas`, MCP chrome-devtools (config global, Chromium de Playwright, headless).

## Decisiones (y por qué)
- PostgreSQL única fuente de verdad: el failover a MySQL del trabajo universitario reasignaba ids y rompía los JWT.
- Datos del esquema anterior **no se migran**; seed de demo nuevo (Ana, Bruno, Carla).
- Recursos ajenos → 404 (IDOR). Ids públicos UUID.
- Firma SigV4 propia en vez de aws-sdk-php (cuatro operaciones no justifican decenas de MB).
- Refresh en `localStorage` serializado con Web Locks; cookie `HttpOnly` (A-15) disponible como opt-in.
- `.claude/agents/` se conserva por si se usa Claude Code; la referencia son `.opencode/agents/`.
- E2E con el entorno aislado del backend (`entorno-pruebas.sh`, 1 nodo PG): la HA ya estaba validada y ahorra ~1,5 GB de RAM.

## Aprendizajes y errores a evitar
- Los mocks MSW deben validar igual que la API real: aceptaban teléfonos sin E.164 y escondieron 2 fallos.
- Al cerrar un pedido entre agentes (DBA → backend) revisar código y docs de ambos lados.
- Dos refresh simultáneos con el mismo token revocan la sesión.
- La RAM es el límite real (~4 GiB libres); el disco ya no (144 GB libres). Aun así, nada de `prune` ni borrar `*Data/`.

## Pendientes
- Crear el repositorio remoto y subir `main` (la rama `feat/multiagente` ya se fusionó en local el 2026-11-18).
- G-09: validar respuestas contra `openapi.yaml`.
- UI: la lista de chats no usa `contact_alias`; botones de Sesiones con el mismo nombre accesible; campos sin `id`/`name`; el chat largo carga 2 páginas al abrir.
- Búsqueda: un número corto sin `+` se trata como teléfono (+506…), así que buscar "2" no encuentra alias con "2"; tampoco normaliza `00506`.
- Copia de respaldos fuera del host (3-2-1) y alertas de backup.
- Rotar/eliminar la credencial del rol `Clients` del esquema anterior donde se haya creado.
