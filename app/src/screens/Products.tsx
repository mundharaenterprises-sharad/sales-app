import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase, friendlyMessage } from '../lib/supabase'
import { getSnapshot, putSnapshot } from '../lib/cache'
import { useOnline, useSession } from '../lib/session'
import { fmtAge, fmtDate, fmtMoney, fmtQty } from '../lib/format'
import { Banner, Empty, ErrorBanner, Loading } from '../components/ui'
import { Check, Field, FormSheet, Row, num, text } from '../components/FormSheet'
import { CodeNameSheet } from '../components/CodeNameSheet'
import { useListKeys } from '../lib/listkeys'

interface ProductRow {
  id: string
  code: string
  name: string
  group_id: string
  group_code: string
  group_name: string
  master_name: string | null
  base_uom: string
  pack_uom: string | null
  pack_size: number
  sale_rate: number
  purchase_rate: number
  pack_sale_rate: number | null
  pack_purchase_rate: number | null
  opening_qty: number
  opening_rate: number
  opening_date: string | null
  is_active: boolean
  opening_locked: boolean
}

interface GroupRow {
  id: string
  code: string
  name: string
  is_active: boolean
  /** Parle, Current or Others — a product inherits it through its group. */
  master: { code: string; name: string } | null
}

const CACHE_KEY = 'products'

/** Price of one pack: as entered if it was, otherwise unit rate x size. */
function packPrice(unit: number, entered: number | null, size: number): number {
  return entered != null ? Number(entered) : Math.round(Number(unit) * Number(size) * 100) / 100
}

