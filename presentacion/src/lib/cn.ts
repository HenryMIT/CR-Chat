/** Une clases condicionales (sustituto mínimo de clsx). */
export function cn(...clases: (string | false | null | undefined)[]): string {
  return clases.filter(Boolean).join(' ')
}
