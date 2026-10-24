import type { ReactNode } from 'react'
import { fmtDate, fmtMoney } from '../lib/format'

/**
 * Everything that is not a sales bill, as it prints.
 *
 * A purchase, a goods return and a payment receipt are three different
 * documents, but on paper they are the same shape: what kind of paper this is,
 * a number and a date, who it is with, a few lines, what it comes to, and
 * somewhere to sign. So they share one sheet rather than three that drift
 * apart — the same reason `BillSheet` is shared between the single bill and a
 * batch print.
 *
 * It deliberately reuses the bill's own classes (`sheet-a5`, `bill-head`,
 * `bill-lines`, `bill-totals`, …) rather than inventing a second set. That
 * inherits every print problem already solved in `lib/printpage.ts`: A5
 * portrait, no page margin so Chrome prints no header of its own, and the
 * white border on the SHEET so a second page is not printed into the paper's
 * edge. A new stylesheet would have had to learn all three again.
 *
 * **No firm name on any of them**, which he confirmed. Bills have never
 * carried one, and the same goes for these. What stands at the top is what
 * kind of document it is, which is the thing somebody holding it needs to
 * know.
 */

export interface VoucherLine {
  key: string
  cells: ReactNode[]
}

export interface VoucherColumn {
  header: string
  align?: 'left' | 'right'
}

export interface VoucherTotal {
  label: string
  value: number | string
  /** The one figure the document is about. */
  grand?: boolean
  /** A deduction, shown with a minus. */
  minus?: boolean
}

export function VoucherSheet({
  kind,
  docNo,
  docDate,
  cancelled,
  stamp,
  meta,
  partyLabel,
  partyName,
  partyLines,
  columns,
  lines,
  emptyLines,
  totals,
  remarks,
  foot,
  signature = 'Authorised signature',
  pageBreak = false,
}: {
  /** What stands at the top: "Purchase Voucher", "Receipt", … */
  kind: string
  docNo: string
  docDate: string
  cancelled?: boolean
  /** A short mark beside the number, such as the payment mode. */
  stamp?: string
  /** Extra lines under the date — a supplier's own bill number, say. */
  meta?: ReactNode
  partyLabel: string
  partyName: string
  partyLines?: (string | null | undefined)[]
  columns?: VoucherColumn[]
  lines?: VoucherLine[]
  /** Shown in place of the table when there is nothing to list. */
  emptyLines?: string
  totals: VoucherTotal[]
  remarks?: string | null
  /** The sentence along the bottom. Different on every document. */
  foot: string
  signature?: string
  pageBreak?: boolean
}) {
  const shown = (partyLines ?? []).filter(Boolean) as string[]

  return (
    <div className={`sheet-a5${pageBreak ? ' page-break' : ''}`}>
      <div className="bill-head">
        <div>
          <div className="bill-business">{kind}</div>
        </div>
        <div className="bill-meta">
          {cancelled && <div className="bill-cancelled">CANCELLED</div>}
          {stamp && !cancelled && <div className="bill-paid">{stamp}</div>}
          <div><strong>{docNo}</strong></div>
          <div>{fmtDate(docDate)}</div>
          {meta}
        </div>
      </div>

      <div className="bill-party">
        <div className="muted">{partyLabel}</div>
        <div className="strong">{partyName}</div>
        {shown.map((l, i) => <div key={i}>{l}</div>)}
      </div>

      {columns && lines && lines.length > 0 ? (
        <table className="bill-lines">
          <thead>
            <tr>
              {columns.map((c, i) => (
                <th key={i} className={c.align === 'right' ? 'num' : undefined}>
                  {c.header}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {lines.map((l) => (
              <tr key={l.key}>
                {l.cells.map((cell, i) => (
                  <td key={i} className={columns[i]?.align === 'right' ? 'num' : undefined}>
                    {cell}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      ) : emptyLines ? (
        <p className="bill-remarks">{emptyLines}</p>
      ) : null}

      <div className="bill-totals">
        {totals.map((t, i) => (
          <div key={i} className={t.grand ? 'grand' : undefined}>
            <span>{t.label}</span>
            <span>
              {t.minus ? '− ' : ''}
              {typeof t.value === 'number' ? fmtMoney(t.value) : t.value}
            </span>
          </div>
        ))}
      </div>

      {remarks && <div className="bill-remarks">{remarks}</div>}

      <div className="bill-foot">
        <div>{foot}</div>
        <div className="sign">{signature}</div>
      </div>
    </div>
  )
}
