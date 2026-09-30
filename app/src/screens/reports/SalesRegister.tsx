import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase, friendlyMessage } from '../../lib/supabase'
import { fmtDate } from '../../lib/format'
import { Report } from '../../components/Report'
import type { ReportColumn } from '../../components/Report'
import { DateRange, useDateRange } from '../../components/DateRange'
import { useMasterGroups, MasterFilter } from '../../lib/masters'
import { useUrlState } from '../../lib/urlstate'
import type { Sheet } from '../../lib/xlsx'

interface Row {
  invoice_id: string
  doc_no: string
  invoice_date: string
  party_code: string
  party_name: string
  master_code: string | null
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

/** One bill line, for the product-wise sheet in the download. */
interface LineRow {
  invoice_id: string
  doc_no: string
  invoice_date: string
  route_name: string
  master_code: string | null
  master_name: string | null
  rep_name: string | null
  product_code: string
  product_name: string
  group_name: string
  base_uom: string
  pack_uom: string | null
  pack_size: number
  qty_base: number
  net_amount: number
}

/** A product's total for the period. */
interface ProductTotal {
  product_code: string
  product_name: string
  group_name: string
  masters: Set<string>
  base_uom: string
  pack_uom: string
  pack_size: number
  qty_base: number
  value: number
  bills: Set<string>
}

export default function SalesRegister() {
  const { from, to, setFrom, setTo, presets } = useDateRange('month')
  const [rows, setRows] = useState<Row[] | null>(null)
  const [lines, setLines] = useState<LineRow[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  // In the address, so opening a bill and coming back lands on the same
  // filtered report rather than on an unfiltered one. See lib/urlstate.ts.
  const [route, setRoute] = useUrlState('route', '')
  const [master, setMaster] = useUrlState('master', '')
  const [rep, setRep] = useUrlState('rep', '')
  const [billFrom, setBillFrom] = useUrlState('billfrom', '')
  const [billTo, setBillTo] = useUrlState('billto', '')
  const { masters } = useMasterGroups()

  const load = useCallback(async () => {
    setError(null)
    setRows(null)
    // Ascending, unlike the Bills list: a register is read forwards, the way
    // a book is. The second key is still needed — without it a day's bills
    // come back in no order at all, which makes two printings of the same
    // register disagree.
    let q = supabase
      .from('v_sales_register')
      .select('*')
      .order('invoice_date')
      .order('doc_no')
    if (from) q = q.gte('invoice_date', from)
    if (to) q = q.lte('invoice_date', to)
    // The lines are fetched with the same window as the bills, and filtered
    // afterwards by the same predicate, so the two sheets in the download can
    // never be describing different sets of bills.
    let ql = supabase.from('v_sales_register_lines').select('*')
    if (from) ql = ql.gte('invoice_date', from)
    if (to) ql = ql.lte('invoice_date', to)

    const [{ data, error }, lineRes] = await Promise.all([q, ql])
    if (error) {
      setError(friendlyMessage(error))
      setRows([])
      return
    }
    setRows((data ?? []) as Row[])
    // A failure here costs the second sheet, not the report. The button says
    // so rather than the screen refusing to load.
    setLines(lineRes.error ? [] : ((lineRes.data ?? []) as LineRow[]))
  }, [from, to])

  useEffect(() => {
    void load()
  }, [load])

  const routes = useMemo(
    () => (rows ? Array.from(new Set(rows.map((r) => r.route_name))).sort() : []),
    [rows],
  )
  // A bill raised straight over the counter has no rep behind it. Calling that
  // "Counter" rather than leaving it blank means the filter can actually find
  // those bills, which is usually the reason somebody opens this report.
  const COUNTER = 'Counter sale'
  const repOf = (r: Row) => r.rep_name ?? COUNTER

  /**
   * A bill number as a number.
   *
   * Bills read INV-000123, and nobody types that: they type 123, or 000123,
   * or paste the whole thing off a bill in front of them. All three have to
   * mean the same bill, so only the digits are compared — and comparing them
   * as numbers rather than as text is what makes 99 to 101 return three bills
   * instead of none.
   *
   * Anything with no digits in it at all is not a bill number and is ignored,
   * rather than filtering the report down to nothing while somebody is still
   * typing.
   */
  const billNo = (s: string): number | null => {
    const digits = (s.match(/\d+/g) ?? []).join('')
    return digits === '' ? null : Number(digits)
  }
  const lo = billNo(billFrom)
  const hi = billNo(billTo)
  const inRange = (doc_no: string) => {
    if (lo === null && hi === null) return true
    const n = billNo(doc_no)
    if (n === null) return false
    return (lo === null || n >= lo) && (hi === null || n <= hi)
  }

  const reps = useMemo(
    () => (rows ? Array.from(new Set(rows.map(repOf))).sort() : []),
    [rows],
  )

  const shown = useMemo(
    () =>
      rows
        ? rows.filter(
            (r) =>
              (!route || r.route_name === route) &&
              (!master || r.master_code === master) &&
              (!rep || repOf(r) === rep) &&
              inRange(r.doc_no),
          )
        : null,
    // inRange is a fresh closure every render; what it actually reads is
    // billFrom and billTo, and both are listed. Spelled out because a missing
    // dependency here is this project's most repeated bug.
    [rows, route, master, rep, billFrom, billTo],
  )


  /**
   * Product-wise totals for exactly the bills the register is showing.
   *
   * The same three filters are applied to the lines as to the bills — by the
   * same expressions, a few lines below where the bill filter lives — because
   * the one thing that must never happen is a file whose two sheets disagree
   * about which sales they cover.
   *
   * Quantities are totalled in base units and then split: 225 pieces at 40 to
   * the carton is 5 cartons and 25 loose. That is what the company asks for
   * and what a stock count actually looks like.
   */
  const productSheet = useCallback((): Sheet<never>[] => {
    const src = (lines ?? []).filter(
      (l) =>
        (!route || l.route_name === route) &&
        (!master || l.master_code === master) &&
        (!rep || (l.rep_name ?? COUNTER) === rep) &&
        inRange(l.doc_no),
    )
    if (src.length === 0) return []

    const by = new Map<string, ProductTotal>()
    for (const l of src) {
      const t = by.get(l.product_code) ?? {
        product_code: l.product_code,
        product_name: l.product_name,
        group_name: l.group_name,
        masters: new Set<string>(),
        base_uom: l.base_uom,
        pack_uom: l.pack_uom ?? '',
        pack_size: Number(l.pack_size) || 1,
        qty_base: 0,
        value: 0,
        bills: new Set<string>(),
      }
      // A product belongs to one master group through its product group, so
      // this is a set of one in practice. Collected rather than assumed,
      // because a row labelled Parle that included Current sales would be a
      // quiet lie in a file going to the company.
      if (l.master_name) t.masters.add(l.master_name)
      t.qty_base += Number(l.qty_base) || 0
      t.value += Number(l.net_amount) || 0
      t.bills.add(l.invoice_id)
      by.set(l.product_code, t)
    }

    const totals = [...by.values()].sort(
      (a, b) => b.value - a.value || a.product_name.localeCompare(b.product_name),
    )

    /** Whole packs, and what is left over. No pack means it is all loose. */
    const packs = (t: ProductTotal) =>
      t.pack_uom && t.pack_size > 1 ? Math.floor(t.qty_base / t.pack_size) : null
    const loose = (t: ProductTotal) =>
      t.pack_uom && t.pack_size > 1 ? t.qty_base % t.pack_size : t.qty_base

    const where = [
      master && masters.find((m) => m.code === master)?.name,
      route && `route ${route}`,
      rep && rep,
      // Named in the sheet title too. A file covering bills 200 to 260 that
      // does not say so is a file somebody will later mistake for the month.
      (lo !== null || hi !== null) &&
        `bills ${lo ?? 'first'} to ${hi ?? 'last'}`,
    ].filter(Boolean).join(' · ')

    /** Whole packs, and what is left over. No pack means it is all loose. */
    const sheetFor = (
      name: string,
      title: string,
      rows: ProductTotal[],
      extra: { header: string; value: (t: ProductTotal) => string; width: number }[] = [],
    ) => ({
      name,
      title,
      columns: [
        ...extra,
        { header: 'Code', value: (t: ProductTotal) => t.product_code, width: 12 },
        { header: 'Product', value: (t: ProductTotal) => t.product_name, width: 32 },
        { header: 'Group', value: (t: ProductTotal) => t.group_name, width: 16 },
        { header: 'Master group', value: (t: ProductTotal) => [...t.masters].sort().join(' + '), width: 14 },
        { header: 'Packs', value: (t: ProductTotal) => packs(t), type: 'qty', width: 10 },
        { header: 'Pack unit', value: (t: ProductTotal) => t.pack_uom, width: 11 },
        { header: 'Loose', value: (t: ProductTotal) => loose(t), type: 'qty', width: 10 },
        { header: 'Base unit', value: (t: ProductTotal) => t.base_uom, width: 11 },
        { header: 'Total qty', value: (t: ProductTotal) => t.qty_base, type: 'qty', width: 12 },
        { header: 'Bills', value: (t: ProductTotal) => t.bills.size, type: 'number', width: 8 },
        { header: 'Value', value: (t: ProductTotal) => t.value, type: 'money', width: 14 },
      ],
      rows,
      totals: [
        ...extra.map(() => ''),
        'Total', '', '', '', null, '', null, '',
        rows.reduce((s2, t) => s2 + t.qty_base, 0),
        null,
        rows.reduce((s2, t) => s2 + t.value, 0),
      ],
    })

    const period = from || to ? ` — ${fmtDate(from)} to ${fmtDate(to)}` : ''

    /**
     * A second grouping: who sold it.
     *
     * The same totals cut by salesman rather than summed over all of them, so
     * a rep's round can be checked against what the company was told went out.
     * A bill raised over the counter has no rep behind it and is its own line
     * rather than a blank — a blank in a column somebody is about to total by
     * hand is how a counter round goes missing.
     */
    const bySalesman = new Map<string, Map<string, ProductTotal>>()
    for (const l of src) {
      const who = l.rep_name ?? COUNTER
      const forWho = bySalesman.get(who) ?? new Map<string, ProductTotal>()
      const t = forWho.get(l.product_code) ?? {
        product_code: l.product_code,
        product_name: l.product_name,
        group_name: l.group_name,
        masters: new Set<string>(),
        base_uom: l.base_uom,
        pack_uom: l.pack_uom ?? '',
        pack_size: Number(l.pack_size) || 1,
        qty_base: 0,
        value: 0,
        bills: new Set<string>(),
      }
      if (l.master_name) t.masters.add(l.master_name)
      t.qty_base += Number(l.qty_base) || 0
      t.value += Number(l.net_amount) || 0
      t.bills.add(l.invoice_id)
      forWho.set(l.product_code, t)
      bySalesman.set(who, forWho)
    }

    const salesmanRows: ProductTotal[] = []
    const salesmanOf = new Map<ProductTotal, string>()
    for (const who of [...bySalesman.keys()].sort()) {
      const rows = [...bySalesman.get(who)!.values()].sort(
        (x, y) => y.value - x.value || x.product_name.localeCompare(y.product_name),
      )
      for (const r of rows) {
        salesmanOf.set(r, who)
        salesmanRows.push(r)
      }
    }

    return [
      sheetFor('Products', `Sold by product${where ? ` — ${where}` : ''}${period}`, totals),
      sheetFor(
        'By salesman',
        `Sold by salesman and product${where ? ` — ${where}` : ''}${period}`,
        salesmanRows,
        [{ header: 'Salesman', value: (t: ProductTotal) => salesmanOf.get(t) ?? '', width: 20 }],
      ),
    ] as unknown as Sheet<never>[]
    // As above: inRange reads billFrom and billTo, both listed.
  }, [lines, route, master, rep, masters, from, to, billFrom, billTo])

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
    { header: 'Rep', value: (r) => r.rep_name ?? COUNTER },
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
      subtitle={
        lo !== null || hi !== null
          ? `${fmtDate(from)} to ${fmtDate(to)} · bills ${lo ?? 'first'} to ${hi ?? 'last'}`
          : `${fmtDate(from)} to ${fmtDate(to)}`
      }
      extraSheets={productSheet}
      footer={
        lines && lines.length > 0 ? (
          <>the Excel download has two more sheets: <strong>Products</strong>, and
          <strong> By salesman</strong> — each product in cartons and loose</>
        ) : undefined
      }
      filters={
        <>
          <DateRange from={from} to={to} setFrom={setFrom} setTo={setTo} presets={presets} />
          <select value={route} onChange={(e) => setRoute(e.target.value)} aria-label="Filter by route">
            <option value="">All routes</option>
            {routes.map((r) => (
              <option key={r} value={r}>{r}</option>
            ))}
          </select>
          <MasterFilter masters={masters} value={master} onChange={setMaster} />
          <label className="inline-field">
            <span>Bills</span>
            <input
              type="text"
              inputMode="numeric"
              value={billFrom}
              onChange={(e) => setBillFrom(e.target.value)}
              placeholder="from"
              aria-label="From bill number"
              style={{ width: 90 }}
            />
          </label>
          <label className="inline-field">
            <span>to</span>
            <input
              type="text"
              inputMode="numeric"
              value={billTo}
              onChange={(e) => setBillTo(e.target.value)}
              placeholder="to"
              aria-label="To bill number"
              style={{ width: 90 }}
            />
          </label>
          <select
            value={rep}
            onChange={(e) => setRep(e.target.value)}
            aria-label="Filter by salesman"
            style={{ width: 'auto', minWidth: 150 }}
          >
            <option value="">All salesmen</option>
            {reps.map((r) => (
              <option key={r} value={r}>{r}</option>
            ))}
          </select>
          {(route || master || rep || billFrom || billTo) && (
            <button
              className="ghost"
              onClick={() => {
                setRoute('')
                setMaster('')
                setRep('')
                setBillFrom('')
                setBillTo('')
              }}
            >
              Clear
            </button>
          )}
        </>
      }
      columns={cols}
      rows={shown}
      error={error}
      fileName="sales-register"
      empty="No bills in this period."
      totals={[
        // One entry per column: Bill, Date, Party, Route, Group, Order, Rep,
        // then the money. Miscount this and the figures sit under the wrong
        // headings, which is worse than having no totals at all.
        'Total', null, null, null, null, null, null,
        sum((r) => r.gross_total),
        sum((r) => Number(r.line_discount_total) + Number(r.bill_discount_amount)),
        sum((r) => r.net_total),
        sum((r) => r.cancelled_value),
        sum((r) => r.effective_total),
      ]}
    />
  )
}
