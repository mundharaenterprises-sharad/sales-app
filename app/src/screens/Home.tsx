import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { useSession } from '../lib/session'
import { fmtQty, fmtMoney } from '../lib/format'
import { Loading } from '../components/ui'
import { onUpdateWaiting, applyUpdate, checkForUpdate, buildLabel } from '../lib/updates'

interface Counts {
  products: number
  parties: number
  lowStock: number
  /** Orders taken and not yet billed: goods promised, money not yet earned. */
  openOrders: number
  openValue: number
  todaySales: number
  todayBills: number
  monthSales: number
  monthBills: number
}

export default function Home() {
  const { user, can } = useSession()
  // The day's and the month's takings are the office's business. A rep can
  // already see what they owe and what is on order; the whole firm's turnover
  // on their phone is a different thing, and not one that was asked for.
  const seesTurnover = can('ACCOUNTS', 'ADMIN')
  const [counts, setCounts] = useState<Counts | null>(null)
  const [updateReady, setUpdateReady] = useState(false)
  const [checked, setChecked] = useState(false)

  useEffect(() => onUpdateWaiting(setUpdateReady), [])

  useEffect(() => {
    let alive = true

    async function load() {
      const today = new Date().toISOString().slice(0, 10)
      const monthStart = today.slice(0, 8) + '01'

      const [products, parties, low, open, sales] = await Promise.all([
        supabase.from('product').select('id', { count: 'exact', head: true }).eq('is_active', true),
        supabase.from('party').select('id', { count: 'exact', head: true }).eq('is_active', true),
        supabase.from('v_stock_report').select('product_id', { count: 'exact', head: true })
          .eq('is_active', true).lte('available', 0),
        // Summed here rather than in a view: it is one number off a list the
        // app already reads, and a view for it would be a view to keep.
        supabase.from('v_pending_orders').select('order_value'),
        // The month to date, which covers today as well — so today's figure
        // comes out of the same rows and the two tiles cannot disagree.
        seesTurnover
          ? supabase
              .from('v_sales_register')
              .select('invoice_date, net_total, status')
              .gte('invoice_date', monthStart)
              .neq('status', 'CANCELLED')
          : Promise.resolve({ data: [], error: null }),
      ])

      if (!alive) return
      const openRows = (open.data ?? []) as { order_value: number }[]
      const saleRows = (sales.data ?? []) as { invoice_date: string; net_total: number }[]
      const todayRows = saleRows.filter((r) => r.invoice_date === today)
      const money = (rs: { net_total: number }[]) =>
        rs.reduce((t, r) => t + Number(r.net_total || 0), 0)

      setCounts({
        products: products.count ?? 0,
        parties: parties.count ?? 0,
        lowStock: low.count ?? 0,
        openOrders: openRows.length,
        openValue: openRows.reduce((t, r) => t + Number(r.order_value || 0), 0),
        todaySales: money(todayRows),
        todayBills: todayRows.length,
        monthSales: money(saleRows),
        monthBills: saleRows.length,
      })
    }

    void load()
    return () => { alive = false }
  }, [seesTurnover])

  const firstName = user?.full_name?.split(' ')[0] ?? ''

  return (
    <>
      <div className="page-head">
        <h1>{firstName ? `Hello, ${firstName}` : 'Hello'}</h1>
      </div>

      {counts === null ? (
        <Loading what="Loading" />
      ) : counts.products === 0 && counts.parties === 0 ? (
        <div className="card card-pad">
          <h2>Nothing here yet</h2>
          <p style={{ color: 'var(--ink-3)' }}>
            The database is set up but empty. Fill in the master data workbook and
            import your routes, product groups, parties and products — then your
            stock and customers will appear here.
          </p>
        </div>
      ) : (
        <div className="tiles">
          {seesTurnover && (
            <>
          <Link className="tile" to="/reports/sales">
            <h3>Sold today</h3>
            <div className="stat">{fmtMoney(counts.todaySales)}</div>
            <p>
              {counts.todayBills === 0
                ? 'nothing billed yet'
                : `${counts.todayBills} bill${counts.todayBills === 1 ? '' : 's'}`}
            </p>
          </Link>

          <Link className="tile" to="/reports/sales">
            <h3>This month</h3>
            <div className="stat">{fmtMoney(counts.monthSales)}</div>
            <p>
              {counts.monthBills} bill{counts.monthBills === 1 ? '' : 's'} since the 1st
            </p>
          </Link>
            </>
          )}

          <Link className="tile" to="/stock">
            <h3>Stock</h3>
            <div className="stat">{fmtQty(counts.products)}</div>
            <p>
              products
              {counts.lowStock > 0 && ` · ${counts.lowStock} with nothing available`}
            </p>
          </Link>

          <Link className="tile" to="/parties">
            <h3>Parties</h3>
            <div className="stat">{fmtQty(counts.parties)}</div>
            <p>on the books</p>
          </Link>

          {/*
            Goods promised and not yet billed. Worth a tile of its own: it is
            the one figure that says how much work the office still owes the
            field, and it is stock that cannot be sold to anybody else.
          */}
          <Link className="tile" to="/orders">
            <h3>Open orders</h3>
            <div className="stat">{fmtMoney(counts.openValue)}</div>
            <p>
              {counts.openOrders === 0
                ? 'nothing waiting to be billed'
                : `${counts.openOrders} order${counts.openOrders === 1 ? '' : 's'} waiting to be billed`}
            </p>
          </Link>
        </div>
      )}

      {/*
        A version on the screen turns "the change didn't come through" from a
        guess into something two people can check against each other.
      */}
      <div className="build-line no-print">
        {updateReady ? (
          <>
            <strong>A newer version is ready.</strong>{' '}
            <button type="button" className="linkish" onClick={applyUpdate}>
              Load it now
            </button>
          </>
        ) : (
          <>
            Version of {buildLabel()} ·{' '}
            <button
              type="button"
              className="linkish"
              onClick={() => {
                checkForUpdate()
                setChecked(true)
                window.setTimeout(() => setChecked(false), 4000)
              }}
            >
              Check for a newer one
            </button>
            {checked && ' · checking…'}
          </>
        )}
      </div>
    </>
  )
}
