import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase, friendlyMessage } from '../lib/supabase'
import { fmtDate, fmtMoney } from '../lib/format'
import { Report } from '../components/Report'
import type { ReportColumn } from '../components/Report'
import { Check } from '../components/FormSheet'
import { useMasterGroups, MasterFilter } from '../lib/masters'

/**
 * One day, one page.
 *
 * What was sold, what was bought and what came in as cash are shown side by
 * side and never netted against each other. A day with a 50,000 bill and a
 * 50,000 purchase is not a quiet day, and a single figure would say it was.
 *
 * The list underneath is every document raised that day in the order it
 * happened, so the close of business is a matter of reading down the page.
 */

interface Entry {
  entry_date: string
  doc_type: string
  doc_no: string
  doc_id: string
  who: string
  who_code: string
  route_name: string | null
  master_code: string | null
  master_name: string | null
  amount: number
  status: string
  entered_by: string | null
  created_at: string
}

interface Summary {
  sales: number | null
  purchases: number | null
  receipts: number | null
  returns: number | null
  cancelled: number | null
  orders: number | null
  bill_count: number
  purchase_count: number
  payment_count: number
  order_count: number
  entry_count: number
}

const LABEL: Record<string, string> = {
  BILL: 'Bill',
  PAYMENT: 'Payment',
  PURCHASE: 'Purchase',
  ORDER: 'Order',
  RETURN: 'Return',
  CANCELLATION: 'Cancellation',
}

/** Where clicking a row goes. Returns and cancellations have no screen of their own. */
const LINK_TO: Record<string, (id: string) => string | null> = {
  BILL: (id) => `/invoices/${id}`,
  PAYMENT: (id) => `/receipts/${id}`,
  PURCHASE: (id) => `/purchases/${id}`,
  ORDER: () => null,
  RETURN: () => null,
  CANCELLATION: () => null,
}

const today = () => new Date().toISOString().slice(0, 10)

