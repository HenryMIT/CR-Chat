/** Claves de TanStack Query centralizadas (evita cadenas sueltas). */
export const claves = {
  yo: () => ['yo'] as const,
  sesiones: () => ['sesiones'] as const,
  conversaciones: () => ['conversaciones'] as const,
  conversacion: (id: string) => ['conversacion', id] as const,
  mensajes: (conversacionId: string) => ['mensajes', conversacionId] as const,
  todosLosMensajes: () => ['mensajes'] as const,
  contactos: (q = '') => ['contactos', q] as const,
  todosLosContactos: () => ['contactos'] as const,
  bloqueos: () => ['bloqueos'] as const,
}
