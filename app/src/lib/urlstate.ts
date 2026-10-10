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
/**
 * Writes made in one go, applied in one go.
 *
 * `setSearchParams(fn)` looks like React's `setState(fn)` and is not. The
 * function it hands you is the address as of the last RENDER, not as of the
 * last write — so two filters set in the same handler both start from the
 * same place, and the second silently throws the first away.
 *
 * That is not a theoretical problem. It is why the sales register's *Today*
 * and *This week* buttons appeared dead: each sets From and then To, and the
 * To wiped the From. The *Clear* button sets five filters and kept one.
 *
 * So writes within a single tick accumulate here instead. The first one takes
 * a copy of the address; the rest amend that copy; a microtask after the
 * handler finishes, it is dropped. Nothing has to remember to batch, which
 * matters more than elegance — the failure is silent and looks like a dead
 * button.
 */
let pending: URLSearchParams | null = null

export function useUrlState(
  key: string,
  initial: string,
): [string, (v: string) => void] {
  const [params, setParams] = useSearchParams()
  const value = params.get(key) ?? initial

  const set = useCallback(
    (v: string) => {
      setParams(
        (prev) => {
          if (!pending) {
            pending = new URLSearchParams(prev)
            // End of this handler, whenever that is.
            queueMicrotask(() => { pending = null })
          }
          // Absent means "whatever this screen starts with", so a filter that
          // is back at its starting value is dropped rather than written out.
          // That keeps the address to the things somebody actually chose.
          //
          // Compared against the default, NOT against empty. Emptying the From
          // date is a real choice — it means every bill ever — and `?from=`
          // has to survive as itself, or pressing All and then Back would
          // quietly restore this month.
          if (v === initial) pending.delete(key)
          else pending.set(key, v)
          return new URLSearchParams(pending)
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
