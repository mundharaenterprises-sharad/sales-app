import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { supabase, friendlyMessage } from '../lib/supabase'
import { fmtDate, fmtMoney, fmtQty, fmtDayMonth } from '../lib/format'
import { Empty, ErrorBanner, Loading } from '../components/ui'
import { Check } from '../components/FormSheet'
import { DateInput } from '../components/DateInput'
import { useMasterGroups, MasterFilter } from '../lib/masters'
import { useUrlState, useUrlFlag } from '../lib/urlstate'
import { useSession } from '../lib/session'

/**
 * Goods that came back.
 *
 * Laid out like the Bills and Purchases lists on purpose: somebody who can
 * read one of those should not have to learn a third.
 *
 * The column worth looking at is the last one. A return credits the customer
 * the moment it is written, but until that credit is put against a bill it
 * floats against the account rather than against the debt it came from. The
 * figures still add up either way — the customer's total is right — but a
 * shop whose oldest bill is still showing in full, with a loose credit beside
 * it, is a shop somebody will chase for money they no longer owe.
 */

interface Row {
  return_id: string
  doc_no: string
  return_date: string
  party_id: string
  party_code: string
  party_name: string
  route_name: string
  invoice_id: string | null
  invoice_no: string | null
  master_code: string | null
  master_name: string | null
  total_value: number
  reason: string
  status: string
  created_by_name: string | null
  lines: number
  qty_base: number
  qty_restocked: number
  qty_written_off: number
  allocated: number
  unallocated: number
}

