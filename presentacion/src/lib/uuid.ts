/**
 * UUID v4 para `client_id`, ids de eventos WS e `Idempotency-Key`.
 * `crypto.randomUUID` solo existe en contextos seguros (https o localhost); si la app
 * se abre por IP de la red local con http se usa `getRandomValues`, que sí está disponible.
 */
export function nuevoUuid(): string {
  if (typeof crypto.randomUUID === 'function') return crypto.randomUUID()
  const b = crypto.getRandomValues(new Uint8Array(16))
  b[6] = ((b[6] ?? 0) & 0x0f) | 0x40
  b[8] = ((b[8] ?? 0) & 0x3f) | 0x80
  const h = Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('')
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`
}
