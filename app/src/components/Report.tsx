import type { ReactNode } from 'react'
import { fmtMoney, fmtQty, isoDate } from '../lib/format'
import { downloadXlsx } from '../lib/xlsx'
import type { CellType } from '../lib/xlsx'
import { Empty, ErrorBanner, Loading } from './ui'
import type { Sheet } from '../lib/xlsx'
import { useReportPage, useDocumentTitle } from '../lib/printpage'

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
  /**
   * Where this column goes when the screen is too narrow for a table.
   *
   * A row becomes two lines on a phone: `title` and `lead` face each other on
   * the first, `meta` columns run along the second, `hide` is left out
   * entirely — still in the Excel file and on the printed page, just not worth
   * the width here.
   *
   * Left unset, the first column is the title, the last money column is the
   * lead, and everything else is meta. That is right often enough that most
   * reports never have to say.
   */
  mobile?: 'title' | 'lead' | 'meta' | 'hide'
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
  extraSheets,
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
  /**
   * More sheets for the Excel file, built when the button is pressed.
   *
   * A function rather than a value so the work — grouping, totalling — only
   * happens on download, and so the sheet is built from whatever is on screen
   * at that moment rather than from whatever it was when the page rendered.
   */
  extraSheets?: () => Sheet<never>[]
}) {
  useReportPage()
  // A report's printed header is expected, so make it say what the report is.
  useDocumentTitle(title)
  const today = isoDate()

  /**
   * Which of the two phone lines each column lands on.
   *
   * The last money column is the lead, because that is the figure a report is
   * usually read for and it belongs beside the name rather than four lines
   * below it. A column can say for itself and override all of this.
   */
  const lastMoney = columns.reduce(
    (best, c, i) => (c.type === 'money' ? i : best), -1)

  const roleOf = (c: ReportColumn<T>, i: number) =>
    c.mobile ?? (i === 0 ? 'title' : i === lastMoney ? 'lead' : 'meta')

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
      ...(extraSheets?.() ?? []),
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
            <table className="data compact">
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
                          `m-${roleOf(c, j)}`,
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
                        className={[
                          'strong',
                          columns[i]?.align === 'right' ? 'num' : '',
                          columns[i] ? `m-${roleOf(columns[i], i)}` : 'm-meta',
                        ].filter(Boolean).join(' ')}
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
