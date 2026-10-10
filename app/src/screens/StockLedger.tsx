import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { supabase, friendlyMessage } from '../lib/supabase'
import { fmtDate, fmtQty } from '../lib/format'
import { Report } from '../components/Report'
import type { ReportColumn } from '../components/Report'
import { DateRange, useDateRange } from '../components/DateRange'
import { Picker } from '../components/Picker'

/**
 * Where a product's stock went.
 *
 * Every movement has been recorded since the first day and there has never
 * been a way to look at it, so "the figure is wrong" has had no answer beyond
 * recounting the shelf. This is the answer: opening, every purchase, every
 * sale, every return and adjustment, in order, with a running balance that
 * ends at what the stock screen says is on hand.
 *
 * Deliberately one product at a time. A ledger of everything is a list with no
 * running balance worth reading — the balance only means something within a
 * product — and nobody asks "what moved" without already having a product in
 * mind.
 */

interface Row {
  id: string
  product_id: string
  product_code: string
  product_name: string
  base_uom: string
  group_name: string
  master_name: string | null
  movement_date: string
  doc_type: string
  doc_id: string | null
  qty_in: number
  qty_out: number
  rate: number
  notes: string | null
  entered_by: string | null
  balance_after: number
}

interface ProductRow {
  product_id: string
  product_code: string
  product_name: string
  group_name: string
  base_uom: string
  on_hand: number
}

/**
 * Where a movement came from.
 *
 * A ledger line that cannot be opened is a dead end: you can see that eighty
 * pieces went out on the 12th and have no way to find out to whom without
 * going to the Bills screen and hunting by date.
 *
 * Only the three that have a screen of their own are links. A cancellation's
 * doc_id points at the cancellation record rather than the bill it undid, and
 * an opening or an adjustment has nowhere to go — those stay plain text
 * rather than becoming links that lead nowhere.
 */
const LINK_TO: Record<string, (id: string) => string> = {
  SALE: (id) => `/invoices/${id}`,
  PURCHASE: (id) => `/purchases/${id}`,
  SALE_RETURN: (id) => `/returns/${id}`,
}

const LABEL: Record<string, string> = {
  OPENING: 'Opening',
  PURCHASE: 'Purchase',
  SALE: 'Sale',
  SALE_RETURN: 'Sales return',
  PURCHASE_RETURN: 'Purchase return',
  ADJUSTMENT: 'Adjustment',
  CANCELLATION: 'Cancellation',
}

