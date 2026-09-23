import { bucketOf, bucketTone } from '../lib/ageing'

/** How old a bill is, at a glance: "32 d" coloured by its bucket. */
export function AgePill({ days }: { days: number | string | null | undefined }) {
  if (days === null || days === undefined) return null
  const b = bucketOf(days)
  return (
    <span className={`pill ${bucketTone(b)}`} title={`In the ${b} bucket`}>
      {Number(days)} d
    </span>
  )
}
