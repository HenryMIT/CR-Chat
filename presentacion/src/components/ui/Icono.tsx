/**
 * Iconos SVG propios (trazo de 1.75 px, rejilla de 24). Sin dependencias externas.
 * Son decorativos por defecto (aria-hidden); el texto accesible lo pone el control.
 */
import type { SVGProps } from 'react'

const TRAZOS = {
  chats: 'M5 5.5A2.5 2.5 0 0 1 7.5 3h9A2.5 2.5 0 0 1 19 5.5v7a2.5 2.5 0 0 1-2.5 2.5H11l-4.2 3.6c-.6.5-1.8.1-1.8-.8V5.5Z M8.5 8h7 M8.5 11h4.5',
  contactos: 'M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7Z M2.5 20c.6-3.4 3.2-5.5 6.5-5.5s5.9 2.1 6.5 5.5 M16 4.3a3.5 3.5 0 0 1 0 6.4 M18.2 14.8c1.7.8 2.9 2.6 3.3 5.2',
  perfil: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8Z M4 20.5c.8-3.7 4-6 8-6s7.2 2.3 8 6',
  enviar: 'M4.5 12 3 4.6c-.2-.9.8-1.6 1.6-1.2l15.6 7.7c.8.4.8 1.5 0 1.9L4.6 20.6c-.8.4-1.8-.3-1.6-1.2L4.5 12Zm0 0h7',
  clip: 'm20 11.5-7.8 7.8a5 5 0 0 1-7.1-7.1l8.1-8.1a3.3 3.3 0 0 1 4.7 4.7l-8.1 8.1a1.7 1.7 0 0 1-2.4-2.4l7.5-7.5',
  check: 'm5 12.5 4.2 4.2L19 7',
  checkDoble: 'm2.5 12.5 4.2 4.2L16 7.4 M12 16.2l.5.5L22 7.4',
  reloj: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z M12 7.5V12l3 2',
  alerta: 'M12 9v4 M12 16.5h.01 M10.3 3.9 2.4 17.6A2 2 0 0 0 4.1 20.6h15.8a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z',
  mas: 'M12 5.5h.01 M12 12h.01 M12 18.5h.01',
  editar: 'M4 20h4L19 9a2.8 2.8 0 0 0-4-4L4 16v4Z M13.5 6.5l4 4',
  papelera: 'M4 6.5h16 M9.5 6.5V4.8c0-.7.6-1.3 1.3-1.3h2.4c.7 0 1.3.6 1.3 1.3v1.7 M6 6.5l.9 12.6c.1 1 1 1.9 2 1.9h6.2c1 0 1.9-.8 2-1.9L18 6.5 M10 11v5.5 M14 11v5.5',
  atras: 'M15 5 8 12l7 7',
  buscar: 'M10.5 18a7.5 7.5 0 1 0 0-15 7.5 7.5 0 0 0 0 15Z m5.3-2.2L21 21',
  agregar: 'M12 5v14 M5 12h14',
  sol: 'M12 16.5a4.5 4.5 0 1 0 0-9 4.5 4.5 0 0 0 0 9Z M12 2v2 M12 20v2 M4.9 4.9l1.4 1.4 M17.7 17.7l1.4 1.4 M2 12h2 M20 12h2 M4.9 19.1l1.4-1.4 M17.7 6.3l1.4-1.4',
  luna: 'M20.5 14.5A8.5 8.5 0 0 1 9.5 3.5a8.5 8.5 0 1 0 11 11Z',
  monitor: 'M3.5 5.5a2 2 0 0 1 2-2h13a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2v-9Z M9 20.5h6 M12 16.5v4',
  cerrar: 'M6 6l12 12 M18 6 6 18',
  salir: 'M14.5 4.5h3a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2h-3 M10 16.5 5.5 12 10 7.5 M5.5 12H15',
  bloquear: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z M5.6 5.6l12.8 12.8',
  archivo: 'M14 3.5H7.5a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2h9a2 2 0 0 0 2-2V8L14 3.5Z M14 3.5V8h4.5',
  candado: 'M6.5 11h11a1.5 1.5 0 0 1 1.5 1.5v6a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 5 18.5v-6A1.5 1.5 0 0 1 6.5 11Z M8 11V8a4 4 0 0 1 8 0v3',
  reintentar: 'M20 11.5A8 8 0 1 1 17.7 6 M20 4v5h-5',
  dispositivo: 'M7.5 3h9A1.5 1.5 0 0 1 18 4.5v15a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 6 19.5v-15A1.5 1.5 0 0 1 7.5 3Z M11 17.5h2',
  abajo: 'M12 5v14 M6 13l6 6 6-6',
  ojo: 'M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12Z M12 14.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5Z',
  ojoTachado: 'M3 3l18 18 M10.6 5.6c.5-.1.9-.1 1.4-.1 6 0 9.5 6.5 9.5 6.5a17 17 0 0 1-2.6 3.4 M6.6 6.6A16.5 16.5 0 0 0 2.5 12S6 18.5 12 18.5c1.6 0 3-.4 4.3-1.1 M9.9 9.9a3 3 0 0 0 4.2 4.2',
  camara: 'M4 8a2 2 0 0 1 2-2h1.7l1.4-2h5.8l1.4 2H18a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V8Z M12 16a3.2 3.2 0 1 0 0-6.4 3.2 3.2 0 0 0 0 6.4Z',
} as const

export type NombreIcono = keyof typeof TRAZOS

interface Props extends Omit<SVGProps<SVGSVGElement>, 'children'> {
  nombre: NombreIcono
  tamano?: number
}

export function Icono({ nombre, tamano = 20, className, ...resto }: Props) {
  return (
    <svg
      viewBox="0 0 24 24"
      width={tamano}
      height={tamano}
      fill="none"
      stroke="currentColor"
      strokeWidth={1.75}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
      className={className}
      {...resto}
    >
      <path d={TRAZOS[nombre]} />
    </svg>
  )
}
