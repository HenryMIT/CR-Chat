/// <reference types="vitest/config" />
import { fileURLToPath, URL } from 'node:url'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { msw } from 'msw/vite'

// Con CHOKIDAR_USEPOLLING=true (contenedor en Windows/macOS) se vigilan los
// archivos por sondeo: los eventos inotify no cruzan los bind mounts.
const usePolling = process.env.CHOKIDAR_USEPOLLING === 'true'

export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
    // Solo sirve/emite mockServiceWorker.js; el arranque de MSW lo decide
    // src/main.tsx según VITE_USE_MOCKS.
    msw({ mode: 'worker-only' }),
  ],
  resolve: {
    alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) },
  },
  server: {
    port: 5173,
    strictPort: true,
    watch: usePolling ? { usePolling: true, interval: 300 } : undefined,
  },
  test: {
    environment: 'jsdom',
    setupFiles: ['./src/test/setup.ts'],
    css: false,
    restoreMocks: true,
    // Valores fijos para que las pruebas no dependan del .env local.
    env: {
      VITE_API_URL: 'http://api.test/api/v1',
      VITE_WS_URL: 'ws://ws.test/ws',
      VITE_USE_MOCKS: 'false',
    },
  },
})
