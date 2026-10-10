import { useEffect, useState } from 'react'
import { useLocation, useNavigate, useNavigationType } from 'react-router-dom'

/**
 * One step back, from anywhere.
 *
 * Several screens grew their own way out — *All bills*, *All payments*, a
 * Back at the bottom of a form — and each goes somewhere slightly different.
 * None of them is the thing people actually want, which is simply to undo the
 * last tap and carry on where they were. On a phone there is a system back
 * button for that; in a browser on a laptop there is one three inches away in
 * a different part of the screen, and in an installed app there is none at
 * all.
 *
 * So: one control, the same place on every screen, doing exactly what the
 * browser's back does — which, since the scroll position is now restored, puts
 * the list back under your finger where you left it rather than at the top.
 *
 * It appears only when there is somewhere in the app to go back TO. Pressing
 * back on the first screen of a freshly opened app would leave the app
 * entirely, which from a button the app itself drew would be startling. That
 * is counted here rather than guessed from `history.length`, which counts
 * everything the tab has ever visited, including whatever was open before.
 */

let depth = 0

export function BackBar() {
  const nav = useNavigate()
  const { key, pathname } = useLocation()
  const navigationType = useNavigationType()
  const [canGoBack, setCanGoBack] = useState(depth > 0)

  useEffect(() => {
    // REPLACE is deliberately not counted: that is a filter being written into
    // the address, not somewhere a person went.
    if (navigationType === 'PUSH') depth += 1
    else if (navigationType === 'POP') depth = Math.max(0, depth - 1)
    setCanGoBack(depth > 0)
  }, [key, navigationType])

  // Home is where back would take you anyway, and a Back button on the first
  // screen somebody sees is noise.
  if (!canGoBack || pathname === '/') return null

  return (
    <div className="backbar no-print">
      <button className="ghost" onClick={() => nav(-1)} aria-label="Go back one step">
        ‹ Back
      </button>
    </div>
  )
}
