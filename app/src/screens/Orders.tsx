import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, useLocation } from 'react-router-dom'
import { supabase, friendlyMessage } from '../lib/supabase'
import { fmtDate, fmtMoney, fmtQty } from '../lib/format'
import { Banner, Empty, ErrorBanner, Loading, Spinner } from '../components/ui'
import { useSession } from '../lib/session'

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
  const location = useLocation()
  const justCreated = (location.state as { justCreated?: string } | null)?.justCreated

  const [rows, setRows] = useState<OrderRow[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [q, setQ] = useState('')

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

  if (rows === null) return <Loading what="Loading orders" />

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
          </div>

          <div className="card table-wrap">
            <table className="data">
              <thead>
                <tr>
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
                  <tr key={r.order_id}>
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
                      <button
                        className="ghost"
                        onClick={() => void cancel(r)}
                        disabled={busyId === r.order_id || !can('REP', 'ACCOUNTS', 'ADMIN')}
                      >
                        {busyId === r.order_id ? <Spinner /> : 'Cancel'}
                      </button>
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
