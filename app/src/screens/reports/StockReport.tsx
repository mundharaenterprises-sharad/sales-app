import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase, friendlyMessage } from '../../lib/supabase'
import { fmtQty } from '../../lib/format'
import { Report } from '../../components/Report'
import type { ReportColumn } from '../../components/Report'
import { Check } from '../../components/FormSheet'
import { useSession } from '../../lib/session'

interface Row {
  product_id: string
  product_code: string
  product_name: string
  group_name: string
  base_uom: string
  pack_uom: string | null
  pack_size: number
  on_hand: number
  reserved: number
  available: number
  sale_rate: number
  purchase_rate: number
  pack_sale_rate: number | null
  stock_value_at_cost: number
  is_active: boolean
}

export default function StockReport() {
  const { can } = useSession()
  const seesCost = can('ACCOUNTS', 'ADMIN')

  const [rows, setRows] = useState<Row[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [group, setGroup] = useState('')
  const [inStockOnly, setInStockOnly] = useState(false)

  const load = useCallback(async () => {
    setError(null)
    const { data, error } = await supabase
      .from('v_stock_report')
      .select('*')
      .eq('is_active', true)
      .order('product_name')
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

  const groups = useMemo(
    () => (rows ? Array.from(new Set(rows.map((r) => r.group_name))).sort() : []),
    [rows],
  )

  const shown = useMemo(() => {
    if (!rows) return null
    return rows.filter((r) => {
      if (group && r.group_name !== group) return false
      if (inStockOnly && Number(r.on_hand) <= 0) return false
      return true
    })
  }, [rows, group, inStockOnly])

  const cols: ReportColumn<Row>[] = [
    { header: 'Product', value: (r) => r.product_name, width: 30 },
    { header: 'Code', value: (r) => r.product_code },
    { header: 'Group', value: (r) => r.group_name },
    {
      header: 'Pack',
      value: (r) => (r.pack_uom ? `1 ${r.pack_uom} = ${Number(r.pack_size)} ${r.base_uom}` : 'Loose'),
    },
    {
      header: 'On hand',
      value: (r) => Number(r.on_hand),
      type: 'qty',
      align: 'right',
      cell: (r) => <>{fmtQty(r.on_hand)} {r.base_uom}</>,
    },
    { header: 'Reserved', value: (r) => Number(r.reserved), type: 'qty', align: 'right' },
    {
      header: 'Available',
      value: (r) => Number(r.available),
      type: 'qty',
      align: 'right',
      cell: (r) => (
        <span className={`pill ${Number(r.available) > 0 ? 'good' : 'bad'}`}>
          {fmtQty(r.available)}
        </span>
      ),
    },
    { header: 'Sale rate', value: (r) => Number(r.sale_rate), type: 'money', align: 'right' },
    ...(seesCost
      ? ([
          { header: 'Cost', value: (r) => Number(r.purchase_rate), type: 'money', align: 'right' },
          {
            header: 'Stock value',
            value: (r) => Number(r.stock_value_at_cost),
            type: 'money',
            align: 'right',
          },
        ] as ReportColumn<Row>[])
      : []),
  ]

  const totals = [
    'Total',
    null,
    null,
    null,
    (shown ?? []).reduce((s, r) => s + Number(r.on_hand), 0),
    (shown ?? []).reduce((s, r) => s + Number(r.reserved), 0),
    (shown ?? []).reduce((s, r) => s + Number(r.available), 0),
    null,
    ...(seesCost
      ? [null, (shown ?? []).reduce((s, r) => s + Number(r.stock_value_at_cost), 0)]
      : []),
  ]

  return (
    <Report<Row>
      title="Stock"
      subtitle={`as at ${new Date().toLocaleDateString('en-GB')}`}
      filters={
        <>
          <select value={group} onChange={(e) => setGroup(e.target.value)} aria-label="Filter by group">
            <option value="">All groups</option>
            {groups.map((g) => (
              <option key={g} value={g}>{g}</option>
            ))}
          </select>
          <Check id="in-stock" checked={inStockOnly} onChange={setInStockOnly}>
            In stock only
          </Check>
        </>
      }
      columns={cols}
      rows={shown}
      error={error}
      fileName="stock"
      empty="No products."
      totals={totals}
    />
  )
}
