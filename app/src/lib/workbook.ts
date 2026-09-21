// The package publishes only subpath exports; there is no root entry.
import readXlsxFile from 'read-excel-file/browser'

/**
 * Turning the master data workbook into rows the importer understands.
 *
 * The header row is the contract: those cell values are the exact field names
 * public.import_masters expects. Everything is read as text, because the
 * database does the validating and a cell reading "12,500" should come back as
 * that string so the error can say so, rather than arriving as a silent NaN.
 */

export type Entity = 'route' | 'product_group' | 'supplier' | 'party' | 'product'

export interface EntitySpec {
  entity: Entity
  label: string
  /** Entities must be imported in this order: later ones reference earlier. */
  order: number
  /** What a sheet name has to contain to be recognised as this entity. */
  match: string[]
  needs?: string
}

export const ENTITIES: EntitySpec[] = [
  { entity: 'route',         label: 'Routes',         order: 1, match: ['route'] },
  { entity: 'product_group', label: 'Product Groups', order: 2, match: ['productgroup', 'group'] },
  { entity: 'supplier',      label: 'Suppliers',      order: 3, match: ['supplier'] },
  { entity: 'party',         label: 'Parties',        order: 4, match: ['party', 'parties', 'customer'],
    needs: 'Routes' },
  { entity: 'product',       label: 'Products',       order: 5, match: ['product'],
    needs: 'Product Groups' },
]

export interface ParsedSheet {
  entity: Entity
  label: string
  sheetName: string
  /** One object per data row, every value a trimmed string. */
  rows: Record<string, string>[]
  /** Header cells that are not fields the importer knows about. */
  unknownColumns: string[]
}

export interface ParseResult {
  sheets: ParsedSheet[]
  /** Sheets in the file that did not look like any entity. */
  ignored: string[]
}

function normalise(s: string): string {
  return s.toLowerCase().replace(/[^a-z]/g, '')
}

/**
 * "4. Parties" -> party. "Products" -> product.
 *
 * Product Groups is checked before Products, because "productgroups" contains
 * "product" and would otherwise match the wrong entity.
 */
function entityForSheet(sheetName: string): EntitySpec | null {
  const n = normalise(sheetName)
  const byLongestMatch = [...ENTITIES].sort(
    (a, b) => Math.max(...b.match.map((m) => m.length)) - Math.max(...a.match.map((m) => m.length)),
  )
  for (const spec of byLongestMatch) {
    if (spec.match.some((m) => n.includes(m))) return spec
  }
  return null
}

/** Every field name the importer accepts, per entity. */
const FIELDS: Record<Entity, string[]> = {
  route: ['code', 'name'],
  product_group: ['code', 'name'],
  supplier: ['code', 'name', 'contact_person', 'phone', 'address', 'city'],
  party: [
    'code', 'name', 'route_code', 'contact_person', 'phone', 'whatsapp_phone',
    'address', 'city', 'credit_limit', 'credit_days',
    'opening_balance', 'opening_balance_date',
  ],
  product: [
    'code', 'name', 'group_code', 'base_uom', 'pack_uom', 'pack_size',
    // *_price: per pack when the row has a pack unit, else per base unit.
    'sale_price', 'purchase_price', 'opening_qty', 'opening_price', 'opening_date',
    // Older template columns, always per base unit. Still accepted.
    'sale_rate', 'purchase_rate', 'opening_rate',
  ],
}

/**
 * Excel hands back a Date for a cell it decided was a date, whatever the column
 * was formatted as. Render it as YYYY-MM-DD, which is what the importer parses,
 * rather than letting toString() produce "Wed Apr 01 2026 ...".
 */
function cellToText(v: unknown): string {
  if (v === null || v === undefined) return ''
  if (v instanceof Date) {
    const y = v.getFullYear()
    const m = String(v.getMonth() + 1).padStart(2, '0')
    const d = String(v.getDate()).padStart(2, '0')
    return `${y}-${m}-${d}`
  }
  if (typeof v === 'number') {
    // Avoid 1e+21 and other exponent forms reaching the database as text.
    return Number.isInteger(v) ? String(v) : String(v)
  }
  return String(v).trim()
}

export async function parseWorkbook(file: File): Promise<ParseResult> {
  // One call returns every sheet with its name and contents.
  const all = await readXlsxFile(file)

  const sheets: ParsedSheet[] = []
  const ignored: string[] = []

  for (const { sheet: sheetName, data } of all) {
    const spec = entityForSheet(sheetName)
    if (!spec) {
      ignored.push(sheetName)
      continue
    }

    const grid = data as unknown[][]
    if (grid.length === 0) {
      ignored.push(sheetName)
      continue
    }

    const header = grid[0].map((c) => cellToText(c))
    const known = FIELDS[spec.entity]

    const unknownColumns = header.filter(
      (h) => h !== '' && !known.includes(h) && !h.startsWith('('),
    )

    const rows: Record<string, string>[] = []
    for (let i = 1; i < grid.length; i++) {
      const row: Record<string, string> = {}
      let hasAnything = false

      header.forEach((h, col) => {
        if (!known.includes(h)) return
        const text = cellToText(grid[i][col])
        row[h] = text
        if (text !== '') hasAnything = true
      })

      // A blank row in the middle of a sheet is spacing, not data. Trailing
      // blank rows are what Excel leaves behind after someone deletes content.
      if (hasAnything) rows.push(row)
    }

    sheets.push({
      entity: spec.entity,
      label: spec.label,
      sheetName,
      rows,
      unknownColumns,
    })
  }

  sheets.sort((a, b) => {
    const oa = ENTITIES.find((e) => e.entity === a.entity)!.order
    const ob = ENTITIES.find((e) => e.entity === b.entity)!.order
    return oa - ob
  })

  return { sheets, ignored }
}

/** The report shape public.import_masters returns. */
export interface ImportReport {
  entity: string
  rows: number
  errors: number
  error_detail: { row: number; field: string; value: string; message: string }[]
  dry_run: boolean
  imported: number
  skipped: number
  skipped_detail: { row: number; code: string }[]
  already_exists: number
  would_import?: number
  note?: string
}
