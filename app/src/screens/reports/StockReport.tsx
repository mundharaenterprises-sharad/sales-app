import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase, friendlyMessage } from '../../lib/supabase'
import { fmtQty, isoDate, fmtDate } from '../../lib/format'
import { Report } from '../../components/Report'
import type { ReportColumn } from '../../components/Report'
import { Check } from '../../components/FormSheet'
import { DateInput } from '../../components/DateInput'
import { useSession } from '../../lib/session'
import { useUrlState, useUrlFlag } from '../../lib/urlstate'

/**
 * What is on the shelf — now, or at the end of any past day.
 *
 * TWO MODES, because they answer different questions and cannot share columns.
 *
 * **Now** reads `v_stock_report`: on hand, what open orders have reserved, and
 * what is therefore available to sell. Reserved and available are facts about
 * this moment — there is no such thing as what was "available" last Tuesday,
 * because the orders that reserved it have since been billed or expired — so
 * those two columns are simply absent in the other mode rather than shown as
 * something they are not.
 *
 * **As on a date** calls `public.stock_as_on(date)` (migration 050): the
 * quantity that was on the shelf at the end of that day, worked out from the
 * stock ledger, with its value at the weighted average cost in force then.
 *
 * Two things about the as-on figures are deliberate and are said on the screen:
 *
 * - **A document cancelled after that date still counts on that date.** A bill
 *   raised on the 1st and cancelled on the 20th means the goods were gone on
 *   the 10th, and a figure for the 10th that pretends otherwise cannot be
 *   reconciled against anything anybody counted.
 * - **The value is Admin only.** Cost is the one figure Accounts may not read,
 *   the same rule Profitability follows. The quantities are for everybody,
 *   because checking a quantity against a physical count is ordinary office
 *   work.
 */

interface Row {
  product_id: string
  product_code: string
  product_name: string
  group_name: string
  base_uom: string
  pack_uom: string | null
  pack_size: number
  on_hand: number
  // Now only.
  reserved?: number
  available?: number
  sale_rate?: number
  purchase_rate?: number
  stock_value_at_cost?: number
  // As on a date only. Null rather than absent when the reader is not an
  // Admin, which is the database's answer and not a decision taken here.
  unit_cost?: number | null
  stock_value?: number | null
  is_active: boolean
}

