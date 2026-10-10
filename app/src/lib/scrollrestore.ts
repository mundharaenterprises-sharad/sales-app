import { useEffect, useRef } from 'react'
import { useLocation, useNavigationType } from 'react-router-dom'

/**
 * Coming back to where you were.
 *
 * Working an ageing report means scrolling to a customer, opening their
 * ledger, deciding something, and coming back for the next one. Landing at the
 * top of the list every time makes that job twice as long and, worse, makes it
 * easy to lose your place and chase the same shop twice.
 *
 * The browser does remember scroll positions, and it cannot use them here.
 * This is a single page: on Back the page does not reload, the screen mounts
 * empty, asks the database for its rows, and only then becomes tall enough to
 * scroll. By the time the rows arrive the browser has long since given up — it
 * tried to scroll a page that was one screen high.
 *
 * So the position is kept here, against the history entry it belongs to, and
 * put back only once the page is actually tall enough to hold it. Three things
 * that are easy to get wrong and are deliberate:
 *
 *   **Per history entry, not per URL.** React Router gives every entry a key.
 *   Visiting the same report twice in one session are two entries with two
 *   positions, which is what somebody who opened it, wandered off and came
 *   back expects.
 *
 *   **Only on Back.** Following a link to a list means starting at the top;
 *   restoring there would be the app ignoring where you asked to go.
 *
 *   **The person wins.** If they scroll, or the rows never arrive, the attempt
 *   is abandoned rather than yanking the page out from under them a second
 *   later.
 */

const positions = new Map<string, number>()

/** How long to keep trying before deciding the rows are not coming. */
const GIVE_UP_AFTER_MS = 2000

export function useScrollRestore() {
  const { key } = useLocation()
  const navigationType = useNavigationType()
  const current = useRef(key)

  // Keep the live position for whichever entry is on screen.
  //
  // Written straight from the scroll event, with no throttling and nothing
  // read on the way out. The obvious-looking version — take one last reading
  // in the cleanup, in case the final scroll never got a frame — is wrong, and
  // wrong in a way that silently undoes the whole thing: by the time React
  // runs a cleanup the old screen has already gone, the page has collapsed to
  // one screen high, and the browser has reset the scroll. The last reading is
  // therefore always zero, and it overwrites the real position with it.
  useEffect(() => {
    current.current = key
    const onScroll = () => { positions.set(current.current, window.scrollY) }
    window.addEventListener('scroll', onScroll, { passive: true })
    return () => window.removeEventListener('scroll', onScroll)
  }, [key])

  useEffect(() => {
    // The browser's own attempt would fight this one, and lose anyway.
    if ('scrollRestoration' in window.history) {
      window.history.scrollRestoration = 'manual'
    }

    const want = positions.get(key)
    if (navigationType !== 'POP' || !want) {
      window.scrollTo(0, 0)
      return
    }

    let cancelled = false
    const started = performance.now()

    // Anything the person does themselves ends it.
    const abandon = () => { cancelled = true }
    window.addEventListener('wheel', abandon, { passive: true, once: true })
    window.addEventListener('touchstart', abandon, { passive: true, once: true })
    window.addEventListener('keydown', abandon, { once: true })

    const tryIt = () => {
      if (cancelled) return
      const room = document.documentElement.scrollHeight - window.innerHeight
      if (room >= want) {
        window.scrollTo(0, want)
        return
      }
      // Not tall enough yet — the rows are still on their way.
      if (performance.now() - started < GIVE_UP_AFTER_MS) {
        requestAnimationFrame(tryIt)
      } else {
        // As close as the page can get. Better than the top: a list that came
        // back shorter than it was still puts you near the end you were at.
        window.scrollTo(0, Math.max(0, room))
      }
    }
    requestAnimationFrame(tryIt)

    return () => {
      cancelled = true
      window.removeEventListener('wheel', abandon)
      window.removeEventListener('touchstart', abandon)
      window.removeEventListener('keydown', abandon)
    }
  }, [key, navigationType])
}

/**
 * Forget where we were on this entry.
 *
 * For a screen that has genuinely changed what it is showing — a filter that
 * cut the list to three rows — where coming back to line 400 would be worse
 * than useless.
 */
export function forgetScroll(key: string) {
  positions.delete(key)
}
