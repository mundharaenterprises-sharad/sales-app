import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, useNavigate, useSearchParams } from 'react-router-dom'
import { supabase, friendlyMessage } from '../lib/supabase'
import { fmtDate, fmtMoney } from '../lib/format'
import { Banner, Empty, ErrorBanner, Loading, Spinner } from '../components/ui'
import { Picker } from '../components/Picker'
import { Field, Row, num } from '../components/FormSheet'
import { useSession } from '../lib/session'
import { AgePill } from '../components/AgePill'

/**
 * Taking a payment: one screen.
 *
 * Choose the customer, tick what the money pays, save. The old two-step —
 * record the payment, then go and apply it — is gone, because in a shop the
 * two are one action: the customer hands over money against particular bills.
 *
 * It is still one transaction in the database, so a payment can never end up
 * recorded but unapplied because something failed in between.
 */

interface PartyRow {
  party_id: string
  party_code: string
  party_name: string
  route_name: string
  balance: number | null
}

interface UserRow {
  id: string
  full_name: string
}

interface OpenBill {
  invoice_id: string
  doc_no: string
  invoice_date: string
  effective_total: number
  outstanding: number
  days_outstanding: number
}

export default function NewReceipt() {
  const nav = useNavigate()
  const { user } = useSession()
  const [params] = useSearchParams()

  const [parties, setParties] = useState<PartyRow[] | null>(null)
  const [users, setUsers] = useState<UserRow[]>([])
  const [party, setParty] = useState<PartyRow | null>(null)

  const [bills, setBills] = useState<OpenBill[] | null>(null)
  const [draft, setDraft] = useState<Record<string, string>>({})

  const [date, setDate] = useState(new Date().toISOString().slice(0, 10))
  const [amount, setAmount] = useState('')
  const [amountTouched, setAmountTouched] = useState(false)
  const [collectedBy, setCollectedBy] = useState('')
  const [remarks, setRemarks] = useState('')

  const [picking, setPicking] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  // ---------------------------------------------------------------------------

  useEffect(() => {
    let alive = true

    async function load() {
      const [p, u] = await Promise.all([
        supabase
          .from('v_party_balance')
          .select('party_id, party_code, party_name, route_name, balance')
          .eq('is_active', true)
          .order('party_name'),
        supabase
          .from('app_user')
          .select('id, full_name')
          .eq('is_active', true)
          .order('full_name'),
      ])
      if (!alive) return
      if (p.error) {
        setError(friendlyMessage(p.error))
        setParties([])
        return
      }
      const list = (p.data ?? []) as PartyRow[]
      setParties(list)
      setUsers((u.data ?? []) as UserRow[])

      const pre = params.get('party')
      if (pre) setParty(list.find((x) => x.party_id === pre) ?? null)
    }

    void load()
    return () => {
      alive = false
    }
  }, [params])

  useEffect(() => {
    if (user && !collectedBy) setCollectedBy(user.id)
  }, [user, collectedBy])

  /** The customer's unpaid bills, refreshed whenever the customer changes. */
  useEffect(() => {
    let alive = true
    if (!party) {
      setBills(null)
      setDraft({})
      return
    }

    async function load() {
      setBills(null)
      const { data, error } = await supabase
        .from('v_invoice_list')
        .select('invoice_id, doc_no, invoice_date, effective_total, outstanding, days_outstanding')
        .eq('party_id', party!.party_id)
        .neq('status', 'CANCELLED')
        .gt('outstanding', 0)
        .order('invoice_date')

      if (!alive) return
      if (error) {
        setError(friendlyMessage(error))
        setBills([])
        return
      }

      const list = (data ?? []) as unknown as OpenBill[]
      setBills(list)

      // Arriving from a particular bill, that bill starts filled in. Otherwise
      // every box starts empty and the money goes where it is put.
      const pre = params.get('invoice')
      const hit = pre ? list.find((b) => b.invoice_id === pre) : undefined
      setDraft(hit ? { [hit.invoice_id]: String(Number(hit.outstanding)) } : {})
    }

    void load()
    return () => {
      alive = false
    }
  }, [party, params])

  // ---------------------------------------------------------------------------

  const applied = useMemo(
    () =>
      Object.values(draft).reduce((s, v) => {
        const n = num(v, 0)
        return s + (Number.isNaN(n) ? 0 : n)
      }, 0),
    [draft],
  )

  // The amount follows the ticks until somebody types over it, at which point
  // it is theirs and the app stops touching it.
  const effectiveAmount = amountTouched ? num(amount, NaN) : applied
  const extra = Math.round((effectiveAmount - applied) * 100) / 100

  const setLine = (id: string, v: string) => setDraft((d) => ({ ...d, [id]: v }))

  const payWhole = (b: OpenBill) => setLine(b.invoice_id, String(Number(b.outstanding)))

  const save = useCallback(async () => {
    setError(null)
    if (!party) {
      setError('Choose a customer first.')
      return
    }
    if (!date) {
      setError('A payment needs a date.')
      return
    }

    const allocations: { invoice_id: string; amount: number }[] = []
    for (const [invoice_id, v] of Object.entries(draft)) {
      const n = num(v, 0)
      if (Number.isNaN(n) || n < 0) {
        setError('Amounts must be plain numbers, 0 or more — no commas.')
        return
      }
      if (n > 0) allocations.push({ invoice_id, amount: n })
    }

    const amt = amountTouched ? num(amount, NaN) : applied
    if (Number.isNaN(amt) || amt <= 0) {
      setError('Enter the amount as a plain number above zero — no commas.')
      return
    }
    if (applied > amt + 0.001) {
      setError(
        `The bills ticked come to ${fmtMoney(applied)}, more than the payment of ${fmtMoney(amt)}.`,
      )
      return
    }

    setBusy(true)
    const { data, error } = await supabase.rpc('receive_payment', {
      p_party_id: party.party_id,
      p_receipt_date: date,
      p_amount: amt,
      p_allocations: allocations,
      p_collected_by: collectedBy || null,
      p_remarks: remarks.trim() || null,
    })
    setBusy(false)

    if (error) {
      setError(friendlyMessage(error))
      return
    }

    const res = data as { receipt_id: string; doc_no: string }
    nav(`/receipts/${res.receipt_id}`, { replace: true, state: { justSaved: res.doc_no } })
  }, [party, date, draft, amount, amountTouched, applied, collectedBy, remarks, nav])

  if (parties === null) return <Loading what="Loading customers" />

  return (
    <>
      <div className="page-head">
        <h1>Receive payment</h1>
        <span className="sub">Money in, and the bills it pays</span>
      </div>

      <ErrorBanner error={error} />

      <div className="card card-pad">
        <Row>
          <Field label="Customer" htmlFor="rc-party">
            <button type="button" className="block" onClick={() => setPicking(true)}>
              {party ? party.party_name : 'Choose a customer'}
            </button>
          </Field>

          <Field label="Date" htmlFor="rc-date">
            <input id="rc-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
          </Field>
        </Row>

        {party && (
          <p className="hint" style={{ marginTop: -4 }}>
            {party.party_code} · {party.route_name} · owes{' '}
            <strong>{fmtMoney(party.balance)}</strong> in total
          </p>
        )}
      </div>

      {party && (
        <>
          <div className="page-head" style={{ marginTop: 18 }}>
            <h2>Which bills is this paying?</h2>
            <span className="sub">Oldest first</span>
          </div>

          {bills === null ? (
            <Loading what="Loading bills" />
          ) : bills.length === 0 ? (
            <Banner tone="info">
              This customer has nothing outstanding. A payment can still be recorded
              and will sit as credit against their next bill.
            </Banner>
          ) : (
            <div className="card table-wrap">
              <table className="data">
                <thead>
                  <tr>
                    <th>Bill</th>
                    <th>Age</th>
                    <th className="num">Bill total</th>
                    <th className="num">Owed</th>
                    <th className="num" style={{ width: 170 }}>Paying now</th>
                  </tr>
                </thead>
                <tbody>
                  {bills.map((b) => {
                    const owed = Number(b.outstanding)
                    const v = num(draft[b.invoice_id] ?? '', 0)
                    const over = !Number.isNaN(v) && v > owed + 0.001
                    return (
                      <tr key={b.invoice_id}>
                        <td className="primary-cell">
                          <Link to={`/invoices/${b.invoice_id}`} className="strong">
                            {b.doc_no}
                          </Link>
                          <br />
                          <span className="muted" style={{ fontSize: 12.5 }}>
                            {fmtDate(b.invoice_date)}
                          </span>
                        </td>
                        <td data-label="Age">
                          <AgePill days={b.days_outstanding} />
                        </td>
                        <td data-label="Bill total" className="num">
                          {fmtMoney(b.effective_total)}
                        </td>
                        <td data-label="Owed" className="num">{fmtMoney(owed)}</td>
                        <td data-label="Paying now" className="num">
                          <span style={{ display: 'inline-flex', flexDirection: 'column', gap: 4 }}>
                            <input
                              type="text"
                              inputMode="decimal"
                              aria-label={`Amount against ${b.doc_no}`}
                              value={draft[b.invoice_id] ?? ''}
                              onChange={(e) => setLine(b.invoice_id, e.target.value)}
                              style={{ textAlign: 'right' }}
                            />
                            <button
                              type="button"
                              className="ghost"
                              style={{ minHeight: 28, padding: '2px 6px', fontSize: 12 }}
                              onClick={() => payWhole(b)}
                            >
                              Pay in full
                            </button>
                            {over && <span className="pill bad">More than this bill owes</span>}
                          </span>
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          )}

          <div className="card card-pad" style={{ marginTop: 12 }}>
            <Row>
              <Field
                label="Amount received"
                htmlFor="rc-amount"
                hint={
                  amountTouched
                    ? extra > 0
                      ? `${fmtMoney(extra)} more than the bills ticked — it stays as credit.`
                      : 'Plain number, no commas.'
                    : 'Adds up from the bills above. Type over it if they paid a round figure.'
                }
              >
                <input
                  id="rc-amount"
                  type="text"
                  inputMode="decimal"
                  value={amountTouched ? amount : applied ? String(applied) : ''}
                  onChange={(e) => {
                    setAmountTouched(true)
                    setAmount(e.target.value)
                  }}
                />
              </Field>

              <Field
                label="Collected by"
                htmlFor="rc-by"
                hint="Who actually took the money."
              >
                <select
                  id="rc-by"
                  value={collectedBy}
                  onChange={(e) => setCollectedBy(e.target.value)}
                >
                  <option value="">Not recorded</option>
                  {users.map((u) => (
                    <option key={u.id} value={u.id}>{u.full_name}</option>
                  ))}
                </select>
              </Field>
            </Row>

            <Field label="Remarks" htmlFor="rc-remarks" hint="Optional — a slip number, a note.">
              <input
                id="rc-remarks"
                type="text"
                value={remarks}
                onChange={(e) => setRemarks(e.target.value)}
              />
            </Field>

            {amountTouched && extra < -0.001 && (
              <Banner tone="bad">
                The bills ticked come to {fmtMoney(applied)}, more than the{' '}
                {fmtMoney(num(amount, 0))} received.
              </Banner>
            )}

            <div style={{ display: 'flex', gap: 8, marginTop: 12, alignItems: 'center' }}>
              <div>
                <div className="sub">Settling</div>
                <div className="strong">{fmtMoney(applied)}</div>
              </div>
              {extra > 0 && (
                <div>
                  <div className="sub">Left as credit</div>
                  <div className="strong">{fmtMoney(extra)}</div>
                </div>
              )}
              <span style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
                <button onClick={() => nav(-1)} disabled={busy}>Back</button>
                <button
                  className="primary"
                  onClick={() => void save()}
                  disabled={busy || !party || (applied <= 0 && !amountTouched)}
                >
                  {busy ? <Spinner /> : 'Save payment'}
                </button>
              </span>
            </div>
          </div>
        </>
      )}

      {!party && (
        <Empty title="Start with the customer">
          Choose who is paying and their unpaid bills appear here to tick off.
        </Empty>
      )}

      {picking && (
        <Picker<PartyRow>
          title="Choose a customer"
          placeholder="Search by name, code or route"
          items={parties}
          keyOf={(p) => p.party_id}
          searchOf={(p) => `${p.party_name} ${p.party_code} ${p.route_name}`}
          onPick={(p) => {
            setParty(p)
            setAmountTouched(false)
            setAmount('')
          }}
          onClose={() => setPicking(false)}
          emptyText="No customers yet."
          render={(p) => (
            <>
              <div className="strong">{p.party_name}</div>
              <div className="sub">
                {p.party_code} · {p.route_name}
                {p.balance != null && <> · owes {fmtMoney(p.balance)}</>}
              </div>
            </>
          )}
        />
      )}
    </>
  )
}
