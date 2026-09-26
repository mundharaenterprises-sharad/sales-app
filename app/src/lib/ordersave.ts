import { supabase, asDbError, friendlyMessage } from './supabase'

/**
 * An order is saved by leaving the screen.
 *
 * There is no Submit button. A rep at a counter has one hand on the phone and
 * a shopkeeper talking at them; the last tap of a job is the one most easily
 * forgotten, and a forgotten tap is a delivery that never happens. So the act
 * of walking away from the screen is what commits the order, the way closing
 * an order book commits what you wrote in it.
 *
 * That trade has to be paid for honestly, in three places.
 *
 * **Accidents.** Backing out is also how you abandon something. So an order is
 * only saved when it has a customer and at least one complete line — opening
 * the screen to look up a price and leaving saves nothing — and whatever is
 * saved can be undone from the banner for as long as the rep stays on the
 * screen they landed on.
 *
 * **Failure.** The rep is gone by the time the database answers, and it can
 * still say no: someone else may have taken the stock. So the answer follows
 * them. The banner lives in the layout, not on the order screen, and reports
 * wherever they went. A refused order is kept whole, and Reopen puts it back
 * on the screen with every line intact.
 *
 * **The app dying.** A phone kills a backgrounded app without asking. The
 * draft is written to this device as it is typed, so the next time the order
 * screen opens it offers back what was on it. Nothing is lost by a phone that
 * went flat, only by a rep who says no to the offer.
 *
 * Nothing here holds the order while it is being typed: no document number is
 * taken and no stock is reserved until the rep leaves. An order that exists is
 * an order somebody meant.
 */

// -----------------------------------------------------------------------------
// What a half-written order looks like on this device
// -----------------------------------------------------------------------------

export interface DraftProduct {
  product_id: string
  product_code: string
  product_name: string
  group_name: string
  base_uom: string
  pack_uom: string | null
  pack_size: number
  available: number
  sale_rate: number
  pack_sale_rate: number | null
}

export interface DraftParty {
  party_id: string
  party_code: string
  party_name: string
  route_name: string
  balance: number | null
  credit_limit: number | null
  over_credit_limit: boolean | null
}

export interface DraftLine {
  product: DraftProduct
  uom: 'BASE' | 'PACK'
  qty: string
  rate: string
  discPct: string
}

export interface OrderDraft {
  /** Set when an existing order is being changed rather than a new one taken. */
  orderId?: string
  docNo?: string
  party: DraftParty | null
  lines: DraftLine[]
  remarks: string
  orderDisc: string
  discMode: 'AMOUNT' | 'PCT'
  /** For an edit: what the order looked like before, so Undo can put it back. */
  original?: Omit<OrderDraft, 'original'>
}

/** Enough of an order to be worth saving: somebody to sell to, something to sell. */
export function worthSaving(d: OrderDraft | null): d is OrderDraft {
  if (!d || !d.party) return false
  return d.lines.some((l) => Number(l.qty) > 0)
}

/** What the database would actually be told, for comparing two drafts. */
function shapeOf(d: OrderDraft) {
  return JSON.stringify({
    party: d.party?.party_id ?? null,
    lines: d.lines
      .filter((l) => Number(l.qty) > 0)
      .map((l) => [l.product.product_id, l.uom, Number(l.qty), Number(l.rate), Number(l.discPct) || 0]),
    disc: [d.discMode, Number(d.orderDisc) || 0],
    remarks: d.remarks.trim(),
  })
}

/**
 * Whether an order being edited still says exactly what it said when it was
 * opened. Worth knowing: modify_sales_order rebuilds the lines and re-reserves
 * the stock, so sending it an unchanged order is a small, pointless disturbance
 * of a document somebody else may be about to bill.
 */
export function unchanged(d: OrderDraft): boolean {
  if (!d.original) return false
  return shapeOf(d) === shapeOf(d.original as OrderDraft)
}

// -----------------------------------------------------------------------------
// The draft kept on this device
// -----------------------------------------------------------------------------

const DRAFT_KEY = 'sales-app.order-draft'

export function keepDraft(d: OrderDraft | null) {
  try {
    if (worthSaving(d)) localStorage.setItem(DRAFT_KEY, JSON.stringify(d))
    else localStorage.removeItem(DRAFT_KEY)
  } catch {
    // A phone with storage full or blocked still takes orders; it just cannot
    // survive being killed mid-order. Not worth failing anything over.
  }
}

export function takeKeptDraft(): OrderDraft | null {
  try {
    const raw = localStorage.getItem(DRAFT_KEY)
    if (!raw) return null
    const d = JSON.parse(raw) as OrderDraft
    return worthSaving(d) ? d : null
  } catch {
    return null
  }
}

export function forgetDraft() {
  try {
    localStorage.removeItem(DRAFT_KEY)
  } catch {
    /* see keepDraft */
  }
}

// -----------------------------------------------------------------------------
// What the banner is currently saying
// -----------------------------------------------------------------------------

