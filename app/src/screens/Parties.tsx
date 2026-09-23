import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase, friendlyMessage } from '../lib/supabase'
import { getSnapshot, putSnapshot } from '../lib/cache'
import { useOnline, useSession } from '../lib/session'
import { fmtAge, fmtDate, fmtMoney } from '../lib/format'
import { Banner, Empty, ErrorBanner, Loading } from '../components/ui'
import { Check, Field, FormSheet, Row, num, text } from '../components/FormSheet'
import { CodeNameSheet } from '../components/CodeNameSheet'
import { useListKeys } from '../lib/listkeys'

export interface PartyRow {
  id: string
  code: string
  name: string
  route_id: string
  route_code: string
  route_name: string
  contact_person: string | null
  phone: string | null
  whatsapp_phone: string | null
  address: string | null
  city: string | null
  credit_limit: number
  credit_days: number
  opening_balance: number
  opening_balance_date: string | null
  is_active: boolean
  opening_locked: boolean
}

interface RouteRow {
  id: string
  code: string
  name: string
  is_active: boolean
}

const CACHE_KEY = 'parties'

export default function Parties() {
  const { user } = useSession()
  const online = useOnline()
  const isAdmin = user?.role === 'ADMIN'

  const [rows, setRows] = useState<PartyRow[] | null>(null)
  const [routes, setRoutes] = useState<RouteRow[]>([])
  const [fetchedAt, setFetchedAt] = useState<number | null>(null)
  const [fromCache, setFromCache] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const [q, setQ] = useState('')
  const [route, setRoute] = useState('')
  const [showInactive, setShowInactive] = useState(false)

  const [editing, setEditing] = useState<PartyRow | 'new' | null>(null)
  const [managingRoutes, setManagingRoutes] = useState(false)

  const load = useCallback(async () => {
    setError(null)
    const [p, r] = await Promise.all([
      supabase.from('v_party_master').select('*').order('name'),
      supabase.from('route').select('id, code, name, is_active').order('name'),
    ])
    if (p.error || r.error) {
      setError(friendlyMessage(p.error ?? r.error))
      return
    }
    const list = (p.data ?? []) as PartyRow[]
    setRows(list)
    setRoutes((r.data ?? []) as RouteRow[])
    setFetchedAt(Date.now())
    setFromCache(false)
    void putSnapshot(CACHE_KEY, list)
  }, [])

  useEffect(() => {
    let alive = true
    async function start() {
      const snap = await getSnapshot<PartyRow[]>(CACHE_KEY)
      if (alive && snap) {
        setRows(snap.data)
        setFetchedAt(snap.fetchedAt)
        setFromCache(true)
      }
      if (navigator.onLine) await load()
      else if (alive && !snap) {
        setRows([])
        setError('You are offline and this device has no saved party list yet.')
      }
    }
    void start()
    return () => {
      alive = false
    }
  }, [load])

  const routeNames = useMemo(() => {
    if (!rows) return []
    return Array.from(new Set(rows.map((r) => r.route_name))).sort()
  }, [rows])

  const filtered = useMemo(() => {
    if (!rows) return []
    const words = q.trim().toLowerCase().split(/\s+/).filter(Boolean)
    return rows.filter((r) => {
      if (!showInactive && !r.is_active) return false
      if (route && r.route_name !== route) return false
      if (words.length === 0) return true
      const hay = `${r.name} ${r.code} ${r.city ?? ''} ${r.phone ?? ''} ${r.contact_person ?? ''}`.toLowerCase()
      return words.every((w) => hay.includes(w))
    })
  }, [rows, q, route, showInactive])

  // Down and Up walk the list, Enter opens the highlighted party.
  const { rowProps } = useListKeys<PartyRow>({
    items: filtered,
    onOpen: (r) => setEditing(r),
    enabled: !editing && !managingRoutes,
  })

  if (rows === null) return <Loading what="Loading parties" />

  return (
    <>
      <div className="page-head">
        <h1>Parties</h1>
        <span className="sub">
          {fetchedAt && fromCache && `Saved on this device ${fmtAge(fetchedAt)}`}
        </span>
        {isAdmin && (
          <span style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
            <button onClick={() => setManagingRoutes(true)} disabled={!online}>Routes</button>
            <button className="primary" onClick={() => setEditing('new')} disabled={!online}>
              Add party
            </button>
          </span>
        )}
      </div>

      <ErrorBanner error={error} />

      <div className="toolbar">
        <span className="grow">
          <label className="sr-only" htmlFor="party-search">Search parties</label>
          <input
            id="party-search"
            type="search"
            autoComplete="off"
            placeholder="Search by name, code, city or phone"
            value={q}
            onChange={(e) => setQ(e.target.value)}
          />
        </span>
        <select value={route} onChange={(e) => setRoute(e.target.value)} aria-label="Filter by route">
          <option value="">All routes</option>
          {routeNames.map((r) => (
            <option key={r} value={r}>{r}</option>
          ))}
        </select>
        <Check id="party-inactive" checked={showInactive} onChange={setShowInactive}>
          Show switched off
        </Check>
      </div>

      {filtered.length === 0 ? (
        <Empty title="Nothing to show">
          {rows.length === 0
            ? 'No parties yet. Import them from the workbook, or add one here.'
            : 'No party matches that search.'}
        </Empty>
      ) : (
        <>
          <div className="card table-wrap">
            <table className="data">
              <thead>
                <tr>
                  <th>Party</th>
                  <th>Route</th>
                  <th>Phone</th>
                  <th>City</th>
                  <th className="num">Credit</th>
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
                      <span className="muted" style={{ fontSize: 12.5 }}>
                        {r.code}
                        {r.contact_person && ` · ${r.contact_person}`}
                      </span>
                    </td>
                    <td data-label="Route" className="muted">{r.route_name}</td>
                    <td data-label="Phone">
                      {r.phone ? (
                        <a href={`tel:${r.phone}`} onClick={(e) => e.stopPropagation()}>{r.phone}</a>
                      ) : (
                        <span className="muted">—</span>
                      )}
                    </td>
                    <td data-label="City" className="muted">{r.city ?? '—'}</td>
                    <td data-label="Credit" className="num">
                      <span>
                        {Number(r.credit_limit) > 0 ? fmtMoney(r.credit_limit) : <span className="muted">No limit</span>}
                        {Number(r.credit_days) > 0 && (
                          <span className="muted" style={{ fontSize: 12 }}> · {r.credit_days} days</span>
                        )}
                      </span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className="sub" style={{ marginTop: 12 }}>
            {filtered.length} part{filtered.length === 1 ? 'y' : 'ies'}
          </p>
        </>
      )}

      {editing && (
        <PartyForm
          party={editing === 'new' ? null : editing}
          routes={routes}
          canEdit={isAdmin && online}
          onClose={() => setEditing(null)}
          onSaved={() => {
            setEditing(null)
            void load()
          }}
        />
      )}

      {managingRoutes && (
        <CodeNameSheet
          table="route"
          title="Routes"
          noun="route"
          onClose={() => setManagingRoutes(false)}
          onChanged={() => void load()}
        />
      )}
    </>
  )
}

