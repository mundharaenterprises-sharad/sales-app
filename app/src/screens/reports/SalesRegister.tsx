import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase, friendlyMessage } from '../../lib/supabase'
import { fmtDate } from '../../lib/format'
import { Report } from '../../components/Report'
import type { ReportColumn } from '../../components/Report'
import { DateRange, useDateRange } from '../../components/DateRange'

interface Row {
  invoice_id: string
  doc_no: string
  invoice_date: string
  party_code: string
  party_name: string
  master_name: string | null
  route_name: string
  order_no: string | null
  rep_name: string | null
  gross_total: number
  line_discount_total: number
  bill_discount_amount: number
  net_total: number
  cancelled_value: number
  effective_total: number
  status: string
}

export default function SalesRegister() {
  const { from, to, setFrom, setTo, presets } = useDateRange('month')
  const [rows, setRows] = useState<Row[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [route, setRoute] = useState('')

  const load = useCallback(async () => {
    setError(null)
    setRows(null)
    let q = supabase.from('v_sales_register').select('*').order('invoice_date')
    if (from) q = q.gte('invoice_date', from)
    if (to) q = q.lte('invoice_date', to)
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

  const routes = useMemo(
    () => (rows ? Array.from(new Set(rows.map((r) => r.route_name))).sort() : []),
    [rows],
  )
  const shown = useMemo(
    () => (rows ? rows.filter((r) => !route || r.route_name === route) : null),
    [rows, route],
  )

  const cols: ReportColumn<Row>[] = [
    {
      header: 'Bill',
      value: (r) => r.doc_no,
      width: 14,
      cell: (r) => (
        <>
          <Link to={`/invoices/${r.invoice_id}`} className="strong">{r.doc_no}</Link>
          {r.status !== 'ACTIVE' && <> <span className="pill bad">Cancelled</span></>}
        </>
      ),
    },
    { header: 'Date', value: (r) => r.invoice_date, cell: (r) => fmtDate(r.invoice_date) },
    { header: 'Party', value: (r) => r.party_name, width: 26 },
    { header: 'Route', value: (r) => r.route_name },
    { header: 'Group', value: (r) => r.master_name, width: 14 },
    { header: 'Order', value: (r) => r.order_no ?? '' },
    { header: 'Rep', value: (r) => r.rep_name ?? '' },
    { header: 'Gross', value: (r) => Number(r.gross_total), type: 'money', align: 'right' },
    {
      header: 'Discount',
      value: (r) => Number(r.line_discount_total) + Number(r.bill_discount_amount),
      type: 'money',
      align: 'right',
    },
    { header: 'Net', value: (r) => Number(r.net_total), type: 'money', align: 'right' },
    { header: 'Cancelled', value: (r) => Number(r.cancelled_value), type: 'money', align: 'right' },
    { header: 'Billed', value: (r) => Number(r.effective_total), type: 'money', align: 'right' },
  ]

  const sum = (pick: (r: Row) => number) =>
    (shown ?? []).reduce((s, r) => s + Number(pick(r) || 0), 0)

  return (
    <Report<Row>
      title="Sales register"
      subtitle={`${fmtDate(from)} to ${fmtDate(to)}`}
      filters={
        <>
          <DateRange from={from} to={to} setFrom={setFrom} setTo={setTo} presets={presets} />
          <select value={route} onChange={(e) => setRoute(e.target.value)} aria-label="Filter by route">
            <option value="">All routes</option>
            {routes.map((r) => (
              <option key={r} value={r}>{r}</option>
            ))}
          </select>
        </>
      }
      columns={cols}
      rows={shown}
      error={error}
      fileName="sales-register"
      empty="No bills in this period."
      totals={[
        'Total', null, null, null, null, null,
        sum((r) => r.gross_total),
        sum((r) => Number(r.line_discount_total) + Number(r.bill_discount_amount)),
        sum((r) => r.net_total),
        sum((r) => r.cancelled_value),
        sum((r) => r.effective_total),
      ]}
    />
  )
}