export default function StockLedger() {
  const [params, setParams] = useSearchParams()
  const { from, to, setFrom, setTo, presets } = useDateRange('month')

  const [products, setProducts] = useState<ProductRow[] | null>(null)
  const [productId, setProductId] = useState(params.get('product') ?? '')

  /**
   * Remember the product in the address, keeping whatever else is there.
   *
   * setParams({ product }) would replace the whole query string, which on this
   * screen means silently throwing away the date range the person had chosen
   * a moment earlier.
   */
  const pickProduct = useCallback((id: string) => {
    setParams((prev) => {
      const next = new URLSearchParams(prev)
      next.set('product', id)
      return next
    }, { replace: true })
  }, [setParams])
  const [rows, setRows] = useState<Row[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [picking, setPicking] = useState(false)

  useEffect(() => {
    let alive = true
    void (async () => {
      const { data } = await supabase
        .from('v_stock_report')
        .select('product_id, product_code, product_name, group_name, base_uom, on_hand')
        .eq('is_active', true)
        .order('product_name')
      if (alive) setProducts((data ?? []) as ProductRow[])
    })()
    return () => { alive = false }
  }, [])

  const load = useCallback(async () => {
    if (!productId) {
      setRows(null)
      return
    }
    setError(null)
    setRows(null)

    // Every movement for this product, in the order the balance was computed.
    // The date window filters what is SHOWN, not what the balance is built
    // from — a ledger whose opening balance silently excluded last month
    // would be a lie with a number on it.
    const { data, error } = await supabase
      .from('v_stock_ledger')
      .select('*')
      .eq('product_id', productId)
      .order('movement_date')
      .order('created_at')
      .order('id')

    if (error) {
      setError(friendlyMessage(error))
      setRows([])
      return
    }
    setRows((data ?? []) as Row[])
  }, [productId])

  useEffect(() => { void load() }, [load])

  const product = useMemo(
    () => (products ?? []).find((p) => p.product_id === productId) ?? null,
    [products, productId],
  )

  const shown = useMemo(() => {
    if (!rows) return null
    return rows.filter(
      (r) => (!from || r.movement_date >= from) && (!to || r.movement_date <= to),
    )
  }, [rows, from, to])

  /**
   * What the balance was before the first row on screen.
   *
   * Without it a ledger filtered to one month opens at whatever that month's
   * first movement happened to be, and the arithmetic down the page cannot be
   * followed. With it, the page reads: this is where we started, here is what
   * happened, here is where we ended.
   */
  const opening = useMemo(() => {
    if (!rows || !shown || shown.length === 0) return null
    const firstShown = rows.findIndex((r) => r.id === shown[0].id)
    if (firstShown <= 0) return 0
    return Number(rows[firstShown - 1].balance_after)
  }, [rows, shown])

  const cols: ReportColumn<Row>[] = [
    {
      header: 'Date',
      value: (r) => r.movement_date,
      cell: (r) => fmtDate(r.movement_date),
      width: 14,
      mobile: 'title',
    },
    {
      header: 'What',
      value: (r) => LABEL[r.doc_type] ?? r.doc_type,
      width: 16,
      mobile: 'meta',
      cell: (r) => {
        const label = LABEL[r.doc_type] ?? r.doc_type
        const to = r.doc_id ? LINK_TO[r.doc_type]?.(r.doc_id) : undefined
        return to ? <Link to={to}>{label}</Link> : <>{label}</>
      },
    },
    { header: 'In', value: (r) => (Number(r.qty_in) > 0 ? Number(r.qty_in) : null),
      type: 'qty', align: 'right', mobile: 'meta' },
    { header: 'Out', value: (r) => (Number(r.qty_out) > 0 ? Number(r.qty_out) : null),
      type: 'qty', align: 'right', mobile: 'meta' },
    { header: 'Rate', value: (r) => Number(r.rate) || null, type: 'money', align: 'right',
      mobile: 'hide' },
    { header: 'Entered by', value: (r) => r.entered_by, width: 18, mobile: 'hide' },
    {
      header: 'Balance',
      value: (r) => Number(r.balance_after),
      type: 'qty',
      align: 'right',
      width: 14,
      mobile: 'lead',
      cell: (r) => <span className="strong">{fmtQty(r.balance_after)}</span>,
    },
  ]

  const filters = (
    <>
      <button onClick={() => setPicking(true)}>
        {product ? `${product.product_name}` : 'Choose a product'}
      </button>
      {product && <DateRange from={from} to={to} setFrom={setFrom} setTo={setTo} presets={presets} />}
    </>
  )

  if (!productId) {
    return (
      <>
        <div className="page-head">
          <h1>Stock ledger</h1>
          <span className="sub">Every movement of one product</span>
        </div>
        <div className="card card-pad">
          <p style={{ marginTop: 0, color: 'var(--ink-3)' }}>
            Choose a product to see everything that has gone in and out of it,
            with the balance after each movement.
          </p>
          <button className="primary" onClick={() => setPicking(true)}>
            Choose a product
          </button>
        </div>
        {picking && products && (
          <Picker<ProductRow>
            title="Choose a product"
            placeholder="Search by name, code or group"
            items={products}
            keyOf={(p) => p.product_id}
            searchOf={(p) => `${p.product_name} ${p.product_code} ${p.group_name}`}
            onPick={(p) => { setProductId(p.product_id); pickProduct(p.product_id) }}
            onClose={() => setPicking(false)}
            render={(p) => (
              <>
                <div className="strong">{p.product_name}</div>
                <div className="sub">
                  {p.product_code} · {p.group_name} · {fmtQty(p.on_hand)} {p.base_uom} on hand
                </div>
              </>
            )}
          />
        )}
      </>
    )
  }

  return (
    <>
      <Report<Row>
        title={product ? `Ledger — ${product.product_name}` : 'Stock ledger'}
        subtitle={
          product
            ? `${product.product_code} · ${fmtQty(product.on_hand)} ${product.base_uom} on hand today`
            : undefined
        }
        filters={filters}
        columns={cols}
        rows={shown}
        error={error}
        fileName={`stock-ledger-${product?.product_code ?? 'product'}`}
        empty="Nothing moved in this period."
        footer={
          shown && shown.length > 0 ? (
            <>
              opened at {fmtQty(opening ?? 0)} {product?.base_uom}
              {' · '}
              in {fmtQty(shown.reduce((s, r) => s + Number(r.qty_in || 0), 0))}
              {' · '}
              out {fmtQty(shown.reduce((s, r) => s + Number(r.qty_out || 0), 0))}
              {' · '}
              closed at{' '}
              <strong>{fmtQty(shown[shown.length - 1].balance_after)}</strong>
            </>
          ) : undefined
        }
      />

      {picking && products && (
        <Picker<ProductRow>
          title="Choose a product"
          placeholder="Search by name, code or group"
          items={products}
          keyOf={(p) => p.product_id}
          searchOf={(p) => `${p.product_name} ${p.product_code} ${p.group_name}`}
          onPick={(p) => { setProductId(p.product_id); pickProduct(p.product_id) }}
          onClose={() => setPicking(false)}
          render={(p) => (
            <>
              <div className="strong">{p.product_name}</div>
              <div className="sub">
                {p.product_code} · {p.group_name} · {fmtQty(p.on_hand)} {p.base_uom} on hand
              </div>
            </>
          )}
        />
      )}
    </>
  )
}
