import type { ReactNode } from 'react'
import { fmtMoney, fmtQty } from '../lib/format'
import { downloadXlsx } from '../lib/xlsx'
import type { CellType } from '../lib/xlsx'
import { Empty, ErrorBanner, Loading } from './ui'
import { usePrintPage, REPORT_PAGE } from '../lib/printpage'

/**
 * One definition, two outputs.
 *
 * A report's columns are declared once and used for the table on screen, the
 * Excel file and the printed page. That is deliberate: the moment the export
 * has its own column list, it starts drifting from what people saw when they
 * decided to export it.
 */

export interface ReportColumn<T> {
  header: string
  /** The value: what Excel stores and, unless `cell` says otherwise, what shows. */
  value: (row: T) => string | number | null | undefined
  /** Richer markup for the screen — a pill, a link, two lines. */
  cell?: (row: T) => ReactNode
  type?: CellType
  width?: number
  align?: 'left' | 'right'
}

export function Report<T>({
  title,
  subtitle,
  filters,
  columns,
  rows,
  loading,
  error,
  totals,
  empty,
  fileName,
  footer,
}: {
  title: string
  subtitle?: string
  filters?: ReactNode
  columns: ReportColumn<T>[]
  rows: T[] | null
  loading?: boolean
  error?: string | null
  /** Totals row, one entry per column. Blank where a total makes no sense. */
  totals?: (string | number | null)[]
  empty?: string
  /** Without the extension; the date is added. */
  fileName: string
  footer?: ReactNode
}) {
  usePrintPage(REPORT_PAGE, '10mm')
  const today = new Date().toISOString().slice(0, 10)

  const exportExcel = () => {
    if (!rows) return
    downloadXlsx(`${fileName}-${today}`, [
      {
        name: title.slice(0, 31),
        title: `${title}${subtitle ? ` — ${subtitle}` : ''}`,
        columns: columns.map((c) => ({
          header: c.header,
          value: c.value,
          type: c.type,
          width: c.width,
        })),
        rows,
        totals,
      },
    ] as never)
  }

  const show = (c: ReportColumn<T>, r: T): ReactNode => {
    if (c.cell) return c.cell(r)
    const v = c.value(r)
    if (v === null || v === undefined || v === '') return <span className="muted">—</span>
    if (c.type === 'money') return fmtMoney(v as number)
    if (c.type === 'qty') return fmtQty(v as number)
    return String(v)
  }

  return (
    <>
      <div className="page-head">
        <h1>{title}</h1>
        {subtitle && <span className="sub">{subtitle}</span>}
        <span className="no-print" style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
          <button onClick={exportExcel} disabled={!rows || rows.length === 0}>
            Excel
          </button>
          <button
            className="primary"
            onClick={() => window.print()}
            disabled={!rows || rows.length === 0}
          >
            PDF / Print
          </button>
        </span>
      </div>

      <div className="no-print">
        <ErrorBanner error={error ?? null} />
        {filters && <div className="toolbar">{filters}</div>}
      </div>

      {/* Printed only: the filters as words, so a printout says what it covers. */}
      <div className="print-only report-stamp">
        {title}
        {subtitle ? ` — ${subtitle}` : ''} · printed {new Date().toLocaleDateString('en-GB')}
      </div>

      {loading || rows === null ? (
        <Loading what="Loading" />
      ) : rows.length === 0 ? (
        <Empty title="Nothing to show">{empty ?? 'No rows match these filters.'}</Empty>
      ) : (
        <>
          <div className="card table-wrap report">
            <table className="data">
              <thead>
                <tr>
                  {columns.map((c) => (
                    <th key={c.header} className={c.align === 'right' ? 'num' : undefined}>
                      {c.header}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {rows.map((r, i) => (
                  <tr key={i}>
                    {columns.map((c, j) => (
                      <td
                        key={c.header}
                        data-label={c.header}
                        className={[
                          c.align === 'right' ? 'num' : '',
                          j === 0 ? 'primary-cell' : '',
                        ]
                          .filter(Boolean)
                          .join(' ') || undefined}
                      >
                        {show(c, r)}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
              {totals && (
                <tfoot>
                  <tr>
                    {totals.map((t, i) => (
                      <td
                        key={i}
                        data-label={columns[i]?.header}
                        className={`strong${columns[i]?.align === 'right' ? ' num' : ''}`}
                      >
                        {typeof t === 'number' ? fmtMoney(t) : (t ?? '')}
                      </td>
                    ))}
                  </tr>
                </tfoot>
              )}
            </table>
          </div>

          <p className="sub" style={{ marginTop: 12 }}>
            {rows.length} row{rows.length === 1 ? '' : 's'}
            {footer && <> · {footer}</>}
          </p>
        </>
      )}
    </>
  )
}
