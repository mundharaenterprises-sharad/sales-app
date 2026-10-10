import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { supabase, asDbError, friendlyMessage } from '../lib/supabase'
import { fmtDate, fmtMoney, fmtQty, isoDate } from '../lib/format'
import { Banner, Empty, ErrorBanner, Loading, Spinner } from '../components/ui'
import { useSession } from '../lib/session'
import { fetchOrderLines, pendingAsLine } from '../lib/billing'
import { useDialog } from '../components/Dialog'
import { useMasterGroups, MasterFilter } from '../lib/masters'
import { useUrlState } from '../lib/urlstate'

interface OrderRow {
  order_id: string
  doc_no: string
  order_date: string
  status: string
  expires_at: string | null
  party_code: string
  party_name: string
  route_name: string
  rep_id: string | null
  rep_name: string | null
  master_code: string | null
  master_name: string | null
  lines: number
  qty_pending_base: number
  order_value: number
  expiring_soon: boolean
}

interface BillResult {
  order: string
  party: string
  ok: boolean
  docNo?: string
  invoiceId?: string
  why?: string
}

const LABEL: Record<string, string> = {
  SUBMITTED: 'Awaiting invoice',
  PARTIALLY_INVOICED: 'Part invoiced',
  INVOICED: 'Invoiced',
  CANCELLED: 'Cancelled',
  EXPIRED: 'Expired',
  DRAFT: 'Draft',
}

