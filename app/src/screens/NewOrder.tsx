import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { supabase, friendlyMessage } from '../lib/supabase'
import { getSnapshot, putSnapshot } from '../lib/cache'
import { fmtMoney, fmtQty, fmtAge } from '../lib/format'
import { Banner, ErrorBanner, Loading } from '../components/ui'
import { Picker } from '../components/Picker'
import { useOnline } from '../lib/session'
import {
  saveOrder,
  keepDraft,
  takeKeptDraft,
  forgetDraft,
  reclaimDraft,
  worthSaving,
  unchanged,
  watchForSignal,
  type OrderDraft,
} from '../lib/ordersave'

interface PartyRow {
  party_id: string
  party_code: string
  party_name: string
  route_name: string
  balance: number | null
  credit_limit: number | null
  over_credit_limit: boolean | null
}

interface ProductRow {
  product_id: string
  product_code: string
  product_name: string
  group_name: string
  base_uom: string
  pack_uom: string | null
  pack_size: number
  available: number
  sale_rate: number
  /** Price of one pack: as entered in the master, else rate x size. */
  pack_sale_rate: number | null
}

interface Line {
  product: ProductRow
  uom: 'BASE' | 'PACK'
  qty: string
  rate: string
  /** What was agreed at the shop for this item, as a percentage. */
  discPct: string
}

const PARTY_CACHE = 'parties'
const PRODUCT_CACHE = 'stock'

