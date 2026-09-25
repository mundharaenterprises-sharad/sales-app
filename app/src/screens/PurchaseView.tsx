import { useCallback, useEffect, useState } from 'react'
import { Link, useLocation, useNavigate, useParams } from 'react-router-dom'
import { supabase, asDbError, friendlyMessage } from '../lib/supabase'
import { fmtDate, fmtMoney, fmtQty } from '../lib/format'
import { Banner, ErrorBanner, Loading, Spinner } from '../components/ui'
import { useSession } from '../lib/session'

/**
 * One purchase, and the way back out of it.
 *
 * Cancelling takes the goods out again on today's date rather than editing
 * anything, so the stock ledger still reads as a history of what happened. If
 * the goods have since been sold the database refuses, and says which product
 * is short — there is no honest way to un-buy something already gone.
 */

interface Head {
  purchase_id: string
  doc_no: string
  purchase_date: string
  supplier_code: string
  supplier_name: string
  supplier_bill_no: string | null
  supplier_bill_date: string | null
  master_name: string | null
  gross_total: number
  other_charges: number
  net_total: number
  status: string
  cancel_reason: string | null
  remarks: string | null
  created_by_name: string | null
}

interface LineRow {
  id: string
  line_no: number
  uom: string
  qty: number
  pack_size: number
  rate: number
  qty_base: number
  amount: number
  product: { code: string; name: string; base_uom: string; pack_uom: string | null } | null
}

export default function PurchaseView() {
  const { id } = useParams()
  const nav = useNavigate()
  const { can } = useSession()
  const justCreated = (useLocation().state as { justCreated?: string } | null)?.justCreated

  const [head, setHead] = useState<Head | null>(null)
  const [lines, setLines] = useState<LineRow[]>([])
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    setError(null)
    const [h, l] = await Promise.all([
      supabase.from('v_purchase_list').select('*').eq('purchase_id', id).single(),
      supabase
        .from('purchase_line')
        .select('*, product:product_id (code, name, base_uom, pack_uom)')
        .eq('purchase_id', id)
        .order('line_no'),
    ])
    if (h.error) {
      setError(friendlyMessage(h.error))
      return
    }
    setHead(h.data as Head)
    if (!l.error) setLines((l.data ?? []) as unknown as LineRow[])
  }, [id])

  useEffect(() => {
    void load()
  }, [load])

  const cancel = useCallback(async () => {
    const reason = window.prompt(
      'Why is this purchase being cancelled? The goods go back out of stock.',
    )
    if (reason === null) return
    if (!reason.trim()) {
      setError('A cancellation needs a reason.')
      return
    }

    setBusy(true)
    setError(null)
    const { error } = await supabase.rpc('cancel_purchase', {
      p_purchase_id: id,
      p_reason: reason.trim(),
    })
    setBusy(false)

    if (error) {
      const de = asDbError(error)
      let msg = de.message ?? friendlyMessage(error)
      // The shortfall arrives as JSON in the detail; say it in words.
      try {
        const short = JSON.parse(String(de.details ?? '[]')) as {
          product: string
          taking_back: number
          in_stock: number
        }[]
        if (short.length > 0) {
          msg +=
            ' ' +
            short
              .map(
                (s) =>
                  `${s.product}: taking back ${fmtQty(s.taking_back)}, only ${fmtQty(
                    s.in_stock,
                  )} in stock.`,
              )
              .join(' ')
        }
      } catch {
        /* no detail to add */
      }
      setError(msg)
      return
    }
    await load()
  }, [id, load])

  if (!head && !error) return <Loading what="Loading purchase" />

  return (
    <>
      <div className="page-head">
        <h1>Purchase {head?.doc_no}</h1>
        <span style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
          <button onClick={() => nav('/purchases')}>All purchases</button>
          {can('ACCOUNTS', 'ADMIN') && head?.status === 'ACTIVE' && (
            <button onClick={() => void cancel()} disabled={busy}>
              {busy ? <Spinner /> : 'Cancel purchase'}
            </button>
          )}
        </span>
      </div>

      <ErrorBanner error={error} />

      {justCreated && (
        <Banner tone="info">
          Purchase <strong>{justCreated}</strong> saved. The goods are in stock.
        </Banner>
      )}

      {head?.status === 'CANCELLED' && (
        <Banner tone="bad">
          This purchase is cancelled and the goods went back out of stock.
          {head.cancel_reason ? ` Reason: ${head.cancel_reason}` : ''}
        </Banner>
      )}

      {head && (
        <div className="card card-pad">
          <div className="tiles">
            <div className="tile">
              <h3>Supplier</h3>
              <div className="stat" style={{ fontSize: 20 }}>{head.supplier_name}</div>
              <p>{head.supplier_code}{head.master_name ? ` · ${head.master_name}` : ''}</p>
            </div>
            <div className="tile">
              <h3>Dated</h3>
              <div className="stat" style={{ fontSize: 20 }}>{fmtDate(head.purchase_date)}</div>
              <p>
                {head.supplier_bill_no
                  ? `their bill ${head.supplier_bill_no}${
                      head.supplier_bill_date ? ` of ${fmtDate(head.supplier_bill_date)}` : ''
                    }`
                  : 'no supplier bill number'}
              </p>
            </div>
            <div className="tile">
              <h3>Total</h3>
              <div className="stat">{fmtMoney(head.net_total)}</div>
              <p>
                {fmtMoney(head.gross_total)} goods
                {Number(head.other_charges) > 0
                  ? ` + ${fmtMoney(head.other_charges)} charges`
                  : ''}
              </p>
            </div>
          </div>
          {head.remarks && <p className="sub" style={{ marginTop: 12 }}>{head.remarks}</p>}
        </div>
      )}

      <div className="card table-wrap" style={{ marginTop: 12 }}>
        <table className="data">
          <thead>
            <tr>
              <th>#</th>
              <th>Product</th>
              <th className="num">Qty</th>
              <th className="num">Rate</th>
              <th className="num">Amount</th>
            </tr>
          </thead>
          <tbody>
            {lines.map((l) => (
              <tr key={l.id}>
                <td className="muted">{l.line_no}</td>
                <td className="primary-cell">
                  <span className="strong">{l.product?.name}</span>
                  <br />
                  <span className="muted" style={{ fontSize: 12.5 }}>{l.product?.code}</span>
                </td>
                <td data-label="Qty" className="num">
                  {fmtQty(l.qty)}{' '}
                  {l.uom === 'PACK' ? (l.product?.pack_uom ?? 'PACK') : l.product?.base_uom}
                  {l.uom === 'PACK' && (
                    <>
                      <br />
                      <span className="muted" style={{ fontSize: 12 }}>
                        {fmtQty(l.qty_base)} {l.product?.base_uom}
                      </span>
                    </>
                  )}
                </td>
                <td data-label="Rate" className="num">{fmtMoney(l.rate)}</td>
                <td data-label="Amount" className="num strong">{fmtMoney(l.amount)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <p className="sub" style={{ marginTop: 12 }}>
        <Link to="/purchases">Back to purchases</Link>
        {head?.created_by_name ? ` · entered by ${head.created_by_name}` : ''}
      </p>
    </>
  )
}