export default function StockReport() {
  const { can } = useSession()
  const seesCost = can('ACCOUNTS', 'ADMIN')

  const [rows, setRows] = useState<Row[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  // Filters in the address, so opening a record and pressing Back returns
  // to the same list. See lib/urlstate.ts.
  const [group, setGroup] = useUrlState('group', '')
  const [inStockOnly, setInStockOnly] = useUrlFlag('instock', false)
  const [asOn, setAsOn] = useUrlState('ason', '')

  const today = isoDate(new Date())
  // Today is not a past date, so asking for it is the live view. That keeps
  // one obvious thing true: clearing the box and typing today's date give the
  // same screen.
  const isAsOn = asOn !== '' && asOn < today

  const load = useCallback(async () => {
    setError(null)
    setRows(null)

    if (asOn !== '' && asOn < today) {
      // One row per product, so there is nothing here that can outgrow a
      // response cap — see bug #31 and migration 048.
      const { data, error } = await supabase.rpc('stock_as_on', { p_as_on: asOn })
      if (error) {
        setError(friendlyMessage(error))
        setRows([])
        return
      }
      setRows(((data ?? []) as Row[]).filter((r) => r.is_active))
      return
    }

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
  }, [asOn, today])

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

  // Whether the database actually gave us a value. On the as-on report that is
  // the server's decision, not this screen's — a non-Admin gets nulls.
  const asOnHasValue =
    isAsOn && (shown ?? []).some((r) => r.stock_value !== null && r.stock_value !== undefined)

  const common: ReportColumn<Row>[] = [
    { header: 'Product', value: (r) => r.product_name, width: 30, mobile: 'title' },
    { header: 'Code', value: (r) => r.product_code },
    { header: 'Group', value: (r) => r.group_name },
    {
      header: 'Pack',
      value: (r) => (r.pack_uom ? `1 ${r.pack_uom} = ${Number(r.pack_size)} ${r.base_uom}` : 'Loose'),
      mobile: 'hide',
    },
    {
      header: 'On hand',
      value: (r) => Number(r.on_hand),
      type: 'qty',
      align: 'right',
      mobile: 'lead',
      cell: (r) => <>{fmtQty(r.on_hand)} {r.base_uom}</>,
    },
  ]

  // One entry per column, in order, or every figure prints under the wrong
  // heading — bug #17. Both arms are built beside their own columns so the two
  // cannot drift apart.
  const cols: ReportColumn<Row>[] = isAsOn
    ? [
        ...common,
        ...(asOnHasValue
          ? ([
              {
                header: 'Cost then',
                value: (r) => (r.unit_cost == null ? null : Number(r.unit_cost)),
                type: 'money',
                align: 'right',
              },
              {
                header: 'Stock value',
                value: (r) => (r.stock_value == null ? null : Number(r.stock_value)),
                type: 'money',
                align: 'right',
              },
            ] as ReportColumn<Row>[])
          : []),
      ]
    : [
        ...common,
        { header: 'Reserved', value: (r) => Number(r.reserved ?? 0), type: 'qty', align: 'right' },
        {
          header: 'Available',
          value: (r) => Number(r.available ?? 0),
          type: 'qty',
          align: 'right',
          cell: (r) => (
            <span className={`pill ${Number(r.available ?? 0) > 0 ? 'good' : 'bad'}`}>
              {fmtQty(r.available ?? 0)}
            </span>
          ),
        },
        { header: 'Sale rate', value: (r) => Number(r.sale_rate ?? 0), type: 'money', align: 'right' },
        ...(seesCost
          ? ([
              { header: 'Cost', value: (r) => Number(r.purchase_rate ?? 0), type: 'money', align: 'right' },
              {
                header: 'Stock value',
                value: (r) => Number(r.stock_value_at_cost ?? 0),
                type: 'money',
                align: 'right',
              },
            ] as ReportColumn<Row>[])
          : []),
      ]

  const sum = (pick: (r: Row) => number) => (shown ?? []).reduce((s, r) => s + pick(r), 0)

  const totals: (string | number | null)[] = isAsOn
    ? [
        'Total',
        null,
        null,
        null,
        sum((r) => Number(r.on_hand)),
        ...(asOnHasValue ? [null, sum((r) => Number(r.stock_value ?? 0))] : []),
      ]
    : [
        'Total',
        null,
        null,
        null,
        sum((r) => Number(r.on_hand)),
        sum((r) => Number(r.reserved ?? 0)),
        sum((r) => Number(r.available ?? 0)),
        null,
        ...(seesCost ? [null, sum((r) => Number(r.stock_value_at_cost ?? 0))] : []),
      ]

  return (
    <Report<Row>
      title="Stock"
      subtitle={
        isAsOn
          ? `as on ${fmtDate(asOn)} — what was on the shelf at the end of that day`
          : `as at ${new Date().toLocaleDateString('en-GB')}`
      }
      filters={
        <>
          <label className="inline-field">
            <span>As on</span>
            <DateInput value={asOn} onChange={setAsOn} aria-label="Stock as on date" />
          </label>
          {isAsOn && (
            <button type="button" className="ghost" onClick={() => setAsOn('')}>
              Back to today
            </button>
          )}
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
      fileName={isAsOn ? `stock-as-on-${asOn}` : 'stock'}
      empty="No products."
      totals={totals}
      footer={
        isAsOn
          ? 'Worked out from the stock ledger. A bill or purchase cancelled AFTER this ' +
            'date still counts on this date, because on this date it had not been ' +
            'cancelled yet — so these figures can be checked against what was ' +
            'actually on the shelf. Reserved and available are not shown: open ' +
            'orders reserve stock now, and there is no such thing as what was ' +
            'available on a past day.' +
            (asOnHasValue
              ? ' Value is at the weighted average cost in force on that date.'
              : ' Stock value is not shown, because cost is Admin only.')
          : undefined
      }
    />
  )
}
