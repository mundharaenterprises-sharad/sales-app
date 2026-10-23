import { useEffect, useState } from 'react'

/**
 * Where the cursor goes when a line is added to a document.
 *
 * The billing screen settled this and the answer is not the obvious one. On
 * adding a product the cursor lands on the **unit** box, not the quantity:
 * pieces or cartons is the decision that changes what every other figure on
 * the line means, and a `<select>` is the one control you cannot reach any
 * other way without a mouse. Up and down arrows change it in place, then Tab
 * walks the quantity, the rate and the discount in the order they are read,
 * and Enter on the quantity asks for the next item. A whole document without
 * reaching for the mouse once.
 *
 * He corrected an earlier version that went straight to the quantity:
 * "can't escape units here."
 *
 * A product with no pack has nothing to choose, so its unit box is disabled
 * and the cursor falls through to the quantity rather than landing on
 * something dead.
 *
 * Mark the two controls on each line with `data-unit-for` and `data-qty-for`
 * carrying the line's key, then call `focusLine(key)` after adding it. It is
 * held as state rather than done in the add handler because neither control
 * exists until React has rendered the line.
 *
 * `NewInvoice` still has its own copy of this, inline and working, in daily
 * use. It is deliberately not being swapped out from under the billing screen
 * for the sake of removing a duplicate; the behaviour here is the behaviour
 * there, and the two are the same eighteen lines.
 */
export function useLineFocus() {
  const [pending, setPending] = useState<string | null>(null)

  useEffect(() => {
    if (!pending) return
    const key = CSS.escape(pending)
    setPending(null)

    const unit = document.querySelector<HTMLSelectElement>(`[data-unit-for="${key}"]`)
    const qty = document.querySelector<HTMLInputElement>(`[data-qty-for="${key}"]`)
    const el = unit && !unit.disabled ? unit : qty
    if (!el) return

    el.focus()
    // On the quantity, select what is there so the first keystroke replaces it
    // rather than being stuck onto the end of whatever was prefilled.
    if (el === qty) {
      try { qty.select() } catch { /* some browsers refuse on some input types */ }
    }
    el.scrollIntoView({ block: 'center', behavior: 'smooth' })
  }, [pending])

  return { focusLine: setPending }
}

/**
 * Focus something by id once React has had a frame to render it.
 *
 * For the step before the lines: after a supplier or a customer is chosen the
 * *Add product* button does not exist yet, because the screen has not
 * re-rendered with them on it. Without this, Tab from the chooser goes to
 * whatever the browser thinks is next — which on the billing screen turned out
 * to be Chrome's own toolbar, and read as "the keyboard stops working halfway
 * through making a bill".
 */
export function focusById(id: string) {
  requestAnimationFrame(() => {
    document.getElementById(id)?.focus()
  })
}
