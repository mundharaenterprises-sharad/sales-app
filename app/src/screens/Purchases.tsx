import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { supabase, friendlyMessage } from '../lib/supabase'
import { fmtDate, fmtMoney } from '../lib/format'
import { Empty, ErrorBanner, Loading } from '../components/ui'
import { Check } from '../components/FormSheet'
import { useMasterGroups, MasterFilter } from '../lib/masters'
import { useSession } from '../lib/session'

/**
 * Goods in. The mirror of the Bills screen, and laid out the same way, because
 * somebody who can find a bill should not have to learn a second list.
 */

interface Row {
  purchase_id: string
  doc_no: string
  purchase_date: string
  supplier_code: string
  supplier_name: string
  supplier_bill_no: string | null
  master_code: string | null
  master_name: string | null
  net_total: number
  other_charges: number
  status: string
  line_count: number
  created_by_name: string | null
}

export default function Purchases() {
  const { can } = useSession()
  const nav = useNavigate()
  const [rows, setRows] = useState<Row[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [q, setQ] = useState('')
  const [master, setMaster] = useState('')
  const [from, setFrom] = useState('')
  const [to, setTo] = useState('')
  const [showCancelled, setShowCancelled] = useState(true)
  const { masters } = useMasterGroups()

  const load = useCallback(async () => {
    setError(null)
    const { data, error } = await supabase
      .from('v_purchase_list')
      .select('*')
      .order('purchase_date', { ascending: false })
      .order('created_at', { ascending: false })
      .limit(500)
    if (error) {
      setError(friendlyMessage(error))
      setRows([])
      return
    }
    setRows((data ?? []) as Row[])
  }, [])

  useEffect(() => {
    void load()
  }, [load])

  const filtered = useMemo(() => {
    if (!rows) return []
    const needle = q.trim().toLowerCase()
    return rows.filter((r) => {
      if (!showCancelled && r.status === 'CANCELLED') return false
      if (master && r.master_code !== master) return false
      if (from && r.purchase_date < from) return false
      if (to && r.purchase_date > to) return false
      if (!needle) return true
      return `${r.doc_no} ${r.supplier_name} ${r.supplier_code} ${r.supplier_bill_no ?? ''}`
        .toLowerCase()
        .includes(needle)
    })
  }, [rows, q, master, from, to, showCancelled])

  const total = filtered
    .filter((r) => r.status !== 'CANCELLED')
    .reduce((s, r) => s + Number(r.net_total), 0)

  const today = () => new Date().toISOString().slice(0, 10)

  if (rows === null) return <Loading what="Loading purchases" />

  return (
    <>
      <div className="page-head">
        <h1>Purchases</h1>
        <span className="sub">Most recent first</span>
        {can('ACCOUNTS', 'ADMIN') && (
          <span style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
            <button onClick={() => nav('/suppliers')}>Suppliers</button>
            <button className="primary" onClick={() => nav('/purchases/new')}>
              New purchase
            </button>
          </span>
        )}
      </div>

      <ErrorBanner error={error} />

      {rows.length === 0 ? (
        <Empty title="No purchases yet">
          Record goods coming in and they will appear here, with the stock they
          brought. Suppliers are managed on the Suppliers screen.
        </Empty>
      ) : (
        <>
          <div className="toolbar">
            <span className="grow">
              <label className="sr-only" htmlFor="pq">Search purchases</label>
              <input
                id="pq"
                type="search"
                autoComplete="off"
                placeholder="Search by number, supplier or their bill number"
                value={q}
                onChange={(e) => setQ(e.target.value)}
              />
            </span>
            <MasterFilter masters={masters} value={master} onChange={setMaster} />
            <Check id="pu-cancelled" checked={showCancelled} onChange={setShowCancelled}>
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
            {(from || to || master || q || !showCancelled) && (
              <button
                className="ghost"
                onClick={() => {
                  setFrom('')
                  setTo('')
                  setMaster('')
                  setQ('')
                  setShowCancelled(true)
                }}
              >
                Clear
              </button>
            )}
          </div>

          <div className="card table-wrap">
            <table className="data">
              <thead>
                <tr>
                  <th>Purchase</th>
                  <th>Supplier</th>
                  <th>Group</th>
                  <th className="num">Lines</th>
                  <th className="num">Total</th>
                </tr>
              </thead>
              <tbody>
                {filtered.map((r) => (
                  <tr key={r.purchase_id} className={r.status === 'CANCELLED' ? 'inactive' : undefined}>
                    <td className="primary-cell">
                      <Link to={`/purchases/${r.purchase_id}`} className="strong">
                        {r.doc_no}
                      </Link>
                      {r.status === 'CANCELLED' && (
                        <> <span className="pill bad">Cancelled</span></>
                      )}
                      <br />
                      <span className="muted" style={{ fontSize: 12.5 }}>
                        {fmtDate(r.purchase_date)}
                        {r.supplier_bill_no ? ` · their no. ${r.supplier_bill_no}` : ''}
                      </span>
                    </td>
                    <td data-label="Supplier">
                      {r.supplier_name}
                      <br />
                      <span className="muted" style={{ fontSize: 12.5 }}>{r.supplier_code}</span>
                    </td>
                    <td data-label="Group">
                      {r.master_name ?? <span className="muted">—</span>}
                    </td>
                    <td data-label="Lines" className="num muted">{r.line_count}</td>
                    <td data-label="Total" className="num strong">{fmtMoney(r.net_total)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <p className="sub" style={{ marginTop: 12 }}>
            {filtered.length} purchase{filtered.length === 1 ? '' : 's'} ·{' '}
            {fmtMoney(total)} bought
          </p>
        </>
      )}
    </>
  )
}
