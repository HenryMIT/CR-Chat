/**
 * Interlocutor simulado para la demo con MSW: cuando escribes a un usuario de demo que no
 * está conectado, "su teléfono" confirma la entrega, se conecta, escribe… y responde.
 * Así se ven en acción ✓, ✓✓, "escribiendo…" y la presencia sin un segundo navegador.
 */
import type { MockDb } from './db'

const RESPUESTAS = [
  '¡Claro! Ahorita lo reviso 👀',
  'Pura vida, gracias por avisar.',
  'Jaja totalmente de acuerdo',
  'Dame un toque y te confirmo.',
  '¿Lo hablamos mañana en la mañana?',
  'Me parece excelente idea 🙌',
  'Listo, quedo atento.',
]

export function iniciarBot(db: MockDb): () => void {
  const pendientes = new Map<string, ReturnType<typeof setTimeout>[]>()
  let turno = 0

  const programar = (conversacionId: string, pasos: [number, () => void][]) => {
    for (const t of pendientes.get(conversacionId) ?? []) clearTimeout(t)
    pendientes.set(
      conversacionId,
      pasos.map(([ms, fn]) =>
        setTimeout(() => {
          try {
            fn()
            db.guardar()
          } catch {
            /* p. ej. bloqueo entre medias: el bot simplemente calla */
          }
        }, ms),
      ),
    )
  }

  return db.alPublicar((destinatario, evento) => {
    if (evento.type !== 'message.new') return
    const m = evento.data.message
    // Solo responde un destinatario simulado: sin conexión ni sesión activa en esta demo
    // (evita que el bot conteste "por" la persona que usa la app si su socket se cae).
    if (m.sender_id === destinatario || db.conectado(destinatario) || db.tieneSesionActiva(destinatario)) return
    const emisor = m.sender_id
    const conv = m.conversation_id
    if (db.hayBloqueo(emisor, destinatario)) return

    programar(conv, [
      [700, () => db.marcarRecibo(destinatario, conv, 'delivered', m.id)],
      [1500, () => db.fijarEnLinea(destinatario, true)],
      [1800, () => db.marcarRecibo(destinatario, conv, 'seen', m.id)],
      [2200, () => db.publicar(emisor, 'typing', { conversation_id: conv, user_id: destinatario, state: 'start' })],
      [
        4200,
        () => {
          const texto = RESPUESTAS[turno++ % RESPUESTAS.length] ?? 'Ok'
          db.enviarMensaje(destinatario, conv, { text: texto })
        },
      ],
      [9000, () => db.fijarEnLinea(destinatario, false)],
    ])
  })
}
