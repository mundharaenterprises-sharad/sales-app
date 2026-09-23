import { useState } from 'react'

/** Today, this week, this month — the three ranges anyone actually asks for. */
export function useDateRange(initial: 'today' | 'week' | 'month' = 'month') {
  const iso = (d: Date) => d.toISOString().slice(0, 10)
  const now = new Date()

  const start = (which: 'today' | 'week' | 'month'): [string, string] => {
    const t = new Date()
    if (which === 'today') return [iso(t), iso(t)]
    if (which === 'week') {
      const d = new Date(t)
      // Weeks start on Monday here, which is how a rep's round is counted.
      const back = (d.getDay() + 6) % 7
      d.setDate(d.getDate() - back)
      return [iso(d), iso(t)]
    }
    return [iso(new Date(t.getFullYear(), t.getMonth(), 1)), iso(t)]
  }

  const [[f0, t0]] = useState(() => start(initial))
  const [from, setFrom] = useState(f0)
  const [to, setTo] = useState(t0)

  const presets = {
    today: () => { const [a, b] = start('today'); setFrom(a); setTo(b) },
    week: () => { const [a, b] = start('week'); setFrom(a); setTo(b) },
    month: () => { const [a, b] = start('month'); setFrom(a); setTo(b) },
    all: () => { setFrom(''); setTo(iso(now)) },
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
        <input type="date" value={from} onChange={(e) => setFrom(e.target.value)} />
      </label>
      <label className="inline-field">
        <span>To</span>
        <input type="date" value={to} onChange={(e) => setTo(e.target.value)} />
      </label>
      <button onClick={presets.today}>Today</button>
      <button onClick={presets.week}>This week</button>
      <button onClick={presets.month}>This month</button>
      <button className="ghost" onClick={presets.all}>All</button>
    </>
  )
}
