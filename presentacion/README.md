# CR_Chat · frontend

React 19 + Vite 8 + TypeScript estricto. TanStack Query (caché, reintentos, scroll infinito por
cursor), Zustand (sesión y estado efímero), React Router 8, Tailwind 4 con tema propio. El cliente
HTTP se genera desde `docs/contratos/openapi.yaml` (`openapi-typescript` + `openapi-fetch`) y el
tiempo real usa WebSocket nativo según `docs/contratos/ws-eventos.md`.

## Arranque

### Con Docker (recomendado, igual en Linux, Windows y macOS)

```bash
docker compose up web          # http://localhost:5173 con HMR
```

`node_modules` vive en el volumen con nombre `web_node_modules` (no se mezcla con el host) y
`CHOKIDAR_USEPOLLING=true` activa la vigilancia por sondeo, necesaria para el HMR con bind mounts en
Windows/macOS. Tras cambiar dependencias:

```bash
docker compose run --rm web npm install <paquete>   # actualiza package.json, lock y el volumen
docker compose build web                            # reconstruye la imagen
```

Comandos útiles dentro del contenedor: `docker compose run --rm web npm test` (o `run lint`,
`run build`, `run gen:api`).

### Sin Docker

Requiere Node 24.

```bash
cd presentacion
cp .env.example .env.local
npm ci
npm run dev
```

## Variables (`.env.example`)

| Variable | Por defecto | Uso |
|---|---|---|
| `VITE_API_URL` | `http://localhost:8000/api/v1` | Base de la API REST v1 |
| `VITE_WS_URL` | `ws://localhost:8080/ws` | Servidor WebSocket (`wss://` en producción) |
| `VITE_USE_MOCKS` | `true` | `true`: API y WebSocket simulados con MSW en el navegador. `false`: backend real |

Todo lo `VITE_*` acaba en el bundle público: nunca secretos.

## Modo demo (MSW)

Con `VITE_USE_MOCKS=true` la app funciona sin backend: handlers HTTP derivados del contrato
(`src/mocks/handlers.ts`), un servidor WebSocket simulado con `ws.link` de MSW (`src/mocks/ws.ts`)
y una base en memoria con los usuarios de `docs/db/README.md` (`src/mocks/db.ts`), que se conserva en
`localStorage` entre recargas. Un interlocutor simulado (`src/mocks/bot.ts`) confirma la entrega, se
conecta, escribe y responde, para ver ✓, ✓✓, «escribiendo…» y la presencia. Para volver a los
datos iniciales: `crchatReiniciarDemo()` en la consola.

| Usuario | Teléfono | Contraseña |
|---|---|---|
| Ana Demo | `+50670000001` (o `70000001`) | `Demo-Ana-2026!` |
| Bruno Demo | `+50670000002` | `Demo-Bruno-2026!` |
| Carla Demo | `+50670000003` | `Demo-Carla-2026!` |

Entra como Carla para ver una **solicitud de mensaje** (Ana no está en su agenda).

## Scripts

| Script | Qué hace |
|---|---|
| `npm run dev` | Servidor de desarrollo |
| `npm run build` | `tsc -b` + build de producción |
| `npm run lint` | ESLint (typescript-eslint strict type-checked, reglas de hooks) sin avisos |
| `npm test` | Vitest + Testing Library + MSW (HTTP y WebSocket) |
| `npm run gen:api` | Regenera `src/api/schema.d.ts` desde el contrato |

## Estructura

```
src/
  api/          cliente openapi-fetch, tipos del contrato, errores RFC 9457, claves de consulta
  auth/         sesión (token en memoria, refresh silencioso, BroadcastChannel) y guardas de ruta
  cache/        operaciones puras sobre la caché (mensajes y conversaciones)
  realtime/     ChatSocket (reconexión, heartbeat, reauth), useChatSocket, eventos → caché, resync
  features/     auth, conversaciones, chat, contactos, perfil, subidas (URL prefirmada)
  components/ui iconos, botones, campos, avatar, diálogo, menú, avisos
  layout/       AppShell (riel de escritorio / barra inferior en móvil), selector de tema
  mocks/        MSW: db de demo, handlers HTTP, WebSocket simulado, bot
  styles/       tema Tailwind propio
  test/         servidor MSW de pruebas y utilidades
```

## Decisiones de diseño

- **Sesión**: el access token solo vive en memoria. El refresh se guarda en `localStorage` para
  sobrevivir a recargas y compartirse entre pestañas; la rotación se serializa entre pestañas con Web
  Locks (el servidor revoca la sesión si se reutiliza un refresh rotado) y es *single-flight* dentro
  de cada pestaña. Riesgo asumido: un XSS podría leer el refresh; el requerimiento A-15 (cookie
  `HttpOnly`) lo eliminaría y el cliente solo tendría que dejar de enviarlo en el cuerpo.
- **Tiempo real**: `ChatSocket` es una clase sin React, probada con temporizadores falsos. Backoff
  1 s, 2 s, 4 s… 30 s con jitter ±25 %, ping cada 25 s y conexión muerta sin pong en 10 s; 4401
  renueva el token (o vuelve al login si es `session_revoked`), 4029 espera 30 s, 1000/1008 no
  reintentan. Tras reconectar se resincroniza por REST con `after=` (contrato §6).
- **Caché**: los eventos se aplican como *upsert* idempotente por `id`/`client_id`, de modo que
  la respuesta REST y `message.new` pueden llegar en cualquier orden. Los mensajes optimistas se
  conservan aunque la consulta se refresque.
- **UI**: paleta propia «selva» (verde azulado), «guaria» (orquídea, acento) y «piedra» (neutros),
  con la paleta por defecto de Tailwind eliminada; tokens semánticos para claro/oscuro, todos con
  contraste AA. Tipografía Plus Jakarta Sans autoalojada y escala compacta pensada para chat.
- **Accesibilidad**: `role="log"` en el historial, menús con patrón ARIA *menu button*, diálogos
  nativos `<dialog>`, foco visible en todo, enlace «Saltar al contenido», flechas en la lista de
  chats, estados anunciados (`role="status"`/`alert`) y `prefers-reduced-motion`.
- **Recibos**: reloj = enviando, ✓ tenue = enviado, ✓ = entregado, ✓✓ en color de acento = visto.
