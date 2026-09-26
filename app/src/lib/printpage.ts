import { useEffect } from 'react'

/**
 * Which size and orientation of paper this screen prints on.
 *
 * `@page` is a property of the document, not of an element. Two `@page` rules
 * in one stylesheet do not each apply to their own part of the page: the later
 * one simply wins, for everything. So the reports rule — `A4 landscape`, added
 * to the foot of styles.css when reports were built — quietly took over the
 * bill, which had asked for `A5 portrait` two hundred lines earlier and had
 * been printing correctly until then. The bill came out of the printer sideways
 * with type the size of a footnote, and nothing about the bill had changed.
 *
 * A CSS file cannot express "A5 for this screen, A4 for that one", because the
 * cascade has no idea which screen is showing. The screen does. So each screen
 * that prints says so, and the rule is written while that screen is open and
 * taken away when it closes. One screen prints at a time, so there is only ever
 * one rule, and it is always the right one.
 *
 * The rule lives in the head rather than the stylesheet for the same reason a
 * migration lives in a file rather than a comment: something has to actually do
 * it, at the right moment.
 */
export function usePrintPage(size: string, margin = '8mm') {
  useEffect(() => {
    const el = document.createElement('style')
    el.id = 'print-page-size'
    el.textContent = `@page { size: ${size}; margin: ${margin}; }`

    // Belt and braces: if a previous screen left one behind — a crash during
    // unmount, a hot reload — the page must not end up with two.
    document.getElementById('print-page-size')?.remove()
    document.head.appendChild(el)

    return () => { el.remove() }
  }, [size, margin])
}

/** A bill: half a sheet, upright, the way a book of bills is. */
export const BILL_PAGE = 'A5 portrait'

/** A report: as many columns as will fit, so wide and flat. */
export const REPORT_PAGE = 'A4 landscape'
