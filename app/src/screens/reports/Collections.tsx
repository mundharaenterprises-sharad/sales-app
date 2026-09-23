import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase, friendlyMessage } from '../../lib/supabase'
import { fmtDate } from '../../lib/format'
import { Report } from '../../components/Report'
import type { ReportColumn } from '../../components/Report'
import { DateRange, useDateRange } from '../../components/DateRange'
import { Check } from '../../components/FormSheet'

/**
 * Money collected, and by whom.
 *
 * "Days in transit" is the gap between the customer paying and the payment
 * being entered — for a rep collecting in the field, how long the cash sat with
 * them. It only sees money that eventually arrived.
 */

interface Row {
  receipt_id: string
  doc_no: string
  receipt_date: string
  entered_on: string
  days_in_transit: number
  party_code: string
  party_name: string
  route_name: string
  amount: number
  collected_by_name: string | null
  entered_by_name: string | null
  status: string
}

export default function Collections() {
  const { from, to, setFrom, setTo, presets } = useDateRange('month')
  const [rows, setRows] = useState<Row[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [who, setWho] = useState('')
  const [byCollector, setByCollector] = useState(false)

  const load = useCallback(async () => {
    setError(null)
    setRows(null)
    let q = supabase
      .from('v_collection_report')
      .select('*')
      .eq('status', 'ACTIVE')
      .order('receipt_date', { ascending: false })
    if (from) q = q.gte('receipt_date', from)
    if (to) q = q.lte('receipt_date', to)
    const { data, error } = await q
    if (error) {
      setError(friendlyMessage(error))
      setRows([])
      return
    }
    setRows((data ?? []) as Row[])
  }, [from, to])

  useEffect(() => {
    void load()
  }, [load])

  const collectors = useMemo(
    () =>
      rows
        ? Array.from(new Set(rows.map((r) => r.collected_by_name ?? 'Not recorded'))).sort()
        : [],
    [rows],
  )

  const shown = useMemo(
    () => (rows ? rows.filter((r) => !who || (r.collected_by_name ?? 'Not recorded') === who) : null),
    [rows, who],
  )

  /** One row per person, when the question is who brought in what. */
  const summary = useMemo(() => {
    if (!shown) return null
    const m = new Map<string, { name: string; receipts: number; collected: number; transit: number }>()
    for (const r of shown) {
      const key = r.collected_by_name ?? 'Not recorded'
      const e = m.get(key) ?? { name: key, receipts: 0, collected: 0, transit: 0 }
      e.receipts += 1
      e.collected += Number(r.amount)
      e.transit += Number(r.days_in_transit || 0)
      m.set(key, e)
    }
    return [...m.values()]
      .map((e) => ({ ...e, avg: e.receipts ? e.transit / e.receipts : 0 }))
      .sort((a, b) => b.collected - a.collected)
  }, [shown])

  const cols: ReportColumn<Row>[] = [
    {
      header: 'Payment',
      value: (r) => r.doc_no,
      width: 14,
      cell: (r) => <Link to={`/receipts/${r.receipt_id}`} className="strong">{r.doc_no}</Link>,
    },
    { header: 'Date', value: (r) => r.receipt_date, cell: (r) => fmtDate(r.receipt_date) },
    { header: 'Party', value: (r) => r.party_name, width: 26 },
    { header: 'Route', value: (r) => r.route_name },
    { header: 'Collected by', value: (r) => r.collected_by_name ?? 'Not recorded' },
    { header: 'Entered by', value: (r) => r.entered_by_name ?? '' },
    {
      header: 'Days in transit',
      value: (r) => Number(r.days_in_transit || 0),
      type: 'number',
      align: 'right',
      cell: (r) => (
        <span className={Number(r.days_in_transit) > 2 ? 'pill warn' : undefined}>
          {Number(r.days_in_transit || 0)} d
        </span>
      ),
    },
    { header: 'Amount', value: (r) => Number(r.amount), type: 'money', align: 'right' },
  ]

  type Sum = { name: string; receipts: number; collected: number; avg: number }
  const sumCols: ReportColumn<Sum>[] = [
    { header: 'Collected by', value: (r) => r.name, width: 26 },
    { header: 'Payments', value: (r) => r.receipts, type: 'number', align: 'right' },
    { header: 'Collected', value: (r) => r.collected, type: 'money', align: 'right' },
    {
      header: 'Average days in transit',
      value: (r) => Math.round(r.avg * 10) / 10,
      type: 'number',
      align: 'right',
      width: 22,
    },
  ]

  const filters = (
    <>
      <DateRange from={from} to={to} setFrom={setFrom} setTo={setTo} presets={presets} />
      <select value={who} onChange={(e) => setWho(e.target.value)} aria-label="Filter by collector">
        <option value="">Everyone</option>
        {collectors.map((c) => (
          <option key={c} value={c}>{c}</option>
        ))}
      </select>
      <Check id="by-collector" checked={byCollector} onChange={setByCollector}>
        Summarise by person
      </Check>
    </>
  )

  const total = (shown ?? []).reduce((s, r) => s + Number(r.amount), 0)

  return byCollector ? (
    <Report<Sum>
      title="Collections by person"
      subtitle={`${fmtDate(from)} to ${fmtDate(to)}`}
      filters={filters}
      columns={sumCols}
      rows={summary}
      error={error}
      fileName="collections-by-person"
      empty="No money collected in this period."
      totals={['Total', (summary ?? []).reduce((s, r) => s + r.receipts, 0), total, null]}
    />
  ) : (
    <Report<Row>
      title="Collections"
      subtitle={`${fmtDate(from)} to ${fmtDate(to)}`}
      filters={filters}
      columns={cols}
      rows={shown}
      error={error}
      fileName="collections"
      empty="No money collected in this period."
      totals={['Total', null, null, null, null, null, null, total]}
    />
  )
}
