import { useEffect } from 'react'

/**
 * What paper this screen prints on, and where the white border comes from.
 *
 * Three problems live here, and the third only appeared once the second was
 * solved — which is why they are all in one file rather than scattered.
 *
 * **The paper.** `@page` is a property of the document, not of an element. Two
 * `@page` rules in one stylesheet do not each apply to their own part of the
 * page: the later one simply wins, for everything. So the reports rule —
 * `A4 landscape`, added to the foot of styles.css when reports were built —
 * quietly took over the bill, which had asked for `A5 portrait` two hundred
 * lines earlier. Bills came out sideways in tiny type and nothing about the
 * bill had changed. A stylesheet cannot say "A5 here, A4 there" because the
 * cascade has no idea which screen is open; the screen does, so each screen
 * says so and the rule is written while it is open.
 *
 * **The browser's own header.** Chrome prints the page title and the web
 * address along the top and bottom of every sheet, so every bill went out with
 * "Sales App" above it. No CSS switches that off — but there is nowhere to
 * draw it when the page has no margin. Hence a zero margin, with the white
 * border supplied by the content instead.
 *
 * **Where that border goes.** This is the part that bit. Padding on a block
 * that spans several pages applies where the block STARTS, not at the top of
 * every page it covers. With the border on the page body, a batch of ten bills
 * printed the first one correctly and the other nine flush against the paper
 * edge, where the printer clipped the bill number. Sharad reported it as "the
 * bill number gets washed away" and he was describing my own change.
 *
 * So the two cases are genuinely different and are treated differently:
 *
 *   A bill starts its own page — `break-before: page` on every sheet after the
 *   first — so padding on the SHEET lands at the top of each page. Zero page
 *   margin, no browser header, correct border on all ten.
 *
 *   A report is one long table that flows across pages, and no element starts
 *   those pages, so nothing the content can do will inset them. It gets a real
 *   page margin instead, and accepts the browser header in exchange for pages
 *   two onwards not being printed into the paper's edge. The header is made
 *   useful rather than merely tolerated: the document title becomes the report
 *   name, so what prints up there is "Ageing" and not "Sales App".
 */

function usePageRule(css: string) {
  useEffect(() => {
    const el = document.createElement('style')
    el.id = 'print-page-size'
    el.textContent = css
    // Belt and braces: if a previous screen left one behind — a crash during
    // unmount, a hot reload — the page must not end up with two.
    document.getElementById('print-page-size')?.remove()
    document.head.appendChild(el)
    return () => { el.remove() }
  }, [css])
}

/** A bill: half a sheet, upright, the way a book of bills is. */
export const BILL_PAGE = 'A5 portrait'

/** A report: as many columns as will fit, so wide and flat. */
export const REPORT_PAGE = 'A4 landscape'

/** Every bill is its own page, so every bill carries its own border. */
export function useBillPage(inset = '8mm') {
  usePageRule(
    `@page { size: ${BILL_PAGE}; margin: 0; }\n` +
      `@media print {\n` +
      `  main { padding: 0 !important; }\n` +
      `  .sheet-a5 { padding: ${inset} !important; box-sizing: border-box; }\n` +
      `}`,
  )
}

/** A report flows across pages, so the pages themselves need the margin. */
export function useReportPage(margin = '10mm') {
  usePageRule(
    `@page { size: ${REPORT_PAGE}; margin: ${margin}; }\n` +
      `@media print { main { padding: 0 !important; } }`,
  )
}

/**
 * What the browser calls this page.
 *
 * On a bill it is belt and braces: the zero margin should leave a header
 * nowhere to go, but that is a browser's choice and not something CSS can
 * insist on, so the title is the bill's own number — a sheet with INV-000001
 * above it is a sheet with its own number above it, rather than an
 * advertisement the customer did not ask for.
 *
 * On a report the header is expected rather than merely survivable, so the
 * title is the report's name and earns its place.
 *
 * Either way the tab says something useful, which is worth having on its own.
 */
export function useDocumentTitle(title: string | null) {
  useEffect(() => {
    if (!title) return
    const was = document.title
    document.title = title
    return () => { document.title = was }
  }, [title])
}
