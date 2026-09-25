import { useCallback, useEffect, useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { supabase, asDbError, friendlyMessage } from '../lib/supabase'
import { fmtMoney } from '../lib/format'
import { Banner, ErrorBanner, Loading, Spinner } from '../components/ui'
import { Picker } from '../components/Picker'
import { num } from '../components/FormSheet'

/**
 * Recording goods in.
 *
 * Deliberately close to the bill screen, because it is the same job in the
 * other direction and nobody should have to learn it twice. The differences
 * are that there is no stock to run out of, and that the rate being typed is
 * what was paid, which becomes the cost every margin figure leans on.
 *
 * One master group per purchase, as everywhere else: once the first product is
 * chosen, the picker only offers others from the same side of the business.
 * That is the database's rule, enforced here so it is a narrowed list rather
 * than a refusal at the end.
 */

interface Supplier {
  id: string
  code: string
  name: string
  city: string | null
}

interface ProductRow {
  id: string
  code: string
  name: string
  base_uom: string
  pack_uom: string | null
  pack_size: number
  purchase_rate: number
  pack_purchase_rate: number | null
  group_name: string
  master_code: string
  master_name: string
  is_active: boolean
}

interface Line {
  key: string
  product: ProductRow
  uom: 'BASE' | 'PACK'
  qty: string
  rate: string
}

const today = () => new Date().toISOString().slice(0, 10)

export default function NewPurchase() {
  const nav = useNavigate()

  const [suppliers, setSuppliers] = useState<Supplier[] | null>(null)
  const [products, setProducts] = useState<ProductRow[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const [supplier, setSupplier] = useState<Supplier | null>(null)
  const [date, setDate] = useState(today())
  const [billNo, setBillNo] = useState('')
  const [billDate, setBillDate] = useState('')
  const [other, setOther] = useState('')
  const [remarks, setRemarks] = useState('')
  const [lines, setLines] = useState<Line[]>([])

  const [pickSupplier, setPickSupplier] = useState(false)
  const [pickProduct, setPickProduct] = useState(false)

  const load = useCallback(async () => {
    const [s, p] = await Promise.all([
      supabase.from('supplier').select('id, code, name, city').eq('is_active', true).order('name'),
      supabase
        .from('v_product_master')
        .select(
          'id, code, name, base_uom, pack_uom, pack_size, purchase_rate,' +
            ' pack_purchase_rate, group_name, master_code, master_name, is_active',
        )
        .eq('is_active', true)
        .order('name'),
    ])
    if (s.error) setError(friendlyMessage(s.error))
    else setSuppliers((s.data ?? []) as Supplier[])
    if (p.error) setError(friendlyMessage(p.error))
    else setProducts((p.data ?? []) as unknown as ProductRow[])
  }, [])

  useEffect(() => {
    void load()
  }, [load])

  // The master group of the purchase, decided by whatever went on it first.
  const master = lines[0]?.product.master_code ?? null
  const masterName = lines[0]?.product.master_name ?? null

  const offerable = useMemo(() => {
    if (!products) return []
    const used = new Set(lines.map((l) => l.product.id))
    return products.filter(
      (p) => !used.has(p.id) && (master === null || p.master_code === master),
    )
  }, [products, lines, master])

  const addProduct = (p: ProductRow) => {
    const byPack = p.pack_uom !== null && p.pack_size > 1
    setLines((ls) => [
      ...ls,
      {
        key: `${p.id}-${Date.now()}`,
        product: p,
        uom: byPack ? 'PACK' : 'BASE',
        qty: '',
        rate: String(
          byPack ? (p.pack_purchase_rate ?? p.purchase_rate * p.pack_size) : p.purchase_rate,
        ),
      },
    ])
    setPickProduct(false)
  }

  const patch = (key: string, p: Partial<Line>) =>
    setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...p } : l)))

  const drop = (key: string) => setLines((ls) => ls.filter((l) => l.key !== key))

  const amountOf = (l: Line) => {
    const q = num(l.qty, 0)
    const r = num(l.rate, 0)
    if (Number.isNaN(q) || Number.isNaN(r)) return 0
    return Math.round(q * r * 100) / 100
  }

  const gross = lines.reduce((s, l) => s + amountOf(l), 0)
  const otherCharges = Number.isNaN(num(other, 0)) ? 0 : num(other, 0)
  const net = Math.round((gross + otherCharges) * 100) / 100

  const save = useCallback(async () => {
    setError(null)

    if (!supplier) {
      setError('Choose the supplier this came from.')
      return
    }
    if (lines.length === 0) {
      setError('Add at least one product.')
      return
    }
    for (const l of lines) {
      const q = num(l.qty, 0)
      const r = num(l.rate, 0)
      if (Number.isNaN(q) || q <= 0) {
        setError(`${l.product.name}: quantity must be a number above zero.`)
        return
      }
      if (Number.isNaN(r) || r < 0) {
        setError(`${l.product.name}: rate must be a plain number — no commas.`)
        return
      }
    }

    setBusy(true)
    const { data, error } = await supabase.rpc('post_purchase', {
      p_supplier_id: supplier.id,
      p_purchase_date: date,
      p_lines: lines.map((l) => ({
        product_id: l.product.id,
        uom: l.uom,
        qty: num(l.qty, 0),
        rate: num(l.rate, 0),
        pack_size: l.product.pack_size,
      })),
      p_other_charges: otherCharges,
      p_supplier_bill_no: billNo.trim() || null,
      p_supplier_bill_date: billDate || null,
      p_remarks: remarks.trim() || null,
    })
    setBusy(false)

    if (error) {
      const de = asDbError(error)
      setError(de.message ?? friendlyMessage(error))
      return
    }

    const r = data as { purchase_id: string; doc_no: string }
    nav(`/purchases/${r.purchase_id}`, { state: { justCreated: r.doc_no } })
  }, [supplier, date, lines, otherCharges, billNo, billDate, remarks, nav])

  if (suppliers === null || products === null) return <Loading what="Loading" />

  return (
    <>
      <div className="page-head">
        <h1>New purchase</h1>
        <span className="sub">Goods in from a supplier</span>
        <span style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
          <button onClick={() => nav('/purchases')}>Cancel</button>
          <button className="primary" onClick={() => void save()} disabled={busy}>
            {busy ? <Spinner /> : 'Save purchase'}
          </button>
        </span>
      </div>

      <ErrorBanner error={error} />

      {suppliers.length === 0 && (
        <Banner tone="warn">
          There are no suppliers yet.{' '}
          <button className="ghost" onClick={() => nav('/suppliers')}>
            Add one
          </button>{' '}
          and come back.
        </Banner>
      )}

      <div className="card card-pad">
        <div className="form-row">
          <div style={{ flex: '2 1 240px' }}>
            <label className="sr-only" htmlFor="pu-supplier">Supplier</label>
            <button
              id="pu-supplier"
              className="block"
              style={{ textAlign: 'left' }}
              onClick={() => setPickSupplier(true)}
              disabled={busy}
            >
              {supplier ? `${supplier.name} · ${supplier.code}` : 'Choose supplier…'}
            </button>
          </div>
          <label className="inline-field">
            <span>Date</span>
            <input type="date" value={date} onChange={(e) => setDate(e.target.value)} />
          </label>
          <label className="inline-field">
            <span>Their bill no.</span>
            <input
              type="text"
              value={billNo}
              placeholder="optional"
              onChange={(e) => setBillNo(e.target.value)}
              style={{ width: 140 }}
            />
          </label>
          <label className="inline-field">
            <span>Their bill date</span>
            <input type="date" value={billDate} onChange={(e) => setBillDate(e.target.value)} />
          </label>
        </div>

        {master && (
          <p className="hint" style={{ marginTop: 10 }}>
            This is a <strong>{masterName}</strong> purchase. A purchase carries one
            master group, so only {masterName} products are offered below. Buying
            both means two purchases.
          </p>
        )}
      </div>

      <div className="card table-wrap" style={{ marginTop: 12 }}>
        <table className="data">
          <thead>
            <tr>
              <th>Product</th>
              <th style={{ width: 110 }}>Unit</th>
              <th className="num" style={{ width: 110 }}>Qty</th>
              <th className="num" style={{ width: 130 }}>Rate</th>
              <th className="num" style={{ width: 130 }}>Amount</th>
              <th style={{ width: 44 }}></th>
            </tr>
          </thead>
          <tbody>
            {lines.map((l) => (
              <tr key={l.key}>
                <td className="primary-cell">
                  <span className="strong">{l.product.name}</span>
                  <br />
                  <span className="muted" style={{ fontSize: 12.5 }}>
                    {l.product.group_name}
                  </span>
                </td>
                <td data-label="Unit">
                  {l.product.pack_uom && l.product.pack_size > 1 ? (
                    <select
                      aria-label={`Unit for ${l.product.name}`}
                      value={l.uom}
                      onChange={(e) => {
                        const uom = e.target.value as 'BASE' | 'PACK'
                        patch(l.key, {
                          uom,
                          rate: String(
                            uom === 'PACK'
                              ? (l.product.pack_purchase_rate ??
                                 l.product.purchase_rate * l.product.pack_size)
                              : l.product.purchase_rate,
                          ),
                        })
                      }}
                    >
                      <option value="PACK">{l.product.pack_uom}</option>
                      <option value="BASE">{l.product.base_uom}</option>
                    </select>
                  ) : (
                    <span className="muted">{l.product.base_uom}</span>
                  )}
                </td>
                <td data-label="Qty" className="num">
                  <input
                    type="text"
                    inputMode="decimal"
                    aria-label={`Quantity of ${l.product.name}`}
                    value={l.qty}
                    onChange={(e) => patch(l.key, { qty: e.target.value })}
                    style={{ textAlign: 'right' }}
                  />
                </td>
                <td data-label="Rate" className="num">
                  <input
                    type="text"
                    inputMode="decimal"
                    aria-label={`Rate for ${l.product.name}`}
                    value={l.rate}
                    onChange={(e) => patch(l.key, { rate: e.target.value })}
                    style={{ textAlign: 'right' }}
                  />
                </td>
                <td data-label="Amount" className="num strong">{fmtMoney(amountOf(l))}</td>
                <td className="num">
                  <button className="ghost" onClick={() => drop(l.key)} aria-label="Remove">
                    ✕
                  </button>
                </td>
              </tr>
            ))}
            {lines.length === 0 && (
              <tr>
                <td colSpan={6} className="muted" style={{ textAlign: 'center', padding: 20 }}>
                  No products yet.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <div className="card card-pad" style={{ marginTop: 12 }}>
        <button onClick={() => setPickProduct(true)} disabled={busy}>
          Add product
        </button>

        <div className="form-row" style={{ marginTop: 14 }}>
          <label className="inline-field">
            <span>Other charges</span>
            <input
              type="text"
              inputMode="decimal"
              value={other}
              placeholder="0"
              onChange={(e) => setOther(e.target.value)}
              style={{ width: 120, textAlign: 'right' }}
            />
          </label>
          <label className="inline-field grow">
            <span>Remarks</span>
            <input
              type="text"
              value={remarks}
              placeholder="optional"
              onChange={(e) => setRemarks(e.target.value)}
            />
          </label>
        </div>

        <p className="hint" style={{ marginTop: 10 }}>
          Freight, loading and the like go in Other charges. They are added to the
          total but not spread across the products, so they do not change any
          product&rsquo;s cost.
        </p>

        <div className="tiles" style={{ marginTop: 14 }}>
          <div className="tile">
            <h3>Goods</h3>
            <div className="stat">{fmtMoney(gross)}</div>
            <p>{lines.length} line{lines.length === 1 ? '' : 's'}</p>
          </div>
          <div className="tile">
            <h3>Other charges</h3>
            <div className="stat">{fmtMoney(otherCharges)}</div>
            <p>&nbsp;</p>
          </div>
          <div className="tile">
            <h3>Total</h3>
            <div className="stat">{fmtMoney(net)}</div>
            <p>what the supplier is owed</p>
          </div>
        </div>
      </div>

      {pickSupplier && (
        <Picker<Supplier>
          title="Choose supplier"
          placeholder="Search by name or code"
          items={suppliers}
          keyOf={(s) => s.id}
          searchOf={(s) => `${s.name} ${s.code} ${s.city ?? ''}`}
          render={(s) => (
            <>
              <span className="strong">{s.name}</span>
              <br />
              <span className="muted" style={{ fontSize: 12.5 }}>
                {s.code}
                {s.city ? ` · ${s.city}` : ''}
              </span>
            </>
          )}
          onPick={(s) => {
            setSupplier(s)
            setPickSupplier(false)
          }}
          onClose={() => setPickSupplier(false)}
          emptyText="No suppliers match."
        />
      )}

      {pickProduct && (
        <Picker<ProductRow>
          title={master ? `Choose ${masterName} product` : 'Choose product'}
          placeholder="Search by name or code"
          items={offerable}
          keyOf={(p) => p.id}
          searchOf={(p) => `${p.name} ${p.code} ${p.group_name} ${p.master_name}`}
          render={(p) => (
            <>
              <span className="strong">{p.name}</span>
              <br />
              <span className="muted" style={{ fontSize: 12.5 }}>
                {p.code} · {p.group_name} · {p.master_name}
              </span>
            </>
          )}
          onPick={addProduct}
          onClose={() => setPickProduct(false)}
          emptyText={
            master
              ? `No more ${masterName} products. A purchase carries one master group.`
              : 'No products match.'
          }
        />
      )}
    </>
  )
}
