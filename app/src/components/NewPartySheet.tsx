import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase, friendlyMessage } from '../lib/supabase'
import { Banner, Spinner } from './ui'

/**
 * Adding a customer, from wherever you happen to be standing.
 *
 * Reps get this because a shop that is not on the list is a shop whose order
 * cannot be taken, and "ring the office" is not an answer at a counter. They
 * do not get editing: a rep tidying a name in the field is how one shop
 * becomes two.
 *
 * Which makes the near-match list the important part of this form, not a
 * decoration. The app cannot merge two customers afterwards — their balances,
 * bills and ageing would all have to be moved — so the only cheap moment to
 * stop "Ram Store", "Ram Stores" and "Ram Store Lahan" from becoming three
 * accounts is while somebody is typing the third one. They are shown as
 * buttons: the likeliest outcome of seeing the shop you meant is wanting to
 * use it.
 *
 * The code is not asked for. It is the next in the sequence, shown but not
 * editable, and settled by the database when the record is actually written —
 * two reps adding a customer in the same minute must not both get AA341.
 */

interface RouteRow {
  id: string
  name: string
}

export interface NewParty {
  party_id: string
  code: string
  name: string
}

export function NewPartySheet({
  initialName = '',
  onCreated,
  onPicked,
  onClose,
}: {
  /** Whatever was typed into the search that came up empty. */
  initialName?: string
  onCreated: (p: NewParty) => void
  /** Chose an existing customer from the near-match list instead. */
  onPicked?: (partyId: string) => void
  onClose: () => void
}) {
  const [name, setName] = useState(initialName)
  const [phone, setPhone] = useState('')
  const [address, setAddress] = useState('')
  const [routeId, setRouteId] = useState('')
  const [routes, setRoutes] = useState<RouteRow[] | null>(null)
  const [nextCode, setNextCode] = useState<string | null>(null)
  const [existing, setExisting] = useState<{ id: string; code: string; name: string }[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let alive = true
    void (async () => {
      const [r, c, p] = await Promise.all([
        supabase.from('route').select('id, name').eq('is_active', true).order('name'),
        supabase.rpc('suggest_master_code', { p_table: 'party' }),
        supabase.from('party').select('id, code, name').eq('is_active', true).order('name'),
      ])
      if (!alive) return
      const rows = (r.data ?? []) as RouteRow[]
      setRoutes(rows)
      if (rows.length === 1) setRouteId(rows[0].id)
      setNextCode(typeof c.data === 'string' ? c.data : null)
      setExisting((p.data ?? []) as { id: string; code: string; name: string }[])
    })()
    return () => { alive = false }
  }, [])

  /**
   * Customers whose names look like the one being typed.
   *
   * Matched on words rather than the whole string, so "ram" finds "Shree Ram
   * Store" and not only names that start that way — the duplicate somebody is
   * about to create is usually the same words in a different order.
   */
  const near = useMemo(() => {
    const words = name.trim().toLowerCase().split(/\s+/).filter((w) => w.length >= 3)
    if (words.length === 0) return []
    return existing
      .filter((p) => {
        const hay = p.name.toLowerCase()
        return words.some((w) => hay.includes(w))
      })
      .slice(0, 6)
  }, [name, existing])

  const save = useCallback(async () => {
    setError(null)
    if (!name.trim()) return setError('The customer needs a name.')
    if (!routeId) return setError('Choose a route.')

    setBusy(true)
    const { data, error } = await supabase.rpc('create_party', {
      p_name: name.trim(),
      p_route_id: routeId,
      p_phone: phone.trim() || null,
      p_address: address.trim() || null,
    })
    setBusy(false)

    if (error) return setError(friendlyMessage(error))
    onCreated(data as NewParty)
  }, [name, routeId, phone, address, onCreated])

  return (
    <div
      className="sheet-backdrop sheet-top"
      onMouseDown={(e) => { if (e.target === e.currentTarget) onClose() }}
    >
      <div className="sheet sheet-dialog" role="dialog" aria-modal="true" aria-label="New customer">
        <div className="sheet-head">
          <h2>New customer</h2>
          <button className="ghost" onClick={onClose}>Close</button>
        </div>

        <div className="sheet-body" style={{ padding: 16 }}>
          {error && <Banner tone="bad">{error}</Banner>}

          <div className="field">
            <label htmlFor="np-name">Shop name</label>
            <input
              id="np-name"
              type="text"
              autoFocus
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="As it is written on the shop"
            />
            <div className="hint">
              Code {nextCode ?? '…'} — given automatically, you do not type it.
            </div>
          </div>

          {near.length > 0 && (
            <Banner tone="warn">
              <strong>
                {near.length === 1
                  ? 'There is already a customer with a similar name.'
                  : `There are already ${near.length} customers with similar names.`}
              </strong>{' '}
              If one of these is the shop you mean, use it — two accounts for one
              shop cannot be merged later.
              <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginTop: 8 }}>
                {near.map((p) => (
                  <button
                    key={p.id}
                    onClick={() => (onPicked ? onPicked(p.id) : onClose())}
                  >
                    {p.name} <span className="muted">({p.code})</span>
                  </button>
                ))}
              </div>
            </Banner>
          )}

          <div className="field">
            <label htmlFor="np-route">Route</label>
            <select id="np-route" value={routeId} onChange={(e) => setRouteId(e.target.value)}>
              <option value="">Choose a route</option>
              {(routes ?? []).map((r) => (
                <option key={r.id} value={r.id}>{r.name}</option>
              ))}
            </select>
          </div>

          <div className="field">
            <label htmlFor="np-phone">Phone (optional)</label>
            <input
              id="np-phone"
              type="tel"
              inputMode="tel"
              value={phone}
              onChange={(e) => setPhone(e.target.value)}
            />
          </div>

          <div className="field">
            <label htmlFor="np-address">Address (optional)</label>
            <input
              id="np-address"
              type="text"
              value={address}
              onChange={(e) => setAddress(e.target.value)}
            />
          </div>

          <p className="sub" style={{ marginBottom: 0 }}>
            Credit limit and opening balance are set by the office, not here.
          </p>
        </div>

        <div className="sheet-foot">
          <button className="ghost" onClick={onClose}>Cancel</button>
          <button
            className="primary"
            style={{ marginLeft: 'auto' }}
            onClick={() => void save()}
            disabled={busy || !name.trim() || !routeId}
          >
            {busy ? <Spinner /> : 'Add customer'}
          </button>
        </div>
      </div>
    </div>
  )
}
