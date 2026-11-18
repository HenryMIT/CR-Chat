# AGENTS.md — CR_Chat

App de mensajería 1:1 (proyecto de portafolio Backend/Full-Stack) con foco en seguridad, alta disponibilidad de datos y tiempo real. Rama principal: `main` (remoto `origin` en GitHub); el trabajo nuevo va en ramas `feat/*`.

## Stack y estructura
- `datos/`: API REST `/api/v1` (PHP 8.4, Slim 4, PHP-DI) en `:8000` y WebSocket Workerman (`datos/ws/`) en `:8080`; Redis pub/sub.
- `presentacion/`: React 19 + Vite + TS estricto, TanStack Query, Zustand, Tailwind con tema propio, `:5173`. `VITE_USE_MOCKS=true` = demo con MSW sin backend.
- `Postgres/migraciones/` (dbmate), `infra/` (Patroni+etcd+HAProxy 5000 escritura/5001 lectura, pgBackRest→MinIO, CDC). `MysqlB/` = réplica de solo lectura (profile `cdc`).
- Contratos (fuente de verdad entre capas): `docs/contratos/openapi.yaml`, `ws-eventos.md`, `db-funciones.md`. Requisitos y decisiones: `docs/requerimientos-api.md`, `docs/db/`.

## Comandos
- Todo: `cp .env.example .env` → `docker compose up -d --wait haproxy backup` → `docker compose up web-datos ws web`. Demo: `docker compose --profile demo up db-seed`.
- Backend aislado: `datos/tests/entorno-pruebas.sh up|test|down` (PHPUnit + `api_test.py` + `ws_test.py`).
- Frontend: `docker compose run --rm web npm run lint|test|build|gen:api`.
- BD: `docker compose up dbmate`; pruebas SQL en `Postgres/pruebas/` (ver `docs/db/README.md`); `infra/scripts/probar-failover.sh`, `probar-restauracion.sh`.

## Convenciones
- Español en código comentado, mensajes, UI, docs y commits (verbo en presente: "Agrega…", "Fase N: …").
- Backend: imita `datos/src/Controllers/*` (`BaseController`, solo funciones `fn_*` con parámetros con nombre), errores RFC 9457 vía `datos/src/Handlers/DbErrorMap.php`.
- BD: migraciones nuevas `NNN_descripcion.sql` con `migrate:up/down`; funciones `SECURITY INVOKER`, `search_path` fijo, SQLSTATE `CRxxx`.

## Reglas de dominio / trampas conocidas
- PostgreSQL es la única fuente de verdad; la API nunca escribe en MySQL ni hace failover entre motores.
- IDOR: toda función de BD recibe el uuid del usuario autenticado; recurso ajeno → 404, nunca 403. Ids públicos siempre UUID.
- El contenido de mensajes se cifra en PHP (libsodium); la clave nunca llega a la BD. Contraseñas argon2id solo en PHP.
- Refresh token: rotación con detección de reutilización; el cliente debe serializar los refresh o la sesión se revoca.
- Un cambio de API/WS/BD empieza en el contrato de `docs/contratos/` y luego se implementa en ambos lados.

## Forma de trabajar
- Tareas grandes o que cruzan capas: plan primero y esperar aprobación. Delega en los subagentes de `.opencode/agents/` (`backend`, `dba`, `frontend`; sus permisos limitan sus carpetas) y cierra con `reviewer`. Pásales todo el contexto: no ven esta conversación.
- Cambios pequeños y enfocados. Al terminar: archivos tocados, resultado de pruebas, decisiones a revisar y pendientes.

## Memoria
- Al empezar, lee `MEMORY.md`. Al terminar una tarea, actualízalo (estado, decisiones con su porqué, errores a evitar) en ~50 líneas máximo.
- Si algo se vuelve regla permanente, propón moverlo aquí. Nunca guardes datos sensibles.

## Límites
- ✅ Siempre: ejecutar las pruebas de la capa tocada; mantener docs y contratos al día con el código; actualizar `MEMORY.md` al terminar.
- ⚠️ Pregunta antes: dependencias o servicios Docker nuevos, cambios de contrato, migraciones que alteren datos, commits/merge/push.
- 🚫 Nunca: leer/imprimir/commitear `.env` o secretos; `docker system prune`/`volume rm` o borrar `*Data/` (RAM del host 11 GiB, ~4 GiB libres: no levantes servicios de más); publicar puertos de BD fuera de `127.0.0.1`.

## Verificación
- Backend: `entorno-pruebas.sh test` con `FALLOS: 0` (incluye IDOR). Frontend: lint sin avisos, Vitest en verde, build sin errores TS. BD: pruebas de `Postgres/pruebas/` en verde.
- Interfaz: verifica con el MCP de Chrome DevTools (consola, red, vista móvil 375 px). `/pruebas <capa>` ejecuta las suites.
- Si algo no se pudo probar, dilo explícitamente.