export default function Products() {
  const { user } = useSession()
  const online = useOnline()
  const isAdmin = user?.role === 'ADMIN'
  // Cost prices are for the office. Reps see selling prices only.
  const seesCost = user?.role === 'ADMIN' || user?.role === 'ACCOUNTS'

  const [rows, setRows] = useState<ProductRow[] | null>(null)
  const [groups, setGroups] = useState<GroupRow[]>([])
  const [fetchedAt, setFetchedAt] = useState<number | null>(null)
  const [fromCache, setFromCache] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const [q, setQ] = useState('')
  const [group, setGroup] = useState('')
  const [showInactive, setShowInactive] = useState(false)

  const [editing, setEditing] = useState<ProductRow | 'new' | null>(null)
  const [managingGroups, setManagingGroups] = useState(false)
  const [managingMasters, setManagingMasters] = useState(false)

  const load = useCallback(async () => {
    setError(null)
    const [p, g] = await Promise.all([
      supabase.from('v_product_master').select('*').order('name'),
      supabase
        .from('product_group')
        .select('id, code, name, is_active, master:master_group_id (code, name)')
        .order('name'),
    ])
    if (p.error || g.error) {
      setError(friendlyMessage(p.error ?? g.error))
      return
    }
    const list = (p.data ?? []) as ProductRow[]
    setRows(list)
    setGroups((g.data ?? []) as unknown as GroupRow[])
    setFetchedAt(Date.now())
    setFromCache(false)
    void putSnapshot(CACHE_KEY, list)
  }, [])

  useEffect(() => {
    let alive = true
    async function start() {
      const snap = await getSnapshot<ProductRow[]>(CACHE_KEY)
      if (alive && snap) {
        setRows(snap.data)
        setFetchedAt(snap.fetchedAt)
        setFromCache(true)
      }
      if (navigator.onLine) await load()
      else if (alive && !snap) {
        setRows([])
        setError('You are offline and this device has no saved product list yet.')
      }
    }
    void start()
    return () => {
      alive = false
    }
  }, [load])

  const groupNames = useMemo(() => {
    if (!rows) return []
    return Array.from(new Set(rows.map((r) => r.group_name))).sort()
  }, [rows])

  const filtered = useMemo(() => {
    if (!rows) return []
    const words = q.trim().toLowerCase().split(/\s+/).filter(Boolean)
    return rows.filter((r) => {
      if (!showInactive && !r.is_active) return false
      if (group && r.group_name !== group) return false
      if (words.length === 0) return true
      const hay = `${r.name} ${r.code} ${r.group_name} ${r.master_name ?? ''}`.toLowerCase()
      return words.every((w) => hay.includes(w))
    })
  }, [rows, q, group, showInactive])

  const { rowProps } = useListKeys<ProductRow>({
    items: filtered,
    onOpen: (r) => setEditing(r),
    enabled: !editing && !managingGroups && !managingMasters,
  })

  if (rows === null) return <Loading what="Loading products" />

  return (
    <>
      <div className="page-head">
        <h1>Products</h1>
        <span className="sub">
          {fetchedAt && fromCache && `Saved on this device ${fmtAge(fetchedAt)}`}
        </span>
        {isAdmin && (
          <span style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
            <button onClick={() => setManagingMasters(true)} disabled={!online}>
              Master groups
            </button>
            <button onClick={() => setManagingGroups(true)} disabled={!online}>Groups</button>
            <button className="primary" onClick={() => setEditing('new')} disabled={!online}>
              Add product
            </button>
          </span>
        )}
      </div>

      <ErrorBanner error={error} />

      <div className="toolbar">
        <span className="grow">
          <label className="sr-only" htmlFor="product-search">Search products</label>
          <input
            id="product-search"
            type="search"
            autoComplete="off"
            placeholder="Search by name, code or group"
            value={q}
            onChange={(e) => setQ(e.target.value)}
          />
        </span>
        <select value={group} onChange={(e) => setGroup(e.target.value)} aria-label="Filter by group">
          <option value="">All groups</option>
          {groupNames.map((g) => (
            <option key={g} value={g}>{g}</option>
          ))}
        </select>
        <Check id="product-inactive" checked={showInactive} onChange={setShowInactive}>
          Show switched off
        </Check>
      </div>

      {filtered.length === 0 ? (
        <Empty title="Nothing to show">
          {rows.length === 0
            ? 'No products yet. Import them from the workbook, or add one here.'
            : 'No product matches that search.'}
        </Empty>
      ) : (
        <>
          <div className="card table-wrap">
            <table className="data">
              <thead>
                <tr>
                  <th>Product</th>
                  <th>Group</th>
                  <th>Master group</th>
                  <th>Pack</th>
                  <th className="num">Sale price</th>
                  {seesCost && <th className="num">Cost</th>}
                </tr>
              </thead>
              <tbody>
                {filtered.map((r, i) => (
                  <tr
                    key={r.id}
                    {...rowProps(i)}
                    className={`clickable${r.is_active ? '' : ' inactive'}${
                      rowProps(i).className ? ' ' + rowProps(i).className : ''
                    }`}
                    onClick={() => setEditing(r)}
                  >
                    <td className="primary-cell">
                      <span className="strong">{r.name}</span>
                      {!r.is_active && <> <span className="pill flat">Off</span></>}
                      <br />
                      <span className="muted" style={{ fontSize: 12.5 }}>{r.code}</span>
                    </td>
                    <td data-label="Group" className="muted">{r.group_name}</td>
                    <td data-label="Master group" className="muted">
                      {r.master_name ?? '—'}
                    </td>
                    <td data-label="Pack" className="muted">
                      {r.pack_uom ? `1 ${r.pack_uom} = ${fmtQty(r.pack_size)} ${r.base_uom}` : `Loose, per ${r.base_uom}`}
                    </td>
                    <td data-label="Sale price" className="num">
                      {r.pack_uom ? (
                        <>
                          {fmtMoney(packPrice(r.sale_rate, r.pack_sale_rate, r.pack_size))} / {r.pack_uom}
                          <br />
                          <span className="muted" style={{ fontSize: 12 }}>
                            {fmtMoney(r.sale_rate)} / {r.base_uom}
                          </span>
                        </>
                      ) : (
                        <>{fmtMoney(r.sale_rate)} / {r.base_uom}</>
                      )}
                    </td>
                    {seesCost && (
                      <td data-label="Cost" className="num">
                        {r.pack_uom
                          ? <>{fmtMoney(packPrice(r.purchase_rate, r.pack_purchase_rate, r.pack_size))} / {r.pack_uom}</>
                          : <>{fmtMoney(r.purchase_rate)} / {r.base_uom}</>}
                      </td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className="sub" style={{ marginTop: 12 }}>
            {filtered.length} product{filtered.length === 1 ? '' : 's'}
          </p>
        </>
      )}

      {editing && (
        <ProductForm
          product={editing === 'new' ? null : editing}
          groups={groups}
          canEdit={isAdmin && online}
          seesCost={seesCost}
          onClose={() => setEditing(null)}
          onSaved={() => {
            setEditing(null)
            void load()
          }}
        />
      )}

      {managingGroups && (
        <CodeNameSheet
          table="product_group"
          title="Product groups"
          noun="group"
          onClose={() => setManagingGroups(false)}
          onChanged={() => void load()}
        />
      )}

      {managingMasters && (
        <CodeNameSheet
          table="master_group"
          title="Master groups"
          noun="master group"
          onClose={() => setManagingMasters(false)}
          onChanged={() => void load()}
        />
      )}
    </>
  )
}

function ProductForm({
  product,
  groups,
  canEdit,
  seesCost,
  onClose,
  onSaved,
}: {
  product: ProductRow | null
  groups: GroupRow[]
  canEdit: boolean
  seesCost: boolean
  onClose: () => void
  onSaved: () => void
}) {
  const isNew = product === null
  const p = product
  const hadPack = !!p?.pack_uom

  const [f, setF] = useState({
    code: p?.code ?? '',
    name: p?.name ?? '',
    group_id: p?.group_id ?? '',
    base_uom: p?.base_uom ?? 'PCS',
    pack_uom: p?.pack_uom ?? '',
    pack_size: p && hadPack ? String(Number(p.pack_size)) : '',
    // Prices are shown the way they are entered: per pack if there is one.
    sale: p
      ? String(hadPack ? packPrice(p.sale_rate, p.pack_sale_rate, p.pack_size) : Number(p.sale_rate))
      : '',
    purchase: p
      ? String(hadPack ? packPrice(p.purchase_rate, p.pack_purchase_rate, p.pack_size) : Number(p.purchase_rate))
      : '',
    opening_qty: p && Number(p.opening_qty) > 0 ? String(Number(p.opening_qty)) : '',
    opening_price: p && Number(p.opening_rate) > 0
      ? String(hadPack ? Math.round(Number(p.opening_rate) * Number(p.pack_size) * 100) / 100 : Number(p.opening_rate))
      : '',
    opening_date: p?.opening_date ?? '',
    is_active: p?.is_active ?? true,
  })
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const set = <K extends keyof typeof f>(k: K, v: (typeof f)[K]) => setF((x) => ({ ...x, [k]: v }))
  const locked = p?.opening_locked ?? false
  const ro = !canEdit

  const hasPack = f.pack_uom.trim() !== ''
  const size = num(f.pack_size, NaN)
  const baseUom = f.base_uom.trim().toUpperCase() || 'unit'
  const packUom = f.pack_uom.trim().toUpperCase()
  const per = hasPack ? packUom : baseUom

  /** "= 20.8333 per PCS", shown under a pack price as it is typed. */
  function perUnit(s: string): string | null {
    const v = num(s, NaN)
    if (!hasPack || Number.isNaN(v) || Number.isNaN(size) || size <= 1 || s.trim() === '') return null
    return `= ${(Math.round((v / size) * 10000) / 10000).toLocaleString('en-IN', { maximumFractionDigits: 4 })} per ${baseUom}`
  }

  const groupOptions = groups.filter((g) => g.is_active || g.id === p?.group_id)

  /** The master group the chosen product group belongs to, for the hint. */
  const chosenMaster =
    groups.find((g) => g.id === f.group_id)?.master?.name ?? null

  async function save() {
    setError(null)
    const problems: string[] = []
    if (isNew && !text(f.code)) problems.push('a code')
    if (!text(f.name)) problems.push('a name')
    if (!f.group_id) problems.push('a group')
    if (!text(f.base_uom)) problems.push('a base unit')
    if (problems.length) {
      setError(`Please give ${problems.join(', ')}.`)
      return
    }
    if (hasPack && (Number.isNaN(size) || size <= 1)) {
      setError(`How many ${baseUom} are in one ${packUom}? Pack size must be a number above 1.`)
      return
    }

    const sale = num(f.sale)
    const purchase = num(f.purchase)
    const oqty = num(f.opening_qty)
    const oprice = num(f.opening_price)
    for (const [label, v] of [
      ['Sale price', sale], ['Purchase price', purchase],
      ['Opening quantity', oqty], ['Opening price', oprice],
    ] as const) {
      if (Number.isNaN(v) || v < 0) {
        setError(`${label} must be a plain number, 0 or more — no commas.`)
        return
      }
    }
    if (!locked && oqty > 0 && !f.opening_date) {
      setError('Opening stock needs a date.')
      return
    }

    const row: Record<string, unknown> = {
      name: text(f.name),
      group_id: f.group_id,
      base_uom: baseUom,
      is_active: f.is_active,
    }

    if (hasPack) {
      // Send only the pack prices. The database works out the per-unit rate
      // from them. Sending both would make it think the unit rate was edited
      // on its own.
      row.pack_uom = packUom
      row.pack_size = size
      row.pack_sale_rate = sale
      if (seesCost) row.pack_purchase_rate = purchase
    } else {
      row.pack_uom = null
      row.pack_size = 1
      row.pack_sale_rate = null
      row.pack_purchase_rate = null
      row.sale_rate = sale
      if (seesCost) row.purchase_rate = purchase
    }

    if (!locked) {
      row.opening_qty = oqty
      row.opening_rate = hasPack ? Math.round((oprice / size) * 10000) / 10000 : oprice
      row.opening_date = oqty > 0 ? f.opening_date : null
    }

    setBusy(true)
    const { error } = isNew
      ? await supabase.from('product').insert({ ...row, code: text(f.code) })
      : await supabase.from('product').update(row).eq('id', p!.id)
    setBusy(false)

    if (error) {
      setError(friendlyMessage(error))
      return
    }
    onSaved()
  }

  const oqtyNum = num(f.opening_qty, NaN)

  return (
    <FormSheet
      title={!p ? 'Add product' : ro ? p.name : `Edit ${p.name}`}
      onClose={onClose}
      onSubmit={ro ? undefined : () => void save()}
      busy={busy}
      error={error}
      submitLabel={isNew ? 'Add product' : 'Save'}
    >
      <Row>
        <Field label="Code" htmlFor="pr-code" hint={isNew ? 'Short and unique, e.g. P210. Cannot be changed later.' : 'Codes cannot be changed.'}>
          <input id="pr-code" type="text" value={f.code} disabled={!isNew || ro}
                 onChange={(e) => set('code', e.target.value)} />
        </Field>
        <Field
          label="Group"
          htmlFor="pr-group"
          hint={
            chosenMaster
              ? `A ${chosenMaster} product — that follows the group, so there is nothing else to pick.`
              : 'Parle or Current follows from the group you choose here.'
          }
        >
          <select id="pr-group" value={f.group_id} disabled={ro}
                  onChange={(e) => set('group_id', e.target.value)}>
            <option value="">Choose a group</option>
            {groupOptions.map((g) => (
              <option key={g.id} value={g.id}>
                {g.name} ({g.code}){g.master ? ` · ${g.master.name}` : ''}
              </option>
            ))}
          </select>
        </Field>
      </Row>

      <Field label="Name" htmlFor="pr-name" hint="As it should print on the bill.">
        <input id="pr-name" type="text" value={f.name} disabled={ro}
               onChange={(e) => set('name', e.target.value)} />
      </Field>

      <div className="form-section">Units</div>
      <Row>
        <Field label="Base unit" htmlFor="pr-base" hint="The unit stock is counted in, e.g. PCS, KG.">
          <input id="pr-base" type="text" value={f.base_uom} disabled={ro}
                 onChange={(e) => set('base_uom', e.target.value)} />
        </Field>
        <Field label="Pack unit" htmlFor="pr-pack" hint="e.g. BOX. Blank if only sold loose.">
          <input id="pr-pack" type="text" value={f.pack_uom} disabled={ro}
                 onChange={(e) => set('pack_uom', e.target.value)} />
        </Field>
      </Row>
      {hasPack && (
        <Field label={`${baseUom} in one ${packUom}`} htmlFor="pr-size">
          <input id="pr-size" type="text" inputMode="decimal" value={f.pack_size} disabled={ro}
                 onChange={(e) => set('pack_size', e.target.value)} />
        </Field>
      )}
      {p && hadPack && hasPack && Number(p.pack_size) !== size && !Number.isNaN(size) && (
        <Banner tone="warn">
          Changing the pack size affects new orders and bills only. Past ones keep
          the size they were made with.
        </Banner>
      )}

      <div className="form-section">Prices</div>
      <Row>
        <Field label={`Sale price per ${per}`} htmlFor="pr-sale" hint={perUnit(f.sale) ?? 'Default on each bill. Can be changed per bill.'}>
          <input id="pr-sale" type="text" inputMode="decimal" value={f.sale} disabled={ro}
                 onChange={(e) => set('sale', e.target.value)} />
        </Field>
        {seesCost && (
          <Field label={`Purchase price per ${per}`} htmlFor="pr-purchase" hint={perUnit(f.purchase) ?? 'Your cost. Used for margin reports.'}>
            <input id="pr-purchase" type="text" inputMode="decimal" value={f.purchase} disabled={ro}
                   onChange={(e) => set('purchase', e.target.value)} />
          </Field>
        )}
      </Row>

      {seesCost && (
        <>
          <div className="form-section">Opening stock</div>
          {locked ? (
            <Banner tone="info">
              {fmtQty(p?.opening_qty)} {p?.base_uom} posted as opening stock on{' '}
              {fmtDate(p?.opening_date)}. This is fixed now. Stock changes from here
              on come through purchases, sales and returns.
            </Banner>
          ) : (
            <>
              <Row>
                <Field
                  label={`Quantity in ${baseUom}`}
                  htmlFor="pr-oqty"
                  hint={
                    hasPack && !Number.isNaN(oqtyNum) && oqtyNum > 0 && size > 1
                      ? `= ${fmtQty(Math.floor(oqtyNum / size))} ${packUom}${oqtyNum % size ? ` + ${fmtQty(oqtyNum % size)} ${baseUom}` : ''}`
                      : 'Stock on the shelf at go-live, counted in the base unit.'
                  }
                >
                  <input id="pr-oqty" type="text" inputMode="decimal" value={f.opening_qty} disabled={ro}
                         onChange={(e) => set('opening_qty', e.target.value)} />
                </Field>
                <Field label={`Cost per ${per}`} htmlFor="pr-oprice" hint="Usually the purchase price.">
                  <input id="pr-oprice" type="text" inputMode="decimal" value={f.opening_price} disabled={ro}
                         onChange={(e) => set('opening_price', e.target.value)} />
                </Field>
              </Row>
              <Field label="As at" htmlFor="pr-odate" hint="Goes into stock when Admin clicks Post opening stock on the Import screen.">
                <input id="pr-odate" type="date" value={f.opening_date} disabled={ro}
                       onChange={(e) => set('opening_date', e.target.value)} />
              </Field>
            </>
          )}
        </>
      )}

      {!isNew && (
        <>
          <div className="form-section">Status</div>
          <Check id="pr-active" checked={f.is_active} disabled={ro}
                 onChange={(v) => set('is_active', v)}>
            In use. Untick to switch this product off. It stays on old bills and
            reports, but is not offered for new orders.
          </Check>
        </>
      )}
    </FormSheet>
  )
}
