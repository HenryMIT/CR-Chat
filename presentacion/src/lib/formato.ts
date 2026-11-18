/** Formateo de fechas, tamaños y teléfonos para la interfaz (es-CR). */

const LOCALE = 'es-CR'

const fmtHora = new Intl.DateTimeFormat(LOCALE, { hour: 'numeric', minute: '2-digit' })
const fmtDiaSemana = new Intl.DateTimeFormat(LOCALE, { weekday: 'long' })
const fmtFechaCorta = new Intl.DateTimeFormat(LOCALE, { day: 'numeric', month: 'short' })
const fmtFechaLarga = new Intl.DateTimeFormat(LOCALE, { day: 'numeric', month: 'long', year: 'numeric' })
const fmtCompleta = new Intl.DateTimeFormat(LOCALE, { dateStyle: 'full', timeStyle: 'short' })

function inicioDelDia(d: Date): number {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
}

function diasDeDiferencia(fecha: Date, ahora: Date): number {
  return Math.round((inicioDelDia(ahora) - inicioDelDia(fecha)) / 86_400_000)
}

export function horaCorta(iso: string): string {
  return fmtHora.format(new Date(iso))
}

export function fechaCompleta(iso: string): string {
  return fmtCompleta.format(new Date(iso))
}

/** Marca de tiempo compacta para la lista de chats: hora, "Ayer", día o fecha. */
export function marcaLista(iso: string, ahora = new Date()): string {
  const fecha = new Date(iso)
  const dias = diasDeDiferencia(fecha, ahora)
  if (dias <= 0) return fmtHora.format(fecha)
  if (dias === 1) return 'Ayer'
  if (dias < 7) return fmtDiaSemana.format(fecha)
  return fmtFechaCorta.format(fecha)
}

/** Separador de día dentro de la conversación. */
export function etiquetaDia(iso: string, ahora = new Date()): string {
  const fecha = new Date(iso)
  const dias = diasDeDiferencia(fecha, ahora)
  if (dias <= 0) return 'Hoy'
  if (dias === 1) return 'Ayer'
  if (dias < 7) {
    const d = fmtDiaSemana.format(fecha)
    return d.charAt(0).toUpperCase() + d.slice(1)
  }
  return fmtFechaLarga.format(fecha)
}

export function mismoDia(a: string, b: string): boolean {
  return inicioDelDia(new Date(a)) === inicioDelDia(new Date(b))
}

/** "hace 5 min", "ayer a las 3:10 p. m."… para la última conexión. */
export function ultimaVez(iso: string, ahora = new Date()): string {
  const fecha = new Date(iso)
  const minutos = Math.round((ahora.getTime() - fecha.getTime()) / 60_000)
  if (minutos < 1) return 'hace un momento'
  if (minutos < 60) return `hace ${minutos} min`
  const dias = diasDeDiferencia(fecha, ahora)
  if (dias === 0) return `hoy a las ${fmtHora.format(fecha)}`
  if (dias === 1) return `ayer a las ${fmtHora.format(fecha)}`
  return `el ${fmtFechaCorta.format(fecha)}`
}

export function tamanoArchivo(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

export function iniciales(nombre: string): string {
  const partes = nombre.trim().split(/\s+/).filter(Boolean)
  const primera = partes[0]?.[0] ?? '?'
  const segunda = partes.length > 1 ? (partes[partes.length - 1]?.[0] ?? '') : ''
  return (primera + segunda).toUpperCase()
}

const E164 = /^\+[1-9][0-9]{7,14}$/

/**
 * Normaliza lo que escribe la persona a E.164: quita espacios, guiones y paréntesis;
 * un número local de 8 dígitos se asume de Costa Rica (+506). La validación definitiva
 * la hace el servidor con libphonenumber.
 */
export function normalizarTelefono(entrada: string): string {
  let t = entrada.trim().replace(/[\s\-().]/g, '')
  if (t.startsWith('00')) t = `+${t.slice(2)}`
  if (/^[0-9]{8}$/.test(t)) t = `+506${t}`
  return t
}

/**
 * Prepara el texto de búsqueda de contactos: la API busca teléfonos por prefijo E.164
 * (`+50670…`), así que si parece un teléfono se quitan separadores y, si no trae código de
 * país (≤ 8 dígitos), se asume +506. Lo que escribe la persona se ve como «7000 0003».
 * Si no parece un teléfono (nombre o alias) se devuelve tal cual, recortado.
 */
export function consultaContactos(entrada: string): string {
  const t = entrada.trim()
  if (!/^\+?[0-9][0-9\s\-().]*$/.test(t)) return t
  const digitos = t.replace(/[\s\-().]/g, '')
  if (digitos.startsWith('+')) return digitos
  if (digitos.length <= 8) return `+506${digitos}`
  return `+${digitos}`
}

export function esTelefonoE164(telefono: string): boolean {
  return E164.test(telefono)
}

/** Presenta +50670000001 como +506 7000 0001 (solo formato visual). */
export function telefonoLegible(e164: string): string {
  const cr = /^\+506(\d{4})(\d{4})$/.exec(e164)
  if (cr) return `+506 ${cr[1] ?? ''} ${cr[2] ?? ''}`
  return e164
}

export function pareceCorreo(texto: string): boolean {
  return texto.includes('@')
}
