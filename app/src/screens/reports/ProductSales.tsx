import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase, friendlyMessage } from '../../lib/supabase'
import { fmtDate } from '../../lib/format'
import { Report } from '../../components/Report'
import type { ReportColumn } from '../../components/Report'
import { DateRange, useDateRange } from '../../components/DateRange'
import { useUrlState } from '../../lib/urlstate'

/**
 * What sold, in quantity and value.
 *
 * This used to carry an "indicative margin", which valued every sale at the
 * product's CURRENT cost — so raising a buying price rewrote last quarter's
 * margin, and two people running the report a month apart got different
 * answers. **Migration 043 removed it**, both from this screen and from the
 * view, and the real figure now lives on the Profitability report, where cost
 * is the average of what was actually paid and the whole thing is Admin only.
 *
 * Two reports disagreeing about margin would be worse than one report not
 * having it, which is why this one does not have it.
 */

interface Raw {
  product_id: string
  product_code: string
  product_name: string
  group_name: string
  master_name: string | null
  base_uom: string
  invoice_date: string
  qty_sold_base: number
  net_sales: number
}

interface Row {
  product_code: string
  product_name: string
  group_name: string
  master_name: string | null
  base_uom: string
  qty: number
  sales: number
}

export default function ProductSales() {
  const { from, to, setFrom, setTo, presets } = useDateRange('month')

  const [raw, setRaw] = useState<Raw[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  // Filters in the address, so opening a record and pressing Back returns
  // to the same list. See lib/urlstate.ts.
  const [group, setGroup] = useUrlState('group', '')

  const load = useCallback(async () => {
    setError(null)
    setRaw(null)
    let q = supabase.from('v_product_sales').select('*')
    if (from) q = q.gte('invoice_date', from)
    if (to) q = q.lte('invoice_date', to)
    const { data, error } = await q
    if (error) {
      setError(friendlyMessage(error))
      setRaw([])
      return
    }
    setRaw((data ?? []) as Raw[])
  }, [from, to])

  useEffect(() => {
    void load()
  }, [load])

  const groups = useMemo(
    () => (raw ? Array.from(new Set(raw.map((r) => r.group_name))).sort() : []),
    [raw],
  )

  /** The view is one row per product per day; a report wants one per product. */
  const rows = useMemo(() => {
    if (!raw) return null
    const m = new Map<string, Row>()
    for (const r of raw) {
      if (group && r.group_name !== group) continue
      const e =
        m.get(r.product_id) ??
        {
          product_code: r.product_code,
          product_name: r.product_name,
          group_name: r.group_name,
          master_name: r.master_name,
          base_uom: r.base_uom,
          qty: 0,
          sales: 0,
        }
      e.qty += Number(r.qty_sold_base || 0)
      e.sales += Number(r.net_sales || 0)
      m.set(r.product_id, e)
    }
    return [...m.values()].sort((a, b) => b.sales - a.sales)
  }, [raw, group])

  const cols: ReportColumn<Row>[] = [
    { header: 'Product', value: (r) => r.product_name, width: 30 },
    { header: 'Code', value: (r) => r.product_code },
    { header: 'Master group', value: (r) => r.master_name, width: 16 },
    { header: 'Group', value: (r) => r.group_name },
    {
      header: 'Quantity',
      value: (r) => r.qty,
      type: 'qty',
      align: 'right',
      cell: (r) => <>{r.qty.toLocaleString('en-IN')} {r.base_uom}</>,
    },
    { header: 'Sales', value: (r) => r.sales, type: 'money', align: 'right' },
  ]

  // One entry per column, in order — Product, Code, Master group, Group,
  // Quantity, Sales. It was one short before, which put the quantity under
  // "Group" and the sales under "Quantity". Bug #17 again, found while taking
  // the margin column out.
  const totals = [
    'Total',
    null,
    null,
    null,
    (rows ?? []).reduce((s, r) => s + r.qty, 0),
    (rows ?? []).reduce((s, r) => s + r.sales, 0),
  ]

  return (
    <Report<Row>
      title="Product sales"
      subtitle={`${fmtDate(from)} to ${fmtDate(to)}`}
      filters={
        <>
          <DateRange from={from} to={to} setFrom={setFrom} setTo={setTo} presets={presets} />
          <select value={group} onChange={(e) => setGroup(e.target.value)} aria-label="Filter by group">
            <option value="">All groups</option>
            {groups.map((g) => (
              <option key={g} value={g}>{g}</option>
            ))}
          </select>
        </>
      }
      columns={cols}
      rows={rows}
      error={error}
      fileName="product-sales"
      empty="Nothing sold in this period."
      totals={totals}
      footer="Margin is on the Profitability report, which is Admin only."
    />
  )
}
