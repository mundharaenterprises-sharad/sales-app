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

/**
 * A date without the year, for a list on a phone.
 *
 * Lists are read within days of the thing happening, so the year is four
 * characters that tell nobody anything — and on a narrow row four characters
 * are the difference between two lines and three. The full date is still on
 * the document itself, and on a wide screen.
 */
export function fmtDayMonth(d: string | Date | null | undefined): string {
  if (!d) return '—'
  const date = typeof d === 'string' ? new Date(d) : d
  if (Number.isNaN(date.getTime())) return '—'
  return date.toLocaleDateString('en-GB', { day: '2-digit', month: 'short' })
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

/**
 * A quantity in cartons and pieces: 140 pieces at 40 to the carton reads
 * "3 CTN 20 PCS".
 *
 * Stock is held in base units because that is the only unit everything can be
 * counted in, and every figure in the app was shown that way. But nobody
 * standing in front of the shelves counts in pieces — they count boxes, and
 * then whatever is loose on top. "3,140 PCS" is a number you have to do
 * arithmetic on before you can go and look at it.
 *
 * A product with no carton, or a quantity smaller than one, reads as plain
 * base units, because "0 CTN 20 PCS" is worse than "20 PCS".
 */
export function fmtPacks(
  qty: number | string | null | undefined,
  packSize: number | string | null | undefined,
  packUom: string | null | undefined,
  baseUom: string,
): string {
  const v = Number(qty)
  if (qty === null || qty === undefined || Number.isNaN(v)) return '—'
  const size = Number(packSize)
  if (!packUom || !(size > 1)) return `${fmtQty(v)} ${baseUom}`

  // Negatives can happen on a ledger line. Split the size, keep the sign.
  const sign = v < 0 ? '-' : ''
  const abs = Math.abs(v)
  const packs = Math.floor(abs / size)
  const loose = abs % size

  if (packs === 0) return `${sign}${fmtQty(loose)} ${baseUom}`
  if (loose === 0) return `${sign}${fmtQty(packs)} ${packUom}`
  return `${sign}${fmtQty(packs)} ${packUom} ${fmtQty(loose)} ${baseUom}`
}
