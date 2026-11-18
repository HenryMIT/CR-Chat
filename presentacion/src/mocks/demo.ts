/**
 * Usuarios de demo de docs/db/README.md (públicos, solo desarrollo). Archivo aparte para
 * que la pantalla de entrada pueda mostrarlos sin arrastrar los mocks al bundle.
 */
export const CREDENCIALES_DEMO = [
  { nombre: 'Ana Demo', email: 'ana@demo.crchat.local', phone: '+50670000001', password: 'Demo-Ana-2026!' },
  { nombre: 'Bruno Demo', email: 'bruno@demo.crchat.local', phone: '+50670000002', password: 'Demo-Bruno-2026!' },
  { nombre: 'Carla Demo', email: 'carla@demo.crchat.local', phone: '+50670000003', password: 'Demo-Carla-2026!' },
] as const
