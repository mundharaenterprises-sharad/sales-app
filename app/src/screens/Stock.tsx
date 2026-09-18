import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase, friendlyMessage } from '../lib/supabase'
import { getSnapshot, putSnapshot } from '../lib/cache'
import { fmtAge, fmtQty, fmtMoney } from '../lib/format'
import { Banner, Empty, ErrorBanner, Loading, Spinner } from '../components/ui'
import { useOnline } from '../lib/session'

interface StockRow {
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
  available_packs: number | null
  sale_rate: number
  is_active: boolean
}

const CACHE_KEY = 'stock'

export default function Stock() {
  const online = useOnline()
  const [rows, setRows] = useState<StockRow[] | null>(null)
  const [fetchedAt, setFetchedAt] = useState<number | null>(null)
  const [fromCache, setFromCache] = useState(false)
  const [refreshing, setRefreshing] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [q, setQ] = useState('')
  const [group, setGroup] = useState('')

  const load = useCallback(async (isRefresh = false) => {
    if (isRefresh) setRefreshing(true)
    setError(null)

    const { data, error } = await supabase
      .from('v_stock_report')
      .select('*')
      .eq('is_active', true)
      .order('product_name')

    if (error) {
      setError(friendlyMessage(error))
      setRefreshing(false)
      return false
    }

    const list = (data ?? []) as StockRow[]
    setRows(list)
    setFetchedAt(Date.now())
    setFromCache(false)
    setRefreshing(false)
    void putSnapshot(CACHE_KEY, list)
    return true
  }, [])

  useEffect(() => {
    let alive = true

    async function start() {
      // Show whatever is on the device immediately, then refresh over the top.
      // A rep opening the app in a shop should see something in under a second.
      const snap = await getSnapshot<StockRow[]>(CACHE_KEY)
      if (alive && snap) {
        setRows(snap.data)
        setFetchedAt(snap.fetchedAt)
        setFromCache(true)
      }

      if (navigator.onLine) {
        await load()
      } else if (alive && !snap) {
        setRows([])
        setError('You are offline and this device has no saved stock list yet.')
      }
    }

    void start()
    return () => {
      alive = false
    }
  }, [load])

  const groups = useMemo(() => {
    if (!rows) return []
    return Array.from(new Set(rows.map((r) => r.group_name))).sort()
  }, [rows])

  const filtered = useMemo(() => {
    if (!rows) return []
    const needle = q.trim().toLowerCase()
    return rows.filter((r) => {
      if (group && r.group_name !== group) return false
      if (!needle) return true
      return (
        r.product_name.toLowerCase().includes(needle) ||
        r.product_code.toLowerCase().includes(needle)
      )
    })
  }, [rows, q, group])

  const totalValue = useMemo(
    () => filtered.reduce((s, r) => s + Number(r.on_hand) * Number(r.sale_rate), 0),
    [filtered],
  )

  if (rows === null) return <Loading what="Loading stock" />

  return (
    <>
      <div className="page-head">
        <h1>Stock</h1>
        <span className="sub">
          {fetchedAt ? (
            <>
              {fromCache ? 'Saved on this device ' : 'Updated '}
              {fmtAge(fetchedAt)}
            </>
          ) : null}
        </span>
        <span style={{ marginLeft: 'auto' }}>
          <button onClick={() => void load(true)} disabled={refreshing || !online}>
            {refreshing ? <Spinner /> : 'Refresh'}
          </button>
        </span>
      </div>

      <ErrorBanner error={error} />

      {fromCache && online && !refreshing && (
        <Banner tone="warn">
          These figures were saved on this device{' '}
          {fetchedAt ? fmtAge(fetchedAt) : 'earlier'} and may have moved on. Tap
          Refresh for the live position.
        </Banner>
      )}

      <div className="toolbar">
        <span className="grow">
          <label className="sr-only" htmlFor="search">Search products</label>
          <input
            id="search"
            type="search"
            placeholder="Search by name or code"
            value={q}
            onChange={(e) => setQ(e.target.value)}
          />
        </span>
        <select
          value={group}
          onChange={(e) => setGroup(e.target.value)}
          aria-label="Filter by group"
        >
          <option value="">All groups</option>
          {groups.map((g) => (
            <option key={g} value={g}>{g}</option>
          ))}
        </select>
      </div>

      {filtered.length === 0 ? (
        <Empty title="Nothing to show">
          {rows.length === 0
            ? 'No products have been added yet. Import your product list to get started.'
            : 'No product matches that search.'}
        </Empty>
      ) : (
        <>
          <div className="card table-wrap">
            <table className="data">
              <thead>
                <tr>
                  <th>Product</th>
                  <th>Group</th>
                  <th className="num">On hand</th>
                  <th className="num">Reserved</th>
                  <th className="num">Available</th>
                  <th className="num">Rate</th>
                </tr>
              </thead>
              <tbody>
                {filtered.map((r) => {
                  const avail = Number(r.available)
                  const reserved = Number(r.reserved)
                  return (
                    <tr key={r.product_id}>
                      <td className="primary-cell">
                        <span className="strong">{r.product_name}</span>
                        <br />
                        <span className="muted" style={{ fontSize: 12.5 }}>
                          {r.product_code}
                          {r.pack_uom && ` · 1 ${r.pack_uom} = ${fmtQty(r.pack_size)} ${r.base_uom}`}
                        </span>
                      </td>
                      <td data-label="Group" className="muted">{r.group_name}</td>
                      <td data-label="On hand" className="num">
                        {fmtQty(r.on_hand)} {r.base_uom}
                      </td>
                      <td data-label="Reserved" className="num">
                        {reserved > 0
                          ? <span className="pill warn">{fmtQty(reserved)}</span>
                          : <span className="muted">—</span>}
                      </td>
                      <td data-label="Available" className="num">
                        <span className={`pill ${avail > 0 ? 'good' : 'bad'}`}>
                          {fmtQty(avail)} {r.base_uom}
                        </span>
                        {r.available_packs !== null && avail > 0 && (
                          <>
                            <br />
                            <span className="muted" style={{ fontSize: 12 }}>
                              {fmtQty(r.available_packs)} {r.pack_uom}
                            </span>
                          </>
                        )}
                      </td>
                      <td data-label="Rate" className="num">{fmtMoney(r.sale_rate)}</td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>

          <p className="sub" style={{ marginTop: 12 }}>
            {filtered.length} product{filtered.length === 1 ? '' : 's'}
            {' · '}stock at selling price {fmtMoney(totalValue)}
          </p>
        </>
      )}
    </>
  )
}
