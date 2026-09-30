import { useCallback } from 'react'
import { useSearchParams } from 'react-router-dom'

/**
 * A filter that survives leaving the screen.
 *
 * Every filter on every report used to be ordinary component state, which
 * meant opening a bill from the sales register and pressing Back put you at
 * the top of an unfiltered report, with the month you had chosen gone. On a
 * screen whose whole purpose is working through a list one bill at a time,
 * that is the difference between usable and not.
 *
 * Keeping it in the address solves it at the level it actually happens:
 * the browser already restores the address on Back, so the filters come back
 * with it — and a reload, a bookmark, or a link pasted to somebody else all
 * land on the same rows. Nothing has to remember anything.
 *
 * Changes REPLACE the current history entry rather than adding one. Typing a
 * date should not be four presses of Back to undo; going into a bill and
 * coming out should be one.
 */
export function useUrlState(
  key: string,
  initial: string,
): [string, (v: string) => void] {
  const [params, setParams] = useSearchParams()
  const value = params.get(key) ?? initial

  const set = useCallback(
    (v: string) => {
      // The updater form, not the current params object: two of these called
      // one after another in the same handler — which is exactly what a date
      // preset does — would otherwise both read the same stale params and the
      // second would undo the first.
      setParams(
        (prev) => {
          const next = new URLSearchParams(prev)
          // Absent means "whatever this screen starts with", so a filter that
          // is back at its starting value is dropped rather than written out.
          // That keeps the address to the things somebody actually chose.
          //
          // Note this is compared against the default, NOT against empty.
          // Emptying the From date is a real choice — it means every bill
          // ever — and `?from=` has to survive as itself, or pressing All and
          // then Back would quietly restore this month.
          if (v === initial) next.delete(key)
          else next.set(key, v)
          return next
        },
        { replace: true },
      )
    },
    [key, initial, setParams],
  )

  return [value, set]
}

/**
 * The same thing for a tick box.
 *
 * Written as `yes` / `no` rather than `true` / `false` or `1` / `0` because
 * the address bar is something the office sees, and `showCancelled=no` can be
 * read by somebody who has never thought about query strings.
 */
export function useUrlFlag(
  key: string,
  initial: boolean,
): [boolean, (v: boolean) => void] {
  const [raw, setRaw] = useUrlState(key, initial ? 'yes' : 'no')
  return [raw === 'yes', useCallback((v: boolean) => setRaw(v ? 'yes' : 'no'), [setRaw])]
}
