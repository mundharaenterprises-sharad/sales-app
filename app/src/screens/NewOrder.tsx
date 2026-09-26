import { useCallback, useEffect, useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { supabase, asDbError, friendlyMessage } from '../lib/supabase'
import { getSnapshot, putSnapshot } from '../lib/cache'
import { fmtMoney, fmtQty, fmtAge } from '../lib/format'
import { Banner, ErrorBanner, Loading, Spinner } from '../components/ui'
import { Picker } from '../components/Picker'
import { useOnline } from '../lib/session'

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

/** One short entry from the SA001 payload. */
interface Shortfall {
  product_id: string
  product_code: string
  product_name: string
  base_uom: string
  requested: number
  available: number
}

const PARTY_CACHE = 'parties'
const PRODUCT_CACHE = 'stock'

export default function NewOrder() {
  const nav = useNavigate()
  const online = useOnline()

  const [parties, setParties] = useState<PartyRow[] | null>(null)
  const [products, setProducts] = useState<ProductRow[] | null>(null)
  const [dataAge, setDataAge] = useState<number | null>(null)
  const [stale, setStale] = useState(false)

  const [party, setParty] = useState<PartyRow | null>(null)
  const [lines, setLines] = useState<Line[]>([])
  const [remarks, setRemarks] = useState('')

  const [picking, setPicking] = useState<'party' | 'product' | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [shortfalls, setShortfalls] = useState<Shortfall[] | null>(null)

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

  const [orderDisc, setOrderDisc] = useState('')
  const [discMode, setDiscMode] = useState<'AMOUNT' | 'PCT'>('PCT')

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

  const canSubmit = !!party && lines.length > 0 && problems.length === 0 && !busy && online

  // ---------------------------------------------------------------------------

  const submit = useCallback(async () => {
    if (!party) return
    setBusy(true)
    setError(null)
    setShortfalls(null)

    const payload = lines.map((l) => ({
      product_id: l.product.product_id,
      uom: l.uom,
      qty: Number(l.qty),
      rate: Number(l.rate),
      line_discount_pct: Number(l.discPct) > 0 ? Number(l.discPct) : null,
    }))

    const { data, error } = await supabase.rpc('create_sales_order', {
      p_party_id: party.party_id,
      p_order_date: new Date().toISOString().slice(0, 10),
      p_lines: payload,
      p_remarks: remarks.trim() || null,
      p_bill_discount_amount: discMode === 'AMOUNT' ? Number(orderDisc) || 0 : 0,
      p_bill_discount_pct: discMode === 'PCT' ? Number(orderDisc) || null : null,
    })

    if (error) {
      const de = asDbError(error)
      if (de.code === 'SA001' && Array.isArray(de.details)) {
        // Somebody else took the stock between this screen loading and now.
        setShortfalls(de.details as Shortfall[])
      } else {
        setError(friendlyMessage(error))
      }
      setBusy(false)
      return
    }

    const res = data as { order_id: string; doc_no: string }
    nav('/orders', { replace: true, state: { justCreated: res.doc_no } })
    // orderDisc and discMode belong here: without them submit keeps the copy
    // it was built with, and an order saves with no discount however much the
    // screen says otherwise.
  }, [party, lines, remarks, orderDisc, discMode, nav])

  /** Apply the shortfall, then let the rep resubmit as one atomic attempt. */
  const applyShortfall = (s: Shortfall, action: 'reduce' | 'remove') => {
    setLines((ls) => {
      const i = ls.findIndex((l) => l.product.product_id === s.product_id)
      if (i < 0) return ls
      if (action === 'remove') return ls.filter((_, j) => j !== i)

      const next = [...ls]
      const l = next[i]
      const pack = Number(l.product.pack_size)
      // Keep the screen's own availability figure honest.
      const product = { ...l.product, available: s.available }

      if (l.uom === 'PACK' && s.available < pack) {
        // What is left will not fill a single pack. Reducing by packs would
        // round down to zero and silently drop the line, so switch the line to
        // base units and take what there is.
        next[i] = {
          ...l,
          product,
          uom: 'BASE',
          qty: String(s.available),
          rate: String(l.product.sale_rate),
        }
      } else {
        // The figure from the database is in base units; express it in whatever
        // unit the rep is working in.
        const per = l.uom === 'PACK' ? pack : 1
        const newQty = l.uom === 'PACK' ? Math.floor(s.available / per) : s.available
        next[i] = { ...l, product, qty: String(newQty) }
      }

      return next.filter((x) => Number(x.qty) > 0)
    })
    setShortfalls((ss) => {
      const left = (ss ?? []).filter((x) => x.product_id !== s.product_id)
      return left.length > 0 ? left : null
    })
  }

  // ---------------------------------------------------------------------------

  if (parties === null || products === null) return <Loading what="Loading customers and stock" />

  return (
    <>
      <div className="page-head">
        <h1>New order</h1>
        {dataAge && (
          <span className="sub">
            {stale ? 'Saved on this device ' : 'Stock as of '}
            {fmtAge(dataAge)}
          </span>
        )}
      </div>

      <ErrorBanner error={error} />

      {!online && (
        <Banner tone="bad">
          <strong>You are offline.</strong> An order cannot be submitted without a
          connection, because the stock it reserves has to be checked as you send
          it. You can still build the order here and send it when you have signal.
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
          <button
            className="primary"
            style={{ marginLeft: 'auto' }}
            onClick={() => void submit()}
            disabled={!canSubmit}
          >
            {busy ? <Spinner /> : 'Submit order'}
          </button>
        </div>

        {problems.length > 0 && (
          <Banner tone="warn">
            {problems.map((p, i) => (
              <div key={i}>{p}</div>
            ))}
          </Banner>
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

      {/* --- Stock conflict ------------------------------------------------ */}
      {shortfalls && (
        <ShortfallDialog
          shortfalls={shortfalls}
          onApply={applyShortfall}
          onCancelOrder={() => { setShortfalls(null); setLines([]) }}
          onClose={() => setShortfalls(null)}
        />
      )}
    </>
  )
}

/**
 * Shown when the order was refused because the stock went while the rep was
 * typing. The order was not partly submitted — nothing was taken — so this is
 * about getting to a set of lines that will go through on the next attempt.
 */
function ShortfallDialog({
  shortfalls,
  onApply,
  onCancelOrder,
  onClose,
}: {
  shortfalls: Shortfall[]
  onApply: (s: Shortfall, action: 'reduce' | 'remove') => void
  onCancelOrder: () => void
  onClose: () => void
}) {
  return (
    <div className="sheet-backdrop">
      <div className="sheet sheet-dialog" role="alertdialog" aria-modal="true">
        <div className="sheet-head">
          <h2>Not enough stock</h2>
        </div>

        <div className="sheet-body" style={{ padding: 16 }}>
          <p style={{ marginTop: 0 }}>
            Someone else took this stock while you were writing the order.{' '}
            <strong>Nothing has been reserved</strong> — sort these out and send it
            again.
          </p>

          {shortfalls.map((s) => (
            <div key={s.product_id} className="card card-pad" style={{ marginBottom: 10 }}>
              <div className="strong">{s.product_name}</div>
              <div className="sub" style={{ marginBottom: 10 }}>
                You asked for {fmtQty(s.requested)} {s.base_uom}, but only{' '}
                {fmtQty(s.available)} {s.base_uom}{' '}
                {Number(s.available) === 1 ? 'is' : 'are'} left.
              </div>
              <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                {Number(s.available) > 0 && (
                  <button className="primary" onClick={() => onApply(s, 'reduce')}>
                    Reduce to {fmtQty(s.available)} {s.base_uom}
                  </button>
                )}
                <button onClick={() => onApply(s, 'remove')}>Remove this item</button>
              </div>
            </div>
          ))}
        </div>

        <div className="sheet-foot">
          <button className="ghost" onClick={onCancelOrder}>Discard the order</button>
          <button onClick={onClose} style={{ marginLeft: 'auto' }}>Close</button>
        </div>
      </div>
    </div>
  )
}
