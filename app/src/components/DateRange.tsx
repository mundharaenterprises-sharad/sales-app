import { useState } from 'react'
import { useUrlState } from '../lib/urlstate'
import { DateInput } from './DateInput'
import { isoDate } from '../lib/format'

/**
 * Today, this week, this month — the three ranges anyone actually asks for.
 *
 * The chosen dates live in the address rather than in component state, so
 * opening a bill from a report and pressing Back returns to the same period
 * instead of to an unfiltered screen. See lib/urlstate.ts for why.
 */
export function useDateRange(initial: 'today' | 'week' | 'month' = 'month') {
  const now = new Date()

  const start = (which: 'today' | 'week' | 'month'): [string, string] => {
    const t = new Date()
    if (which === 'today') return [isoDate(t), isoDate(t)]
    if (which === 'week') {
      const d = new Date(t)
      // Weeks start on Monday here, which is how a rep's round is counted.
      const back = (d.getDay() + 6) % 7
      d.setDate(d.getDate() - back)
      return [isoDate(d), isoDate(t)]
    }
    return [isoDate(new Date(t.getFullYear(), t.getMonth(), 1)), isoDate(t)]
  }

  // Worked out once, at the first render, and then held still. It is both the
  // starting range and the value that counts as "nothing chosen" — so it must
  // not be recomputed, or a screen left open across midnight would start
  // writing yesterday's default into the address.
  const [[f0, t0]] = useState(() => start(initial))
  const [from, setFrom] = useUrlState('from', f0)
  const [to, setTo] = useUrlState('to', t0)

  const presets = {
    today: () => { const [a, b] = start('today'); setFrom(a); setTo(b) },
    week: () => { const [a, b] = start('week'); setFrom(a); setTo(b) },
    month: () => { const [a, b] = start('month'); setFrom(a); setTo(b) },
    all: () => { setFrom(''); setTo(isoDate(now)) },
  }

  return { from, to, setFrom, setTo, presets }
}

export function DateRange({
  from,
  to,
  setFrom,
  setTo,
  presets,
}: {
  from: string
  to: string
  setFrom: (v: string) => void
  setTo: (v: string) => void
  presets: { today: () => void; week: () => void; month: () => void; all: () => void }
}) {
  return (
    <>
      <label className="inline-field">
        <span>From</span>
        <DateInput value={from} onChange={setFrom} />
      </label>
      <label className="inline-field">
        <span>To</span>
        <DateInput value={to} onChange={setTo} />
      </label>
      <button onClick={presets.today}>Today</button>
      <button onClick={presets.week}>This week</button>
      <button onClick={presets.month}>This month</button>
      <button className="ghost" onClick={presets.all}>All</button>
    </>
  )
}
