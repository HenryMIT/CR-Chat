---
description: Ejecuta las pruebas de una capa y resume el resultado (uso - /pruebas backend|frontend|bd|todo)
agent: build
---
Ejecuta las pruebas de CR_Chat para: $ARGUMENTS (si está vacío, usa `git status` para deducir qué capas cambiaron).

- **backend**: `datos/tests/entorno-pruebas.sh up` (solo si no está levantado) y `datos/tests/entorno-pruebas.sh test` → PHPUnit, `api_test.py` y `ws_test.py`.
- **frontend**: `docker compose run --rm web npm run lint`, `docker compose run --rm web npm test` y `docker compose run --rm web npm run build`.
- **bd**: las pruebas de `Postgres/pruebas/` según `docs/db/README.md` (app_rw en el líder, app_ro en la réplica, catálogo). Requiere el clúster levantado; si no lo está, dilo y no lo levantes sin preguntarme.
- **todo**: las tres anteriores.

Reglas:
- No modifiques archivos ni intentes arreglar fallos: solo ejecuta y reporta.
- Nunca leas ni imprimas `.env`. No bajes entornos (`down`) salvo que te lo pida.

Responde con una tabla por capa (suite, total, fallos) y, si algo falla, el nombre de cada caso fallido con su mensaje en una línea. Termina diciendo qué no se pudo ejecutar y por qué.