export default function Returns() {
  const nav = useNavigate()
  const { can } = useSession()
  const mayAdd = can('ACCOUNTS', 'ADMIN')
  const { masters } = useMasterGroups()

  const [rows, setRows] = useState<Row[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  const [q, setQ] = useUrlState('q', '')
  const [from, setFrom] = useUrlState('from', '')
  const [to, setTo] = useUrlState('to', '')
  const [master, setMaster] = useUrlState('master', '')
  const [looseOnly, setLooseOnly] = useUrlFlag('loose', false)
  const [showCancelled, setShowCancelled] = useUrlFlag('cancelled', true)

  const load = useCallback(async () => {
    setError(null)
    const { data, error } = await supabase
      .from('v_return_list')
      .select('*')
      .order('return_date', { ascending: false })
      .order('doc_no', { ascending: false })
    if (error) {
      setError(friendlyMessage(error))
      setRows([])
      return
    }
    setRows((data ?? []) as Row[])
  }, [])

  useEffect(() => { void load() }, [load])

  const shown = useMemo(() => {
    if (!rows) return null
    const needle = q.trim().toLowerCase()
    return rows.filter((r) => {
      if (!showCancelled && r.status === 'CANCELLED') return false
      if (master && r.master_code !== master) return false
      if (from && r.return_date < from) return false
      if (to && r.return_date > to) return false
      if (looseOnly && Number(r.unallocated) <= 0) return false
      if (!needle) return true
      return (
        r.doc_no.toLowerCase().includes(needle) ||
        r.party_name.toLowerCase().includes(needle) ||
        r.party_code.toLowerCase().includes(needle) ||
        (r.invoice_no ?? '').toLowerCase().includes(needle)
      )
    })
  }, [rows, q, from, to, master, looseOnly, showCancelled])

  const total = (shown ?? []).reduce((s, r) =>
    s + (r.status === 'CANCELLED' ? 0 : Number(r.total_value || 0)), 0)
  const loose = (shown ?? []).reduce((s, r) =>
    s + (r.status === 'CANCELLED' ? 0 : Number(r.unallocated || 0)), 0)

  return (
    <>
      <div className="page-head">
        <h1>Returns</h1>
        <span className="sub">Goods that came back</span>
        {mayAdd && (
          <button className="primary" onClick={() => nav('/returns/new')}>
            New return
          </button>
        )}
      </div>

      <ErrorBanner error={error} />

      <div className="toolbar">
        <span className="grow" style={{ minWidth: 200 }}>
          <label className="sr-only" htmlFor="ret-q">Find a return</label>
          <input
            id="ret-q"
            type="search"
            autoComplete="off"
            placeholder="Return, bill or customer"
            value={q}
            onChange={(e) => setQ(e.target.value)}
          />
        </span>
        <label className="inline-field">
          <span>From</span>
          <DateInput value={from} onChange={setFrom} />
        </label>
        <label className="inline-field">
          <span>To</span>
          <DateInput value={to} onChange={setTo} />
        </label>
        <MasterFilter masters={masters} value={master} onChange={setMaster} />
        <Check id="ret-loose" checked={looseOnly} onChange={setLooseOnly}>
          Not yet put against a bill
        </Check>
        <Check id="ret-cancelled" checked={showCancelled} onChange={setShowCancelled}>
          Include cancelled
        </Check>
      </div>

      {shown === null ? (
        <Loading what="Loading returns" />
      ) : shown.length === 0 ? (
        <Empty title="No returns">
          {rows && rows.length > 0
            ? 'Nothing matches those filters.'
            : 'When a shop sends goods back, record it here and the credit comes off what they owe.'}
        </Empty>
      ) : (
        <>
          <div className="card">
            <table className="data">
              <thead>
                <tr>
                  <th>Return</th>
                  <th>Customer</th>
                  <th>Against</th>
                  <th className="num">Back on shelf</th>
                  <th className="num">Value</th>
                  <th className="num">Still loose</th>
                </tr>
              </thead>
              <tbody>
                {shown.map((r) => {
                  const cancelled = r.status === 'CANCELLED'
                  return (
                    <tr key={r.return_id}>
                      <td className="primary-cell m-title">
                        <Link to={`/returns/${r.return_id}`} className="strong">
                          {r.doc_no}
                        </Link>
                        {cancelled && <> <span className="pill bad">Cancelled</span></>}
                        <br />
                        <span className="muted" style={{ fontSize: 12.5 }}>
                          <span className="only-wide">{fmtDate(r.return_date)}</span>
                          <span className="only-narrow">{fmtDayMonth(r.return_date)}</span>
                          {r.master_name && ` · ${r.master_name}`}
                        </span>
                      </td>
                      <td data-label="Customer" className="m-meta">
                        {r.party_name}
                        <span className="only-wide">
                          <br />
                          <span className="muted" style={{ fontSize: 12.5 }}>
                            {r.party_code} · {r.route_name}
                          </span>
                        </span>
                      </td>
                      <td data-label="Against" className="m-meta">
                        {r.invoice_id ? (
                          <Link to={`/invoices/${r.invoice_id}`}>{r.invoice_no}</Link>
                        ) : (
                          <span className="muted">no bill</span>
                        )}
                      </td>
                      <td data-label="Back on shelf" className="num m-meta">
                        {fmtQty(r.qty_restocked)}
                        {Number(r.qty_written_off) > 0 && (
                          <>
                            {' '}
                            <span className="pill warn" title="Credited but not resaleable">
                              {fmtQty(r.qty_written_off)} written off
                            </span>
                          </>
                        )}
                      </td>
                      <td data-label="Value" className="num m-lead">
                        <span className={cancelled ? 'muted' : 'strong'}>
                          {fmtMoney(r.total_value)}
                        </span>
                      </td>
                      <td data-label="Still loose" className="num m-meta">
                        {cancelled ? (
                          <span className="muted">—</span>
                        ) : Number(r.unallocated) > 0 ? (
                          <span className="pill warn">{fmtMoney(r.unallocated)}</span>
                        ) : (
                          <span className="pill good">settled</span>
                        )}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>

          <p className="sub" style={{ marginTop: 10 }}>
            {shown.length} return{shown.length === 1 ? '' : 's'} ·{' '}
            <strong>{fmtMoney(total)}</strong> credited
            {loose > 0 && <> · <strong>{fmtMoney(loose)}</strong> not yet against a bill</>}
          </p>
        </>
      )}
    </>
  )
}
