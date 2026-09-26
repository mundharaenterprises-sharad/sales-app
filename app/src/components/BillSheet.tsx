import { fmtDate, fmtMoney, fmtQty } from '../lib/format'

/**
 * One bill, as it prints.
 *
 * Used by the single bill screen and by batch printing, so a bill printed in a
 * run of fifteen is the same document as one printed on its own.
 */

export interface BillLineRow {
  id: string
  line_no: number
  uom: 'BASE' | 'PACK'
  qty: number
  pack_size: number
  rate: number
  qty_base: number
  line_discount_pct: number | null
  line_discount_amount: number
  gross_amount: number
  net_amount: number
  qty_cancelled_base: number
  product: { code: string; name: string; base_uom: string; pack_uom: string | null }
}

export interface Bill {
  id: string
  doc_no: string
  invoice_date: string
  gross_total: number
  line_discount_total: number
  bill_discount_amount: number
  round_off: number
  net_total: number
  cancelled_value: number
  effective_total: number
  status: string
  remarks: string | null
  party: {
    code: string
    name: string
    address: string | null
    city: string | null
    phone: string | null
    route: { name: string } | null
  }
  order: { doc_no: string } | null
  lines: BillLineRow[]
}

/** Everything a bill needs, in one query, so both screens fetch it the same way. */
export const BILL_SELECT =
  '*, party:party_id (code, name, address, city, phone, route:route_id (name)),' +
  ' order:order_id (doc_no),' +
  ' lines:sales_invoice_line (*, product:product_id (code, name, base_uom, pack_uom))'

export function BillSheet({
  bill,
  pageBreak = false,
}: {
  bill: Bill
  /** In a batch, every bill starts a new sheet of paper. */
  pageBreak?: boolean
}) {
  const lines = [...(bill.lines ?? [])].sort((a, b) => a.line_no - b.line_no)

  return (
    <div className={`sheet-a5${pageBreak ? ' page-break' : ''}`}>
      <div className="bill-head">
        <div>
          {/*
            The firm's name is deliberately not on this document, by Sharad's
            instruction. What the paper has to say is what kind of paper it is,
            so that is what stands at the top of it.
          */}
          <div className="bill-business">Estimate Bill</div>
        </div>
        <div className="bill-meta">
          {bill.status === 'CANCELLED' && (
            <div className="bill-cancelled">CANCELLED</div>
          )}
          <div><strong>{bill.doc_no}</strong></div>
          <div>{fmtDate(bill.invoice_date)}</div>
          {bill.order && <div>Order {bill.order.doc_no}</div>}
        </div>
      </div>

      <div className="bill-party">
        <div className="muted">Billed to</div>
        <div className="strong">{bill.party.name}</div>
        {bill.party.route && <div>{bill.party.route.name}</div>}
        {(bill.party.address || bill.party.city) && (
          <div>{[bill.party.address, bill.party.city].filter(Boolean).join(', ')}</div>
        )}
        {bill.party.phone && <div>{bill.party.phone}</div>}
      </div>

      <table className="bill-lines">
        <thead>
          <tr>
            <th>#</th>
            <th>Item</th>
            <th className="num">Qty</th>
            <th className="num">Rate</th>
            <th className="num">Value</th>
            <th className="num">Disc</th>
            <th className="num">Amount</th>
          </tr>
        </thead>
        <tbody>
          {lines.map((l) => (
            <tr key={l.id}>
              <td>{l.line_no}</td>
              <td>{l.product.name}</td>
              <td className="num">
                {fmtQty(l.qty)} {l.uom === 'PACK' ? l.product.pack_uom : l.product.base_uom}
              </td>
              <td className="num">{fmtMoney(l.rate)}</td>
              <td className="num">{fmtMoney(l.gross_amount)}</td>
              <td className="num">
                {Number(l.line_discount_amount) > 0 ? (
                  <>
                    {fmtMoney(l.line_discount_amount)}
                    {l.line_discount_pct ? (
                      <span className="muted small"> ({fmtQty(l.line_discount_pct)}%)</span>
                    ) : null}
                  </>
                ) : (
                  '—'
                )}
              </td>
              <td className="num">{fmtMoney(l.net_amount)}</td>
            </tr>
          ))}
        </tbody>
      </table>

      <div className="bill-totals">
        <div><span>Items</span><span>{fmtMoney(bill.gross_total)}</span></div>
        {Number(bill.line_discount_total) > 0 && (
          <div><span>Item discounts</span><span>− {fmtMoney(bill.line_discount_total)}</span></div>
        )}
        {Number(bill.bill_discount_amount) > 0 && (
          <div><span>Bill discount</span><span>− {fmtMoney(bill.bill_discount_amount)}</span></div>
        )}
        {Number(bill.round_off) !== 0 && (
          <div><span>Rounding</span><span>{fmtMoney(bill.round_off)}</span></div>
        )}
        <div className="grand"><span>Net payable</span><span>{fmtMoney(bill.net_total)}</span></div>
        {Number(bill.cancelled_value) > 0 && (
          <>
            <div><span>Cancelled</span><span>− {fmtMoney(bill.cancelled_value)}</span></div>
            <div className="grand"><span>Now payable</span><span>{fmtMoney(bill.effective_total)}</span></div>
          </>
        )}
      </div>

      {bill.remarks && <div className="bill-remarks">{bill.remarks}</div>}

      <div className="bill-foot">
        <div>Goods once sold are not taken back without agreement.</div>
        <div className="sign">Authorised signature</div>
      </div>
    </div>
  )
}
