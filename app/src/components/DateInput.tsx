import { useEffect, useRef, useState } from 'react'

/**
 * A date box you can type into.
 *
 * The problem it solves, which took some finding: picking from the calendar
 * worked and typing the digits did not. The typed numbers simply would not
 * stay in the box.
 *
 * A native date input is three little fields in a trench coat — day, month,
 * year — and until all three are filled it reports its value as an **empty
 * string**. Every date box in this app was wired straight to state:
 *
 *     <input type="date" value={from} onChange={e => setFrom(e.target.value)} />
 *
 * So typing the first digit of a day made the input report "", which set the
 * state to "", which re-rendered the input with value="", which threw away the
 * digit that had just been typed. Round and round, with nothing ever
 * appearing. The calendar worked because it fills all three fields at once.
 *
 * Since the filters moved into the address bar this got worse, not better: the
 * round trip now goes through the router, so the re-render is guaranteed.
 *
 * The fix is to let the box keep its own half-finished state while somebody is
 * in the middle of typing, and only tell the rest of the app once there is a
 * real date to tell it about. A half-typed date never reaches a query — which
 * is also the end of *invalid input syntax for type date*, since nothing
 * partial is ever sent.
 *
 * Clearing the box on purpose still clears the filter: that is settled on the
 * way out rather than on every keystroke, because an empty box mid-typing and
 * an empty box left empty look identical until the person moves on.
 */

/** A complete calendar date, not a year with hopes. */
function isWholeDate(v: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(v)) return false
  const [y, m, d] = v.split('-').map(Number)
  if (y < 1900 || y > 2999 || m < 1 || m > 12 || d < 1 || d > 31) return false
  // Catches 31 February, which passes every test above.
  const probe = new Date(Date.UTC(y, m - 1, d))
  return probe.getUTCMonth() === m - 1 && probe.getUTCDate() === d
}

export function DateInput({
  value,
  onChange,
  id,
  ...rest
}: {
  value: string
  onChange: (v: string) => void
  id?: string
} & Omit<React.InputHTMLAttributes<HTMLInputElement>, 'value' | 'onChange' | 'type'>) {
  const [text, setText] = useState(value)
  const typing = useRef(false)

  // Follow the outside world — a preset button, a Back, a reload — but never
  // while somebody has their fingers in the box.
  useEffect(() => {
    if (!typing.current) setText(value)
  }, [value])

  return (
    <input
      {...rest}
      id={id}
      type="date"
      value={text}
      onFocus={(e) => {
        typing.current = true
        rest.onFocus?.(e)
      }}
      onChange={(e) => {
        const v = e.target.value
        setText(v)
        // Only a real date goes any further. "" is deliberately not sent here:
        // it is what a half-typed box reports, and clearing a filter on every
        // keystroke would reload the screen under the person typing.
        if (isWholeDate(v)) onChange(v)
      }}
      onBlur={(e) => {
        typing.current = false
        // Left empty on purpose — now it counts.
        if (text === '') onChange('')
        // Left half-finished: put back whatever the app actually holds,
        // rather than leaving a box showing a date that is not in force.
        else if (!isWholeDate(text)) setText(value)
        rest.onBlur?.(e)
      }}
    />
  )
}
