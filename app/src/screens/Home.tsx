import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { useSession } from '../lib/session'
import { fmtQty } from '../lib/format'
import { Loading } from '../components/ui'

interface Counts {
  products: number
  parties: number
  lowStock: number
}

export default function Home() {
  const { user } = useSession()
  const [counts, setCounts] = useState<Counts | null>(null)

  useEffect(() => {
    let alive = true

    async function load() {
      const [products, parties, low] = await Promise.all([
        supabase.from('product').select('id', { count: 'exact', head: true }).eq('is_active', true),
        supabase.from('party').select('id', { count: 'exact', head: true }).eq('is_active', true),
        supabase.from('v_stock_report').select('product_id', { count: 'exact', head: true })
          .eq('is_active', true).lte('available', 0),
      ])

      if (!alive) return
      setCounts({
        products: products.count ?? 0,
        parties: parties.count ?? 0,
        lowStock: low.count ?? 0,
      })
    }

    void load()
    return () => { alive = false }
  }, [])

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
          <Link className="tile" to="/stock">
            <h3>Stock</h3>
            <div className="stat">{fmtQty(counts.products)}</div>
            <p>
              products
              {counts.lowStock > 0 && ` · ${counts.lowStock} with nothing available`}
            </p>
          </Link>

          <div className="tile">
            <h3>Customers</h3>
            <div className="stat">{fmtQty(counts.parties)}</div>
            <p>on the books</p>
          </div>
        </div>
      )}
    </>
  )
}
