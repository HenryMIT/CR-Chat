import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import '@/styles/index.css'
import { env } from '@/lib/env'
import { App } from '@/app/App'

async function arrancar(): Promise<void> {
  if (env.usarMocks) {
    // Import dinámico: con VITE_USE_MOCKS=false los mocks no entran en el bundle.
    const { iniciarMocks } = await import('./mocks/navegador')
    await iniciarMocks({ apiUrl: env.apiUrl, wsUrl: env.wsUrl })
  }
  const raiz = document.getElementById('root')
  if (!raiz) throw new Error('Falta el elemento #root')
  createRoot(raiz).render(
    <StrictMode>
      <App />
    </StrictMode>,
  )
}

void arrancar()
