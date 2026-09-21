import { useCallback, useEffect, useState } from 'react'
import { supabase, friendlyMessage } from '../lib/supabase'
import { FormSheet, text } from './FormSheet'
import { Loading, Spinner } from './ui'

interface Item {
  id: string
  code: string
  name: string
  is_active: boolean
}

/**
 * Routes and product groups are just a code and a name. One small screen
 * manages either: add one, rename one, switch one off.
 *
 * Switching off hides it from new parties or products. It never removes it,
 * because existing parties and products still point at it.
 */
export function CodeNameSheet({
  table,
  title,
  noun,
  onClose,
  onChanged,
}: {
  table: 'route' | 'product_group'
  title: string
  noun: string
  onClose: () => void
  onChanged: () => void
}) {
  const [items, setItems] = useState<Item[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [newCode, setNewCode] = useState('')
  const [newName, setNewName] = useState('')
  const [edits, setEdits] = useState<Record<string, string>>({})

  const load = useCallback(async () => {
    const { data, error } = await supabase
      .from(table)
      .select('id, code, name, is_active')
      .order('code')
    if (error) setError(friendlyMessage(error))
    else setItems((data ?? []) as Item[])
  }, [table])

  useEffect(() => {
    void load()
  }, [load])

  async function add() {
    setError(null)
    const code = text(newCode)
    const name = text(newName)
    if (!code || !name) {
      setError(`Give the new ${noun} a code and a name.`)
      return
    }
    setBusy('new')
    const { error } = await supabase.from(table).insert({ code, name })
    setBusy(null)
    if (error) {
      setError(friendlyMessage(error))
      return
    }
    setNewCode('')
    setNewName('')
    await load()
    onChanged()
  }

  async function save(it: Item, patch: Partial<Item>) {
    setError(null)
    if (patch.name !== undefined && !text(patch.name)) {
      setError('A name cannot be blank.')
      return
    }
    setBusy(it.id)
    const { error } = await supabase.from(table).update(patch).eq('id', it.id)
    setBusy(null)
    if (error) {
      setError(friendlyMessage(error))
      return
    }
    setEdits((e) => {
      const next = { ...e }
      delete next[it.id]
      return next
    })
    await load()
    onChanged()
  }

  return (
    <FormSheet title={title} onClose={onClose} error={error}>
      <div className="form-section" style={{ marginTop: 0, paddingTop: 0, borderTop: 'none' }}>
        Add a {noun}
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: '90px 1fr auto', gap: 8 }}>
        <input
          type="text"
          aria-label="Code"
          placeholder="Code"
          value={newCode}
          onChange={(e) => setNewCode(e.target.value)}
        />
        <input
          type="text"
          aria-label="Name"
          placeholder="Name"
          value={newName}
          onChange={(e) => setNewName(e.target.value)}
        />
        <button type="button" onClick={() => void add()} disabled={busy !== null}>
          {busy === 'new' ? <Spinner /> : 'Add'}
        </button>
      </div>

      <div className="form-section">Existing</div>
      {items === null ? (
        <Loading />
      ) : items.length === 0 ? (
        <p className="hint">None yet.</p>
      ) : (
        items.map((it) => {
          const draft = edits[it.id]
          const dirty = draft !== undefined && draft.trim() !== it.name
          return (
            <div
              key={it.id}
              style={{
                display: 'grid',
                gridTemplateColumns: '90px 1fr auto',
                gap: 8,
                alignItems: 'center',
                marginBottom: 8,
                opacity: it.is_active ? 1 : 0.6,
              }}
            >
              <span className="strong" style={{ fontSize: 14 }}>{it.code}</span>
              <input
                type="text"
                aria-label={`Name of ${it.code}`}
                value={draft ?? it.name}
                onChange={(e) => setEdits((x) => ({ ...x, [it.id]: e.target.value }))}
              />
              {dirty ? (
                <button
                  type="button"
                  className="primary"
                  disabled={busy !== null}
                  onClick={() => void save(it, { name: draft.trim() })}
                >
                  {busy === it.id ? <Spinner /> : 'Save'}
                </button>
              ) : (
                <button
                  type="button"
                  disabled={busy !== null}
                  onClick={() => void save(it, { is_active: !it.is_active })}
                  title={it.is_active ? 'Hide from new entries' : 'Use again'}
                >
                  {busy === it.id ? <Spinner /> : it.is_active ? 'Switch off' : 'Switch on'}
                </button>
              )}
            </div>
          )
        })
      )}
      <p className="hint" style={{ marginTop: 14 }}>
        Codes cannot be changed once added. A {noun} that is switched off stays on
        existing records but is not offered for new ones.
      </p>
    </FormSheet>
  )
}