export default function Orders() {
  const { can, user } = useSession()
  const nav = useNavigate()
  const canBill = can('ACCOUNTS', 'ADMIN')

  /**
   * A rep works their own orders; the office works everyone's. This mirrors
   * app.require_own_order_if_rep in the database — which is what actually
   * enforces it. Hiding the button is a courtesy, not the rule.
   */
  const mine = useCallback(
    (r: OrderRow) =>
      user?.role !== 'REP' || r.rep_id === null || r.rep_id === user.id,
    [user],
  )

  const editable = useCallback(
    (r: OrderRow) => r.status === 'SUBMITTED' && mine(r),
    [mine],
  )

  const [rows, setRows] = useState<OrderRow[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)
  // Filters in the address, so opening a record and pressing Back returns
  // to the same list. See lib/urlstate.ts.
  const [q, setQ] = useUrlState('q', '')
  const [master, setMaster] = useUrlState('master', '')
  const [rep, setRep] = useUrlState('rep', '')
  const { masters } = useMasterGroups()

  const [picked, setPicked] = useState<Set<string>>(new Set())
  const [billing, setBilling] = useState<{ done: number; total: number } | null>(null)
  const [results, setResults] = useState<BillResult[] | null>(null)
  const { dialog, ask } = useDialog()

  const load = useCallback(async () => {
    setError(null)
    const { data, error } = await supabase
      .from('v_pending_orders')
      .select('*')
      // Newest at the top. The second key matters: several orders share a
      // date, and without it the database returns them in whatever order it
      // finds them, so a rep's morning round came back shuffled.
      .order('order_date', { ascending: false })
      .order('doc_no', { ascending: false })

    if (error) {
      setError(friendlyMessage(error))
      setRows([])
      return
    }
    setRows((data ?? []) as OrderRow[])
  }, [])

  useEffect(() => { void load() }, [load])

  const cancel = useCallback(
    (row: OrderRow) => {
      ask({
        title: `Cancel ${row.doc_no}?`,
        tone: 'warn',
        body: (
          <p>
            <strong>{row.party_name}</strong> — {fmtMoney(row.order_value)}. The stock
            it is holding goes back into available, and this cannot be undone.
          </p>
        ),
        ask: {
          label: 'Why is it being cancelled?',
          placeholder: 'Shop closed, ordered by mistake…',
          required: true,
        },
        actions: [
          { label: 'Keep the order' },
          {
            label: 'Cancel it',
            tone: 'danger',
            onPick: async (reason) => {
              setBusyId(row.order_id)
              const { error } = await supabase.rpc('cancel_sales_order', {
                p_order_id: row.order_id,
                p_reason: reason,
              })
              setBusyId(null)
              // Thrown, not swallowed: the dialog stays open with the reason
              // still typed in it so the answer can be tried again.
              if (error) throw new Error(friendlyMessage(error))
              await load()
            },
          },
        ],
      })
    },
    [load, ask],
  )

  /**
   * An order taken at the counter has no rep behind it. Naming that rather
   * than leaving a blank in the list keeps the filter honest — and matches
   * what the sales register already calls it.
   */
  const COUNTER = 'Counter sale'
  const repOf = (r: OrderRow) => r.rep_name ?? COUNTER

  const reps = useMemo(
    () => [...new Set((rows ?? []).map(repOf))].sort(),
    [rows],
  )

  const filtered = useMemo(() => {
    if (!rows) return []
    const needle = q.trim().toLowerCase()
    return rows.filter((r) => {
      if (master && r.master_code !== master) return false
      if (rep && repOf(r) !== rep) return false
      if (!needle) return true
      return `${r.doc_no} ${r.party_name} ${r.party_code} ${r.route_name}`
        .toLowerCase()
        .includes(needle)
    })
  }, [rows, q, master, rep])

  const totalValue = useMemo(
    () => filtered.reduce((s, r) => s + Number(r.order_value), 0),
    [filtered],
  )

  const toggle = (id: string) =>
    setPicked((s) => {
      const next = new Set(s)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })

  /**
   * The orders that are both ticked AND on screen.
   *
   * Everything about the selection is derived from this rather than from the
   * ticked set, because the two can differ the moment a filter is applied.
   * The button used to count the ticked set while billPicked only ever billed
   * the visible ones, so ticking three Parle orders, switching to Current and
   * ticking two more offered to "Bill 5 orders" and raised two. A button that
   * overstates what it is about to do is worse than no button.
   */
  const toBill = useMemo(
    () => filtered.filter((r) => picked.has(r.order_id)),
    [filtered, picked],
  )

  const pickedValue = useMemo(
    () => toBill.reduce((t, r) => t + Number(r.order_value), 0),
    [toBill],
  )

  const allShownPicked = filtered.length > 0 && filtered.every((r) => picked.has(r.order_id))

  /**
   * Changing the group or the salesman clears the selection.
   *
   * This is how the office works: one group, bill it, next group. Carrying
   * ticks across a change of filter serves nothing and invites the mistake
   * above, so the selection belongs to the view that made it.
   */
  useEffect(() => { setPicked(new Set()) }, [master, rep])

  /**
   * Bill every ticked order, each as its own bill, at whatever the order still
   * has pending and the rates on the order.
   *
   * Deliberately one call per order rather than one big one: each bill is its
   * own transaction, so an order that runs short of stock is refused on its
   * own and the rest still go through. The report afterwards says which.
   */
  const billPicked = useCallback(async () => {
    // Oldest order first, whatever order the list is being shown in. The list
    // reads newest-first because that is how you look for something; bills
    // should come out in the order the orders were taken, so their numbers
    // run the same way. Billing a whole group in one go therefore produces a
    // consecutive block of bill numbers in order-number order.
    const orders = [...toBill].sort((a, b) => a.doc_no.localeCompare(b.doc_no))
    if (orders.length === 0) return

    setError(null)
    setResults(null)
    setBilling({ done: 0, total: orders.length })

    const out: BillResult[] = []
    const date = isoDate()

    for (const o of orders) {
      try {
        const lines = (await fetchOrderLines(o.order_id))
          .map(pendingAsLine)
          .filter((l): l is NonNullable<typeof l> => l !== null)

        if (lines.length === 0) {
          out.push({ order: o.doc_no, party: o.party_name, ok: false, why: 'Nothing left to bill' })
        } else {
          const { data, error } = await supabase.rpc('create_sales_invoice', {
            p_invoice_date: date,
            p_lines: lines,
            p_order_id: o.order_id,
            p_party_id: null,
            p_bill_discount_amount: 0,
            p_bill_discount_pct: null,
            p_remarks: null,
          })
          if (error) {
            const de = asDbError(error)
            const short = Array.isArray(de.details)
              ? (de.details as { product_name: string }[]).map((d) => d.product_name).join(', ')
              : null
            out.push({
              order: o.doc_no,
              party: o.party_name,
              ok: false,
              why: short ? `Not enough stock: ${short}` : friendlyMessage(error),
            })
          } else {
            const res = data as { invoice_id: string; doc_no: string }
            out.push({
              order: o.doc_no,
              party: o.party_name,
              ok: true,
              docNo: res.doc_no,
              invoiceId: res.invoice_id,
            })
          }
        }
      } catch (e) {
        out.push({ order: o.doc_no, party: o.party_name, ok: false, why: friendlyMessage(e) })
      }
      setBilling((b) => (b ? { ...b, done: b.done + 1 } : b))
    }

    setBilling(null)
    setResults(out)
    setPicked(new Set())
    await load()
  }, [toBill, load])

  if (rows === null) return <Loading what="Loading orders" />

  const billed = results?.filter((r) => r.ok) ?? []
  const refused = results?.filter((r) => !r.ok) ?? []

  return (
    <>
      {dialog}
      <div className="page-head">
        <h1>Orders</h1>
        <span className="sub">Holding stock, waiting to be invoiced</span>
        <span style={{ marginLeft: 'auto' }}>
          <Link to="/orders/new">
            <button className="primary">New order</button>
          </Link>
        </span>
      </div>

      <ErrorBanner error={error} />

      {results && (
        <Banner tone={refused.length === 0 ? 'info' : 'warn'}>
          <strong>
            {billed.length} bill{billed.length === 1 ? '' : 's'} raised
            {refused.length > 0 && `, ${refused.length} refused`}.
          </strong>
          {billed.length > 0 && (
            <div style={{ marginTop: 6 }}>
              {billed.map((r) => `${r.docNo} (${r.party})`).join(', ')}
            </div>
          )}
          {refused.length > 0 && (
            <ul style={{ margin: '8px 0 0 18px' }}>
              {refused.map((r) => (
                <li key={r.order}>
                  {r.order} · {r.party} — {r.why}
                </li>
              ))}
            </ul>
          )}
          <div style={{ display: 'flex', gap: 8, marginTop: 10 }}>
            {billed.length > 0 && (
              <button
                className="primary"
                onClick={() =>
                  nav(`/invoices/print?ids=${billed.map((r) => r.invoiceId).join(',')}`)
                }
              >
                Print {billed.length === 1 ? 'the bill' : `all ${billed.length} bills`}
              </button>
            )}
            <button onClick={() => setResults(null)}>Dismiss</button>
          </div>
        </Banner>
      )}

      {rows.length === 0 ? (
        <Empty title="No orders waiting">
          Orders appear here from the moment they are submitted until they have
          been fully invoiced.
        </Empty>
      ) : (
        <>
          <div className="toolbar">
            <span className="grow">
              <label className="sr-only" htmlFor="oq">Search orders</label>
              <input
                id="oq"
                type="search"
            autoComplete="off"
                placeholder="Search by order number, customer or route"
                value={q}
                onChange={(e) => setQ(e.target.value)}
              />
            </span>

            <MasterFilter masters={masters} value={master} onChange={setMaster} />

            {reps.length > 1 && (
              <label className="inline-field">
                <span>Salesman</span>
                <select
                  value={rep}
                  aria-label="Filter by salesman"
                  onChange={(e) => setRep(e.target.value)}
                >
                  <option value="">Everyone</option>
                  {reps.map((r) => (
                    <option key={r} value={r}>{r}</option>
                  ))}
                </select>
              </label>
            )}

            {(master || rep) && (
              <button className="ghost" onClick={() => { setMaster(''); setRep('') }}>
                Clear
              </button>
            )}

            {canBill && toBill.length > 0 && (
              <button className="primary" onClick={() => void billPicked()} disabled={!!billing}>
                {billing ? (
                  <>
                    <Spinner /> {billing.done} of {billing.total}
                  </>
                ) : (
                  `Bill ${toBill.length} order${toBill.length === 1 ? '' : 's'} · ${fmtMoney(pickedValue)}`
                )}
              </button>
            )}
          </div>

          {canBill && toBill.length > 0 && !billing && (
            <Banner tone="info">
              {master && (
                <>
                  <strong>
                    {toBill.length === filtered.length
                      ? `All ${filtered.length} ${masters.find((m) => m.code === master)?.name ?? ''} orders`
                      : `${toBill.length} ${masters.find((m) => m.code === master)?.name ?? ''} orders`}
                  </strong>{' '}
                  — billed oldest first, so the bill numbers run in the same order
                  as the order numbers.{' '}
                </>
              )}
              Each ticked order becomes its own bill, for everything it still has
              pending, at the rates on the order. To change a quantity or give a
              discount, use <strong>Make bill</strong> on that order instead.
            </Banner>
          )}

          <div className="card table-wrap">
            <table className="data compact">
              <thead>
                <tr>
                  {canBill && (
                    <th style={{ width: 34 }}>
                      <input
                        type="checkbox"
                        aria-label="Select all orders shown"
                        checked={allShownPicked}
                        onChange={(e) =>
                          setPicked(
                            e.target.checked
                              ? new Set(filtered.map((r) => r.order_id))
                              : new Set(),
                          )
                        }
                      />
                    </th>
                  )}
                  <th>Customer</th>
                  <th>Order</th>
                  <th>Group</th>
                  <th>Status</th>
                  <th className="num">Lines</th>
                  <th className="num">Value</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {filtered.map((r) => (
                  <tr key={r.order_id} className={picked.has(r.order_id) ? 'picked' : undefined}>
                    {canBill && (
                      <td data-label="Bill" className="m-pick">
                        <input
                          type="checkbox"
                          aria-label={`Select ${r.doc_no}`}
                          checked={picked.has(r.order_id)}
                          onChange={() => toggle(r.order_id)}
                        />
                      </td>
                    )}
                    {/*
                      On a wide screen these are seven columns. On a phone the
                      classes fold them into two lines: the shop and the money
                      on the first, everything else small underneath. The
                      desktop wording is unchanged — the second line just uses
                      the short forms, because a phone has no room for
                      "Awaiting invoice · 3 lines · 240 pending".
                    */}
                    <td data-label="Customer" className="primary-cell m-title">
                      {r.party_name}
                      <span className="sub only-wide">
                        <br />
                        {r.party_code} · {r.route_name}
                      </span>
                    </td>

                    <td data-label="Order" className="m-meta">
                      <span className="strong">{r.doc_no}</span>
                      <span className="only-wide">
                        <br />
                        <span className="muted" style={{ fontSize: 12.5 }}>
                          {fmtDate(r.order_date)}
                          {r.rep_name && ` · ${r.rep_name}`}
                        </span>
                      </span>
                    </td>

                    <td data-label="Group" className="m-meta">{r.master_name ?? '—'}</td>

                    <td data-label="Status" className="m-meta">
                      {r.status === 'PARTIALLY_INVOICED' ? (
                        <span className="pill warn">{LABEL[r.status]}</span>
                      ) : (
                        /* Every row here is awaiting its bill. Saying so on
                           each one costs a phone's whole second line and tells
                           nobody anything, so only the exceptions speak up. */
                        <span className="only-wide">
                          <span className="pill flat">{LABEL[r.status] ?? r.status}</span>
                        </span>
                      )}
                      {r.expiring_soon && (
                        <> <span className="pill bad">Expiring</span></>
                      )}
                    </td>

                    <td data-label="Lines" className="num m-meta">
                      <span className="only-wide">
                        {r.lines}
                        <br />
                        <span className="muted" style={{ fontSize: 12 }}>
                          {fmtQty(r.qty_pending_base)} pending
                        </span>
                      </span>
                      <span className="only-narrow">
                        {r.lines} item{r.lines === 1 ? '' : 's'}
                      </span>
                    </td>

                    <td data-label="Value" className="num strong m-lead">
                      {fmtMoney(r.order_value)}
                    </td>
                    <td data-label="" className="num m-actions">
                      <span style={{ display: 'flex', gap: 6, justifyContent: 'flex-end' }}>
                        {canBill && (
                          <Link to={`/invoices/new?order=${r.order_id}`}>
                            <button className="primary">
                              <span className="only-wide">Make bill</span>
                              <span className="only-narrow">Bill</span>
                            </button>
                          </Link>
                        )}
                        {editable(r) && (
                          <Link to={`/orders/${r.order_id}/edit`}>
                            <button>Edit</button>
                          </Link>
                        )}
                        <button
                          className="ghost"
                          onClick={() => cancel(r)}
                          disabled={busyId === r.order_id || !mine(r)}
                          title={mine(r) ? undefined : `${r.rep_name} took this order`}
                        >
                          {busyId === r.order_id ? <Spinner /> : 'Cancel'}
                        </button>
                      </span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <p className="sub" style={{ marginTop: 12 }}>
            {filtered.length} order{filtered.length === 1 ? '' : 's'} ·{' '}
            {fmtMoney(totalValue)} of stock held
          </p>
        </>
      )}
    </>
  )
}
