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

/**
 * How long to keep trying before deciding the rows are never coming.
 *
 * Generous on purpose. The first version gave up after two seconds, which is
 * fine on a desk and not fine on the thing this is for — a rep's phone on a
 * slow connection, where the list can take longer than that to arrive. When
 * it gave up the page was still one screen high, so "scroll as far as you
 * can" meant scrolling to the top: exactly the behaviour being fixed, and
 * only on the occasions it mattered most.
 */
const GIVE_UP_AFTER_MS = 15000

/** …and how long the page must stop growing before we believe it is done. */
const SETTLED_FOR_MS = 1500

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
    const onScroll = () => {
      const y = window.scrollY
      const room = document.documentElement.scrollHeight - window.innerHeight
      const had = positions.get(current.current) ?? 0
      // A scroll to the top on a page that has just become too short to hold
      // where we were is not somebody scrolling up. It is the old screen being
      // torn down: the rows go, the page collapses to one screen, and the
      // browser pins the scroll to zero. That event arrives while this
      // listener is still attached, and taking it at face value overwrites the
      // position with zero a moment before it is needed — which is exactly how
      // this went wrong the first time, from the other direction.
      if (y < had && room < had) return
      positions.set(current.current, y)
    }
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
    let tallest = 0
    let grewAt = started

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

      const now = performance.now()
      if (room > tallest) {
        tallest = room
        grewAt = now
      }

      // Two ways to stop: the page has stopped growing for long enough that
      // the rows are evidently all in, or we have waited far too long. Height
      // rather than a plain timer, because a page that is still filling is a
      // page worth waiting for however long it has taken.
      // `tallest > 0` matters: a page that has not grown AT ALL has not
      // settled, it has not started. Without that, a list still being fetched
      // looks exactly like a list that came back empty, and the wait ends a
      // second and a half after Back — which on a slow connection is every
      // time.
      const settled = tallest > 0 && now - grewAt > SETTLED_FOR_MS
      const waitedTooLong = now - started > GIVE_UP_AFTER_MS

      if (!settled && !waitedTooLong) {
        // A frame at a time while the page is actively filling, then slower.
        // Restoring a scroll position does not need sixty checks a second for
        // fifteen seconds on a phone.
        if (now - started < 1000) requestAnimationFrame(tryIt)
        else window.setTimeout(tryIt, 100)
        return
      }

      // The list came back shorter than it was — fewer rows, or a filter.
      // Go as far as it now goes, which still lands near the end somebody was
      // reading. If it did not grow at all, leave the page alone rather than
      // scrolling it to the top for no reason.
      if (room > 0) window.scrollTo(0, Math.min(want, room))
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
