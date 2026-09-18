/** Money, quantities and dates, formatted the same way everywhere. */

const money = new Intl.NumberFormat('en-IN', {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
})

const qtyFmt = new Intl.NumberFormat('en-IN', {
  minimumFractionDigits: 0,
  maximumFractionDigits: 3,
})

export function fmtMoney(n: number | string | null | undefined): string {
  const v = typeof n === 'string' ? Number(n) : n
  if (v === null || v === undefined || Number.isNaN(v)) return '—'
  return money.format(v)
}

/** Quantities print without trailing zeros: 24 not 24.0000. */
export function fmtQty(n: number | string | null | undefined): string {
  const v = typeof n === 'string' ? Number(n) : n
  if (v === null || v === undefined || Number.isNaN(v)) return '—'
  return qtyFmt.format(v)
}

export function fmtDate(d: string | Date | null | undefined): string {
  if (!d) return '—'
  const date = typeof d === 'string' ? new Date(d) : d
  if (Number.isNaN(date.getTime())) return '—'
  return date.toLocaleDateString('en-GB', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
  })
}

export function fmtTime(d: string | Date | number): string {
  const date = typeof d === 'number' ? new Date(d) : typeof d === 'string' ? new Date(d) : d
  return date.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })
}

/**
 * "just now", "12 minutes ago", "at 14:32", "yesterday at 09:10".
 *
 * Used for the age of cached stock, where the point is to make staleness
 * obvious rather than to be precise.
 */
export function fmtAge(ts: number): string {
  const secs = Math.floor((Date.now() - ts) / 1000)
  if (secs < 45) return 'just now'
  if (secs < 90) return 'a minute ago'

  const mins = Math.round(secs / 60)
  if (mins < 60) return `${mins} minutes ago`

  const then = new Date(ts)
  const sameDay = new Date().toDateString() === then.toDateString()
  if (sameDay) return `at ${fmtTime(then)}`

  const yesterday = new Date(Date.now() - 86400000).toDateString() === then.toDateString()
  if (yesterday) return `yesterday at ${fmtTime(then)}`

  return `${fmtDate(then)} at ${fmtTime(then)}`
}
