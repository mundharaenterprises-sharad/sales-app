import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { supabase, friendlyMessage } from '../lib/supabase'
import { fmtDate, fmtMoney } from '../lib/format'
import { Empty, ErrorBanner, Loading } from '../components/ui'
import { Check } from '../components/FormSheet'
import { useSession } from '../lib/session'

interface InvoiceRow {
  invoice_id: string
  doc_no: string
  party_id: string
  party_code: string
  party_name: string
  route_name: string
  invoice_date: string
  net_total: number
  cancelled_value: number
  effective_total: number
  settled: number
  outstanding: number
  days_outstanding: number
  status: string
  order_no: string | null
  replaces_doc_no: string | null
  replaced_by_doc_no: string | null
  replaced_by_invoice_id: string | null
}

const LABEL: Record<string, string> = {
  ACTIVE: 'Active',
  PARTIALLY_CANCELLED: 'Part cancelled',
  CANCELLED: 'Cancelled',
}

export default function Invoices() {
  const { can } = useSession()
  const nav = useNavigate()
  const [rows, setRows] = useState<InvoiceRow[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [q, setQ] = useState('')
  const [unpaidOnly, setUnpaidOnly] = useState(false)
  const [route, setRoute] = useState('')
  const [from, setFrom] = useState('')
  const [to, setTo] = useState('')
  const [picked, setPicked] = useState<Set<string>>(new Set())
  const [showCancelled, setShowCancelled] = useState(true)

  const load = useCallback(async () => {
    setError(null)
    const { data, error } = await supabase
      .from('v_invoice_list')
      .select('*')
      .order('invoice_date', { ascending: false })
      .limit(500)

    if (error) {
      setError(friendlyMessage(error))
      setRows([])
      return
    }
    setRows((data ?? []) as InvoiceRow[])
  }, [])

  useEffect(() => {
    void load()
  }, [load])

  const routes = useMemo(
    () => (rows ? Array.from(new Set(rows.map((r) => r.route_name))).sort() : []),
    [rows],
  )

  const filtered = useMemo(() => {
    if (!rows) return []
    const needle = q.trim().toLowerCase()
    return rows.filter((r) => {
      if (!showCancelled && r.status === 'CANCELLED') return false
      if (unpaidOnly && Number(r.outstanding) <= 0) return false
      if (route && r.route_name !== route) return false
      // Dates are plain YYYY-MM-DD, so comparing them as text is comparing them
      // as dates, with no timezone to get wrong.
      if (from && r.invoice_date < from) return false
      if (to && r.invoice_date > to) return false
      if (!needle) return true
      return `${r.doc_no} ${r.party_name} ${r.party_code} ${r.route_name}`
        .toLowerCase()
        .includes(needle)
    })
  }, [rows, q, unpaidOnly, route, from, to, showCancelled])

  const toggle = (id: string) =>
    setPicked((s) => {
      const next = new Set(s)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })

  const printable = filtered.filter((r) => r.status !== 'CANCELLED')
  const allShownPicked =
    printable.length > 0 && printable.every((r) => picked.has(r.invoice_id))

  const printPicked = () => {
    const ids = filtered.filter((r) => picked.has(r.invoice_id)).map((r) => r.invoice_id)
    if (ids.length > 0) nav(`/invoices/print?ids=${ids.join(',')}`)
  }

  const today = () => new Date().toISOString().slice(0, 10)

  const totals = useMemo(
    () => ({
      billed: filtered.reduce((s, r) => s + Number(r.effective_total), 0),
      due: filtered.reduce((s, r) => s + Number(r.outstanding), 0),
    }),
    [filtered],
  )

  if (rows === null) return <Loading what="Loading bills" />

  return (
    <>
      <div className="page-head">
        <h1>Bills</h1>
        <span className="sub">Most recent first</span>
        {can('ACCOUNTS', 'ADMIN') && (
          <span style={{ marginLeft: 'auto' }}>
            <Link to="/invoices/new">
              <button className="primary">New bill</button>
            </Link>
          </span>
        )}
      </div>

      <ErrorBanner error={error} />

      {rows.length === 0 ? (
        <Empty title="No bills yet">
          {can('ACCOUNTS', 'ADMIN')
            ? 'Bill an order from the Orders screen, or raise a direct bill here.'
            : 'Bills raised by the office will appear here.'}
        </Empty>
      ) : (
        <>
          <div className="toolbar">
            <span className="grow">
              <label className="sr-only" htmlFor="iq">Search bills</label>
              <input
                id="iq"
                type="search"
            autoComplete="off"
                placeholder="Search by bill number, customer or route"
                value={q}
                onChange={(e) => setQ(e.target.value)}
              />
            </span>
            <select value={route} onChange={(e) => setRoute(e.target.value)} aria-label="Filter by route">
              <option value="">All routes</option>
              {routes.map((r) => (
                <option key={r} value={r}>{r}</option>
              ))}
            </select>
            <Check id="unpaid" checked={unpaidOnly} onChange={setUnpaidOnly}>
              Unpaid only
            </Check>
            <Check id="cancelled" checked={showCancelled} onChange={setShowCancelled}>
              Show cancelled
            </Check>
          </div>

          <div className="toolbar">
            <label className="inline-field">
              <span>From</span>
              <input type="date" value={from} onChange={(e) => setFrom(e.target.value)} />
            </label>
            <label className="inline-field">
              <span>To</span>
              <input type="date" value={to} onChange={(e) => setTo(e.target.value)} />
            </label>
            <button
              onClick={() => {
                setFrom(today())
                setTo(today())
              }}
            >
              Today
            </button>
            {(from || to || route || q || unpaidOnly || !showCancelled) && (
              <button
                className="ghost"
                onClick={() => {
                  setFrom('')
                  setTo('')
                  setRoute('')
                  setQ('')
                  setUnpaidOnly(false)
                  setShowCancelled(true)
                }}
              >
                Clear
              </button>
            )}
            <button
              className="primary"
              style={{ marginLeft: 'auto' }}
              onClick={printPicked}
              disabled={picked.size === 0}
            >
              {picked.size === 0
                ? 'Print selected'
                : `Print ${picked.size} bill${picked.size === 1 ? '' : 's'}`}
            </button>
          </div>

          <div className="card table-wrap">
            <table className="data">
              <thead>
                <tr>
                  <th style={{ width: 34 }}>
                    <input
                      type="checkbox"
                      aria-label="Select all bills shown"
                      checked={allShownPicked}
                      onChange={(e) =>
                        setPicked(
                          e.target.checked
                            ? new Set(
                                filtered
                                  .filter((r) => r.status !== 'CANCELLED')
                                  .map((r) => r.invoice_id),
                              )
                            : new Set(),
                        )
                      }
                    />
                  </th>
                  <th>Bill</th>
                  <th>Customer</th>
                  <th className="num">Amount</th>
                  <th className="num">Paid</th>
                  <th className="num">Due</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {filtered.map((r) => (
                  <tr
                    key={r.invoice_id}
                    className={
                      [
                        picked.has(r.invoice_id) ? 'picked' : '',
                        r.status === 'CANCELLED' ? 'inactive' : '',
                      ]
                        .filter(Boolean)
                        .join(' ') || undefined
                    }
                  >
                    <td data-label="Print">
                      <input
                        type="checkbox"
                        aria-label={`Select ${r.doc_no}`}
                        checked={picked.has(r.invoice_id)}
                        onChange={() => toggle(r.invoice_id)}
                      />
                    </td>
                    <td className="primary-cell">
                      <Link to={`/invoices/${r.invoice_id}`} className="strong">
                        {r.doc_no}
                      </Link>
                      <br />
                      <span className="muted" style={{ fontSize: 12.5 }}>
                        {fmtDate(r.invoice_date)}
                      </span>
                      {r.status !== 'ACTIVE' && (
                        <> <span className="pill bad">{LABEL[r.status] ?? r.status}</span></>
                      )}
                      {r.replaced_by_doc_no && (
                        <>
                          <br />
                          <span className="muted" style={{ fontSize: 12 }}>
                            corrected to{' '}
                            <Link to={`/invoices/${r.replaced_by_invoice_id}`}>
                              {r.replaced_by_doc_no}
                            </Link>
                          </span>
                        </>
                      )}
                      {r.replaces_doc_no && (
                        <>
                          <br />
                          <span className="muted" style={{ fontSize: 12 }}>
                            corrects {r.replaces_doc_no}
                          </span>
                        </>
                      )}
                    </td>
                    <td data-label="Customer">
                      {r.party_name}
                      <br />
                      <span className="muted" style={{ fontSize: 12.5 }}>
                        {r.party_code} · {r.route_name}
                      </span>
                    </td>
                    <td data-label="Amount" className="num">{fmtMoney(r.effective_total)}</td>
                    <td data-label="Paid" className="num muted">{fmtMoney(r.settled)}</td>
                    <td data-label="Due" className="num">
                      {Number(r.outstanding) > 0 ? (
                        <span className="strong">
                          {fmtMoney(r.outstanding)}
                          <br />
                          <span className="muted" style={{ fontSize: 12 }}>
                            {r.days_outstanding} days
                          </span>
                        </span>
                      ) : (
                        <span className="pill good">Settled</span>
                      )}
                    </td>
                    <td data-label="" className="num">
                      {can('ACCOUNTS', 'ADMIN') && Number(r.outstanding) > 0 && (
                        <Link
                          to={`/receipts/new?party=${r.party_id}&invoice=${r.invoice_id}`}
                        >
                          <button>Pay</button>
                        </Link>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <p className="sub" style={{ marginTop: 12 }}>
            {filtered.length} bill{filtered.length === 1 ? '' : 's'} ·{' '}
            {fmtMoney(totals.billed)} billed · {fmtMoney(totals.due)} outstanding
          </p>
        </>
      )}
    </>
  )
}
