---
description: Planifica una funcionalidad o cambio antes de tocar código (uso - /feature descripción)
agent: plan
---
Quiero añadir esta funcionalidad o cambio en CR_Chat: $ARGUMENTS

Ten en cuenta el estado actual del proyecto: @MEMORY.md

Antes de escribir código, prepárame un plan con:
1. Qué capas toca (BD, API, WS, frontend) y qué subagente hace cada parte (`dba`, `backend`, `frontend`), respetando su alcance y las reglas de AGENTS.md.
2. Qué cambia en los contratos de `docs/contratos/` (OpenAPI, eventos WS, funciones de BD). El contrato se actualiza primero.
3. Qué archivos se crean o modifican y qué cambia en cada uno.
4. Riesgos de seguridad (IDOR, secretos, validación) y migraciones con su `migrate:down`.
5. Pruebas que lo verifican: PHPUnit/`api_test.py`/`ws_test.py`, pruebas SQL, Vitest y verificación visual con Chrome DevTools si hay interfaz.
6. Casos límite y dudas que debo decidir yo antes de empezar.
7. Qué actualizarías en AGENTS.md y en MEMORY.md.

Si el cambio es grande (más de unas 10 tareas), propón dividirlo. No modifiques ningún archivo hasta que apruebe el plan.
