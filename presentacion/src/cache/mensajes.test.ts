import { describe, expect, it } from 'vitest'
import type { MensajeChat } from '@/api/tipos'
import { aplicarRecibo, cacheVacia, marcarBorrado, mensajesOrdenados, upsertMensaje, type CacheMensajes } from './mensajes'

const YO = 'yo'
const OTRO = 'otro'

function msg(id: string, minuto: number, extra: Partial<MensajeChat> = {}): MensajeChat {
  return {
    id,
    conversation_id: 'c',
    sender_id: YO,
    client_id: null,
    text: id,
    media: null,
    created_at: `2026-10-29T10:${String(minuto).padStart(2, '0')}:00.000Z`,
    edited_at: null,
    deleted_at: null,
    cursor: id,
    status: 'sent',
    ...extra,
  }
}

describe('caché de mensajes', () => {
  it('upsert es idempotente y reconcilia el optimista por client_id', () => {
    let c: CacheMensajes = cacheVacia()
    c = upsertMensaje(c, msg('tmp', 5, { client_id: 'k', local: 'enviando', cursor: '' }))
    c = upsertMensaje(c, msg('real', 5, { client_id: 'k' }))
    c = upsertMensaje(c, msg('real', 5, { client_id: 'k' }))
    const lista = mensajesOrdenados(c)
    expect(lista).toHaveLength(1)
    expect(lista[0]).toMatchObject({ id: 'real' })
    expect(lista[0]?.local).toBeUndefined()
  })

  it('ordena por (created_at, id) y recorre las páginas de antigua a reciente', () => {
    const c: CacheMensajes = {
      pages: [
        { items: [msg('c', 3), msg('d', 4)], next_cursor: 'x' },
        { items: [msg('a', 1), msg('b', 2)], next_cursor: null },
      ],
      pageParams: [null, 'x'],
    }
    const con = upsertMensaje(c, msg('e', 0))
    expect(mensajesOrdenados(c).map((m) => m.id)).toEqual(['a', 'b', 'c', 'd'])
    expect(con.pages[0]?.items.map((m) => m.id)).toEqual(['e', 'c', 'd'])
  })

  it('los recibos suben el estado de mis mensajes hasta el indicado y nunca bajan', () => {
    let c = cacheVacia()
    c = upsertMensaje(c, msg('m1', 1))
    c = upsertMensaje(c, msg('m2', 2, { status: 'seen' }))
    c = upsertMensaje(c, msg('x', 3, { sender_id: OTRO, status: undefined }))
    c = upsertMensaje(c, msg('m3', 4))
    const r = aplicarRecibo(c, 'm2', 'delivered', YO)
    expect(r).not.toBeNull()
    const estados = Object.fromEntries(mensajesOrdenados(r ?? undefined).map((m) => [m.id, m.status]))
    expect(estados).toEqual({ m1: 'delivered', m2: 'seen', x: undefined, m3: 'sent' })
    expect(aplicarRecibo(c, 'desconocido', 'seen', YO)).toBeNull()
  })

  it('el borrado deja una lápida sin contenido', () => {
    const c = upsertMensaje(cacheVacia(), msg('m', 1))
    const b = mensajesOrdenados(marcarBorrado(c, 'm', '2026-10-29T11:00:00.000Z'))[0]
    expect(b).toMatchObject({ text: null, media: null, deleted_at: '2026-10-29T11:00:00.000Z' })
  })
})
