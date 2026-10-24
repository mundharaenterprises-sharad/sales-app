import { useCallback, useEffect, useMemo, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { supabase, asDbError, friendlyMessage } from '../lib/supabase'
import { fmtMoney, isoDate } from '../lib/format'
import { Banner, ErrorBanner, Loading, Spinner } from '../components/ui'
import { Picker } from '../components/Picker'
import { num } from '../components/FormSheet'
import { DateInput } from '../components/DateInput'
import { useLineFocus, focusById } from '../lib/linefocus'
import { money2, rate4 } from '../lib/precision'

/**
 * Recording goods in.
 *
 * Deliberately close to the bill screen, because it is the same job in the
 * other direction and nobody should have to learn it twice. The differences
 * are that there is no stock to run out of, and that the rate being typed is
 * what was paid, which becomes the cost every margin figure leans on.
 *
 * One master group per purchase, as everywhere else: once the first product is
 * chosen, the picker only offers others from the same side of the business.
 * That is the database's rule, enforced here so it is a narrowed list rather
 * than a refusal at the end.
 *
 * **Discounts**, per line and on the whole bill, work exactly as they do on a
 * sales bill — enter the percentage or the rupees and the other is worked out.
 * A scheme discount from Parle or Current used to have to be absorbed by
 * typing a lower rate than the supplier's bill showed, which made the entry
 * disagree with the paper. Now the rate is what the bill says and the discount
 * is recorded as a discount.
 *
 * A bill-wise discount comes off the goods and not off the freight — the
 * supplier is not discounting the transporter — and the database spreads it
 * across the lines so each product carries its share of the saving. That
 * matters because **the discount lowers the recorded cost of the stock**: a
 * carton bought at 1,900 with 5% off is costed at 1,805, which is what was
 * paid and therefore what any future margin should be measured against.
 *
 * **The keyboard** walks it the way it walks a bill: choose the supplier, Tab
 * to *Add product*, then unit, quantity, rate, discount, Enter for the next
 * item. See lib/linefocus.ts for why the cursor lands on the unit box.
 *
 * **Correcting one** (`?revise=<id>`, migration 044) opens this same screen
 * with the purchase loaded, because a correction is the same job as an entry
 * and two screens would drift apart within a month — the lesson from orders,
 * which are taken and corrected on one screen for the same reason. Saving
 * cancels the original and posts this in its place, in one transaction, so
 * there is no moment where the goods are counted twice or not at all. It is
 * refused if any of what the original brought in has already been sold.
 */

interface Supplier {
  id: string
  code: string
  name: string
  city: string | null
}

interface ProductRow {
  id: string
  code: string
  name: string
  base_uom: string
  pack_uom: string | null
  pack_size: number
  purchase_rate: number
  pack_purchase_rate: number | null
  group_name: string
  master_code: string
  master_name: string
  is_active: boolean
}

interface Line {
  key: string
  product: ProductRow
  uom: 'BASE' | 'PACK'
  qty: string
  rate: string
  /** Per cent off this line. Blank means none. */
  discPct: string
}

const today = () => isoDate()

export default function NewPurchase() {
  const nav = useNavigate()
  const [params] = useSearchParams()
  /** The purchase being corrected, if this screen was opened to correct one. */
  const revising = params.get('revise')

  const [suppliers, setSuppliers] = useState<Supplier[] | null>(null)
  const [products, setProducts] = useState<ProductRow[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const [supplier, setSupplier] = useState<Supplier | null>(null)
  const [date, setDate] = useState(today())
  const [billNo, setBillNo] = useState('')
  const [billDate, setBillDate] = useState('')
  const [other, setOther] = useState('')
  const [remarks, setRemarks] = useState('')
  const [lines, setLines] = useState<Line[]>([])

  // A discount on the whole bill, entered either way round. The mode decides
  // which of the two the database is sent; it works out the other.
  const [discMode, setDiscMode] = useState<'AMOUNT' | 'PCT'>('AMOUNT')
  const [billDisc, setBillDisc] = useState('')

  const [pickSupplier, setPickSupplier] = useState(false)
  const [pickProduct, setPickProduct] = useState(false)

  const { focusLine } = useLineFocus()

  const load = useCallback(async () => {
    const [s, p] = await Promise.all([
      supabase.from('supplier').select('id, code, name, city').eq('is_active', true).order('name'),
      supabase
        .from('v_product_master')
        .select(
          'id, code, name, base_uom, pack_uom, pack_size, purchase_rate,' +
            ' pack_purchase_rate, group_name, master_code, master_name, is_active',
        )
        .eq('is_active', true)
        .order('name'),
    ])
    if (s.error) setError(friendlyMessage(s.error))
    else setSuppliers((s.data ?? []) as Supplier[])
    if (p.error) setError(friendlyMessage(p.error))
    else setProducts((p.data ?? []) as unknown as ProductRow[])
  }, [])

  useEffect(() => {
    void load()
  }, [load])

  /**
   * Load the purchase being corrected, once the product list is in.
   *
   * The lines are rebuilt from the product master rather than from the stored
   * line, because the unit dropdown and the rates on this screen come from the
   * master — a line whose product has since been edited has to show what the
   * product IS, or the screen offers a carton size that no longer exists.
   * Quantity, rate and discount are the purchase's own and are carried across
   * exactly.
   */
  useEffect(() => {
    if (!revising || !products || !suppliers) return
    let alive = true
    void (async () => {
      const [h, l] = await Promise.all([
        supabase.from('v_purchase_list').select('*').eq('purchase_id', revising).single(),
        supabase.from('purchase_line').select('*').eq('purchase_id', revising).order('line_no'),
      ])
      if (!alive) return
      if (h.error) { setError(friendlyMessage(h.error)); return }

      const head = h.data as {
        supplier_id: string
        purchase_date: string
        supplier_bill_no: string | null
        supplier_bill_date: string | null
        other_charges: number
        bill_discount_amount: number
        remarks: string | null
        status: string
        doc_no: string
      }

      if (head.status !== 'ACTIVE') {
        setError(`${head.doc_no} is already cancelled, so it cannot be corrected.`)
        return
      }

      setSupplier(suppliers.find((x) => x.id === head.supplier_id) ?? null)
      setDate(head.purchase_date)
      setBillNo(head.supplier_bill_no ?? '')
      setBillDate(head.supplier_bill_date ?? '')
      setOther(Number(head.other_charges) ? String(Number(head.other_charges)) : '')
      setRemarks(head.remarks ?? '')
      setDiscMode('AMOUNT')
      setBillDisc(
        Number(head.bill_discount_amount) ? String(Number(head.bill_discount_amount)) : '',
      )

      const rows = (l.data ?? []) as unknown as {
        id: string
        product_id: string
        uom: 'BASE' | 'PACK'
        qty: number
        rate: number
        line_discount_pct: number | null
      }[]

      setLines(
        rows
          .map((r) => {
            const prod = products.find((x) => x.id === r.product_id)
            if (!prod) return null
            return {
              key: `${r.id}`,
              product: prod,
              uom: r.uom,
              qty: String(Number(r.qty)),
              rate: String(Number(r.rate)),
              discPct: r.line_discount_pct ? String(Number(r.line_discount_pct)) : '',
            }
          })
          .filter(Boolean) as Line[],
      )
    })()
    return () => { alive = false }
  }, [revising, products, suppliers])

  // The master group of the purchase, decided by whatever went on it first.
  const master = lines[0]?.product.master_code ?? null
  const masterName = lines[0]?.product.master_name ?? null

  const offerable = useMemo(() => {
    if (!products) return []
    const used = new Set(lines.map((l) => l.product.id))
    return products.filter(
      (p) => !used.has(p.id) && (master === null || p.master_code === master),
    )
  }, [products, lines, master])

  const addProduct = (p: ProductRow) => {
    const byPack = p.pack_uom !== null && p.pack_size > 1
    const key = `${p.id}-${Date.now()}`
    setLines((ls) => [
      ...ls,
      {
        key,
        product: p,
        uom: byPack ? 'PACK' : 'BASE',
        qty: '',
        rate: String(
          byPack ? (p.pack_purchase_rate ?? p.purchase_rate * p.pack_size) : p.purchase_rate,
        ),
        discPct: '',
      },
    ])
    setPickProduct(false)
    focusLine(key)
  }

  const patch = (key: string, p: Partial<Line>) =>
    setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...p } : l)))

  const drop = (key: string) => setLines((ls) => ls.filter((l) => l.key !== key))

  /** What the line comes to before any discount — what the supplier's bill says. */
  const grossOf = (l: Line) => {
    const q = num(l.qty, 0)
    const r = num(l.rate, 0)
    if (Number.isNaN(q) || Number.isNaN(r)) return 0
    return money2(q * r)
  }

  /** Rounded the way the database rounds it, so the two cannot disagree. */
  const discountOf = (l: Line) => {
    const pct = num(l.discPct, 0)
    if (Number.isNaN(pct) || pct <= 0) return 0
    return money2((grossOf(l) * pct) / 100)
  }

  const netOf = (l: Line) => money2(grossOf(l) - discountOf(l))

  const gross = lines.reduce((s, l) => s + grossOf(l), 0)
  const lineDisc = lines.reduce((s, l) => s + discountOf(l), 0)
  const afterLines = money2(gross - lineDisc)

  // An amount is taken as typed; a percentage is of the goods after the line
  // discounts, which is the base the database uses too.
  const billDiscValue = useMemo(() => {
    const v = num(billDisc, 0)
    if (Number.isNaN(v) || v <= 0) return 0
    return discMode === 'AMOUNT' ? money2(v) : money2((afterLines * v) / 100)
  }, [billDisc, discMode, afterLines])

  const otherCharges = Number.isNaN(num(other, 0)) ? 0 : money2(num(other, 0))

  // Goods, less the discounts, then charges on top.
  const net = money2(afterLines - billDiscValue + otherCharges)

  const save = useCallback(async () => {
    setError(null)

    if (!supplier) {
      setError('Choose the supplier this came from.')
      return
    }
    if (lines.length === 0) {
      setError('Add at least one product.')
      return
    }
    for (const l of lines) {
      const q = num(l.qty, 0)
      const r = num(l.rate, 0)
      if (Number.isNaN(q) || q <= 0) {
        setError(`${l.product.name}: quantity must be a number above zero.`)
        return
      }
      if (Number.isNaN(r) || r < 0) {
        setError(`${l.product.name}: rate must be a plain number — no commas.`)
        return
      }
      const d = num(l.discPct, 0)
      if (l.discPct.trim() !== '' && (Number.isNaN(d) || d < 0 || d > 100)) {
        setError(`${l.product.name}: a discount has to be between 0 and 100 per cent.`)
        return
      }
    }

    if (billDiscValue > afterLines) {
      setError(
        `The bill discount of ${fmtMoney(billDiscValue)} is more than the ` +
          `${fmtMoney(afterLines)} of goods on this purchase.`,
      )
      return
    }

    setBusy(true)
    // One shape of arguments for both calls: a correction is the same entry
    // plus the document it replaces, and the database does the cancelling.
    const args = {
      p_supplier_id: supplier.id,
      p_purchase_date: date,
      p_lines: lines.map((l) => ({
        product_id: l.product.id,
        uom: l.uom,
        qty: num(l.qty, 0),
        // Four places, because that is what the rate column holds. See
        // lib/precision.ts and migration 040.
        rate: rate4(num(l.rate, 0)),
        // The percentage travels, not the rupees — an amount agreed on this
        // quantity would be wrong if the quantity were ever changed.
        line_discount_pct: l.discPct.trim() === '' ? null : num(l.discPct, 0),
      })),
      p_other_charges: otherCharges,
      p_supplier_bill_no: billNo.trim() || null,
      p_supplier_bill_date: billDate || null,
      p_remarks: remarks.trim() || null,
      p_bill_discount_amount: discMode === 'AMOUNT' ? num(billDisc, 0) || 0 : 0,
      p_bill_discount_pct: discMode === 'PCT' ? num(billDisc, 0) || null : null,
    }

    const { data, error } = revising
      ? await supabase.rpc('revise_purchase', { p_purchase_id: revising, ...args })
      : await supabase.rpc('post_purchase', args)
    setBusy(false)

    if (error) {
      const de = asDbError(error)
      let msg = de.message ?? friendlyMessage(error)
      // SA001 carries the shortfall as JSON. "Some of what this purchase
      // brought in has already gone out" is true but not actionable on its
      // own; which product, and how much, is.
      try {
        const short = JSON.parse(String(de.details ?? '[]')) as {
          product: string
          taking_back: number
          in_stock: number
        }[]
        if (short.length > 0) {
          msg +=
            ' ' +
            short
              .map((x) => `${x.product}: ${x.taking_back} went in, only ${x.in_stock} left.`)
              .join(' ')
        }
      } catch {
        /* no detail to add */
      }
      setError(msg)
      return
    }

    const r = data as { purchase_id: string; doc_no: string }
    nav(`/purchases/${r.purchase_id}`, { state: { justCreated: r.doc_no } })
    // Every piece of state this reads has to be named here, or the save sends
    // a stale copy of it — bug #12, which once would have saved every cash
    // bill as credit.
  }, [supplier, date, lines, otherCharges, billNo, billDate, remarks, nav,
      billDisc, discMode, billDiscValue, afterLines, revising])

  if (suppliers === null || products === null) return <Loading what="Loading" />

  return (
    <>
      <div className="page-head">
        <h1>{revising ? 'Correct purchase' : 'New purchase'}</h1>
        <span className="sub">
          {revising
            ? 'The original is cancelled and this is entered in its place'
            : 'Goods in from a supplier'}
        </span>
        <span style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
          <button onClick={() => nav('/purchases')}>Cancel</button>
          <button className="primary" onClick={() => void save()} disabled={busy}>
            {busy ? <Spinner /> : revising ? 'Save correction' : 'Save purchase'}
          </button>
        </span>
      </div>

      <ErrorBanner error={error} />

      {revising && (
        <Banner tone="warn">
          Saving this cancels the original purchase and enters this one in its
          place. It is refused if any of what the original brought in has
          already been sold. Changing a rate also changes the average cost from
          this purchase&rsquo;s date onward, and so the margin on everything
          sold after it — which is right if the rate was keyed wrong.
        </Banner>
      )}

      {suppliers.length === 0 && (
        <Banner tone="warn">
          There are no suppliers yet.{' '}
          <button className="ghost" onClick={() => nav('/suppliers')}>
            Add one
          </button>{' '}
          and come back.
        </Banner>
      )}

      <div className="card card-pad">
        <div className="form-row">
          <div style={{ flex: '2 1 240px' }}>
            <label className="sr-only" htmlFor="pu-supplier">Supplier</label>
            <button
              id="pu-supplier"
              className="block"
              style={{ textAlign: 'left' }}
              onClick={() => setPickSupplier(true)}
              disabled={busy}
            >
              {supplier ? `${supplier.name} · ${supplier.code}` : 'Choose supplier…'}
            </button>
          </div>
          <label className="inline-field">
            <span>Date</span>
            <DateInput value={date} onChange={setDate} />
          </label>
          <label className="inline-field">
            <span>Their bill no.</span>
            <input
              type="text"
              value={billNo}
              placeholder="optional"
              onChange={(e) => setBillNo(e.target.value)}
              style={{ width: 140 }}
            />
          </label>
          <label className="inline-field">
            <span>Their bill date</span>
            <DateInput value={billDate} onChange={setBillDate} />
          </label>
        </div>

        {master && (
          <p className="hint" style={{ marginTop: 10 }}>
            This is a <strong>{masterName}</strong> purchase. A purchase carries one
            master group, so only {masterName} products are offered below. Buying
            both means two purchases.
          </p>
        )}
      </div>

      <div className="card table-wrap" style={{ marginTop: 12 }}>
        <table className="data">
          <thead>
            <tr>
              <th>Product</th>
              <th style={{ width: 110 }}>Unit</th>
              <th className="num" style={{ width: 110 }}>Qty</th>
              <th className="num" style={{ width: 130 }}>Rate</th>
              <th className="num" style={{ width: 90 }}>Disc %</th>
              <th className="num" style={{ width: 130 }}>Amount</th>
              <th style={{ width: 44 }}></th>
            </tr>
          </thead>
          <tbody>
            {lines.map((l) => (
              <tr key={l.key}>
                <td className="primary-cell">
                  <span className="strong">{l.product.name}</span>
                  <br />
                  <span className="muted" style={{ fontSize: 12.5 }}>
                    {l.product.group_name}
                  </span>
                </td>
                <td data-label="Unit">
                  {l.product.pack_uom && l.product.pack_size > 1 ? (
                    <select
                      data-unit-for={l.key}
                      aria-label={`Unit for ${l.product.name}`}
                      value={l.uom}
                      onChange={(e) => {
                        const uom = e.target.value as 'BASE' | 'PACK'
                        patch(l.key, {
                          uom,
                          rate: String(
                            uom === 'PACK'
                              ? (l.product.pack_purchase_rate ??
                                 l.product.purchase_rate * l.product.pack_size)
                              : l.product.purchase_rate,
                          ),
                        })
                      }}
                    >
                      <option value="PACK">{l.product.pack_uom}</option>
                      <option value="BASE">{l.product.base_uom}</option>
                    </select>
                  ) : (
                    <span className="muted">{l.product.base_uom}</span>
                  )}
                </td>
                <td data-label="Qty" className="num">
                  <input
                    type="text"
                    inputMode="decimal"
                    data-qty-for={l.key}
                    aria-label={`Quantity of ${l.product.name}`}
                    value={l.qty}
                    onChange={(e) => patch(l.key, { qty: e.target.value })}
                    onKeyDown={(e) => {
                      // Enter asks for the next product, which closes the
                      // loop: pick, type the quantity, Enter, pick again.
                      if (e.key === 'Enter') {
                        e.preventDefault()
                        setPickProduct(true)
                      }
                    }}
                    style={{ textAlign: 'right' }}
                  />
                </td>
                <td data-label="Rate" className="num">
                  <input
                    type="text"
                    inputMode="decimal"
                    aria-label={`Rate for ${l.product.name}`}
                    value={l.rate}
                    onChange={(e) => patch(l.key, { rate: e.target.value })}
                    style={{ textAlign: 'right' }}
                  />
                </td>
                <td data-label="Disc %" className="num">
                  <input
                    type="text"
                    inputMode="decimal"
                    aria-label={`Discount per cent on ${l.product.name}`}
                    value={l.discPct}
                    placeholder="0"
                    onChange={(e) => patch(l.key, { discPct: e.target.value })}
                    style={{ textAlign: 'right' }}
                  />
                </td>
                <td data-label="Amount" className="num strong">
                  {fmtMoney(netOf(l))}
                  {discountOf(l) > 0 && (
                    <>
                      <br />
                      <span className="muted" style={{ fontSize: 12.5 }}>
                        was {fmtMoney(grossOf(l))}
                      </span>
                    </>
                  )}
                </td>
                <td className="num">
                  <button className="ghost" onClick={() => drop(l.key)} aria-label="Remove">
                    ✕
                  </button>
                </td>
              </tr>
            ))}
            {lines.length === 0 && (
              <tr>
                <td colSpan={7} className="muted" style={{ textAlign: 'center', padding: 20 }}>
                  No products yet.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <div className="card card-pad" style={{ marginTop: 12 }}>
        <button id="pu-add-item" onClick={() => setPickProduct(true)} disabled={busy}>
          Add product
        </button>

        <div className="form-row" style={{ marginTop: 14 }}>
          <label className="inline-field">
            <span>Discount on the whole bill</span>
            <span style={{ display: 'flex', gap: 6 }}>
              <input
                type="text"
                inputMode="decimal"
                aria-label="Discount on the whole bill"
                value={billDisc}
                placeholder="0"
                onChange={(e) => setBillDisc(e.target.value)}
                style={{ width: 100, textAlign: 'right' }}
              />
              <select
                aria-label="Discount in rupees or per cent"
                value={discMode}
                onChange={(e) => setDiscMode(e.target.value as 'AMOUNT' | 'PCT')}
              >
                <option value="AMOUNT">Rs</option>
                <option value="PCT">%</option>
              </select>
            </span>
          </label>
          <label className="inline-field">
            <span>Other charges</span>
            <input
              type="text"
              inputMode="decimal"
              value={other}
              placeholder="0"
              onChange={(e) => setOther(e.target.value)}
              style={{ width: 120, textAlign: 'right' }}
            />
          </label>
          <label className="inline-field grow">
            <span>Remarks</span>
            <input
              type="text"
              value={remarks}
              placeholder="optional"
              onChange={(e) => setRemarks(e.target.value)}
            />
          </label>
        </div>

        <p className="hint" style={{ marginTop: 10 }}>
          A discount comes off the goods and is spread across the lines, so each
          product&rsquo;s recorded cost drops with it &mdash; a carton bought at
          1,900 with 5% off is costed at 1,805.
        </p>

        <p className="hint" style={{ marginTop: 6 }}>
          Freight, loading and the like go in Other charges. They are added
          <em> after</em> the discount, and are not spread across the products,
          so they do not change any product&rsquo;s cost.
        </p>

        <div className="tiles" style={{ marginTop: 14 }}>
          <div className="tile">
            <h3>Goods</h3>
            <div className="stat">{fmtMoney(gross)}</div>
            <p>{lines.length} line{lines.length === 1 ? '' : 's'}</p>
          </div>
          <div className="tile">
            <h3>Discount</h3>
            <div className="stat">
              {lineDisc + billDiscValue > 0 ? '− ' : ''}
              {fmtMoney(lineDisc + billDiscValue)}
            </div>
            <p>
              {lineDisc > 0 && billDiscValue > 0
                ? `${fmtMoney(lineDisc)} on lines, ${fmtMoney(billDiscValue)} on the bill`
                : lineDisc > 0
                  ? 'on the lines'
                  : billDiscValue > 0
                    ? 'on the whole bill'
                    : '\u00a0'}
            </p>
          </div>
          <div className="tile">
            <h3>Other charges</h3>
            <div className="stat">{fmtMoney(otherCharges)}</div>
            <p>&nbsp;</p>
          </div>
          <div className="tile">
            <h3>Total</h3>
            <div className="stat">{fmtMoney(net)}</div>
            <p>what the supplier is owed</p>
          </div>
        </div>
      </div>

      {pickSupplier && (
        <Picker<Supplier>
          title="Choose supplier"
          placeholder="Search by name or code"
          items={suppliers}
          keyOf={(s) => s.id}
          searchOf={(s) => `${s.name} ${s.code} ${s.city ?? ''}`}
          render={(s) => (
            <>
              <span className="strong">{s.name}</span>
              <br />
              <span className="muted" style={{ fontSize: 12.5 }}>
                {s.code}
                {s.city ? ` · ${s.city}` : ''}
              </span>
            </>
          )}
          onPick={(s) => {
            setSupplier(s)
            setPickSupplier(false)
            // Straight on to the goods, rather than Tab falling through to
            // whatever the browser thinks is next.
            focusById('pu-add-item')
          }}
          onClose={() => setPickSupplier(false)}
          emptyText="No suppliers match."
        />
      )}

      {pickProduct && (
        <Picker<ProductRow>
          title={master ? `Choose ${masterName} product` : 'Choose product'}
          placeholder="Search by name or code"
          items={offerable}
          keyOf={(p) => p.id}
          searchOf={(p) => `${p.name} ${p.code} ${p.group_name} ${p.master_name}`}
          render={(p) => (
            <>
              <span className="strong">{p.name}</span>
              <br />
              <span className="muted" style={{ fontSize: 12.5 }}>
                {p.code} · {p.group_name} · {p.master_name}
              </span>
            </>
          )}
          onPick={addProduct}
          onClose={() => setPickProduct(false)}
          emptyText={
            master
              ? `No more ${masterName} products. A purchase carries one master group.`
              : 'No products match.'
          }
        />
      )}
    </>
  )
}
