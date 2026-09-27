import { useEffect } from 'react'

/**
 * Which size and orientation of paper this screen prints on, and how far in
 * from the edge of it the printing starts.
 *
 * Two separate problems are solved here, and they turn out to have one answer.
 *
 * **The paper.** `@page` is a property of the document, not of an element. Two
 * `@page` rules in one stylesheet do not each apply to their own part of the
 * page: the later one simply wins, for everything. So the reports rule —
 * `A4 landscape`, added to the foot of styles.css when reports were built —
 * quietly took over the bill, which had asked for `A5 portrait` two hundred
 * lines earlier and had been printing correctly until then. Bills came out of
 * the printer sideways in tiny type, and nothing about the bill had changed.
 *
 * A stylesheet cannot say "A5 for this screen, A4 for that one", because the
 * cascade has no idea which screen is showing. The screen does. So each screen
 * that prints says so, and the rule is written while that screen is open and
 * taken away when it closes.
 *
 * **The browser's own header.** Chrome prints the page title and the web
 * address along the top and bottom of every sheet, so every bill carried the
 * words "Sales App" above it and a claude-free-looking URL below. There is no
 * CSS that switches those off — but there is nowhere to draw them when the
 * page has no margin. So the margin is zero and the white space around the
 * bill is the page's own padding instead. The customer's copy then has nothing
 * on it that the customer did not buy.
 *
 * Which is why both live in one function: the margin trick only works if
 * something else supplies the inset, and that something has to change with the
 * screen in exactly the same way the paper size does.
 */
export function usePrintPage(size: string, inset = '8mm') {
  useEffect(() => {
    const el = document.createElement('style')
    el.id = 'print-page-size'
    el.textContent =
      `@page { size: ${size}; margin: 0; }\n` +
      `@media print { main { padding: ${inset} !important; } }`

    // Belt and braces: if a previous screen left one behind — a crash during
    // unmount, a hot reload — the page must not end up with two.
    document.getElementById('print-page-size')?.remove()
    document.head.appendChild(el)

    return () => { el.remove() }
  }, [size, inset])
}

/** A bill: half a sheet, upright, the way a book of bills is. */
export const BILL_PAGE = 'A5 portrait'

/** A report: as many columns as will fit, so wide and flat. */
export const REPORT_PAGE = 'A4 landscape'

/**
 * What the browser calls this page.
 *
 * Belt and braces for the header above. Chrome prints the document title
 * across the top of every sheet, and while a zero page margin normally leaves
 * it nowhere to go, that is a browser's choice and not something CSS can
 * insist on — an older Chrome, or a different browser, may print it anyway.
 *
 * So the title is made into something that would not embarrass the bill if it
 * did print. A sheet with "INV-000001" above it is a sheet with its own number
 * above it; a sheet with "Sales App" above it is an advertisement the customer
 * did not ask for. The tab says the bill number too, which is worth having on
 * its own.
 */
export function useDocumentTitle(title: string | null) {
  useEffect(() => {
    if (!title) return
    const was = document.title
    document.title = title
    return () => { document.title = was }
  }, [title])
}
