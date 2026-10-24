import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase, friendlyMessage } from '../../lib/supabase'
import { fmtDate, fmtMoney, fmtQty } from '../../lib/format'
import { Report } from '../../components/Report'
import type { ReportColumn } from '../../components/Report'
import { DateRange, useDateRange } from '../../components/DateRange'
import { useUrlState } from '../../lib/urlstate'

/**
 * What each item and each group actually earned. Admin only.
 *
 * **Cost is the average of what was actually paid.** It is worked out from the
 * stock ledger: opening stock at its entered cost, each purchase at its real
 * cost net of discount, and a sale takes the average in force at that moment.
 * So 10 cartons at 1,900 and 10 at 2,000 make an average of 1,950, and a sale
 * out of that stock is costed at 1,950 whatever the price does afterwards —
 * last month's margin stays last month's margin. See migration 043.
 *
 * The database refuses this to anyone who is not an Admin, so the figures
 * cannot be reached by typing the URL either. The route is also redirected,
 * which is the polite half of the same rule.
 *
 * Three things on this screen are not obvious and are said on it, because a
 * margin figure gets acted on:
 *
 * - **Returns are in it, as negative rows.** A return reduces what was earned
 *   in the period it came back in, not in the period of the bill it came off.
 *   Stock already works that way, so the two agree.
 * - **A written-off return shows a loss**, and should. The customer was
 *   credited and the goods are gone, so there is no cost to give back. It is
 *   the one case where an item's margin can go negative with nothing wrong.
 * - **Freight is not in cost.** `other_charges` on a purchase is not spread
 *   across products, here or in stock value, because freight on a mixed load
 *   cannot be attributed to one product honestly.
 */

interface Line {
  kind: string
  doc_no: string
  doc_date: string
  product_id: string
  product_code: string
  product_name: string
  group_code: string
  group_name: string
  master_code: string
  master_name: string
  base_uom: string
  qty_base: number
  net_sales: number
  cost_amount: number
  margin: number
}

interface Row {
  key: string
  name: string
  code: string
  group_name: string
  master_name: string
  base_uom: string
  qty: number
  sales: number
  cost: number
  margin: number
}

type By = 'item' | 'group' | 'master'

const BY_LABEL: Record<By, string> = {
  item: 'By item',
  group: 'By product group',
  master: 'By master group',
}

/**
 * Margin as a share of what was earned.
 *
 * Guarded rather than computed blind: a period with nothing but returns in it
 * has negative earnings, and a percentage of a negative number reads as
 * nonsense on a report. Shown as a dash instead.
 */
function pct(margin: number, sales: number): string {
  if (!(sales > 0)) return '—'
  return `${((margin / sales) * 100).toFixed(1)}%`
}

