import { useCallback, useEffect, useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { supabase, friendlyMessage } from '../lib/supabase'
import { fmtDate, fmtMoney } from '../lib/format'
import { Empty, ErrorBanner, Loading } from '../components/ui'
import { Check, Field, FormSheet, Row, text } from '../components/FormSheet'
import { useListKeys } from '../lib/listkeys'
import { useSession } from '../lib/session'

/**
 * Who you buy from.
 *
 * Short list, simple screen — but it is a master, so it follows the same rules
 * as the others: Admin edits, codes never change, and a supplier with history
 * is switched off rather than removed.
 */

interface Row_ {
  id: string
  code: string
  name: string
  contact_person: string | null
  phone: string | null
  address: string | null
  city: string | null
  is_active: boolean
  purchase_count: number
  bought_value: number | null
  last_purchase_date: string | null
}

const BLANK = {
  code: '',
  name: '',
  contact_person: '',
  phone: '',
  address: '',
  city: '',
}

export default function Suppliers() {
  const nav = useNavigate()
  const { can } = useSession()
  const isAdmin = can('ADMIN')

  const [rows, setRows] = useState<Row_[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [q, setQ] = useState('')
  const [showInactive, setShowInactive] = useState(false)
  const [editing, setEditing] = useState<Row_ | 'new' | null>(null)

  const load = useCallback(async () => {
    setError(null)
    const { data, error } = await supabase
      .from('v_supplier_list')
      .select('*')
      .order('name')
    if (error) setError(friendlyMessage(error))
    else setRows((data ?? []) as Row_[])
  }, [])

  useEffect(() => {
    void load()
  }, [load])

  const filtered = useMemo(() => {
    if (!rows) return []
    const needle = q.trim().toLowerCase()
    return rows.filter((r) => {
      if (!showInactive && !r.is_active) return false
      if (!needle) return true
      return `${r.name} ${r.code} ${r.city ?? ''} ${r.contact_person ?? ''} ${r.phone ?? ''}`
        .toLowerCase()
        .includes(needle)
    })
  }, [rows, q, showInactive])

  const { rowProps } = useListKeys<Row_>({
    items: filtered,
    onOpen: (r) => setEditing(r),
    enabled: !editing,
  })

  if (rows === null) return <Loading what="Loading suppliers" />

  return (
    <>
      <div className="page-head">
        <h1>Suppliers</h1>
        <span className="sub">Who you buy from</span>
        <span style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
          <button onClick={() => nav('/purchases')}>Purchases</button>
          {isAdmin && (
            <button className="primary" onClick={() => setEditing('new')}>
              Add supplier
            </button>
          )}
        </span>
      </div>

      <ErrorBanner error={error} />

      <div className="toolbar">
        <span className="grow">
          <label className="sr-only" htmlFor="sup-search">Search suppliers</label>
          <input
            id="sup-search"
            type="search"
            autoComplete="off"
            placeholder="Search by name, code, town or contact"
            value={q}
            onChange={(e) => setQ(e.target.value)}
          />
        </span>
        <Check id="sup-inactive" checked={showInactive} onChange={setShowInactive}>
          Show switched off
        </Check>
      </div>

      {filtered.length === 0 ? (
        <Empty title="Nothing to show">
          {rows.length === 0
            ? isAdmin
              ? 'No suppliers yet. Add the first one.'
              : 'No suppliers yet.'
            : 'No supplier matches that search.'}
        </Empty>
      ) : (
        <div className="card table-wrap">
          <table className="data">
            <thead>
              <tr>
                <th>Supplier</th>
                <th>Contact</th>
                <th>Town</th>
                <th className="num">Purchases</th>
                <th className="num">Bought</th>
              </tr>
            </thead>
            <tbody>
              {filtered.map((r, i) => (
                <tr
                  key={r.id}
                  {...rowProps(i)}
                  className={[rowProps(i).className, r.is_active ? '' : 'inactive']
                    .filter(Boolean)
                    .join(' ') || undefined}
                  onClick={() => setEditing(r)}
                  style={{ cursor: 'pointer' }}
                >
                  <td className="primary-cell">
                    <span className="strong">{r.name}</span>
                    {!r.is_active && <> <span className="pill flat">Off</span></>}
                    <br />
                    <span className="muted" style={{ fontSize: 12.5 }}>{r.code}</span>
                  </td>
                  <td data-label="Contact" className="muted">
                    {r.contact_person || '—'}
                    {r.phone ? (
                      <>
                        <br />
                        <span style={{ fontSize: 12.5 }}>{r.phone}</span>
                      </>
                    ) : null}
                  </td>
                  <td data-label="Town" className="muted">{r.city || '—'}</td>
                  <td data-label="Purchases" className="num muted">
                    {r.purchase_count}
                    {r.last_purchase_date ? (
                      <>
                        <br />
                        <span style={{ fontSize: 12 }}>
                          last {fmtDate(r.last_purchase_date)}
                        </span>
                      </>
                    ) : null}
                  </td>
                  <td data-label="Bought" className="num">
                    {Number(r.bought_value ?? 0) > 0 ? fmtMoney(r.bought_value) : '—'}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <p className="sub" style={{ marginTop: 12 }}>
        {filtered.length} supplier{filtered.length === 1 ? '' : 's'}
        {isAdmin ? ' · click one to edit' : ''}
      </p>

      {editing && (
        <SupplierForm
          supplier={editing === 'new' ? null : editing}
          readOnly={!isAdmin}
          onClose={() => setEditing(null)}
          onSaved={() => {
            setEditing(null)
            void load()
          }}
        />
      )}
    </>
  )
}

function SupplierForm({
  supplier,
  readOnly,
  onClose,
  onSaved,
}: {
  supplier: Row_ | null
  readOnly: boolean
  onClose: () => void
  onSaved: () => void
}) {
  const isNew = supplier === null
  const [f, setF] = useState({
    code: supplier?.code ?? BLANK.code,
    name: supplier?.name ?? BLANK.name,
    contact_person: supplier?.contact_person ?? '',
    phone: supplier?.phone ?? '',
    address: supplier?.address ?? '',
    city: supplier?.city ?? '',
  })
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const set = (k: keyof typeof f, v: string) => setF((x) => ({ ...x, [k]: v }))

  const save = useCallback(async () => {
    setError(null)
    if (!text(f.code)) {
      setError('A supplier needs a code.')
      return
    }
    if (!text(f.name)) {
      setError('A supplier needs a name.')
      return
    }

    const patch = {
      code: text(f.code),
      name: text(f.name),
      contact_person: text(f.contact_person),
      phone: text(f.phone),
      address: text(f.address),
      city: text(f.city),
    }

    setBusy(true)
    const { error } = isNew
      ? await supabase.from('supplier').insert(patch)
      : await supabase
          .from('supplier')
          .update({ ...patch, code: undefined })
          .eq('id', supplier!.id)
    setBusy(false)

    if (error) {
      setError(friendlyMessage(error))
      return
    }
    onSaved()
  }, [f, isNew, supplier, onSaved])

  const toggleActive = useCallback(async () => {
    if (!supplier) return
    setBusy(true)
    setError(null)
    const { error } = await supabase
      .from('supplier')
      .update({ is_active: !supplier.is_active })
      .eq('id', supplier.id)
    setBusy(false)
    if (error) setError(friendlyMessage(error))
    else onSaved()
  }, [supplier, onSaved])

  return (
    <FormSheet
      title={isNew ? 'Add supplier' : readOnly ? supplier!.name : `Edit ${supplier!.name}`}
      onClose={onClose}
      onSubmit={readOnly ? undefined : () => void save()}
      busy={busy}
      error={error}
      submitLabel={isNew ? 'Add supplier' : 'Save'}
    >
      <Row>
        <Field
          label="Code"
          htmlFor="s-code"
          hint={
            isNew
              ? 'Short and unique, e.g. S1. Cannot be changed later.'
              : 'Codes cannot be changed.'
          }
        >
          <input
            id="s-code"
            type="text"
            value={f.code}
            disabled={!isNew || readOnly}
            onChange={(e) => set('code', e.target.value)}
          />
        </Field>
        <Field label="Town" htmlFor="s-city">
          <input
            id="s-city"
            type="text"
            value={f.city}
            disabled={readOnly}
            onChange={(e) => set('city', e.target.value)}
          />
        </Field>
      </Row>

      <Field label="Name" htmlFor="s-name" hint="As you refer to them.">
        <input
          id="s-name"
          type="text"
          value={f.name}
          disabled={readOnly}
          onChange={(e) => set('name', e.target.value)}
        />
      </Field>

      <Row>
        <Field label="Contact person" htmlFor="s-contact">
          <input
            id="s-contact"
            type="text"
            value={f.contact_person}
            disabled={readOnly}
            onChange={(e) => set('contact_person', e.target.value)}
          />
        </Field>
        <Field label="Phone" htmlFor="s-phone">
          <input
            id="s-phone"
            type="tel"
            value={f.phone}
            disabled={readOnly}
            onChange={(e) => set('phone', e.target.value)}
          />
        </Field>
      </Row>

      <Field label="Address" htmlFor="s-address">
        <input
          id="s-address"
          type="text"
          value={f.address}
          disabled={readOnly}
          onChange={(e) => set('address', e.target.value)}
        />
      </Field>

      {!isNew && !readOnly && (
        <>
          <div className="form-section">Switching off</div>
          <p className="hint" style={{ marginTop: 0 }}>
            {supplier!.purchase_count > 0
              ? `${supplier!.name} is on ${supplier!.purchase_count} purchase${
                  supplier!.purchase_count === 1 ? '' : 's'
                }, so they are never removed. Switching off keeps that history and stops them being offered on new ones.`
              : 'Switching off keeps the supplier but stops them being offered on new purchases.'}
          </p>
          <button type="button" onClick={() => void toggleActive()} disabled={busy}>
            {supplier!.is_active ? 'Switch off' : 'Switch on'}
          </button>
        </>
      )}
    </FormSheet>
  )
}
