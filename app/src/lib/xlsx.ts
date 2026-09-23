import { zipSync, strToU8 } from 'fflate'

/**
 * A small Excel writer.
 *
 * An .xlsx file is a zip of XML parts, and writing the handful this app needs
 * is a couple of hundred lines. The obvious library for this has open security
 * advisories and the maintained alternative drags in 23MB and its own
 * advisories; neither is worth it for "put these rows in a spreadsheet".
 *
 * What it supports, because it is all the reports need: one or more sheets, a
 * bold header row, text and number cells, money formatted to two decimals,
 * frozen headers and sensible column widths.
 */

export type CellType = 'text' | 'number' | 'money' | 'qty'

export interface Column<T> {
  header: string
  /** Pulls the value out of a row. */
  value: (row: T) => string | number | null | undefined
  type?: CellType
  width?: number
}

export interface Sheet<T> {
  name: string
  /** Printed above the table, e.g. "Ageing as at 23 Sept 2026". */
  title?: string
  columns: Column<T>[]
  rows: T[]
  /** A final bold row, for totals. */
  totals?: (string | number | null)[]
}

const esc = (s: string) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

/** A1, B1, ... Z1, AA1 */
function ref(col: number, row: number): string {
  let s = ''
  let n = col
  while (n >= 0) {
    s = String.fromCharCode((n % 26) + 65) + s
    n = Math.floor(n / 26) - 1
  }
  return `${s}${row}`
}

const STYLE = { plain: 0, bold: 1, money: 2, qty: 3, title: 4 }

function styleFor(type: CellType | undefined): number {
  if (type === 'money') return STYLE.money
  if (type === 'qty') return STYLE.qty
  return STYLE.plain
}

function cell(
  col: number,
  row: number,
  value: string | number | null | undefined,
  style: number,
): string {
  const r = ref(col, row)
  if (value === null || value === undefined || value === '') {
    return `<c r="${r}" s="${style}"/>`
  }
  if (typeof value === 'number' && Number.isFinite(value)) {
    return `<c r="${r}" s="${style}"><v>${value}</v></c>`
  }
  return `<c r="${r}" s="${style}" t="inlineStr"><is><t xml:space="preserve">${esc(
    String(value),
  )}</t></is></c>`
}

function sheetXml<T>(s: Sheet<T>): string {
  const rows: string[] = []
  let r = 1

  if (s.title) {
    rows.push(`<row r="${r}">${cell(0, r, s.title, STYLE.title)}</row>`)
    r += 1
    rows.push(`<row r="${r}"/>`) // a blank line under the title
    r += 1
  }

  const headerRow = r
  rows.push(
    `<row r="${r}">${s.columns
      .map((c, i) => cell(i, r, c.header, STYLE.bold))
      .join('')}</row>`,
  )
  r += 1

  for (const item of s.rows) {
    const cells = s.columns.map((c, i) => {
      const v = c.value(item)
      const n = typeof v === 'string' && v !== '' && c.type && c.type !== 'text' ? Number(v) : v
      return cell(i, r, typeof n === 'number' && Number.isNaN(n) ? v : n, styleFor(c.type))
    })
    rows.push(`<row r="${r}">${cells.join('')}</row>`)
    r += 1
  }

  if (s.totals) {
    const cells = s.totals.map((v, i) =>
      cell(i, r, v, typeof v === 'number' ? STYLE.money : STYLE.bold),
    )
    rows.push(`<row r="${r}">${cells.join('')}</row>`)
    r += 1
  }

  const cols = s.columns
    .map((c, i) => `<col min="${i + 1}" max="${i + 1}" width="${c.width ?? 16}" customWidth="1"/>`)
    .join('')

  // Freeze everything above the first data row, so headers stay put.
  const frozen = `<sheetViews><sheetView workbookViewId="0"><pane ySplit="${headerRow}" topLeftCell="A${
    headerRow + 1
  }" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>`

  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">${frozen}<cols>${cols}</cols><sheetData>${rows.join(
    '',
  )}</sheetData></worksheet>`
}

/** Excel refuses a sheet name with these in it, or one over 31 characters. */
const safeName = (n: string, i: number) =>
  (n.replace(/[\\/?*[\]:]/g, ' ').slice(0, 31) || `Sheet${i + 1}`)

export function buildXlsx(sheets: Sheet<never>[]): Uint8Array {
  const names = sheets.map((s, i) => safeName(s.name, i))

  const files: Record<string, Uint8Array> = {
    '[Content_Types].xml': strToU8(
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
${names
  .map(
    (_, i) =>
      `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`,
  )
  .join('')}
</Types>`,
    ),

    '_rels/.rels': strToU8(
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>`,
    ),

    'xl/workbook.xml': strToU8(
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>${names
        .map((n, i) => `<sheet name="${esc(n)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`)
        .join('')}</sheets></workbook>`,
    ),

    'xl/_rels/workbook.xml.rels': strToU8(
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${names
        .map(
          (_, i) =>
            `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${
              i + 1
            }.xml"/>`,
        )
        .join('')}<Relationship Id="rId${
        names.length + 1
      }" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>`,
    ),

    // Five styles: plain, bold, money, quantity, title.
    'xl/styles.xml': strToU8(
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<numFmts count="2"><numFmt numFmtId="164" formatCode="#,##0.00"/><numFmt numFmtId="165" formatCode="#,##0.###"/></numFmts>
<fonts count="3"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="13"/><name val="Calibri"/></font></fonts>
<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="5">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>
</cellXfs>
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>`,
    ),
  }

  sheets.forEach((s, i) => {
    files[`xl/worksheets/sheet${i + 1}.xml`] = strToU8(sheetXml(s))
  })

  return zipSync(files, { level: 6 })
}

/** Builds the workbook and hands it to the browser as a download. */
export function downloadXlsx(filename: string, sheets: Sheet<never>[]): void {
  const data = buildXlsx(sheets)
  const blob = new Blob([data as unknown as BlobPart], {
    type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename.endsWith('.xlsx') ? filename : `${filename}.xlsx`
  document.body.appendChild(a)
  a.click()
  a.remove()
  // Give the download a moment before the blob goes away.
  setTimeout(() => URL.revokeObjectURL(url), 5000)
}