export default function Profitability() {
  const { from, to, setFrom, setTo, presets } = useDateRange('month')

  const [lines, setLines] = useState<Line[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  // In the address, so opening something and pressing Back comes back to the
  // same view. See lib/urlstate.ts.
  const [by, setBy] = useUrlState('by', 'item')
  const [master, setMaster] = useUrlState('master', '')
  const [group, setGroup] = useUrlState('group', '')

  const load = useCallback(async () => {
    setError(null)
    setLines(null)
    const { data, error } = await supabase.rpc('profit_lines', {
      p_from: from || null,
      p_to: to || null,
    })
    if (error) {
      setError(friendlyMessage(error))
      setLines([])
      return
    }
    setLines((data ?? []) as Line[])
  }, [from, to])

  useEffect(() => {
    void load()
  }, [load])

  const masters = useMemo(
    () => (lines ? Array.from(new Set(lines.map((l) => l.master_name))).sort() : []),
    [lines],
  )

  const groups = useMemo(
    () =>
      lines
        ? Array.from(
            new Set(
              lines
                .filter((l) => !master || l.master_name === master)
                .map((l) => l.group_name),
            ),
          ).sort()
        : [],
    [lines, master],
  )

  const view = (by === 'group' || by === 'master' ? by : 'item') as By

  const rows = useMemo(() => {
    if (!lines) return null
    const m = new Map<string, Row>()

    for (const l of lines) {
      if (master && l.master_name !== master) continue
      if (group && l.group_name !== group) continue

      const key =
        view === 'item' ? l.product_id : view === 'group' ? l.group_code : l.master_code

      const e =
        m.get(key) ??
        {
          key,
          name:
            view === 'item'
              ? l.product_name
              : view === 'group'
                ? l.group_name
                : l.master_name,
          code: view === 'item' ? l.product_code : view === 'group' ? l.group_code : l.master_code,
          group_name: l.group_name,
          master_name: l.master_name,
          base_uom: l.base_uom,
          qty: 0,
          sales: 0,
          cost: 0,
          margin: 0,
        }

      e.qty += Number(l.qty_base || 0)
      e.sales += Number(l.net_sales || 0)
      e.cost += Number(l.cost_amount || 0)
      e.margin += Number(l.margin || 0)
      m.set(key, e)
    }

    // Worst first would be a stranger default; the biggest earner first is
    // what somebody opens this to see.
    return [...m.values()].sort((a, b) => b.margin - a.margin)
  }, [lines, view, master, group])

  const totalSales = (rows ?? []).reduce((s, r) => s + r.sales, 0)
  const totalCost = (rows ?? []).reduce((s, r) => s + r.cost, 0)
  const totalMargin = (rows ?? []).reduce((s, r) => s + r.margin, 0)

  // Quantities in mixed units cannot be added up honestly once more than one
  // product is in the row, so the column is only shown by item.
  const cols: ReportColumn<Row>[] = [
    {
      header: view === 'item' ? 'Product' : view === 'group' ? 'Group' : 'Master group',
      value: (r) => r.name,
      width: 30,
      mobile: 'title',
    },
    ...(view === 'item'
      ? ([
          { header: 'Code', value: (r) => r.code },
          { header: 'Group', value: (r) => r.group_name, width: 16 },
          {
            header: 'Quantity',
            value: (r) => r.qty,
            type: 'qty',
            align: 'right',
            cell: (r) => <>{fmtQty(r.qty)} {r.base_uom}</>,
          },
        ] as ReportColumn<Row>[])
      : []),
    { header: 'Earned', value: (r) => r.sales, type: 'money', align: 'right', mobile: 'lead' },
    { header: 'Cost', value: (r) => r.cost, type: 'money', align: 'right' },
    {
      header: 'Margin',
      value: (r) => r.margin,
      type: 'money',
      align: 'right',
      width: 14,
      // A line that lost money is the reason to open this report, and a minus
      // sign in a column of similar-looking numbers is easy to read past.
      cell: (r) =>
        r.margin < 0
          ? <span className="pill bad">{fmtMoney(r.margin)}</span>
          : <>{fmtMoney(r.margin)}</>,
    },
    {
      header: 'Margin %',
      value: (r) => pct(r.margin, r.sales),
      align: 'right',
    },
  ]

  // One entry per column, in order. A totals row one short prints every figure
  // under the wrong heading — bug #17, which this report is not repeating.
  // The quantity column has no total on purpose: these are base units, and
  // adding pieces of one product to pieces of another is a number with no
  // meaning. Every other column is money and adds up honestly.
  const totals = [
    'Total',
    ...(view === 'item' ? [null, null, null] : []),
    totalSales,
    totalCost,
    totalMargin,
    pct(totalMargin, totalSales),
  ]

  return (
    <Report<Row>
      title="Profitability"
      subtitle={`${fmtDate(from)} to ${fmtDate(to)} · ${BY_LABEL[view].toLowerCase()}`}
      filters={
        <>
          <DateRange from={from} to={to} setFrom={setFrom} setTo={setTo} presets={presets} />
          <select value={view} onChange={(e) => setBy(e.target.value)} aria-label="Group by">
            {(['item', 'group', 'master'] as By[]).map((b) => (
              <option key={b} value={b}>{BY_LABEL[b]}</option>
            ))}
          </select>
          <select
            value={master}
            onChange={(e) => { setMaster(e.target.value); setGroup('') }}
            aria-label="Filter by master group"
          >
            <option value="">All master groups</option>
            {masters.map((m) => (
              <option key={m} value={m}>{m}</option>
            ))}
          </select>
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
      fileName="profitability"
      empty="Nothing sold in this period."
      totals={totals}
      footer={
        'Cost is the average of what was actually paid, from the stock ledger — ' +
        'so a price change today does not move a past month’s margin. Returns are ' +
        'included as negative figures, in the period the goods came back. A ' +
        'written-off return shows a loss, because the customer was credited and ' +
        'the goods are gone. Freight and loading are not part of cost.'
      }
    />
  )
}
