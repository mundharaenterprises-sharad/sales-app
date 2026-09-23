/**
 * Ageing buckets: 0–15, 16–30, 31–45, 46+ days.
 *
 * The same four buckets the database uses in v_ageing, repeated here so a
 * screen can label a single bill without asking the server which bucket it
 * falls in. If the buckets ever change they change in both places, which is
 * why the boundaries are written out rather than hidden in arithmetic.
 */

export type Bucket = '0-15' | '16-30' | '31-45' | '46+'

export function bucketOf(days: number | string | null | undefined): Bucket {
  const d = Number(days ?? 0)
  if (d <= 15) return '0-15'
  if (d <= 30) return '16-30'
  if (d <= 45) return '31-45'
  return '46+'
}

/** How alarming the bucket should look. */
export function bucketTone(b: Bucket): 'good' | 'flat' | 'warn' | 'bad' {
  switch (b) {
    case '0-15':
      return 'good'
    case '16-30':
      return 'flat'
    case '31-45':
      return 'warn'
    default:
      return 'bad'
  }
}

export const BUCKET_LABEL: Record<Bucket, string> = {
  '0-15': '0–15 days',
  '16-30': '16–30 days',
  '31-45': '31–45 days',
  '46+': 'over 45 days',
}