export default function NewOrder() {
  const nav = useNavigate()
  const online = useOnline()
  /** Present when an existing order is being changed rather than a new one taken. */
  const { id: editId } = useParams()

  const [parties, setParties] = useState<PartyRow[] | null>(null)
  const [products, setProducts] = useState<ProductRow[] | null>(null)
  const [dataAge, setDataAge] = useState<number | null>(null)
  const [stale, setStale] = useState(false)

  const [party, setParty] = useState<PartyRow | null>(null)
  const [lines, setLines] = useState<Line[]>([])
  const [remarks, setRemarks] = useState('')
  const [orderDisc, setOrderDisc] = useState('')
  const [discMode, setDiscMode] = useState<'AMOUNT' | 'PCT'>('PCT')

  const [picking, setPicking] = useState<'party' | 'product' | null>(null)
  const [error, setError] = useState<string | null>(null)

  /** The order being edited, and what it looked like before, so Undo can work. */
  const [docNo, setDocNo] = useState<string | null>(null)
  const [original, setOriginal] = useState<OrderDraft | null>(null)
  const [loadingOrder, setLoadingOrder] = useState(!!editId)
  /** Set when a draft this device had kept was put back on the screen. */
  const [restored, setRestored] = useState(false)

  /**
   * Whatever was left over from last time, claimed on the first render.
   *
   * It has to happen here rather than in the effect that fills the screen,
   * because that one waits for the customer and stock lists to arrive and by
   * then this screen has already written its own empty state over the device
   * copy. Read it before anything can overwrite it; apply it once there are
   * products to hang it on.
   */
  const [leftOver] = useState<OrderDraft | null>(() =>
    editId ? null : reclaimDraft() ?? takeKeptDraft(),
  )
  /** Nothing is written back to the device until the screen is filled in. */
  const [settled, setSettled] = useState(false)

  // ---------------------------------------------------------------------------

  useEffect(() => {
    let alive = true

    async function load() {
      const [pSnap, sSnap] = await Promise.all([
        getSnapshot<PartyRow[]>(PARTY_CACHE),
        getSnapshot<ProductRow[]>(PRODUCT_CACHE),
      ])
      if (alive && pSnap && sSnap) {
        setParties(pSnap.data)
        setProducts(sSnap.data)
        setDataAge(Math.min(pSnap.fetchedAt, sSnap.fetchedAt))
        setStale(true)
      }

      if (!navigator.onLine) {
        if (alive && !(pSnap && sSnap)) {
          setParties([])
          setProducts([])
          setError('You are offline and this device has no saved customer list yet.')
        }
        return
      }

      const [pRes, sRes] = await Promise.all([
        supabase.from('v_party_balance').select('*').eq('is_active', true).order('party_name'),
        supabase.from('v_stock_report').select('*').eq('is_active', true).order('product_name'),
      ])

      if (!alive) return

      if (pRes.error || sRes.error) {
        // v_party_balance needs permission to see money. A rep without it still
        // needs the customer list, so fall back to the plain table.
        const fallback = await supabase
          .from('party')
          .select('id, code, name, route:route_id(name)')
          .eq('is_active', true)
          .order('name')

        if (fallback.error) {
          setError(friendlyMessage(pRes.error ?? sRes.error))
          if (!pSnap) setParties([])
          if (!sSnap) setProducts([])
          return
        }

        const rows = (fallback.data ?? []).map((r) => {
          const p = r as unknown as { id: string; code: string; name: string; route: { name: string } | null }
          return {
            party_id: p.id,
            party_code: p.code,
            party_name: p.name,
            route_name: p.route?.name ?? '',
            balance: null,
            credit_limit: null,
            over_credit_limit: null,
          } as PartyRow
        })
        setParties(rows)
        void putSnapshot(PARTY_CACHE, rows)
      } else {
        setParties(pRes.data as PartyRow[])
        void putSnapshot(PARTY_CACHE, pRes.data)
      }

      if (!sRes.error) {
        setProducts(sRes.data as ProductRow[])
        void putSnapshot(PRODUCT_CACHE, sRes.data)
      }

      setDataAge(Date.now())
      setStale(false)
    }

    void load()
    return () => { alive = false }
  }, [])

  /**
   * Fill the screen: either an order being changed, or a draft this device
   * kept from a session that ended badly.
   *
   * Both need the product list first — a line is only meaningful here with the
   * stock figures and pack sizes beside it — so this waits for the loader
   * above rather than racing it.
   */
  useEffect(() => {
    if (!products || !parties) return
    let alive = true

    async function fill() {
      // An order the rep asked to change.
      if (editId) {
        const [head, ls] = await Promise.all([
          supabase.from('v_order_for_edit').select('*').eq('order_id', editId).maybeSingle(),
          supabase
            .from('sales_order_line')
            .select('product_id, uom, qty, rate, line_discount_pct')
            .eq('order_id', editId)
            .order('line_no'),
        ])
        if (!alive) return

        if (head.error || !head.data) {
          setError(head.error ? friendlyMessage(head.error) : 'That order no longer exists.')
          setLoadingOrder(false)
          return
        }

        const h = head.data as {
          doc_no: string
          party_id: string
          remarks: string | null
          bill_discount_pct: number | null
          bill_discount_amount: number | null
          is_editable: boolean
        }

        if (!h.is_editable) {
          setError('This order has been billed or cancelled, so it can no longer be changed.')
          setLoadingOrder(false)
          return
        }

        const p = (parties ?? []).find((x) => x.party_id === h.party_id) ?? null
        const restoredLines: Line[] = ((ls.data ?? []) as {
          product_id: string
          uom: 'BASE' | 'PACK'
          qty: number
          rate: number
          line_discount_pct: number | null
        }[])
          .map((r) => {
            const prod = (products ?? []).find((x) => x.product_id === r.product_id)
            if (!prod) return null
            return {
              product: prod,
              uom: r.uom,
              qty: String(r.qty),
              rate: String(r.rate),
              discPct: r.line_discount_pct ? String(r.line_discount_pct) : '',
            } as Line
          })
          .filter((l): l is Line => l !== null)

        const pct = h.bill_discount_pct
        const amt = h.bill_discount_amount

        setParty(p)
        setLines(restoredLines)
        setRemarks(h.remarks ?? '')
        setDocNo(h.doc_no)
        setDiscMode(pct != null ? 'PCT' : 'AMOUNT')
        setOrderDisc(pct != null ? String(pct) : amt ? String(amt) : '')
        setSettled(true)
        setOriginal({
          orderId: editId,
          docNo: h.doc_no,
          party: p,
          lines: restoredLines,
          remarks: h.remarks ?? '',
          orderDisc: pct != null ? String(pct) : amt ? String(amt) : '',
          discMode: pct != null ? 'PCT' : 'AMOUNT',
        })
        setLoadingOrder(false)
        return
      }

      // A new order: whatever was claimed on the first render, if anything.
      if (!alive) return
      if (leftOver && !leftOver.orderId) {
        setParty((leftOver.party as PartyRow) ?? null)
        setLines(leftOver.lines as Line[])
        setRemarks(leftOver.remarks)
        setOrderDisc(leftOver.orderDisc)
        setDiscMode(leftOver.discMode)
        setRestored(true)
      }
      setSettled(true)
    }

    void fill()
    return () => { alive = false }
    // Deliberately runs once the lists are in, and not again: re-running would
    // throw away whatever the rep has typed since.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [editId, products !== null, parties !== null])

  // ---------------------------------------------------------------------------

  const addProduct = useCallback((p: ProductRow) => {
    setLines((ls) => {
      // Adding a product already on the order bumps its quantity rather than
      // creating a second line — the database allows only one line per product.
      const i = ls.findIndex((l) => l.product.product_id === p.product_id)
      if (i >= 0) {
        const next = [...ls]
        next[i] = { ...next[i], qty: String((Number(next[i].qty) || 0) + 1) }
        return next
      }
      return [...ls, { product: p, uom: 'BASE', qty: '1', rate: String(p.sale_rate), discPct: '' }]
    })
  }, [])

  const setLine = (i: number, p: Partial<Line>) =>
    setLines((ls) => ls.map((l, j) => (j === i ? { ...l, ...p } : l)))

  const removeLine = (i: number) => setLines((ls) => ls.filter((_, j) => j !== i))

  /** Switching between pieces and boxes rescales the rate to match. */
  const switchUom = (i: number, uom: 'BASE' | 'PACK') => {
    setLines((ls) =>
      ls.map((l, j) => {
        if (j !== i) return l
        // Use the pack price as entered. Multiplying the derived unit rate
        // back up (20.8333 x 24 = 499.9992) would lose paisa on every box.
        const rate =
          uom === 'PACK'
            ? l.product.pack_sale_rate != null
              ? Number(l.product.pack_sale_rate)
              : Number(l.product.sale_rate) * Number(l.product.pack_size)
            : Number(l.product.sale_rate)
        return { ...l, uom, rate: String(rate) }
      }),
    )
  }

  const qtyBase = (l: Line) =>
    (Number(l.qty) || 0) * (l.uom === 'PACK' ? Number(l.product.pack_size) : 1)

  const lineGross = (l: Line) => (Number(l.qty) || 0) * (Number(l.rate) || 0)

  const lineDiscount = (l: Line) => {
    const pct = Number(l.discPct)
    if (!Number.isFinite(pct) || pct <= 0) return 0
    return Math.round(lineGross(l) * Math.min(pct, 100)) / 100 === 0
      ? 0
      : Math.round(((lineGross(l) * Math.min(pct, 100)) / 100) * 100) / 100
  }

  const lineTotal = (l: Line) =>
    Math.round((lineGross(l) - lineDiscount(l)) * 100) / 100

  const gross = useMemo(() => lines.reduce((s, l) => s + lineGross(l), 0), [lines])
  const lineDiscTotal = useMemo(
    () => lines.reduce((s, l) => s + lineDiscount(l), 0),
    [lines],
  )
  const afterLines = Math.round((gross - lineDiscTotal) * 100) / 100

  // A discount on the whole order, on top of anything given per item. Typed as
  // a percentage or an amount, because a rep agrees whichever the shop asked
  // for, and translating in your head at the counter is how mistakes happen.
  const orderDiscValue = useMemo(() => {
    const v = Number(orderDisc)
    if (!Number.isFinite(v) || v <= 0) return 0
    return discMode === 'PCT'
      ? Math.round(afterLines * Math.min(v, 100)) / 100 === 0
        ? 0
        : Math.round(((afterLines * Math.min(v, 100)) / 100) * 100) / 100
      : Math.round(v * 100) / 100
  }, [orderDisc, discMode, afterLines])

  const total = Math.round((afterLines - orderDiscValue) * 100) / 100

  const problems = useMemo(() => {
    const out: string[] = []
    lines.forEach((l, i) => {
      const d = Number(l.discPct)
      if (l.discPct.trim() !== '' && (!Number.isFinite(d) || d < 0 || d > 100)) {
        out.push(`Line ${i + 1}: discount must be between 0 and 100`)
      }
    })
    if (orderDiscValue > afterLines) {
      out.push('The discount on the order is more than the order itself')
    }
    lines.forEach((l, i) => {
      const q = Number(l.qty)
      if (!Number.isFinite(q) || q <= 0) out.push(`Line ${i + 1}: quantity must be above zero`)
      if (!Number.isFinite(Number(l.rate))) out.push(`Line ${i + 1}: rate is not a number`)
      if (qtyBase(l) > Number(l.product.available))
        out.push(
          `${l.product.product_name}: only ${fmtQty(l.product.available)} ${l.product.base_uom} available`,
        )
    })
    return out
  }, [lines, orderDiscValue, afterLines])

  /** Whether leaving now would save anything. Mirrors worthSaving(). */
  const readyToSave = !!party && lines.some((l) => Number(l.qty) > 0)

  // ---------------------------------------------------------------------------

  /** Everything the screen is holding, in the shape the saver understands. */
  const draft: OrderDraft = useMemo(
    () => ({
      orderId: editId,
      docNo: docNo ?? undefined,
      party,
      lines,
      remarks,
      orderDisc,
      discMode,
      original: original ?? undefined,
    }),
    [editId, docNo, party, lines, remarks, orderDisc, discMode, original],
  )

  /**
   * The unmount handler reads this rather than closing over state, because a
   * cleanup function keeps the values it was created with and the whole job
   * here is to save what the screen ended up holding, not what it held when
   * the effect last ran.
   */
  const draftRef = useRef(draft)
  draftRef.current = draft

  const settledRef = useRef(settled)
  settledRef.current = settled

  // Kept on this device as it is typed, so a phone that dies mid-order can
  // give it back. Cleared by a successful save.
  useEffect(() => {
    if (!settled) return
    keepDraft(draft)
  }, [draft, settled])

  useEffect(() => { watchForSignal() }, [])

  /**
   * Leaving the screen is what saves the order.
   *
   * Every way out lands here — the phone's back button, a tab in the nav, a
   * link — because they all unmount this screen, and none of them can be
   * relied on individually. Nothing is sent when there is no customer or
   * nothing to sell: opening the screen to look up a price and backing out
   * must cost nothing.
   */
  /** Set when the rep says to throw the order away, so leaving saves nothing. */
  const abandoned = useRef(false)

  useEffect(() => {
    return () => {
      if (abandoned.current || !settledRef.current) return
      const d = draftRef.current
      if (!worthSaving(d)) return
      // An order opened, looked at and left alone is not a change. Sending it
      // anyway would rebuild its lines and re-reserve its stock for nothing.
      if (d.orderId && unchanged(d)) return
      void saveOrder(d)
    }
  }, [])

  /**
   * The way out that saves nothing. Without a Submit button there has to be
   * one, or an order added by mistake can only be undone after it exists.
   */
  const discard = useCallback(() => {
    abandoned.current = true
    forgetDraft()
    nav(editId ? '/orders' : '/orders', { replace: true })
  }, [nav, editId])

  // ---------------------------------------------------------------------------

  if (parties === null || products === null) return <Loading what="Loading customers and stock" />
  if (loadingOrder) return <Loading what="Loading the order" />

  return (
    <>
      <div className="page-head">
        <h1>{editId ? `Change ${docNo ?? 'order'}` : 'New order'}</h1>
        {dataAge && (
          <span className="sub">
            {stale ? 'Saved on this device ' : 'Stock as of '}
            {fmtAge(dataAge)}
          </span>
        )}
      </div>

      <ErrorBanner error={error} />

      {restored && (
        <Banner tone="info">
          <strong>Picked up where you left off.</strong> This order was still on
          this phone from last time. Carry on, or remove the items you do not
          want.
        </Banner>
      )}

      {!online && (
        <Banner tone="warn">
          <strong>You are offline.</strong> Write the order as usual. It is kept on
          this phone and goes as soon as you have signal — the stock it needs can
          only be checked when it reaches the office.
        </Banner>
      )}

      {/* --- Customer ------------------------------------------------------ */}
      <div className="card card-pad">
        <h2>Customer</h2>
        {party ? (
          <div style={{ display: 'flex', alignItems: 'flex-start', gap: 12, marginTop: 10 }}>
            <div style={{ flex: 1 }}>
              <div className="strong" style={{ fontSize: 16 }}>{party.party_name}</div>
              <div className="sub">
                {party.party_code}
                {party.route_name && ` · ${party.route_name}`}
              </div>
              {party.balance !== null && (
                <div style={{ marginTop: 6 }}>
                  <span className={`pill ${party.over_credit_limit ? 'bad' : 'flat'}`}>
                    Owes {fmtMoney(party.balance)}
                  </span>
                </div>
              )}
            </div>
            <button onClick={() => setPicking('party')}>Change</button>
          </div>
        ) : (
          <button className="primary" style={{ marginTop: 10 }} onClick={() => setPicking('party')}>
            Choose customer
          </button>
        )}

        {party?.over_credit_limit && (
          <Banner tone="warn">
            <strong>Over their credit limit.</strong> They owe{' '}
            {fmtMoney(party.balance)} against a limit of {fmtMoney(party.credit_limit)}.
            You can still take the order — this is a warning, not a block.
          </Banner>
        )}
      </div>

      {/* --- Lines --------------------------------------------------------- */}
      <div className="card card-pad">
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <h2 style={{ flex: 1 }}>Items</h2>
          <button onClick={() => setPicking('product')}>Add item</button>
        </div>

        {lines.length === 0 ? (
          <p className="sub" style={{ marginTop: 12, marginBottom: 0 }}>
            No items yet.
          </p>
        ) : (
          <div style={{ marginTop: 12 }}>
            {lines.map((l, i) => {
              const over = qtyBase(l) > Number(l.product.available)
              return (
                <div key={l.product.product_id} className="order-line">
                  <div className="order-line-head">
                    <div style={{ flex: 1 }}>
                      <span className="strong">{l.product.product_name}</span>
                      <div className="sub">
                        {fmtQty(l.product.available)} {l.product.base_uom} available
                      </div>
                    </div>
                    <button className="ghost" onClick={() => removeLine(i)} aria-label="Remove">
                      Remove
                    </button>
                  </div>

                  <div className="order-line-grid">
                    <label>
                      <span>Quantity</span>
                      <input
                        type="number"
                        inputMode="decimal"
                        min="0"
                        step="any"
                        value={l.qty}
                        onChange={(e) => setLine(i, { qty: e.target.value })}
                      />
                    </label>

                    <label>
                      <span>Unit</span>
                      <select
                        value={l.uom}
                        onChange={(e) => switchUom(i, e.target.value as 'BASE' | 'PACK')}
                        disabled={!l.product.pack_uom || Number(l.product.pack_size) <= 1}
                      >
                        <option value="BASE">{l.product.base_uom}</option>
                        {l.product.pack_uom && Number(l.product.pack_size) > 1 && (
                          <option value="PACK">
                            {l.product.pack_uom} of {fmtQty(l.product.pack_size)}
                          </option>
                        )}
                      </select>
                    </label>

                    <label>
                      <span>Rate</span>
                      <input
                        type="number"
                        inputMode="decimal"
                        min="0"
                        step="any"
                        value={l.rate}
                        onChange={(e) => setLine(i, { rate: e.target.value })}
                      />
                    </label>

                    <label>
                      <span>Disc %</span>
                      <input
                        type="number"
                        inputMode="decimal"
                        min="0"
                        max="100"
                        step="any"
                        placeholder="0"
                        value={l.discPct}
                        onChange={(e) => setLine(i, { discPct: e.target.value })}
                      />
                    </label>

                    <div className="order-line-total">
                      <span>Amount</span>
                      <strong>{fmtMoney(lineTotal(l))}</strong>
                      {lineDiscount(l) > 0 && (
                        <div className="sub" style={{ fontWeight: 400 }}>
                          was {fmtMoney(lineGross(l))}
                        </div>
                      )}
                    </div>
                  </div>

                  {l.uom === 'PACK' && (
                    <div className="sub">
                      = {fmtQty(qtyBase(l))} {l.product.base_uom}
                    </div>
                  )}

                  {over && (
                    <div className="sub" style={{ color: 'var(--bad)', fontWeight: 600 }}>
                      More than is available.
                    </div>
                  )}
                </div>
              )
            })}
          </div>
        )}
      </div>

      {/* --- Finish -------------------------------------------------------- */}
      <div className="card card-pad">
        <div className="field">
          <label htmlFor="remarks">Remarks (optional)</label>
          <input
            id="remarks"
            type="text"
            value={remarks}
            onChange={(e) => setRemarks(e.target.value)}
            placeholder="Anything the office should know"
          />
        </div>

        <div className="field">
          <label htmlFor="ord-disc">Discount on the whole order</label>
          <div style={{ display: 'flex', gap: 8 }}>
            <input
              id="ord-disc"
              type="number"
              inputMode="decimal"
              min="0"
              step="any"
              placeholder="0"
              value={orderDisc}
              onChange={(e) => setOrderDisc(e.target.value)}
            />
            <select
              value={discMode}
              aria-label="Discount type"
              onChange={(e) => setDiscMode(e.target.value as 'AMOUNT' | 'PCT')}
              style={{ width: 'auto' }}
            >
              <option value="PCT">%</option>
              <option value="AMOUNT">Amount</option>
            </select>
          </div>
          <div className="hint">
            On top of anything given per item. It carries onto the bill as a
            percentage, so a part delivery takes its share and no more.
          </div>
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: 16, flexWrap: 'wrap' }}>
          <div>
            <div className="sub">Order total</div>
            <div className="stat">{fmtMoney(total)}</div>
            {(lineDiscTotal > 0 || orderDiscValue > 0) && (
              <div className="sub">
                {fmtMoney(gross)} less {fmtMoney(lineDiscTotal + orderDiscValue)} discount
              </div>
            )}
          </div>

          {/*
            There is no Submit button. Going back is what saves the order, and
            a screen that does something on the way out has to say so where the
            button used to be — otherwise the rep is left wondering, and wonders
            by tapping things.
          */}
          <div className="save-note" style={{ marginLeft: 'auto' }}>
            {readyToSave ? (
              <>
                <strong>Go back and this is saved.</strong>
                <div className="sub">
                  {editId
                    ? 'The change goes through as you leave the screen.'
                    : 'The order goes through as you leave the screen. You can undo it straight after.'}
                </div>
              </>
            ) : (
              <>
                <strong>Nothing to save yet.</strong>
                <div className="sub">
                  {party ? 'Add an item.' : 'Choose a customer and add an item.'} Leaving
                  now saves nothing.
                </div>
              </>
            )}
          </div>
        </div>

        {problems.length > 0 && (
          <Banner tone="warn">
            {problems.map((p, i) => (
              <div key={i}>{p}</div>
            ))}
          </Banner>
        )}

        {(editId || readyToSave) && (
          <div style={{ marginTop: 12 }}>
            <button className="ghost" onClick={discard}>
              {editId ? 'Leave without changing anything' : 'Throw this order away'}
            </button>
          </div>
        )}
      </div>

      {/* --- Pickers ------------------------------------------------------- */}
      {picking === 'party' && (
        <Picker<PartyRow>
          title="Choose customer"
          placeholder="Search by name, code or route"
          items={parties}
          keyOf={(p) => p.party_id}
          searchOf={(p) => `${p.party_name} ${p.party_code} ${p.route_name}`}
          onPick={setParty}
          onClose={() => setPicking(null)}
          emptyText="No customers have been imported yet."
          render={(p) => (
            <>
              <div className="strong">{p.party_name}</div>
              <div className="sub">
                {p.party_code}
                {p.route_name && ` · ${p.route_name}`}
                {p.balance !== null && p.balance > 0 && ` · owes ${fmtMoney(p.balance)}`}
              </div>
            </>
          )}
        />
      )}

      {picking === 'product' && (
        <Picker<ProductRow>
          title="Add item"
          placeholder="Search by name, code or group"
          items={products}
          keyOf={(p) => p.product_id}
          searchOf={(p) => `${p.product_name} ${p.product_code} ${p.group_name}`}
          onPick={addProduct}
          onClose={() => setPicking(null)}
          emptyText="No products have been imported yet."
          render={(p) => (
            <>
              <div className="strong">{p.product_name}</div>
              <div className="sub">
                {p.product_code} ·{' '}
                {p.pack_uom && p.pack_sale_rate != null
                  ? `${fmtMoney(p.pack_sale_rate)} per ${p.pack_uom} · `
                  : ''}
                {fmtMoney(p.sale_rate)} per {p.base_uom}
              </div>
              <div style={{ marginTop: 4 }}>
                <span className={`pill ${Number(p.available) > 0 ? 'good' : 'bad'}`}>
                  {fmtQty(p.available)} {p.base_uom} available
                </span>
              </div>
            </>
          )}
        />
      )}
    </>
  )
}