export default function DayBook() {
  const [date, setDate] = useState(today())
  const [entries, setEntries] = useState<Entry[] | null>(null)
  const [summary, setSummary] = useState<Summary | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [master, setMaster] = useState('')
  const [showOrders, setShowOrders] = useState(true)
  const [byGroup, setByGroup] = useState(false)
  const { masters } = useMasterGroups()

  const load = useCallback(async () => {
    setError(null)
    setEntries(null)
    const [e, s] = await Promise.all([
      supabase
        .from('v_day_book')
        .select('*')
        .eq('entry_date', date)
        .order('created_at'),
      supabase.from('v_day_summary').select('*').eq('entry_date', date).maybeSingle(),
    ])
    if (e.error) {
      setError(friendlyMessage(e.error))
      setEntries([])
      return
    }
    setEntries((e.data ?? []) as Entry[])
    setSummary((s.data as Summary) ?? null)
  }, [date])

  useEffect(() => {
    void load()
  }, [load])

  const filtered = useMemo(() => {
    if (!entries) return null
    return entries.filter((r) => {
      // A payment belongs to no master group until somebody applies it to a
      // bill, so filtering by group must not silently hide the day's cash —
      // "Received 0.00" would read as a bug rather than as an answer.
      if (master && r.master_code !== null && r.master_code !== master) return false
      if (!showOrders && r.doc_type === 'ORDER') return false
      return true
    })
  }, [entries, master, showOrders])

  /**
   * Chronological by default, because the day book's job is "what happened
   * today, in the order it happened". Grouping is the other question — how did
   * each side of the business do — and it is a different read of the same day,
   * so it is a switch rather than a replacement.
   *
   * Within a group the entries stay in time order. A payment belongs to no
   * group, so those sit together at the end under their own heading.
   */
  const rows = useMemo(() => {
    if (!filtered) return null
    if (!byGroup) return filtered
    const rank = new Map(masters.map((m, i) => [m.code, i]))
    return [...filtered].sort((a, b) => {
      const ra = a.master_code === null ? 99 : (rank.get(a.master_code) ?? 98)
      const rb = b.master_code === null ? 99 : (rank.get(b.master_code) ?? 98)
      if (ra !== rb) return ra - rb
      return a.created_at.localeCompare(b.created_at)
    })
  }, [filtered, byGroup, masters])

  // The tiles follow whatever filter is on, so they always describe the page.
  const shown = rows ?? []
  const live = (type: string) =>
    shown.filter((r) => r.doc_type === type && r.status !== 'CANCELLED')
  const sum = (type: string) =>
    live(type).reduce((s, r) => s + Number(r.amount || 0), 0)

  const sales = sum('BILL')
  const purchases = sum('PURCHASE')
  const receipts = sum('PAYMENT')
  const returns = sum('RETURN')

  /** "Parle 12,500 · Current 7,000" for one kind of document. */
  const splitOf = (type: string) => {
    const rows = live(type)
    const by = new Map<string, number>()
    for (const r of rows) {
      const k = r.master_name ?? 'Not grouped'
      by.set(k, (by.get(k) ?? 0) + Number(r.amount || 0))
    }
    if (by.size < 2) return null
    const order = masters.map((m) => m.name)
    return [...by.entries()]
      .sort((a, b) => {
        const ia = order.indexOf(a[0])
        const ib = order.indexOf(b[0])
        return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib)
      })
      .map(([name, value]) => `${name} ${fmtMoney(value)}`)
      .join(' · ')
  }

  const cols: ReportColumn<Entry>[] = [
    {
      header: 'Type',
      value: (r) => LABEL[r.doc_type] ?? r.doc_type,
      width: 14,
    },
    {
      header: 'Document',
      value: (r) => r.doc_no,
      width: 16,
      cell: (r) => {
        const to = LINK_TO[r.doc_type]?.(r.doc_id) ?? null
        return (
          <>
            {to ? (
              <Link to={to} className="strong">{r.doc_no}</Link>
            ) : (
              <span className="strong">{r.doc_no}</span>
            )}
            {r.status === 'CANCELLED' && <> <span className="pill bad">Cancelled</span></>}
          </>
        )
      },
    },
    {
      header: 'Who',
      value: (r) => r.who,
      width: 28,
      cell: (r) => (
        <>
          {r.who}
          <br />
          <span className="muted" style={{ fontSize: 12.5 }}>
            {r.who_code}
            {r.route_name ? ` · ${r.route_name}` : ''}
          </span>
        </>
      ),
    },
    { header: 'Group', value: (r) => r.master_name, width: 12 },
    { header: 'Entered by', value: (r) => r.entered_by, width: 18 },
    {
      header: 'Amount',
      value: (r) => Number(r.amount || 0),
      type: 'money',
      align: 'right',
      cell: (r) =>
        r.status === 'CANCELLED' ? (
          <span className="muted">{fmtMoney(r.amount)}</span>
        ) : (
          <span className="strong">{fmtMoney(r.amount)}</span>
        ),
    },
  ]

  const shift = (days: number) => {
    const d = new Date(date + 'T00:00:00')
    d.setDate(d.getDate() + days)
    setDate(d.toISOString().slice(0, 10))
  }

  const filters = (
    <>
      <button onClick={() => shift(-1)} aria-label="Previous day">‹</button>
      <label className="inline-field">
        <span>Date</span>
        <input type="date" value={date} onChange={(e) => setDate(e.target.value)} />
      </label>
      <button onClick={() => shift(1)} aria-label="Next day">›</button>
      <button onClick={() => setDate(today())} disabled={date === today()}>
        Today
      </button>
      <MasterFilter masters={masters} value={master} onChange={setMaster} />
      <Check id="db-orders" checked={showOrders} onChange={setShowOrders}>
        Include orders
      </Check>
      <Check id="db-group" checked={byGroup} onChange={setByGroup}>
        Group together
      </Check>
    </>
  )

  return (
    <>
      <div className="tiles no-print" style={{ marginBottom: 6 }}>
        <div className="tile">
          <h3>Sold</h3>
          <div className="stat">{fmtMoney(sales)}</div>
          <p>
            {shown.filter((r) => r.doc_type === 'BILL').length} bill
            {shown.filter((r) => r.doc_type === 'BILL').length === 1 ? '' : 's'}
            {returns > 0 ? ` · ${fmtMoney(returns)} returned` : ''}
            {splitOf('BILL') && (
              <>
                <br />
                {splitOf('BILL')}
              </>
            )}
          </p>
        </div>
        <div className="tile">
          <h3>Bought</h3>
          <div className="stat">{fmtMoney(purchases)}</div>
          <p>
            {shown.filter((r) => r.doc_type === 'PURCHASE').length} purchase
            {shown.filter((r) => r.doc_type === 'PURCHASE').length === 1 ? '' : 's'}
            {splitOf('PURCHASE') && (
              <>
                <br />
                {splitOf('PURCHASE')}
              </>
            )}
          </p>
        </div>
        <div className="tile">
          <h3>Received</h3>
          <div className="stat">{fmtMoney(receipts)}</div>
          <p>
            {shown.filter((r) => r.doc_type === 'PAYMENT').length} payment
            {shown.filter((r) => r.doc_type === 'PAYMENT').length === 1 ? '' : 's'}
            {master ? ' · all groups, a payment belongs to none until applied' : ''}
          </p>
        </div>
      </div>

      <Report<Entry>
        title="Day book"
        subtitle={fmtDate(date)}
        filters={filters}
        columns={cols}
        rows={rows}
        error={error}
        fileName={`day-book-${date}`}
        empty="Nothing was entered on this day."
        footer={
          <>
            {fmtMoney(sales)} sold · {fmtMoney(purchases)} bought ·{' '}
            {fmtMoney(receipts)} received
            {summary && summary.entry_count > shown.length
              ? ` · ${summary.entry_count - shown.length} hidden by the filters`
              : ''}
          </>
        }
      />
    </>
  )
}
