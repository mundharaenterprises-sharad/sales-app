import { useCallback, useEffect, useMemo, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { supabase, asDbError, friendlyMessage } from '../lib/supabase'
import { fmtMoney, fmtQty } from '../lib/format'
import { Banner, ErrorBanner, Loading, Spinner } from '../components/ui'
import { Picker } from '../components/Picker'
import { Check, num } from '../components/FormSheet'

/**
 * Raising a bill.
 *
 * Three ways in:
 *   /invoices/new?order=<id>   bill an order a rep sent — lines come prefilled
 *                              with whatever is still pending on it
 *   /invoices/new              a direct sale: pick the party, pick the products
 *   /invoices/new?revise=<id>  correct a bill raised today — lines come from
 *                              that bill, and saving replaces it
 *
 * Quantities and rates stay editable either way: what actually leaves the
 * godown is what gets billed. The database refuses anything above what the
 * order still has pending, and anything above the stock on hand.
 */

interface PartyRow {
  party_id: string
  party_code: string
  party_name: string
  route_name: string
  balance: number | null
  credit_limit: number | null
  over_credit_limit: boolean | null
}

interface StockRow {
  product_id: string
  product_code: string
  product_name: string
  group_name: string
  base_uom: string
  pack_uom: string | null
  pack_size: number
  available: number
  on_hand: number
  sale_rate: number
  pack_sale_rate: number | null
}

interface OrderHead {
  id: string
  doc_no: string
  party_id: string
  order_date: string
  status: string
  remarks: string | null
}

interface OrderLineRow {
  id: string
  product_id: string
  uom: 'BASE' | 'PACK'
  qty: number
  pack_size: number
  rate: number
  qty_pending_base: number
  product: {
    code: string
    name: string
    base_uom: string
    pack_uom: string | null
    pack_size: number
  }
}

interface Line {
  key: string
  /** Set when this line comes from an order. */
  orderLineId: string | null
  productId: string
  code: string
  name: string
  baseUom: string
  packUom: string | null
  packSize: number
  uom: 'BASE' | 'PACK'
  qty: string
  rate: string
  discPct: string
  /** Pending on the order, in base units. Null for a direct sale. */
  pendingBase: number | null
  include: boolean
}

interface Shortfall {
  product_code: string
  product_name: string
  base_uom: string
  requested: number
  on_hand: number
}

const today = () => new Date().toISOString().slice(0, 10)

/** Quantity in base units, for comparing against stock and order pending. */
function baseQty(l: Line): number {
  const q = num(l.qty, NaN)
  if (Number.isNaN(q)) return NaN
  return l.uom === 'PACK' ? q * l.packSize : q
}

function lineGross(l: Line): number {
  const q = num(l.qty, NaN)
  const r = num(l.rate, NaN)
  if (Number.isNaN(q) || Number.isNaN(r)) return 0
  return Math.round(q * r * 100) / 100
}

function lineDiscount(l: Line): number {
  const pct = num(l.discPct, NaN)
  if (Number.isNaN(pct) || pct <= 0) return 0
  return Math.round(lineGross(l) * pct) / 100
}

export default function NewInvoice() {
  const nav = useNavigate()
  const [params] = useSearchParams()
  const reviseId = params.get('revise')
  const [orderId, setOrderId] = useState<string | null>(params.get('order'))
  const [replacing, setReplacing] = useState<{ doc_no: string } | null>(null)

  const [order, setOrder] = useState<OrderHead | null>(null)
  const [parties, setParties] = useState<PartyRow[] | null>(null)
  const [stock, setStock] = useState<StockRow[] | null>(null)
  const [party, setParty] = useState<PartyRow | null>(null)
  const [lines, setLines] = useState<Line[]>([])

  const [invoiceDate, setInvoiceDate] = useState(today())
  const [discMode, setDiscMode] = useState<'AMOUNT' | 'PCT'>('AMOUNT')
  const [billDisc, setBillDisc] = useState('')
  const [remarks, setRemarks] = useState('')

  const [picking, setPicking] = useState<null | 'party' | 'product'>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [shortfalls, setShortfalls] = useState<Shortfall[] | null>(null)

  // ---------------------------------------------------------------------------
  // Load
  // ---------------------------------------------------------------------------

  useEffect(() => {
    let alive = true

    async function load() {
      const [p, s] = await Promise.all([
        supabase.from('v_party_balance').select('*').eq('is_active', true).order('party_name'),
        supabase.from('v_stock_report').select('*').eq('is_active', true).order('product_name'),
      ])
      if (!alive) return
      if (p.error || s.error) {
        setError(friendlyMessage(p.error ?? s.error))
        setParties([])
        setStock([])
        return
      }
      const plist = (p.data ?? []) as PartyRow[]
      setParties(plist)
      setStock((s.data ?? []) as StockRow[])

      // Correcting a bill raised today: its own lines are the starting point.
      if (reviseId) {
        const inv = await supabase
          .from('sales_invoice')
          .select(
            '*, lines:sales_invoice_line (*, product:product_id' +
              ' (code, name, base_uom, pack_uom, pack_size))',
          )
          .eq('id', reviseId)
          .single()
        if (!alive) return
        if (inv.error) {
          setError(friendlyMessage(inv.error))
          return
        }
        const row = inv.data as unknown as {
          doc_no: string
          party_id: string
          order_id: string | null
          invoice_date: string
          remarks: string | null
          bill_discount_amount: number
          lines: {
            id: string
            line_no: number
            order_line_id: string | null
            product_id: string
            uom: 'BASE' | 'PACK'
            qty: number
            pack_size: number
            rate: number
            line_discount_pct: number | null
            product: { code: string; name: string; base_uom: string; pack_uom: string | null }
          }[]
        }

        setReplacing({ doc_no: row.doc_no })
        setOrderId(row.order_id)
        setParty(plist.find((x) => x.party_id === row.party_id) ?? null)
        setInvoiceDate(row.invoice_date)
        setRemarks(row.remarks ?? '')
        if (Number(row.bill_discount_amount) > 0) {
          setDiscMode('AMOUNT')
          setBillDisc(String(Number(row.bill_discount_amount)))
        }
        setLines(
          [...row.lines]
            .sort((a, b) => a.line_no - b.line_no)
            .map((l) => ({
              key: l.id,
              orderLineId: l.order_line_id,
              productId: l.product_id,
              code: l.product.code,
              name: l.product.name,
              baseUom: l.product.base_uom,
              packUom: l.product.pack_uom,
              packSize: Number(l.pack_size),
              uom: l.uom,
              qty: String(Number(l.qty)),
              rate: String(Number(l.rate)),
              discPct: l.line_discount_pct ? String(Number(l.line_discount_pct)) : '',
              // The bill being replaced still holds these quantities, so the
              // order's pending figure is not the limit here. The database
              // checks the real limit when the correction is saved.
              pendingBase: null,
              include: true,
            })),
        )
        return
      }

      if (!orderId) return

      const [o, ol] = await Promise.all([
        supabase.from('sales_order').select('*').eq('id', orderId).single(),
        supabase
          .from('sales_order_line')
          .select(
            'id, product_id, uom, qty, pack_size, rate, qty_pending_base,' +
              ' product:product_id (code, name, base_uom, pack_uom, pack_size)',
          )
          .eq('order_id', orderId)
          .order('line_no'),
      ])
      if (!alive) return
      if (o.error || ol.error) {
        setError(friendlyMessage(o.error ?? ol.error))
        return
      }

      const head = o.data as OrderHead
      setOrder(head)
      setParty(plist.find((x) => x.party_id === head.party_id) ?? null)
      setRemarks(head.remarks ?? '')

      const rows = (ol.data ?? []) as unknown as OrderLineRow[]
      setLines(
        rows
          .filter((r) => Number(r.qty_pending_base) > 0)
          .map((r) => {
            const pending = Number(r.qty_pending_base)
            const packSize = Number(r.pack_size)
            // Show what is left in the unit the rep ordered in, as long as it
            // still divides into whole packs. A part pack goes out as pieces.
            const asPack = r.uom === 'PACK' && pending % packSize === 0
            return {
              key: r.id,
              orderLineId: r.id,
              productId: r.product_id,
              code: r.product.code,
              name: r.product.name,
              baseUom: r.product.base_uom,
              packUom: r.product.pack_uom,
              packSize,
              uom: asPack ? ('PACK' as const) : ('BASE' as const),
              qty: String(asPack ? pending / packSize : pending),
              rate: String(asPack ? Number(r.rate) : Number(r.rate) / (r.uom === 'PACK' ? packSize : 1)),
              discPct: '',
              pendingBase: pending,
              include: true,
            }
          }),
      )
    }

    void load()
    return () => {
      alive = false
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [orderId, reviseId])

  // ---------------------------------------------------------------------------
  // Lines
  // ---------------------------------------------------------------------------

  const stockFor = useCallback(
    (productId: string) => stock?.find((s) => s.product_id === productId) ?? null,
    [stock],
  )

  const addProduct = useCallback((p: StockRow) => {
    setLines((ls) => {
      const i = ls.findIndex((l) => l.productId === p.product_id)
      if (i >= 0) {
        const next = [...ls]
        next[i] = { ...next[i], qty: String((num(next[i].qty, 0) || 0) + 1), include: true }
        return next
      }
      return [
        ...ls,
        {
          key: `new-${p.product_id}`,
          orderLineId: null,
          productId: p.product_id,
          code: p.product_code,
          name: p.product_name,
          baseUom: p.base_uom,
          packUom: p.pack_uom,
          packSize: Number(p.pack_size),
          uom: 'BASE',
          qty: '1',
          rate: String(Number(p.sale_rate)),
          discPct: '',
          pendingBase: null,
          include: true,
        },
      ]
    })
  }, [])

  const setLine = (key: string, patch: Partial<Line>) =>
    setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)))

  const removeLine = (key: string) => setLines((ls) => ls.filter((l) => l.key !== key))

  /** Switching between pieces and boxes rescales the rate to match. */
  const switchUom = (l: Line, uom: 'BASE' | 'PACK') => {
    const s = stockFor(l.productId)
    const perUnit = s ? Number(s.sale_rate) : num(l.rate, 0) / (l.uom === 'PACK' ? l.packSize : 1)
    const packRate =
      s?.pack_sale_rate != null
        ? Number(s.pack_sale_rate)
        : Math.round(perUnit * l.packSize * 100) / 100
    setLine(l.key, { uom, rate: String(uom === 'PACK' ? packRate : perUnit) })
  }

  // ---------------------------------------------------------------------------
  // Totals
  // ---------------------------------------------------------------------------

  const active = useMemo(() => lines.filter((l) => l.include), [lines])

  const gross = useMemo(() => active.reduce((s, l) => s + lineGross(l), 0), [active])
  const lineDisc = useMemo(() => active.reduce((s, l) => s + lineDiscount(l), 0), [active])
  const afterLines = Math.round((gross - lineDisc) * 100) / 100

  const billDiscValue = useMemo(() => {
    const v = num(billDisc, 0)
    if (Number.isNaN(v) || v <= 0) return 0
    return discMode === 'AMOUNT' ? v : Math.round(afterLines * v) / 100
  }, [billDisc, discMode, afterLines])

  const net = Math.round((afterLines - billDiscValue) * 100) / 100

  // ---------------------------------------------------------------------------
  // Save
  // ---------------------------------------------------------------------------

  const save = useCallback(async () => {
    setError(null)
    setShortfalls(null)

    if (!party) {
      setError('Choose a customer first.')
      return
    }
    if (active.length === 0) {
      setError('A bill needs at least one item.')
      return
    }
    for (const l of active) {
      const q = num(l.qty, NaN)
      const r = num(l.rate, NaN)
      if (Number.isNaN(q) || q <= 0) {
        setError(`${l.name}: quantity must be a number above zero.`)
        return
      }
      if (Number.isNaN(r) || r < 0) {
        setError(`${l.name}: rate must be a plain number.`)
        return
      }
      const pct = num(l.discPct, 0)
      if (Number.isNaN(pct) || pct < 0 || pct > 100) {
        setError(`${l.name}: discount must be between 0 and 100 per cent.`)
        return
      }
      if (l.pendingBase !== null && baseQty(l) > l.pendingBase) {
        setError(
          `${l.name}: the order has only ${fmtQty(l.pendingBase)} ${l.baseUom} left to bill.`,
        )
        return
      }
      const s = stockFor(l.productId)
      if (!reviseId && s && baseQty(l) > Number(s.on_hand)) {
        setError(
          `${l.name}: only ${fmtQty(s.on_hand)} ${l.baseUom} in stock. Reduce the quantity.`,
        )
        return
      }
    }
    if (billDiscValue > afterLines) {
      setError('The bill discount is larger than the bill.')
      return
    }

    setBusy(true)
    const payload = active.map((l) => ({
      order_line_id: l.orderLineId,
      product_id: l.productId,
      uom: l.uom,
      qty: num(l.qty, 0),
      rate: num(l.rate, 0),
      line_discount_pct: num(l.discPct, 0) || null,
    }))

    const { data, error } = reviseId
      ? await supabase.rpc('revise_sales_invoice', {
          p_invoice_id: reviseId,
          p_lines: payload,
          p_bill_discount_amount: discMode === 'AMOUNT' ? num(billDisc, 0) || 0 : 0,
          p_bill_discount_pct: discMode === 'PCT' ? num(billDisc, 0) || null : null,
          p_remarks: remarks.trim() || null,
        })
      : await supabase.rpc('create_sales_invoice', {
          p_invoice_date: invoiceDate,
          p_lines: payload,
          p_order_id: orderId,
          p_party_id: orderId ? null : party.party_id,
          p_bill_discount_amount: discMode === 'AMOUNT' ? num(billDisc, 0) || 0 : 0,
          p_bill_discount_pct: discMode === 'PCT' ? num(billDisc, 0) || null : null,
          p_remarks: remarks.trim() || null,
        })

    if (error) {
      const de = asDbError(error)
      if (de.code === 'SA001' && Array.isArray(de.details)) {
        setShortfalls(de.details as Shortfall[])
      } else {
        setError(friendlyMessage(error))
      }
      setBusy(false)
      return
    }

    const res = data as { invoice_id: string; doc_no: string; replaced_doc_no?: string }
    nav(`/invoices/${res.invoice_id}`, {
      replace: true,
      state: { justCreated: res.doc_no, replaced: res.replaced_doc_no },
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [party, active, billDisc, billDiscValue, afterLines, discMode, invoiceDate, orderId, reviseId, remarks, nav, stockFor])

  // ---------------------------------------------------------------------------

  if (parties === null || stock === null) return <Loading what="Loading customers and stock" />

  const pickableProducts = (stock ?? []).filter(
    (s) => !orderId || lines.some((l) => l.productId === s.product_id),
  )
  const canAddItems = !orderId

  return (
    <>
      <div className="page-head">
        <h1>
          {replacing
            ? `Correct bill ${replacing.doc_no}`
            : order
              ? `Bill ${order.doc_no}`
              : 'New bill'}
        </h1>
        <span className="sub">
          {replacing
            ? 'Saving replaces it with a corrected bill'
            : order
              ? 'Only what the order still has pending'
              : 'Direct sale — no order'}
        </span>
      </div>

      <ErrorBanner error={error} />

      {replacing && (
        <Banner tone="warn">
          <strong>Correcting bill {replacing.doc_no}.</strong> When you save, that
          bill is cancelled and a new one is raised with these items — in one go,
          so stock and the customer's balance can never be half-corrected. The
          new bill gets the next number; the old one stays on record as
          cancelled. Only possible today, and only while no payment has been put
          against it.
        </Banner>
      )}

      {shortfalls && (
        <Banner tone="bad">
          <strong>Not enough stock.</strong> Nothing has been billed. Reduce these
          and try again:
          <ul style={{ margin: '8px 0 0 18px' }}>
            {shortfalls.map((s) => (
              <li key={s.product_code}>
                {s.product_name}: asked for {fmtQty(s.requested)} {s.base_uom}, only{' '}
                {fmtQty(s.on_hand)} on hand
              </li>
            ))}
          </ul>
        </Banner>
      )}

      <div className="card card-pad">
        <div className="form-row">
          <div className="field">
            <label htmlFor="inv-party">Customer</label>
            {order || replacing ? (
              <input id="inv-party" type="text" value={party?.party_name ?? ''} disabled />
            ) : (
              <button type="button" className="block" onClick={() => setPicking('party')}>
                {party ? party.party_name : 'Choose a customer'}
              </button>
            )}
            {party && (
              <div className="hint">
                {party.party_code} · {party.route_name}
                {party.balance != null && <> · owes {fmtMoney(party.balance)}</>}
              </div>
            )}
          </div>

          <div className="field">
            <label htmlFor="inv-date">Bill date</label>
            <input
              id="inv-date"
              type="date"
              value={invoiceDate}
              disabled={!!replacing}
              onChange={(e) => setInvoiceDate(e.target.value)}
            />
          </div>
        </div>

        {party?.over_credit_limit && (
          <Banner tone="warn">
            <strong>{party.party_name} is over their credit limit.</strong> They owe{' '}
            {fmtMoney(party.balance)} against a limit of {fmtMoney(party.credit_limit)}.
          </Banner>
        )}
      </div>

      {lines.length === 0 ? (
        <div className="card card-pad" style={{ marginTop: 12 }}>
          <p style={{ marginTop: 0, color: 'var(--ink-3)' }}>
            {order && !replacing
              ? 'This order has nothing left to bill.'
              : 'No items yet. Add what the customer is taking.'}
          </p>
          {canAddItems && (
            <button className="primary" onClick={() => setPicking('product')} disabled={!party}>
              Add item
            </button>
          )}
        </div>
      ) : (
        <div style={{ marginTop: 12 }}>
          {lines.map((l) => {
            const s = stockFor(l.productId)
            const over = s != null && baseQty(l) > Number(s.on_hand)
            const overOrder = l.pendingBase !== null && baseQty(l) > l.pendingBase
            return (
              <div className="order-line" key={l.key} style={{ opacity: l.include ? 1 : 0.55 }}>
                <div className="order-line-head">
                  <div style={{ flex: 1 }}>
                    <div className="strong">{l.name}</div>
                    <div className="sub">
                      {l.code}
                      {l.pendingBase !== null && (
                        <> · {fmtQty(l.pendingBase)} {l.baseUom} pending on the order</>
                      )}
                      {s && <> · {fmtQty(s.on_hand)} {l.baseUom} in stock</>}
                    </div>
                  </div>
                  {l.orderLineId ? (
                    <Check
                      id={`inc-${l.key}`}
                      checked={l.include}
                      onChange={(v) => setLine(l.key, { include: v })}
                    >
                      Bill
                    </Check>
                  ) : (
                    <button className="ghost" onClick={() => removeLine(l.key)}>Remove</button>
                  )}
                </div>

                <div className="order-line-grid">
                  <label>
                    <span>Unit</span>
                    <select
                      value={l.uom}
                      disabled={!l.packUom || l.packSize <= 1}
                      onChange={(e) => switchUom(l, e.target.value as 'BASE' | 'PACK')}
                    >
                      <option value="BASE">{l.baseUom}</option>
                      {l.packUom && l.packSize > 1 && (
                        <option value="PACK">
                          {l.packUom} of {fmtQty(l.packSize)}
                        </option>
                      )}
                    </select>
                  </label>

                  <label>
                    <span>Quantity</span>
                    <input
                      type="text"
                      inputMode="decimal"
                      value={l.qty}
                      onChange={(e) => setLine(l.key, { qty: e.target.value })}
                    />
                  </label>

                  <label>
                    <span>Rate</span>
                    <input
                      type="text"
                      inputMode="decimal"
                      value={l.rate}
                      onChange={(e) => setLine(l.key, { rate: e.target.value })}
                    />
                  </label>

                  <label>
                    <span>Disc %</span>
                    <input
                      type="text"
                      inputMode="decimal"
                      value={l.discPct}
                      placeholder="0"
                      onChange={(e) => setLine(l.key, { discPct: e.target.value })}
                    />
                  </label>

                  <div className="order-line-total">
                    <span>Amount</span>
                    <strong>{fmtMoney(lineGross(l) - lineDiscount(l))}</strong>
                  </div>
                </div>

                {(over || overOrder) && l.include && (
                  <Banner tone="bad">
                    {overOrder
                      ? `The order has only ${fmtQty(l.pendingBase)} ${l.baseUom} left to bill.`
                      : `Only ${fmtQty(s?.on_hand)} ${l.baseUom} in stock.`}
                  </Banner>
                )}
              </div>
            )
          })}

          {canAddItems && (
            <button onClick={() => setPicking('product')} disabled={!party}>
              Add another item
            </button>
          )}
        </div>
      )}

      {lines.length > 0 && (
        <div className="card card-pad" style={{ marginTop: 12 }}>
          <div className="form-row">
            <div className="field">
              <label htmlFor="bd">Bill discount</label>
              <div style={{ display: 'flex', gap: 8 }}>
                <input
                  id="bd"
                  type="text"
                  inputMode="decimal"
                  value={billDisc}
                  placeholder="0"
                  onChange={(e) => setBillDisc(e.target.value)}
                />
                <select
                  value={discMode}
                  aria-label="Discount type"
                  onChange={(e) => setDiscMode(e.target.value as 'AMOUNT' | 'PCT')}
                  style={{ width: 'auto' }}
                >
                  <option value="AMOUNT">Amount</option>
                  <option value="PCT">%</option>
                </select>
              </div>
              <div className="hint">Spread across the items in proportion to their value.</div>
            </div>

            <div className="field">
              <label htmlFor="inv-remarks">Remarks</label>
              <input
                id="inv-remarks"
                type="text"
                value={remarks}
                onChange={(e) => setRemarks(e.target.value)}
              />
            </div>
          </div>

          <table className="data" style={{ marginTop: 4 }}>
            <tbody>
              <tr>
                <td>Items</td>
                <td className="num">{fmtMoney(gross)}</td>
              </tr>
              {lineDisc > 0 && (
                <tr>
                  <td>Item discounts</td>
                  <td className="num">− {fmtMoney(lineDisc)}</td>
                </tr>
              )}
              {billDiscValue > 0 && (
                <tr>
                  <td>Bill discount</td>
                  <td className="num">− {fmtMoney(billDiscValue)}</td>
                </tr>
              )}
              <tr>
                <td className="strong">Net</td>
                <td className="num strong">{fmtMoney(net)}</td>
              </tr>
            </tbody>
          </table>
          <p className="hint">
            The net may be rounded to the nearest rupee when the bill is saved.
          </p>

          <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
            <button onClick={() => nav(-1)} disabled={busy}>Back</button>
            <button
              className="primary"
              style={{ marginLeft: 'auto' }}
              onClick={() => void save()}
              disabled={busy || active.length === 0 || !party}
            >
              {busy ? <Spinner /> : replacing ? 'Save correction' : 'Save bill'}
            </button>
          </div>
        </div>
      )}

      {picking === 'party' && (
        <Picker<PartyRow>
          title="Choose a customer"
          placeholder="Search by name, code or route"
          items={parties}
          keyOf={(p) => p.party_id}
          searchOf={(p) => `${p.party_name} ${p.party_code} ${p.route_name}`}
          onPick={setParty}
          onClose={() => setPicking(null)}
          emptyText="No customers yet."
          render={(p) => (
            <>
              <div className="strong">{p.party_name}</div>
              <div className="sub">
                {p.party_code} · {p.route_name}
                {p.balance != null && <> · owes {fmtMoney(p.balance)}</>}
              </div>
            </>
          )}
        />
      )}

      {picking === 'product' && (
        <Picker<StockRow>
          title="Add item"
          placeholder="Search by name, code or group"
          items={pickableProducts}
          keyOf={(p) => p.product_id}
          searchOf={(p) => `${p.product_name} ${p.product_code} ${p.group_name}`}
          onPick={addProduct}
          onClose={() => setPicking(null)}
          emptyText="No products yet."
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
                <span className={`pill ${Number(p.on_hand) > 0 ? 'good' : 'bad'}`}>
                  {fmtQty(p.on_hand)} {p.base_uom} in stock
                </span>
              </div>
            </>
          )}
        />
      )}
    </>
  )
}
