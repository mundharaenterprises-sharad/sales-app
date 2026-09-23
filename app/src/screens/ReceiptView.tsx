import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, useLocation, useNavigate, useParams } from 'react-router-dom'
import { supabase, friendlyMessage } from '../lib/supabase'
import { fmtDate, fmtMoney } from '../lib/format'
import { Banner, Empty, ErrorBanner, Loading, Spinner } from '../components/ui'
import { num } from '../components/FormSheet'
import { useSession } from '../lib/session'
import { AgePill } from '../components/AgePill'

/**
 * One payment, and which bills it pays.
 *
 * Allocation is always a decision, never a side effect: the boxes start empty
 * and money lands on a bill only because somebody typed it there. What is sent
 * is the complete picture for this payment, so clearing a box takes that
 * settlement back off the bill.
 */

interface Receipt {
  id: string
  doc_no: string
  receipt_date: string
  amount: number
  status: string
  remarks: string | null
  cancel_reason: string | null
  party_id: string
  party: { code: string; name: string; route: { name: string } | null } | null
  collector: { full_name: string } | null
}

interface OpenBill {
  invoice_id: string
  doc_no: string
  invoice_date: string
  effective_total: number
  settled: number
  outstanding: number
  days_outstanding: number
  status: string
}

export default function ReceiptView() {
  const { id } = useParams()
  const nav = useNavigate()
  const { can } = useSession()
  const justSaved = (useLocation().state as { justSaved?: string } | null)?.justSaved
  const mayEdit = can('ACCOUNTS', 'ADMIN')

  const [receipt, setReceipt] = useState<Receipt | null>(null)
  const [bills, setBills] = useState<OpenBill[] | null>(null)
  /** What this payment has already settled, by invoice. */
  const [applied, setApplied] = useState<Record<string, number>>({})
  /** What is typed in the boxes now. */
  const [draft, setDraft] = useState<Record<string, string>>({})

  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [saved, setSaved] = useState(false)

  const load = useCallback(async () => {
    setError(null)
    const r = await supabase
      .from('receipt')
      .select(
        'id, doc_no, receipt_date, amount, status, remarks, cancel_reason, party_id,' +
          ' party:party_id (code, name, route:route_id (name)),' +
          ' collector:collected_by (full_name)',
      )
      .eq('id', id)
      .single()

    if (r.error) {
      setError(friendlyMessage(r.error))
      return
    }
    const rec = r.data as unknown as Receipt
    setReceipt(rec)

    const [b, a] = await Promise.all([
      supabase
        .from('v_invoice_list')
        .select(
          'invoice_id, doc_no, invoice_date, effective_total, settled, outstanding,' +
            ' days_outstanding, status',
        )
        .eq('party_id', rec.party_id)
        .neq('status', 'CANCELLED')
        .order('invoice_date'),
      supabase.from('credit_allocation').select('invoice_id, amount').eq('receipt_id', id),
    ])

    if (b.error) {
      setError(friendlyMessage(b.error))
      return
    }

    const mine: Record<string, number> = {}
    for (const x of (a.data ?? []) as { invoice_id: string; amount: number }[]) {
      mine[x.invoice_id] = Number(x.amount)
    }
    setApplied(mine)
    setDraft(
      Object.fromEntries(
        Object.entries(mine).map(([k, v]) => [k, String(v)]),
      ),
    )

    // Bills still owing, plus any this payment is already sitting on.
    setBills(
      ((b.data ?? []) as unknown as OpenBill[]).filter(
        (x) => Number(x.outstanding) > 0 || mine[x.invoice_id] != null,
      ),
    )
  }, [id])

  useEffect(() => {
    void load()
  }, [load])

  /** What a bill still owes, ignoring this payment's own contribution. */
  const owedIgnoringThis = (b: OpenBill) =>
    Math.round((Number(b.outstanding) + (applied[b.invoice_id] ?? 0)) * 100) / 100

  const typed = useMemo(
    () =>
      Object.values(draft).reduce((s, v) => {
        const n = num(v, 0)
        return s + (Number.isNaN(n) ? 0 : n)
      }, 0),
    [draft],
  )

  const left = receipt ? Math.round((Number(receipt.amount) - typed) * 100) / 100 : 0
  const dirty = useMemo(() => {
    const keys = new Set([...Object.keys(applied), ...Object.keys(draft)])
    for (const k of keys) {
      const a = applied[k] ?? 0
      const d = num(draft[k] ?? '', 0)
      if ((Number.isNaN(d) ? 0 : d) !== a) return true
    }
    return false
  }, [applied, draft])

  const apply = useCallback(async () => {
    if (!receipt) return
    setError(null)
    setSaved(false)

    const allocations: { invoice_id: string; amount: number }[] = []
    for (const [invoice_id, v] of Object.entries(draft)) {
      const n = num(v, 0)
      if (Number.isNaN(n) || n < 0) {
        setError('Amounts must be plain numbers, 0 or more — no commas.')
        return
      }
      if (n > 0) allocations.push({ invoice_id, amount: n })
    }

    if (typed > Number(receipt.amount) + 0.001) {
      setError(
        `That is ${fmtMoney(typed)} against a payment of ${fmtMoney(receipt.amount)}.`,
      )
      return
    }

    setBusy(true)
    const { error } = await supabase.rpc('allocate_credit', {
      p_allocations: allocations,
      p_receipt_id: receipt.id,
      p_sales_return_id: null,
    })
    setBusy(false)

    if (error) {
      setError(friendlyMessage(error))
      return
    }
    setSaved(true)
    await load()
  }, [receipt, draft, typed, load])

  const cancel = useCallback(async () => {
    if (!receipt) return
    const reason = window.prompt(
      `Cancel payment ${receipt.doc_no} of ${fmtMoney(receipt.amount)}?\n\n` +
        'Anything it was paying goes back to being owed. Say why:',
    )
    if (reason === null) return
    if (!reason.trim()) {
      setError('A cancellation needs a reason.')
      return
    }

    setBusy(true)
    const { error } = await supabase.rpc('cancel_receipt', {
      p_receipt_id: receipt.id,
      p_reason: reason.trim(),
    })
    setBusy(false)

    if (error) setError(friendlyMessage(error))
    else await load()
  }, [receipt, load])

  if (!receipt && !error) return <Loading what="Loading payment" />

  const live = receipt?.status === 'ACTIVE'

  return (
    <>
      <div className="page-head">
        <h1>Payment {receipt?.doc_no}</h1>
        <span style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
          <button onClick={() => nav('/receipts')}>All payments</button>
          {mayEdit && live && (
            <button onClick={() => void cancel()} disabled={busy}>
              {busy ? <Spinner /> : 'Cancel payment'}
            </button>
          )}
        </span>
      </div>

      <ErrorBanner error={error} />

      {justSaved && (
        <Banner tone="info">
          Payment <strong>{justSaved}</strong> recorded. Now put it against the bills
          it pays, below.
        </Banner>
      )}

      {receipt && !live && (
        <Banner tone="bad">
          This payment is cancelled{receipt.cancel_reason && `: ${receipt.cancel_reason}`}.
          Whatever it was paying is owed again.
        </Banner>
      )}

      {receipt && (
        <div className="card card-pad">
          <div className="tiles">
            <div className="tile">
              <h3>Customer</h3>
              <div className="strong">{receipt.party?.name}</div>
              <p>
                {receipt.party?.code}
                {receipt.party?.route && ` · ${receipt.party.route.name}`}
              </p>
            </div>
            <div className="tile">
              <h3>Amount</h3>
              <div className="stat">{fmtMoney(receipt.amount)}</div>
              <p>
                {fmtDate(receipt.receipt_date)}
                {receipt.collector && ` · ${receipt.collector.full_name}`}
              </p>
            </div>
            <div className="tile">
              <h3>Not yet applied</h3>
              <div className="stat">{fmtMoney(live ? left : 0)}</div>
              <p>{live ? 'of this payment' : 'payment cancelled'}</p>
            </div>
          </div>
          {receipt.remarks && <p className="hint" style={{ marginTop: 10 }}>{receipt.remarks}</p>}
        </div>
      )}

      {live && (
        <>
          <div className="page-head" style={{ marginTop: 18 }}>
            <h2>Put it against bills</h2>
            <span className="sub">Oldest first. Type what this payment pays.</span>
          </div>

          {saved && !dirty && (
            <Banner tone="info">Saved. The bills below now show what is left on them.</Banner>
          )}

          {bills === null ? (
            <Loading what="Loading bills" />
          ) : bills.length === 0 ? (
            <Empty title="Nothing outstanding">
              This customer has no unpaid bills. The payment stays on account until
              a bill is raised, and can be applied then.
            </Empty>
          ) : (
            <>
              <div className="card table-wrap">
                <table className="data">
                  <thead>
                    <tr>
                      <th>Bill</th>
                      <th>Age</th>
                      <th className="num">Bill total</th>
                      <th className="num">Owed</th>
                      <th className="num" style={{ width: 160 }}>This payment</th>
                    </tr>
                  </thead>
                  <tbody>
                    {bills.map((b) => {
                      const owed = owedIgnoringThis(b)
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
                          <td data-label="Owed" className="num">
                            {fmtMoney(owed)}
                            {(applied[b.invoice_id] ?? 0) > 0 && (
                              <>
                                <br />
                                <span className="muted" style={{ fontSize: 12 }}>
                                  incl. {fmtMoney(applied[b.invoice_id])} from this payment
                                </span>
                              </>
                            )}
                          </td>
                          <td data-label="This payment" className="num">
                            <span style={{ display: 'inline-flex', flexDirection: 'column', gap: 4 }}>
                              <input
                                type="text"
                                inputMode="decimal"
                                aria-label={`Amount against ${b.doc_no}`}
                                value={draft[b.invoice_id] ?? ''}
                                disabled={!mayEdit}
                                onChange={(e) =>
                                  setDraft((d) => ({ ...d, [b.invoice_id]: e.target.value }))
                                }
                                style={{ textAlign: 'right' }}
                              />
                              {mayEdit && (
                                <button
                                  type="button"
                                  className="ghost"
                                  style={{ minHeight: 28, padding: '2px 6px', fontSize: 12 }}
                                  onClick={() =>
                                    setDraft((d) => ({
                                      ...d,
                                      [b.invoice_id]: String(Math.min(owed, Math.max(left + v, 0))),
                                    }))
                                  }
                                >
                                  Pay this bill
                                </button>
                              )}
                              {over && (
                                <span className="pill bad">More than this bill owes</span>
                              )}
                            </span>
                          </td>
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              </div>

              <div className="card card-pad" style={{ marginTop: 12 }}>
                <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap', alignItems: 'center' }}>
                  <div>
                    <div className="sub">Being applied</div>
                    <div className="strong">{fmtMoney(typed)}</div>
                  </div>
                  <div>
                    <div className="sub">Left on this payment</div>
                    <div className={`strong ${left < 0 ? 'bad' : ''}`}>{fmtMoney(left)}</div>
                  </div>
                  {mayEdit && (
                    <span style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
                      <button onClick={() => setDraft({})} disabled={busy || typed === 0}>
                        Clear all
                      </button>
                      <button
                        className="primary"
                        onClick={() => void apply()}
                        disabled={busy || left < -0.001 || !dirty}
                      >
                        {busy ? <Spinner /> : 'Save'}
                      </button>
                    </span>
                  )}
                </div>
                <p className="hint" style={{ marginTop: 10 }}>
                  Money left over stays on this payment and can be applied to a later
                  bill. Clearing a box and saving takes that amount back off the bill.
                </p>
              </div>
            </>
          )}
        </>
      )}
    </>
  )
}
