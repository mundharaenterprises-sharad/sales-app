import { useCallback, useEffect, useMemo, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { supabase, friendlyMessage } from '../lib/supabase'
import { fmtDate, fmtMoney, fmtQty, isoDate } from '../lib/format'
import { Banner, ErrorBanner, Loading, Spinner } from '../components/ui'
import { Field, Row, Check, num } from '../components/FormSheet'
import { DateInput } from '../components/DateInput'
import { Picker } from '../components/Picker'
import { useDialog } from '../components/Dialog'

/**
 * Goods coming back from a shop.
 *
 * This is deliberately not "cancel part of the bill". The shop took delivery;
 * what is being recorded is a second event on a later date. So the bill stays
 * as it was raised — that day's sales really did happen — and the return
 * stands beside it as its own document, dated the day the goods arrived back.
 * Stock goes back in on that day too, not on the bill's date, which is the
 * difference that makes a stock figure match a shelf.
 *
 * Two things here are easy to get wrong and are worth the screen space:
 *
 * **Back on the shelf, line by line.** A carton returned because the shop
 * over-ordered is worth selling again. One returned because it is crushed or
 * out of date is not. Both credit the customer the same amount; only one
 * belongs in stock. The box defaults to on, because most returns are the first
 * kind, and it is per line because one delivery can contain both.
 *
 * **The credit goes against the bill it came from.** A return is money the
 * shop no longer owes, and if it is left floating against the account their
 * oldest bill still reads in full. So the allocation happens here, as part of
 * saving, rather than being a second job somebody has to remember. Anything
 * the bill cannot absorb — a return larger than what is still owed on it —
 * stays as credit for the next bill, and the screen says so.
 */

interface PartyRow {
  party_id: string
  party_code: string
  party_name: string
  route_name: string
  balance: number
}

interface BillRow {
  invoice_id: string
  doc_no: string
  invoice_date: string
  effective_total: number
  outstanding: number
  status: string
  is_opening: boolean
}

interface BillLine {
  id: string
  line_no: number
  product_id: string
  uom: 'BASE' | 'PACK'
  qty: number
  qty_base: number
  pack_size: number
  rate: number
  qty_cancelled_base: number
  product: { code: string; name: string; base_uom: string; pack_uom: string | null }
}

interface Line {
  key: string
  invoiceLineId: string | null
  productId: string
  code: string
  name: string
  baseUom: string
  /** What is left to come back, in base units. */
  room: number
  rate: number
  qty: string
  restock: boolean
}

export default function NewReturn() {
  const nav = useNavigate()
  const [params] = useSearchParams()
  const { dialog, ask } = useDialog()

  const [parties, setParties] = useState<PartyRow[] | null>(null)
  const [party, setParty] = useState<PartyRow | null>(null)
  const [picking, setPicking] = useState(false)

  const [bills, setBills] = useState<BillRow[] | null>(null)
  const [bill, setBill] = useState<BillRow | null>(null)
  const [pickingBill, setPickingBill] = useState(false)

  const [lines, setLines] = useState<Line[]>([])
  const [loadingLines, setLoadingLines] = useState(false)

  const [date, setDate] = useState(
    params.get('date') || isoDate(),
  )
  const [reason, setReason] = useState('')
  const [remarks, setRemarks] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let alive = true
    void (async () => {
      const { data } = await supabase
        .from('v_party_balance')
        .select('party_id, party_code, party_name, route_name, balance')
        .order('party_name')
      if (!alive) return
      const rows = (data ?? []) as PartyRow[]
      setParties(rows)
      const want = params.get('party')
      if (want) setParty(rows.find((p) => p.party_id === want) ?? null)
    })()
    return () => { alive = false }
  }, [params])

  // That customer's bills, newest first — a return is nearly always against
  // something recent.
  useEffect(() => {
    let alive = true
    setBills(null)
    setBill(null)
    setLines([])
    if (!party) return
    void (async () => {
      const { data, error } = await supabase
        .from('v_invoice_list')
        .select('invoice_id, doc_no, invoice_date, effective_total, outstanding, status, is_opening')
        .eq('party_id', party.party_id)
        .neq('status', 'CANCELLED')
        .order('invoice_date', { ascending: false })
        .order('doc_no', { ascending: false })
      if (!alive) return
      if (error) { setError(friendlyMessage(error)); setBills([]); return }
      setBills(((data ?? []) as BillRow[]).filter((b) => !b.is_opening))
    })()
    return () => { alive = false }
  }, [party])

  /**
   * The bill's lines, with the room left on each.
   *
   * Room is what was billed, less anything already cancelled off it, less
   * anything returned against it before. Without the last of those, a shop
   * could return the same carton twice over three visits and the credit would
   * exceed the sale.
   */
  const loadBill = useCallback(async (b: BillRow) => {
    setBill(b)
    setLines([])
    setLoadingLines(true)
    setError(null)

    const [inv, prior] = await Promise.all([
      supabase
        .from('sales_invoice_line')
        .select(
          'id, line_no, product_id, uom, qty, qty_base, pack_size, rate, qty_cancelled_base,' +
            ' product:product_id (code, name, base_uom, pack_uom)',
        )
        .eq('invoice_id', b.invoice_id)
        .order('line_no'),
      supabase
        .from('sales_return_line')
        .select('invoice_line_id, qty_base, sales_return:return_id (status, invoice_id)')
        .eq('sales_return.invoice_id', b.invoice_id),
    ])
    setLoadingLines(false)

    if (inv.error) { setError(friendlyMessage(inv.error)); return }

    const returned = new Map<string, number>()
    for (const r of (prior.data ?? []) as unknown as {
      invoice_line_id: string | null
      qty_base: number
      sales_return: { status: string } | null
    }[]) {
      if (!r.invoice_line_id) continue
      if (r.sales_return?.status !== 'ACTIVE') continue
      returned.set(r.invoice_line_id,
        (returned.get(r.invoice_line_id) ?? 0) + Number(r.qty_base || 0))
    }

    const rows = (inv.data ?? []) as unknown as BillLine[]
    setLines(
      rows
        .map((l) => {
          const room =
            Number(l.qty_base) -
            Number(l.qty_cancelled_base || 0) -
            (returned.get(l.id) ?? 0)
          return {
            key: l.id,
            invoiceLineId: l.id,
            productId: l.product_id,
            code: l.product.code,
            name: l.product.name,
            baseUom: l.product.base_uom,
            room,
            // Per base unit, whatever the bill was written in: the return is
            // entered in pieces, so the rate has to be in pieces too or the
            // credit comes out forty times too big.
            rate: Number(l.rate) / (l.uom === 'PACK' ? Number(l.pack_size) || 1 : 1),
            qty: '',
            restock: true,
          }
        })
        .filter((l) => l.room > 0),
    )
  }, [])

  const chosen = useMemo(
    () => lines.filter((l) => num(l.qty, 0) > 0),
    [lines],
  )

  const value = useMemo(
    () => chosen.reduce((s, l) => s + Math.round(num(l.qty, 0) * l.rate * 100) / 100, 0),
    [chosen],
  )

  const tooMuch = useMemo(
    () => lines.filter((l) => num(l.qty, 0) > l.room),
    [lines],
  )

  const setLine = (key: string, patch: Partial<Line>) =>
    setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)))

  /** Post the return, then put its credit against the bill it came from. */
  const doSave = useCallback(async () => {
    if (!party || !bill) return
    setBusy(true)
    const { data, error } = await supabase.rpc('post_sales_return', {
      p_party_id: party.party_id,
      p_return_date: date,
      p_invoice_id: bill.invoice_id,
      p_reason: reason.trim(),
      p_remarks: remarks.trim() || null,
      p_lines: chosen.map((l) => ({
        product_id: l.productId,
        invoice_line_id: l.invoiceLineId,
        uom: 'BASE',
        qty: num(l.qty, 0),
        rate: l.rate,
        restock: l.restock,
      })),
    })

    if (error) {
      setBusy(false)
      setError(friendlyMessage(error))
      // Thrown so a dialog that triggered this stays open with the message.
      throw new Error(friendlyMessage(error))
    }

    const res = (data ?? {}) as { return_id?: string; doc_no?: string; total_value?: number }

    /**
     * Put the credit where it came from.
     *
     * Capped at what the bill still owes: a return larger than the unpaid part
     * of a bill cannot be forced onto it, and the rest is left as credit the
     * office can put against something else. A separate call because posting
     * the return is the part that must not be lost — if this one fails the
     * return still exists, and the next screen says it is waiting to be put
     * against a bill rather than pretending nothing happened.
     */
    const room = Math.min(Number(res.total_value ?? 0), Number(bill.outstanding || 0))
    let allocNote: string | null = null
    if (room > 0 && res.return_id) {
      const alloc = await supabase.rpc('allocate_credit', {
        p_sales_return_id: res.return_id,
        p_allocations: [{ invoice_id: bill.invoice_id, amount: room }],
      })
      if (alloc.error) allocNote = friendlyMessage(alloc.error)
    }

    setBusy(false)
    nav(`/returns/${res.return_id}`, {
      replace: true,
      state: { justSaved: res.doc_no, allocNote },
    })
  }, [party, bill, chosen, reason, remarks, date, nav])

  const save = useCallback(() => {
    if (!party || !bill) return
    setError(null)

    if (chosen.length === 0) {
      return setError('Put a quantity against at least one item.')
    }
    if (tooMuch.length > 0) {
      return setError(
        `More is coming back than went out on ${tooMuch[0].name}. ` +
          `At most ${fmtQty(tooMuch[0].room)} ${tooMuch[0].baseUom}.`,
      )
    }
    if (!reason.trim()) {
      return setError('Say why the goods came back — it goes on the document.')
    }

    // Writing goods off is the one choice here that cannot be seen on the
    // document afterwards without reading it line by line, so it is confirmed.
    const writeOff = chosen.filter((l) => !l.restock)
    if (writeOff.length === 0) {
      void doSave()
      return
    }

    ask({
      title: 'Some of this is not going back on the shelf',
      tone: 'warn',
      body: (
        <>
          <p style={{ marginTop: 0 }}>
            {writeOff.map((l) => l.name).join(', ')} will credit{' '}
            {fmtMoney(writeOff.reduce((s, l) => s + num(l.qty, 0) * l.rate, 0))} to{' '}
            {party.party_name} without going back into stock.
          </p>
          <p style={{ marginBottom: 0 }}>
            Right for damaged or expired goods. Wrong for anything you can sell
            again.
          </p>
        </>
      ),
      actions: [
        { label: 'Go back', tone: 'plain' },
        { label: 'That is right', tone: 'primary', onPick: () => doSave() },
      ],
    })
  }, [party, bill, chosen, tooMuch, reason, ask, doSave])


  if (parties === null) return <Loading what="Loading customers" />

  return (
    <>
      {dialog}

      <div className="page-head">
        <h1>Goods returned</h1>
        <span className="sub">What came back, and off which bill</span>
      </div>

      <ErrorBanner error={error} />

      <div className="card card-pad">
        <Row>
          <Field label="Customer" htmlFor="rt-party">
            <button type="button" className="block" onClick={() => setPicking(true)}>
              {party ? party.party_name : 'Choose a customer'}
            </button>
          </Field>

          <Field
            label="Came back on"
            htmlFor="rt-date"
            hint="Stock goes back in on this day, not the bill's day."
          >
            <DateInput id="rt-date" value={date} onChange={setDate} />
          </Field>
        </Row>

        {party && (
          <Field
            label="Off which bill"
            htmlFor="rt-bill"
            hint="The credit comes off this bill's balance."
          >
            <button
              type="button"
              className="block"
              onClick={() => setPickingBill(true)}
              disabled={!bills || bills.length === 0}
            >
              {bill
                ? `${bill.doc_no} · ${fmtDate(bill.invoice_date)} · ${fmtMoney(bill.outstanding)} still owed`
                : bills === null
                  ? 'Loading bills…'
                  : bills.length === 0
                    ? 'This customer has no bills'
                    : 'Choose a bill'}
            </button>
          </Field>
        )}
      </div>

      {bill && (
        <>
          {loadingLines ? (
            <Loading what="Loading the bill" />
          ) : lines.length === 0 ? (
            <Banner tone="warn">
              Everything on {bill.doc_no} has already been returned or cancelled.
            </Banner>
          ) : (
            <div className="card" style={{ marginTop: 12 }}>
              <table className="data">
                <thead>
                  <tr>
                    <th>Item</th>
                    <th className="num">Can come back</th>
                    <th className="num">Rate</th>
                    <th className="num">Coming back</th>
                    <th>Back on the shelf</th>
                    <th className="num">Credit</th>
                  </tr>
                </thead>
                <tbody>
                  {lines.map((l) => {
                    const q = num(l.qty, 0)
                    const over = q > l.room
                    return (
                      <tr key={l.key}>
                        <td className="primary-cell">
                          <span className="strong">{l.name}</span>
                          <br />
                          <span className="muted" style={{ fontSize: 12.5 }}>{l.code}</span>
                        </td>
                        <td data-label="Can come back" className="num">
                          {fmtQty(l.room)} {l.baseUom}
                        </td>
                        <td data-label="Rate" className="num">{fmtMoney(l.rate)}</td>
                        <td data-label="Coming back" className="num">
                          <input
                            type="text"
                            inputMode="decimal"
                            aria-label={`Quantity of ${l.name} coming back`}
                            value={l.qty}
                            onChange={(e) => setLine(l.key, { qty: e.target.value })}
                            style={{ textAlign: 'right', width: 90 }}
                          />
                          {over && (
                            <>
                              <br />
                              <span className="pill bad">more than went out</span>
                            </>
                          )}
                        </td>
                        <td data-label="Back on the shelf">
                          <Check
                            id={`rs-${l.key}`}
                            checked={l.restock}
                            disabled={q === 0}
                            onChange={(v) => setLine(l.key, { restock: v })}
                          >
                            {l.restock ? 'Resaleable' : 'Written off'}
                          </Check>
                        </td>
                        <td data-label="Credit" className="num">
                          {q > 0 ? fmtMoney(q * l.rate) : <span className="muted">—</span>}
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          )}

          <div className="card card-pad" style={{ marginTop: 12 }}>
            <Field
              label="Why did it come back"
              htmlFor="rt-reason"
              hint="Goes on the document — damaged, wrong item, over-ordered, expired."
            >
              <input
                id="rt-reason"
                type="text"
                value={reason}
                onChange={(e) => setReason(e.target.value)}
              />
            </Field>

            <Field label="Remarks" htmlFor="rt-remarks" hint="Optional.">
              <input
                id="rt-remarks"
                type="text"
                value={remarks}
                onChange={(e) => setRemarks(e.target.value)}
              />
            </Field>

            {value > Number(bill.outstanding) && (
              <Banner tone="warn">
                This comes to {fmtMoney(value)}, more than the{' '}
                {fmtMoney(bill.outstanding)} still owed on {bill.doc_no}. The rest
                stays as credit for another bill.
              </Banner>
            )}

            <div style={{ display: 'flex', gap: 16, marginTop: 12, alignItems: 'center' }}>
              <div>
                <div className="sub">Credit to {party?.party_name}</div>
                <div className="strong">{fmtMoney(value)}</div>
              </div>
              <span style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
                <button onClick={() => nav(-1)} disabled={busy}>Back</button>
                <button
                  id="rt-save"
                  className="primary"
                  onClick={() => save()}
                  disabled={busy || chosen.length === 0 || tooMuch.length > 0}
                >
                  {busy ? <Spinner /> : 'Save return'}
                </button>
              </span>
            </div>
          </div>
        </>
      )}

      {picking && parties && (
        <Picker<PartyRow>
          title="Choose a customer"
          placeholder="Search by name, code or route"
          items={parties}
          keyOf={(p) => p.party_id}
          searchOf={(p) => `${p.party_name} ${p.party_code} ${p.route_name}`}
          onPick={(p) => { setParty(p); setPicking(false) }}
          onClose={() => setPicking(false)}
          render={(p) => (
            <>
              <div className="strong">{p.party_name}</div>
              <div className="sub">
                {p.party_code} · {p.route_name} · owes {fmtMoney(p.balance)}
              </div>
            </>
          )}
        />
      )}

      {pickingBill && bills && (
        <Picker<BillRow>
          title="Choose the bill"
          placeholder="Search by bill number"
          items={bills}
          keyOf={(b) => b.invoice_id}
          searchOf={(b) => `${b.doc_no} ${b.invoice_date}`}
          onPick={(b) => { void loadBill(b); setPickingBill(false) }}
          onClose={() => setPickingBill(false)}
          render={(b) => (
            <>
              <div className="strong">{b.doc_no}</div>
              <div className="sub">
                {fmtDate(b.invoice_date)} · {fmtMoney(b.effective_total)} ·{' '}
                {Number(b.outstanding) > 0
                  ? `${fmtMoney(b.outstanding)} still owed`
                  : 'paid'}
              </div>
            </>
          )}
        />
      )}
    </>
  )
}