function PartyForm({
  party,
  routes,
  canEdit,
  onClose,
  onSaved,
}: {
  party: PartyRow | null
  routes: RouteRow[]
  canEdit: boolean
  onClose: () => void
  onSaved: () => void
}) {
  const isNew = party === null
  const [f, setF] = useState({
    code: party?.code ?? '',
    name: party?.name ?? '',
    route_id: party?.route_id ?? '',
    contact_person: party?.contact_person ?? '',
    phone: party?.phone ?? '',
    whatsapp_phone: party?.whatsapp_phone ?? '',
    address: party?.address ?? '',
    city: party?.city ?? '',
    credit_limit: party ? String(Number(party.credit_limit)) : '',
    credit_days: party ? String(party.credit_days) : '',
    opening_balance: party && Number(party.opening_balance) !== 0 ? String(Number(party.opening_balance)) : '',
    opening_balance_date: party?.opening_balance_date ?? '',
    is_active: party?.is_active ?? true,
  })
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const set = <K extends keyof typeof f>(k: K, v: (typeof f)[K]) => setF((x) => ({ ...x, [k]: v }))
  const locked = party?.opening_locked ?? false
  const ro = !canEdit

  // A switched-off route is not offered for a new choice, but a party already
  // on one keeps showing it.
  const routeOptions = routes.filter((r) => r.is_active || r.id === party?.route_id)

  async function save() {
    setError(null)
    const credit_limit = num(f.credit_limit)
    const credit_days = num(f.credit_days)
    const opening_balance = num(f.opening_balance)

    const problems: string[] = []
    if (isNew && !text(f.code)) problems.push('a code')
    if (!text(f.name)) problems.push('a name')
    if (!f.route_id) problems.push('a route')
    if (problems.length) {
      setError(`Please give ${problems.join(', ')}.`)
      return
    }
    if (Number.isNaN(credit_limit) || credit_limit < 0) {
      setError('Credit limit must be a plain number, 0 or more — no commas.')
      return
    }
    if (Number.isNaN(credit_days) || credit_days < 0 || !Number.isInteger(credit_days)) {
      setError('Credit days must be a whole number, 0 or more.')
      return
    }
    if (Number.isNaN(opening_balance)) {
      setError('Opening balance must be a plain number — no commas.')
      return
    }
    if (opening_balance !== 0 && !f.opening_balance_date) {
      setError('An opening balance needs a date.')
      return
    }

    const row: Record<string, unknown> = {
      name: text(f.name),
      route_id: f.route_id,
      contact_person: text(f.contact_person),
      phone: text(f.phone),
      whatsapp_phone: text(f.whatsapp_phone),
      address: text(f.address),
      city: text(f.city),
      credit_limit,
      credit_days,
      is_active: f.is_active,
    }
    if (!locked) {
      row.opening_balance = opening_balance
      row.opening_balance_date = opening_balance !== 0 ? f.opening_balance_date : null
    }

    setBusy(true)
    const { error } = isNew
      ? await supabase.from('party').insert({ ...row, code: text(f.code) })
      : await supabase.from('party').update(row).eq('id', party.id)
    setBusy(false)

    if (error) {
      setError(friendlyMessage(error))
      return
    }
    onSaved()
  }

  return (
    <FormSheet
      title={isNew ? 'Add party' : ro ? party.name : `Edit ${party.name}`}
      onClose={onClose}
      onSubmit={ro ? undefined : () => void save()}
      busy={busy}
      error={error}
      submitLabel={isNew ? 'Add party' : 'Save'}
    >
      <Row>
        <Field label="Code" htmlFor="p-code" hint={isNew ? 'Short and unique, e.g. C104. Cannot be changed later.' : 'Codes cannot be changed.'}>
          <input id="p-code" type="text" value={f.code} disabled={!isNew || ro}
                 onChange={(e) => set('code', e.target.value)} />
        </Field>
        <Field label="Route" htmlFor="p-route">
          <select id="p-route" value={f.route_id} disabled={ro}
                  onChange={(e) => set('route_id', e.target.value)}>
            <option value="">Choose a route</option>
            {routeOptions.map((r) => (
              <option key={r.id} value={r.id}>{r.name} ({r.code})</option>
            ))}
          </select>
        </Field>
      </Row>

      <Field label="Name" htmlFor="p-name" hint="As it should print on the bill.">
        <input id="p-name" type="text" value={f.name} disabled={ro}
               onChange={(e) => set('name', e.target.value)} />
      </Field>

      <Row>
        <Field label="Contact person" htmlFor="p-contact">
          <input id="p-contact" type="text" value={f.contact_person} disabled={ro}
                 onChange={(e) => set('contact_person', e.target.value)} />
        </Field>
        <Field label="Phone" htmlFor="p-phone">
          <input id="p-phone" type="text" inputMode="tel" value={f.phone} disabled={ro}
                 onChange={(e) => set('phone', e.target.value)} />
        </Field>
      </Row>

      <Row>
        <Field label="WhatsApp" htmlFor="p-wa" hint="Only if different from phone.">
          <input id="p-wa" type="text" inputMode="tel" value={f.whatsapp_phone} disabled={ro}
                 onChange={(e) => set('whatsapp_phone', e.target.value)} />
        </Field>
        <Field label="City" htmlFor="p-city">
          <input id="p-city" type="text" value={f.city} disabled={ro}
                 onChange={(e) => set('city', e.target.value)} />
        </Field>
      </Row>

      <Field label="Address" htmlFor="p-address" hint="Prints on the bill.">
        <input id="p-address" type="text" value={f.address} disabled={ro}
               onChange={(e) => set('address', e.target.value)} />
      </Field>

      <div className="form-section">Credit</div>
      <Row>
        <Field label="Credit limit" htmlFor="p-limit" hint="Blank or 0 means no limit.">
          <input id="p-limit" type="text" inputMode="decimal" value={f.credit_limit} disabled={ro}
                 onChange={(e) => set('credit_limit', e.target.value)} />
        </Field>
        <Field label="Credit days" htmlFor="p-days">
          <input id="p-days" type="text" inputMode="numeric" value={f.credit_days} disabled={ro}
                 onChange={(e) => set('credit_days', e.target.value)} />
        </Field>
      </Row>

      <div className="form-section">Opening balance</div>
      {locked ? (
        <Banner tone="info">
          {Number(party?.opening_balance) !== 0
            ? <>Opening balance {fmtMoney(party?.opening_balance)} as at {fmtDate(party?.opening_balance_date)}. </>
            : <>No opening balance. </>}
          This is fixed now, because the party already has orders, bills or payments.
        </Banner>
      ) : (
        <Row>
          <Field label="Amount owed at the start" htmlFor="p-ob" hint="What they owed you on the go-live date.">
            <input id="p-ob" type="text" inputMode="decimal" value={f.opening_balance} disabled={ro}
                   onChange={(e) => set('opening_balance', e.target.value)} />
          </Field>
          <Field label="As at" htmlFor="p-obd">
            <input id="p-obd" type="date" value={f.opening_balance_date} disabled={ro}
                   onChange={(e) => set('opening_balance_date', e.target.value)} />
          </Field>
        </Row>
      )}

      {!isNew && (
        <>
          <div className="form-section">Status</div>
          <Check id="p-active" checked={f.is_active} disabled={ro}
                 onChange={(v) => set('is_active', v)}>
            In use. Untick to switch this party off. It stays on old bills and
            reports, but is not offered for new orders.
          </Check>
        </>
      )}
    </FormSheet>
  )
}
