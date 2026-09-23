import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, useLocation, useNavigate } from 'react-router-dom'
import { supabase, asDbError, friendlyMessage } from '../lib/supabase'
import { fmtDate, fmtMoney, fmtQty } from '../lib/format'
import { Banner, Empty, ErrorBanner, Loading, Spinner } from '../components/ui'
import { useSession } from '../lib/session'
import { fetchOrderLines, pendingAsLine } from '../lib/billing'

interface OrderRow {
  order_id: string
  doc_no: string
  order_date: string
  status: string
  expires_at: string | null
  party_code: string
  party_name: string
  route_name: string
  rep_name: string | null
  lines: number
  qty_pending_base: number
  order_value: number
  expiring_soon: boolean
}

interface BillResult {
  order: string
  party: string
  ok: boolean
  docNo?: string
  invoiceId?: string
  why?: string
}

const LABEL: Record<string, string> = {
  SUBMITTED: 'Awaiting invoice',
  PARTIALLY_INVOICED: 'Part invoiced',
  INVOICED: 'Invoiced',
  CANCELLED: 'Cancelled',
  EXPIRED: 'Expired',
  DRAFT: 'Draft',
}

export default function Orders() {
  const { can } = useSession()
  const nav = useNavigate()
  const location = useLocation()
  const justCreated = (location.state as { justCreated?: string } | null)?.justCreated
  const canBill = can('ACCOUNTS', 'ADMIN')

  const [rows, setRows] = useState<OrderRow[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [q, setQ] = useState('')

  const [picked, setPicked] = useState<Set<string>>(new Set())
  const [billing, setBilling] = useState<{ done: number; total: number } | null>(null)
  const [results, setResults] = useState<BillResult[] | null>(null)

  const load = useCallback(async () => {
    setError(null)
    const { data, error } = await supabase
      .from('v_pending_orders')
      .select('*')
      .order('order_date', { ascending: false })

    if (error) {
      setError(friendlyMessage(error))
      setRows([])
      return
    }
    setRows((data ?? []) as OrderRow[])
  }, [])

  useEffect(() => { void load() }, [load])

  const cancel = useCallback(
    async (row: OrderRow) => {
      const reason = window.prompt(
        `Cancel ${row.doc_no} for ${row.party_name}?\n\nThe stock it is holding goes back into available. Say why:`,
      )
      if (reason === null) return
      if (!reason.trim()) {
        setError('A cancellation needs a reason.')
        return
      }

      setBusyId(row.order_id)
      const { error } = await supabase.rpc('cancel_sales_order', {
        p_order_id: row.order_id,
        p_reason: reason.trim(),
      })
      setBusyId(null)

      if (error) setError(friendlyMessage(error))
      else await load()
    },
    [load],
  )

  const filtered = useMemo(() => {
    if (!rows) return []
    const needle = q.trim().toLowerCase()
    if (!needle) return rows
    return rows.filter((r) =>
      `${r.doc_no} ${r.party_name} ${r.party_code} ${r.route_name}`.toLowerCase().includes(needle),
    )
  }, [rows, q])

  const totalValue = useMemo(
    () => filtered.reduce((s, r) => s + Number(r.order_value), 0),
    [filtered],
  )

  const toggle = (id: string) =>
    setPicked((s) => {
      const next = new Set(s)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })

  const allShownPicked = filtered.length > 0 && filtered.every((r) => picked.has(r.order_id))

  /**
   * Bill every ticked order, each as its own bill, at whatever the order still
   * has pending and the rates on the order.
   *
   * Deliberately one call per order rather than one big one: each bill is its
   * own transaction, so an order that runs short of stock is refused on its
   * own and the rest still go through. The report afterwards says which.
   */
  const billPicked = useCallback(async () => {
    const orders = filtered.filter((r) => picked.has(r.order_id))
    if (orders.length === 0) return

    setError(null)
    setResults(null)
    setBilling({ done: 0, total: orders.length })

    const out: BillResult[] = []
    const date = new Date().toISOString().slice(0, 10)

    for (const o of orders) {
      try {
        const lines = (await fetchOrderLines(o.order_id))
          .map(pendingAsLine)
          .filter((l): l is NonNullable<typeof l> => l !== null)

        if (lines.length === 0) {
          out.push({ order: o.doc_no, party: o.party_name, ok: false, why: 'Nothing left to bill' })
        } else {
          const { data, error } = await supabase.rpc('create_sales_invoice', {
            p_invoice_date: date,
            p_lines: lines,
            p_order_id: o.order_id,
            p_party_id: null,
            p_bill_discount_amount: 0,
            p_bill_discount_pct: null,
            p_remarks: null,
          })
          if (error) {
            const de = asDbError(error)
            const short = Array.isArray(de.details)
              ? (de.details as { product_name: string }[]).map((d) => d.product_name).join(', ')
              : null
            out.push({
              order: o.doc_no,
              party: o.party_name,
              ok: false,
              why: short ? `Not enough stock: ${short}` : friendlyMessage(error),
            })
          } else {
            const res = data as { invoice_id: string; doc_no: string }
            out.push({
              order: o.doc_no,
              party: o.party_name,
              ok: true,
              docNo: res.doc_no,
              invoiceId: res.invoice_id,
            })
          }
        }
      } catch (e) {
        out.push({ order: o.doc_no, party: o.party_name, ok: false, why: friendlyMessage(e) })
      }
      setBilling((b) => (b ? { ...b, done: b.done + 1 } : b))
    }

    setBilling(null)
    setResults(out)
    setPicked(new Set())
    await load()
  }, [filtered, picked, load])

  if (rows === null) return <Loading what="Loading orders" />

  const billed = results?.filter((r) => r.ok) ?? []
  const refused = results?.filter((r) => !r.ok) ?? []

  return (
    <>
      <div className="page-head">
        <h1>Orders</h1>
        <span className="sub">Holding stock, waiting to be invoiced</span>
        <span style={{ marginLeft: 'auto' }}>
          <Link to="/orders/new">
            <button className="primary">New order</button>
          </Link>
        </span>
      </div>

      {justCreated && (
        <Banner tone="info">
          Order <strong>{justCreated}</strong> submitted. The stock on it is now
          reserved.
        </Banner>
      )}

      <ErrorBanner error={error} />

      {results && (
        <Banner tone={refused.length === 0 ? 'info' : 'warn'}>
          <strong>
            {billed.length} bill{billed.length === 1 ? '' : 's'} raised
            {refused.length > 0 && `, ${refused.length} refused`}.
          </strong>
          {billed.length > 0 && (
            <div style={{ marginTop: 6 }}>
              {billed.map((r) => `${r.docNo} (${r.party})`).join(', ')}
            </div>
          )}
          {refused.length > 0 && (
            <ul style={{ margin: '8px 0 0 18px' }}>
              {refused.map((r) => (
                <li key={r.order}>
                  {r.order} · {r.party} — {r.why}
                </li>
              ))}
            </ul>
          )}
          <div style={{ display: 'flex', gap: 8, marginTop: 10 }}>
            {billed.length > 0 && (
              <button
                className="primary"
                onClick={() =>
                  nav(`/invoices/print?ids=${billed.map((r) => r.invoiceId).join(',')}`)
                }
              >
                Print {billed.length === 1 ? 'the bill' : `all ${billed.length} bills`}
              </button>
            )}
            <button onClick={() => setResults(null)}>Dismiss</button>
          </div>
        </Banner>
      )}

      {rows.length === 0 ? (
        <Empty title="No orders waiting">
          Orders appear here from the moment they are submitted until they have
          been fully invoiced.
        </Empty>
      ) : (
        <>
          <div className="toolbar">
            <span className="grow">
              <label className="sr-only" htmlFor="oq">Search orders</label>
              <input
                id="oq"
                type="search"
                placeholder="Search by order number, customer or route"
                value={q}
                onChange={(e) => setQ(e.target.value)}
              />
            </span>
            {canBill && picked.size > 0 && (
              <button className="primary" onClick={() => void billPicked()} disabled={!!billing}>
                {billing ? (
                  <>
                    <Spinner /> {billing.done} of {billing.total}
                  </>
                ) : (
                  `Bill ${picked.size} order${picked.size === 1 ? '' : 's'}`
                )}
              </button>
            )}
          </div>

          {canBill && picked.size > 0 && !billing && (
            <Banner tone="info">
              Each ticked order becomes its own bill, for everything it still has
              pending, at the rates on the order. To change a quantity or give a
              discount, use <strong>Make bill</strong> on that order instead.
            </Banner>
          )}

          <div className="card table-wrap">
            <table className="data">
              <thead>
                <tr>
                  {canBill && (
                    <th style={{ width: 34 }}>
                      <input
                        type="checkbox"
                        aria-label="Select all orders shown"
                        checked={allShownPicked}
                        onChange={(e) =>
                          setPicked(
                            e.target.checked
                              ? new Set(filtered.map((r) => r.order_id))
                              : new Set(),
                          )
                        }
                      />
                    </th>
                  )}
                  <th>Order</th>
                  <th>Customer</th>
                  <th>Status</th>
                  <th className="num">Lines</th>
                  <th className="num">Value</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {filtered.map((r) => (
                  <tr key={r.order_id} className={picked.has(r.order_id) ? 'picked' : undefined}>
                    {canBill && (
                      <td data-label="Bill">
                        <input
                          type="checkbox"
                          aria-label={`Select ${r.doc_no}`}
                          checked={picked.has(r.order_id)}
                          onChange={() => toggle(r.order_id)}
                        />
                      </td>
                    )}
                    <td className="primary-cell">
                      <span className="strong">{r.doc_no}</span>
                      <br />
                      <span className="muted" style={{ fontSize: 12.5 }}>
                        {fmtDate(r.order_date)}
                        {r.rep_name && ` · ${r.rep_name}`}
                      </span>
                    </td>
                    <td data-label="Customer">
                      {r.party_name}
                      <br />
                      <span className="muted" style={{ fontSize: 12.5 }}>
                        {r.party_code} · {r.route_name}
                      </span>
                    </td>
                    <td data-label="Status">
                      <span
                        className={`pill ${
                          r.status === 'PARTIALLY_INVOICED' ? 'warn' : 'flat'
                        }`}
                      >
                        {LABEL[r.status] ?? r.status}
                      </span>
                      {r.expiring_soon && (
                        <>
                          <br />
                          <span className="pill bad" style={{ marginTop: 4 }}>
                            Reservation expiring
                          </span>
                        </>
                      )}
                    </td>
                    <td data-label="Lines" className="num">
                      {r.lines}
                      <br />
                      <span className="muted" style={{ fontSize: 12 }}>
                        {fmtQty(r.qty_pending_base)} pending
                      </span>
                    </td>
                    <td data-label="Value" className="num strong">
                      {fmtMoney(r.order_value)}
                    </td>
                    <td data-label="" className="num">
                      <span style={{ display: 'flex', gap: 6, justifyContent: 'flex-end' }}>
                        {canBill && (
                          <Link to={`/invoices/new?order=${r.order_id}`}>
                            <button className="primary">Make bill</button>
                          </Link>
                        )}
                        <button
                          className="ghost"
                          onClick={() => void cancel(r)}
                          disabled={busyId === r.order_id || !can('REP', 'ACCOUNTS', 'ADMIN')}
                        >
                          {busyId === r.order_id ? <Spinner /> : 'Cancel'}
                        </button>
                      </span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <p className="sub" style={{ marginTop: 12 }}>
            {filtered.length} order{filtered.length === 1 ? '' : 's'} ·{' '}
            {fmtMoney(totalValue)} of stock held
          </p>
        </>
      )}
    </>
  )
}