export type SaveState =
  | { state: 'saving'; draft: OrderDraft }
  | { state: 'saved'; draft: OrderDraft; orderId: string; docNo: string; edited: boolean }
  | { state: 'undone'; docNo: string }
  | { state: 'failed'; draft: OrderDraft; message: string; shortOfStock: boolean }
  | { state: 'waiting'; draft: OrderDraft }

type Listener = (s: SaveState | null) => void

let current: SaveState | null = null
const listeners = new Set<Listener>()

function set(s: SaveState | null) {
  current = s
  for (const l of listeners) l(s)
}

export function onSaveState(l: Listener): () => void {
  listeners.add(l)
  l(current)
  return () => {
    listeners.delete(l)
  }
}

export function currentSaveState() {
  return current
}

export function dismissSaveState() {
  set(null)
}

/** Hand a failed or waiting order back to the screen. */
export function reclaimDraft(): OrderDraft | null {
  const d =
    current && (current.state === 'failed' || current.state === 'waiting')
      ? current.draft
      : null
  if (d) set(null)
  return d
}

// -----------------------------------------------------------------------------
// Saving
// -----------------------------------------------------------------------------

function payloadOf(d: OrderDraft) {
  return d.lines
    .filter((l) => Number(l.qty) > 0)
    .map((l) => ({
      product_id: l.product.product_id,
      uom: l.uom,
      qty: Number(l.qty),
      rate: Number(l.rate),
      line_discount_pct: Number(l.discPct) > 0 ? Number(l.discPct) : null,
    }))
}

function discountsOf(d: OrderDraft) {
  return {
    p_bill_discount_amount: d.discMode === 'AMOUNT' ? Number(d.orderDisc) || 0 : 0,
    p_bill_discount_pct: d.discMode === 'PCT' ? Number(d.orderDisc) || null : null,
  }
}

/**
 * Send the order. Called as the rep leaves, so it reports through the banner
 * rather than returning anything anyone is still around to read.
 */
export async function saveOrder(d: OrderDraft): Promise<void> {
  if (!worthSaving(d)) return
  keepDraft(d)

  if (!navigator.onLine) {
    set({ state: 'waiting', draft: d })
    return
  }

  set({ state: 'saving', draft: d })

  const lines = payloadOf(d)
  const disc = discountsOf(d)

  const { data, error } = d.orderId
    ? await supabase.rpc('modify_sales_order', {
        p_order_id: d.orderId,
        p_lines: lines,
        ...disc,
      })
    : await supabase.rpc('create_sales_order', {
        p_party_id: d.party!.party_id,
        p_order_date: new Date().toISOString().slice(0, 10),
        p_lines: lines,
        p_remarks: d.remarks.trim() || null,
        ...disc,
      })

  if (error) {
    const de = asDbError(error)
    const short =
      de.code === 'SA001' && Array.isArray(de.details)
        ? (de.details as { product_name: string }[]).map((x) => x.product_name).join(', ')
        : null
    set({
      state: 'failed',
      draft: d,
      message: short ? `there is no longer enough ${short}` : friendlyMessage(error),
      shortOfStock: !!short,
    })
    return
  }

  forgetDraft()

  const res = (data ?? {}) as { order_id?: string; doc_no?: string }
  set({
    state: 'saved',
    draft: d,
    orderId: d.orderId ?? res.order_id ?? '',
    docNo: d.docNo ?? res.doc_no ?? '',
    edited: !!d.orderId,
  })
}

/**
 * Put it back the way it was.
 *
 * A new order is cancelled outright, which hands its stock back. An edited one
 * is re-saved with the lines it had before, because the rep undoing a change
 * meant the change, not the order.
 */
export async function undoLastSave(): Promise<void> {
  if (!current || current.state !== 'saved') return
  const { orderId, docNo, edited, draft } = current

  set({ state: 'saving', draft })

  if (edited && draft.original) {
    const before = draft.original
    const { error } = await supabase.rpc('modify_sales_order', {
      p_order_id: orderId,
      p_lines: payloadOf(before as OrderDraft),
      ...discountsOf(before as OrderDraft),
    })
    if (error) {
      set({ state: 'failed', draft, message: friendlyMessage(error), shortOfStock: false })
      return
    }
  } else {
    const { error } = await supabase.rpc('cancel_sales_order', {
      p_order_id: orderId,
      p_reason: 'Undone straight after it was saved',
    })
    if (error) {
      set({ state: 'failed', draft, message: friendlyMessage(error), shortOfStock: false })
      return
    }
  }

  set({ state: 'undone', docNo })
}

/** Try again by hand, or automatically when the signal comes back. */
export async function retrySave(): Promise<void> {
  const d = current?.state === 'failed' || current?.state === 'waiting' ? current.draft : null
  if (d) await saveOrder(d)
}

let watching = false

/** An order held back for want of signal goes as soon as there is some. */
export function watchForSignal() {
  if (watching) return
  watching = true
  window.addEventListener('online', () => {
    if (current?.state === 'waiting') void retrySave()
  })
}
