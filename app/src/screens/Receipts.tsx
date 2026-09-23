import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, useLocation, useNavigate } from 'react-router-dom'
import { supabase, friendlyMessage } from '../lib/supabase'
import { fmtDate, fmtMoney } from '../lib/format'
import { Banner, Empty, ErrorBanner, Loading } from '../components/ui'
import { Check } from '../components/FormSheet'
import { useSession } from '../lib/session'

/**
 * Money received.
 *
 * A payment is recorded when it is actually in hand — there is no pending or
 * cleared state to track, deliberately. What matters afterwards is how much of
 * each payment has been put against bills, which is what the Unapplied column
 * shows.
 */

interface ReceiptRow {
  id: string
  doc_no: string
  receipt_date: string
  amount: number
  status: string
  remarks: string | null
  party: { code: string; name: string; route: { name: string } | null } | null
  collector: { full_name: string } | null
  /** Filled in from the unallocated-credit view. */
  unallocated: number
}

export default function Receipts() {
  const { can } = useSession()
  const nav = useNavigate()
  const justSaved = (useLocation().state as { justSaved?: string } | null)?.justSaved

  const [rows, setRows] = useState<ReceiptRow[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [q, setQ] = useState('')
  const [from, setFrom] = useState('')
  const [to, setTo] = useState('')
  const [unappliedOnly, setUnappliedOnly] = useState(false)

  const load = useCallback(async () => {
    setError(null)
    const [r, u] = await Promise.all([
      supabase
        .from('receipt')
        .select(
          'id, doc_no, receipt_date, amount, status, remarks,' +
            ' party:party_id (code, name, route:route_id (name)),' +
            ' collector:collected_by (full_name)',
        )
        .order('receipt_date', { ascending: false })
        .limit(500),
      supabase.from('v_unallocated_credit').select('credit_id, unallocated'),
    ])

    if (r.error) {
      setError(friendlyMessage(r.error))
      setRows([])
      return
    }

    const left = new Map<string, number>(
      ((u.data ?? []) as { credit_id: string; unallocated: number }[]).map((x) => [
        x.credit_id,
        Number(x.unallocated),
      ]),
    )

    setRows(
      ((r.data ?? []) as unknown as ReceiptRow[]).map((x) => ({
        ...x,
        unallocated: left.get(x.id) ?? 0,
      })),
    )
  }, [])

  useEffect(() => {
    void load()
  }, [load])

  const filtered = useMemo(() => {
    if (!rows) return []
    const needle = q.trim().toLowerCase()
    return rows.filter((r) => {
      if (unappliedOnly && (r.status !== 'ACTIVE' || r.unallocated <= 0)) return false
      if (from && r.receipt_date < from) return false
      if (to && r.receipt_date > to) return false
      if (!needle) return true
      return `${r.doc_no} ${r.party?.name ?? ''} ${r.party?.code ?? ''} ${r.party?.route?.name ?? ''}`
        .toLowerCase()
        .includes(needle)
    })
  }, [rows, q, from, to, unappliedOnly])

  const totals = useMemo(
    () => ({
      received: filtered
        .filter((r) => r.status === 'ACTIVE')
        .reduce((s, r) => s + Number(r.amount), 0),
      unapplied: filtered
        .filter((r) => r.status === 'ACTIVE')
        .reduce((s, r) => s + r.unallocated, 0),
    }),
    [filtered],
  )

  const today = () => new Date().toISOString().slice(0, 10)

  if (rows === null) return <Loading what="Loading payments" />

  return (
    <>
      <div className="page-head">
        <h1>Payments</h1>
        <span className="sub">Money received, newest first</span>
        {can('ACCOUNTS', 'ADMIN') && (
          <span style={{ marginLeft: 'auto' }}>
            <Link to="/receipts/new">
              <button className="primary">New payment</button>
            </Link>
          </span>
        )}
      </div>

      {justSaved && (
        <Banner tone="info">
          Payment <strong>{justSaved}</strong> recorded.
        </Banner>
      )}

      <ErrorBanner error={error} />

      {rows.length === 0 ? (
        <Empty title="No payments yet">
          {can('ACCOUNTS', 'ADMIN')
            ? 'Record a payment when money comes in, then put it against the bills it pays.'
            : 'Payments entered by the office will appear here.'}
        </Empty>
      ) : (
        <>
          <div className="toolbar">
            <span className="grow">
              <label className="sr-only" htmlFor="rq">Search payments</label>
              <input
                id="rq"
                type="search"
                placeholder="Search by number, customer or route"
                value={q}
                onChange={(e) => setQ(e.target.value)}
              />
            </span>
            <Check id="unapplied" checked={unappliedOnly} onChange={setUnappliedOnly}>
              Not yet applied
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
            <button onClick={() => { setFrom(today()); setTo(today()) }}>Today</button>
            {(from || to || q || unappliedOnly) && (
              <button
                className="ghost"
                onClick={() => { setFrom(''); setTo(''); setQ(''); setUnappliedOnly(false) }}
              >
                Clear
              </button>
            )}
          </div>

          <div className="card table-wrap">
            <table className="data">
              <thead>
                <tr>
                  <th>Payment</th>
                  <th>Customer</th>
                  <th>Collected by</th>
                  <th className="num">Amount</th>
                  <th className="num">Unapplied</th>
                </tr>
              </thead>
              <tbody>
                {filtered.map((r) => (
                  <tr
                    key={r.id}
                    className={`clickable${r.status === 'CANCELLED' ? ' inactive' : ''}`}
                    onClick={() => nav(`/receipts/${r.id}`)}
                  >
                    <td className="primary-cell">
                      <span className="strong">{r.doc_no}</span>
                      {r.status === 'CANCELLED' && (
                        <> <span className="pill bad">Cancelled</span></>
                      )}
                      <br />
                      <span className="muted" style={{ fontSize: 12.5 }}>
                        {fmtDate(r.receipt_date)}
                      </span>
                    </td>
                    <td data-label="Customer">
                      {r.party?.name ?? '—'}
                      <br />
                      <span className="muted" style={{ fontSize: 12.5 }}>
                        {r.party?.code}
                        {r.party?.route && ` · ${r.party.route.name}`}
                      </span>
                    </td>
                    <td data-label="Collected by" className="muted">
                      {r.collector?.full_name ?? '—'}
                    </td>
                    <td data-label="Amount" className="num strong">{fmtMoney(r.amount)}</td>
                    <td data-label="Unapplied" className="num">
                      {r.status !== 'ACTIVE' ? (
                        <span className="muted">—</span>
                      ) : r.unallocated > 0 ? (
                        <span className="pill warn">{fmtMoney(r.unallocated)}</span>
                      ) : (
                        <span className="pill good">Applied</span>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <p className="sub" style={{ marginTop: 12 }}>
            {filtered.length} payment{filtered.length === 1 ? '' : 's'} ·{' '}
            {fmtMoney(totals.received)} received · {fmtMoney(totals.unapplied)} not yet
            put against a bill
          </p>
        </>
      )}
    </>
  )
}
