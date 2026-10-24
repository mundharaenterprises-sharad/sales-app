import { useCallback, useEffect, useState } from 'react'
import { Link, useLocation, useNavigate, useParams } from 'react-router-dom'
import { supabase, asDbError, friendlyMessage } from '../lib/supabase'
import { fmtDate, fmtMoney, fmtQty } from '../lib/format'
import { Banner, ErrorBanner, Loading, Spinner } from '../components/ui'
import { useSession } from '../lib/session'
import { useBillPage } from '../lib/printpage'
import { VoucherSheet } from '../components/VoucherSheet'
import { DateInput } from '../components/DateInput'

/**
 * One purchase, what it cost, and the two ways to correct it.
 *
 * Cancelling takes the goods out again on today's date rather than editing
 * anything, so the stock ledger still reads as a history of what happened. If
 * the goods have since been sold the database refuses, and says which product
 * is short — there is no honest way to un-buy something already gone.
 *
 * **Correcting** (044) is that cancellation and a fresh entry in one step,
 * with the old one kept and linked. It inherits the same refusal, which is
 * what decides how long a purchase can be corrected: not a clock, but whether
 * the goods are still on the shelf. Changing a rate moves the average cost
 * from that date onward and so the margins already reported — correct, if the
 * rate was keyed wrong, and said on the screen before it happens.
 *
 * **The details** — the supplier's own bill number, its date, the remarks —
 * move no stock and no money, so they can be fixed at any time, including long
 * after the goods have gone and correcting is no longer possible. That is the
 * whole reason there are two ways rather than one.
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
  line_discount_total: number
  bill_discount_amount: number
  discount_total: number
  other_charges: number
  net_total: number
  status: string
  cancel_reason: string | null
  remarks: string | null
  created_by_name: string | null
  replaces_doc_no: string | null
  replaced_by_id: string | null
  replaced_by_doc_no: string | null
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
  line_discount_pct: number | null
  line_discount_amount: number
  allocated_bill_discount: number
  net_amount: number
  product: { code: string; name: string; base_uom: string; pack_uom: string | null } | null
}

export default function PurchaseView() {
  const { id } = useParams()
  const nav = useNavigate()
  const { can } = useSession()
  const justCreated = (useLocation().state as { justCreated?: string } | null)?.justCreated

  // A5 portrait, no page margin, border on the sheet. See lib/printpage.ts.
  useBillPage()

  const [head, setHead] = useState<Head | null>(null)
  const [lines, setLines] = useState<LineRow[]>([])
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  // Editing the details is a separate, smaller job from correcting the
  // purchase, so it is a separate, smaller form that opens in place.
  const [editing, setEditing] = useState(false)
  const [billNo, setBillNo] = useState('')
  const [billDate, setBillDate] = useState('')
  const [remarks, setRemarks] = useState('')
  const [savedNote, setSavedNote] = useState<string | null>(null)

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
    const row = h.data as Head
    setHead(row)
    setBillNo(row.supplier_bill_no ?? '')
    setBillDate(row.supplier_bill_date ?? '')
    setRemarks(row.remarks ?? '')
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

  /** The supplier's bill number, its date, the remarks. Nothing that moves. */
  const saveDetails = useCallback(async () => {
    setError(null)
    setBusy(true)
    const { error } = await supabase.rpc('update_purchase_details', {
      p_purchase_id: id,
      // An empty box clears the field; null would leave it alone. The database
      // uses the same convention, so the two cannot disagree about what an
      // emptied box means.
      p_supplier_bill_no: billNo.trim(),
      p_supplier_bill_date: billDate || null,
      p_remarks: remarks.trim(),
    })
    setBusy(false)
    if (error) {
      setError(friendlyMessage(error))
      return
    }
    setEditing(false)
    setSavedNote('Details saved.')
    await load()
  }, [id, billNo, billDate, remarks, load])

  const mayEdit = can('ACCOUNTS', 'ADMIN') && head?.status === 'ACTIVE'

  if (!head && !error) return <Loading what="Loading purchase" />

  return (
    <>
      <div className="page-head no-print">
        <h1>Purchase {head?.doc_no}</h1>
        <span style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
          <button onClick={() => nav('/purchases')}>All purchases</button>
          <button className="primary" onClick={() => window.print()} disabled={!head}>
            Print
          </button>
          {mayEdit && (
            <button onClick={() => { setEditing((v) => !v); setSavedNote(null) }}>
              {editing ? 'Stop editing' : 'Edit details'}
            </button>
          )}
          {mayEdit && (
            <button onClick={() => nav(`/purchases/new?revise=${head!.purchase_id}`)}>
              Correct purchase
            </button>
          )}
          {mayEdit && (
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

      {savedNote && <Banner tone="info">{savedNote}</Banner>}

      {head?.status === 'CANCELLED' && (
        <Banner tone="bad">
          This purchase is cancelled and the goods went back out of stock.
          {head.cancel_reason ? ` Reason: ${head.cancel_reason}` : ''}
          {head.replaced_by_doc_no && (
            <>
              {' '}It was corrected and re-entered as{' '}
              <Link to={`/purchases/${head.replaced_by_id}`}>
                {head.replaced_by_doc_no}
              </Link>.
            </>
          )}
        </Banner>
      )}

      {head?.status === 'ACTIVE' && head.replaces_doc_no && (
        <Banner tone="info">
          This corrects <strong>{head.replaces_doc_no}</strong>, which was
          cancelled when this one was entered.
        </Banner>
      )}

      {editing && head && (
        <div className="card card-pad no-print">
          <h3 style={{ marginTop: 0 }}>Details</h3>
          <p className="hint" style={{ marginTop: 0 }}>
            The supplier&rsquo;s own bill number, its date and the remarks. None
            of these move stock or money, so they can be fixed at any time —
            including after the goods have gone out, when correcting the
            purchase is no longer possible.
          </p>
          <div className="form-row">
            <label className="inline-field">
              <span>Their bill no.</span>
              <input
                type="text"
                value={billNo}
                placeholder="optional"
                onChange={(e) => setBillNo(e.target.value)}
                style={{ width: 160 }}
              />
            </label>
            <label className="inline-field">
              <span>Their bill date</span>
              <DateInput value={billDate} onChange={setBillDate} />
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
          <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
            <button className="primary" onClick={() => void saveDetails()} disabled={busy}>
              {busy ? <Spinner /> : 'Save details'}
            </button>
            <button onClick={() => { setEditing(false); void load() }} disabled={busy}>
              Cancel
            </button>
          </div>
        </div>
      )}

      {head && (
        <div className="card card-pad no-print">
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
                {Number(head.discount_total) > 0
                  ? ` − ${fmtMoney(head.discount_total)} discount`
                  : ''}
                {Number(head.other_charges) > 0
                  ? ` + ${fmtMoney(head.other_charges)} charges`
                  : ''}
              </p>
            </div>
          </div>
          {head.remarks && <p className="sub" style={{ marginTop: 12 }}>{head.remarks}</p>}
        </div>
      )}

      <div className="card table-wrap no-print" style={{ marginTop: 12 }}>
        <table className="data">
          <thead>
            <tr>
              <th>#</th>
              <th>Product</th>
              <th className="num">Qty</th>
              <th className="num">Rate</th>
              <th className="num">Discount</th>
              <th className="num">Cost</th>
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
                <td data-label="Discount" className="num">
                  {Number(l.line_discount_amount) + Number(l.allocated_bill_discount) > 0 ? (
                    <>
                      − {fmtMoney(Number(l.line_discount_amount) +
                                  Number(l.allocated_bill_discount))}
                      {l.line_discount_pct != null && Number(l.line_discount_pct) > 0 && (
                        <>
                          <br />
                          <span className="muted" style={{ fontSize: 12 }}>
                            {fmtQty(l.line_discount_pct)}% on the line
                          </span>
                        </>
                      )}
                      {Number(l.allocated_bill_discount) > 0 && (
                        <>
                          <br />
                          <span className="muted" style={{ fontSize: 12 }}>
                            {fmtMoney(l.allocated_bill_discount)} share of the bill
                          </span>
                        </>
                      )}
                    </>
                  ) : (
                    <span className="muted">—</span>
                  )}
                </td>
                <td data-label="Cost" className="num strong">
                  {fmtMoney(l.net_amount)}
                  {Number(l.net_amount) !== Number(l.amount) && (
                    <>
                      <br />
                      <span className="muted" style={{ fontSize: 12 }}>
                        billed {fmtMoney(l.amount)}
                      </span>
                    </>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <p className="sub no-print" style={{ marginTop: 12 }}>
        <Link to="/purchases">Back to purchases</Link>
        {head?.created_by_name ? ` · entered by ${head.created_by_name}` : ''}
      </p>

      {/*
        The document, as it prints. The screen above is for reading — it shows
        the discount worked out per line, which is useful on a monitor and
        noise on a filed voucher. This is what goes in the file.
      */}
      {head && (
        <div className="print-only">
          <VoucherSheet
            kind="Purchase Voucher"
            docNo={head.doc_no}
            docDate={head.purchase_date}
            cancelled={head.status === 'CANCELLED'}
            meta={
              <>
                {head.supplier_bill_no && <div>Their bill {head.supplier_bill_no}</div>}
                {head.supplier_bill_date && <div>{fmtDate(head.supplier_bill_date)}</div>}
                {head.replaces_doc_no && <div>Corrects {head.replaces_doc_no}</div>}
              </>
            }
            partyLabel="Received from"
            partyName={head.supplier_name}
            partyLines={[head.supplier_code, head.master_name]}
            columns={[
              { header: '#' },
              { header: 'Item' },
              { header: 'Qty', align: 'right' },
              { header: 'Rate', align: 'right' },
              { header: 'Value', align: 'right' },
              { header: 'Disc', align: 'right' },
              { header: 'Cost', align: 'right' },
            ]}
            lines={lines.map((l) => ({
              key: l.id,
              cells: [
                l.line_no,
                l.product?.name ?? '',
                <>
                  {fmtQty(l.qty)}{' '}
                  {l.uom === 'PACK' ? (l.product?.pack_uom ?? 'PACK') : l.product?.base_uom}
                </>,
                fmtMoney(l.rate),
                fmtMoney(l.amount),
                Number(l.line_discount_amount) + Number(l.allocated_bill_discount) > 0
                  ? fmtMoney(
                      Number(l.line_discount_amount) + Number(l.allocated_bill_discount),
                    )
                  : '—',
                fmtMoney(l.net_amount),
              ],
            }))}
            totals={[
              { label: 'Goods', value: head.gross_total },
              ...(Number(head.line_discount_total) > 0
                ? [{ label: 'Item discounts', value: head.line_discount_total, minus: true }]
                : []),
              ...(Number(head.bill_discount_amount) > 0
                ? [{ label: 'Bill discount', value: head.bill_discount_amount, minus: true }]
                : []),
              ...(Number(head.other_charges) > 0
                ? [{ label: 'Other charges', value: head.other_charges }]
                : []),
              { label: 'Payable to supplier', value: head.net_total, grand: true },
            ]}
            remarks={head.remarks}
            foot="Goods received in good order unless noted above."
            signature="Received by"
          />
        </div>
      )}
    </>
  )
}
