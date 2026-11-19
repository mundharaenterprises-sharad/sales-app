import { useCallback, useEffect, useState } from 'react'
import { supabase, friendlyMessage } from '../lib/supabase'
import { FormSheet } from './FormSheet'
import { Banner, Spinner } from './ui'
import { fmtDate, fmtMoney, fmtQty } from '../lib/format'

/**
 * What this shop bought before, read without leaving the bill you are typing.
 *
 * Asked for on 18 November: *"Allow me to open party ledger while making a
 * bill to check previous bills and rates applied."* The question underneath it
 * is almost always the same one — **what did I charge this shop for this item
 * last time** — and answering it used to mean opening the ledger screen, which
 * means leaving the billing screen, which means losing a half-typed bill.
 *
 * So this is a sheet and not a page. It sits over the billing screen, the
 * form's state is untouched because it lives in the screen rather than in
 * here, and Escape or Close puts you back exactly where you were. Nothing in
 * this component writes anything.
 *
 * Two levels, because two questions. The list answers "what have they had and
 * what do they owe"; tapping a bill answers "at what rate", which is the one
 * he actually asked about, so the rate column is the one that is emphasised.
 *
 * **Opening balances are listed and cannot be opened.** They are bills so that
 * they can age and be settled (026), but they have no lines and never had a
 * rate, so offering to open one would be offering an empty sheet.
 */

interface BillRow {
  invoice_id: string
  doc_no: string
  invoice_date: string
  net_total: number
  outstanding: number
  status: string
  is_opening: boolean
}

interface LineRow {
  line_no: number
  uom: string
  qty: number
  pack_size: number
  rate: number
  line_discount_pct: number | null
  gross_amount: number
  effective_amount: number
  product: {
    code: string
    name: string
    base_uom: string
    pack_uom: string | null
  } | null
}

const LINE_SELECT =
  'line_no, uom, qty, pack_size, rate, line_discount_pct, gross_amount,' +
  ' effective_amount, product:product_id (code, name, base_uom, pack_uom)'

export function ShopHistory({
  partyId,
  partyName,
  onClose,
}: {
  partyId: string
  partyName: string
  onClose: () => void
}) {
  const [bills, setBills] = useState<BillRow[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  const [openBill, setOpenBill] = useState<BillRow | null>(null)
  const [lines, setLines] = useState<LineRow[] | null>(null)
  const [lineError, setLineError] = useState<string | null>(null)

  const load = useCallback(async () => {
    setError(null)
    // The last twenty-five bills. Not paged on purpose: this is a reference
    // panel somebody is reading while typing, and "every bill since go-live"
    // is not what anybody wants to scroll through at a counter. The ledger
    // screen is still there for the whole history.
    const { data, error } = await supabase
      .from('v_invoice_list')
      .select('invoice_id, doc_no, invoice_date, net_total, outstanding, status, is_opening')
      .eq('party_id', partyId)
      .order('invoice_date', { ascending: false })
      .order('doc_no', { ascending: false })
      .limit(25)

    if (error) {
      setError(friendlyMessage(error))
      setBills([])
      return
    }
    setBills((data ?? []) as BillRow[])
  }, [partyId])

  useEffect(() => {
    void load()
  }, [load])

  const openLines = useCallback(async (bill: BillRow) => {
    setOpenBill(bill)
    setLines(null)
    setLineError(null)

    const { data, error } = await supabase
      .from('sales_invoice_line')
      .select(LINE_SELECT)
      .eq('invoice_id', bill.invoice_id)
      .order('line_no')

    if (error) {
      setLineError(friendlyMessage(error))
      setLines([])
      return
    }
    setLines((data ?? []) as unknown as LineRow[])
  }, [])

  const owed = (bills ?? [])
    .filter((b) => b.status !== 'CANCELLED')
    .reduce((s, b) => s + Number(b.outstanding || 0), 0)

  return (
    <FormSheet title={openBill ? `${openBill.doc_no} — ${partyName}` : partyName} onClose={onClose}>
      {openBill === null ? (
        <>
          {error && <Banner tone="bad">{error}</Banner>}

          {bills === null ? (
            <Spinner />
          ) : bills.length === 0 ? (
            <Banner tone="info">Nothing billed to this shop yet.</Banner>
          ) : (
            <>
              <p className="muted" style={{ marginTop: 0 }}>
                Last {bills.length} bill{bills.length === 1 ? '' : 's'} · outstanding{' '}
                <strong>{fmtMoney(owed)}</strong>. Tap a bill to see the rates on it.
              </p>

              <table className="data compact">
                <thead>
                  <tr>
                    <th>Bill</th>
                    <th>Date</th>
                    <th className="num">Value</th>
                    <th className="num">Outstanding</th>
                  </tr>
                </thead>
                <tbody>
                  {bills.map((b) => (
                    <tr key={b.invoice_id}>
                      <td>
                        {b.is_opening ? (
                          <>
                            {b.doc_no} <span className="muted">· opening balance</span>
                          </>
                        ) : (
                          <button type="button" className="ghost" onClick={() => void openLines(b)}>
                            {b.doc_no}
                          </button>
                        )}
                        {b.status === 'CANCELLED' && (
                          <> <span className="pill bad">cancelled</span></>
                        )}
                      </td>
                      <td>{fmtDate(b.invoice_date)}</td>
                      <td className="num">{fmtMoney(b.net_total)}</td>
                      <td className="num">
                        {Number(b.outstanding) > 0 ? fmtMoney(b.outstanding) : '—'}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </>
          )}
        </>
      ) : (
        <>
          {lineError && <Banner tone="bad">{lineError}</Banner>}

          <p style={{ marginTop: 0 }}>
            <button type="button" className="ghost" onClick={() => setOpenBill(null)}>
              ← All bills
            </button>{' '}
            <span className="muted">
              {fmtDate(openBill.invoice_date)} · {fmtMoney(openBill.net_total)}
            </span>
          </p>

          {lines === null ? (
            <Spinner />
          ) : lines.length === 0 ? (
            <Banner tone="info">This bill has no items on it.</Banner>
          ) : (
            <table className="data compact">
              <thead>
                <tr>
                  <th>Item</th>
                  <th className="num">Quantity</th>
                  {/* The column he opened this for. */}
                  <th className="num">Rate</th>
                  <th className="num">Disc</th>
                  <th className="num">Amount</th>
                </tr>
              </thead>
              <tbody>
                {lines.map((l) => (
                  <tr key={l.line_no}>
                    <td>
                      {l.product?.name ?? '—'}
                      <div className="muted">{l.product?.code}</div>
                    </td>
                    <td className="num">
                      {fmtQty(l.qty)}{' '}
                      {l.uom === 'PACK'
                        ? (l.product?.pack_uom ?? 'PACK')
                        : (l.product?.base_uom ?? '')}
                    </td>
                    <td className="num">
                      <strong>{fmtMoney(l.rate)}</strong>
                      <div className="muted">
                        per{' '}
                        {l.uom === 'PACK'
                          ? (l.product?.pack_uom ?? 'PACK')
                          : (l.product?.base_uom ?? '')}
                      </div>
                    </td>
                    <td className="num">
                      {l.line_discount_pct ? `${Number(l.line_discount_pct)}%` : '—'}
                    </td>
                    <td className="num">{fmtMoney(l.effective_amount)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}

          <p className="muted">
            The rate is per the unit the line was billed in, which is how it was typed and
            how it printed — a carton rate and a piece rate are different numbers for the
            same goods.
          </p>
        </>
      )}
    </FormSheet>
  )
}
