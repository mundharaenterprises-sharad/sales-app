import { useCallback, useEffect, useState } from 'react'
import { Link, useLocation, useNavigate, useParams } from 'react-router-dom'
import { supabase, friendlyMessage } from '../lib/supabase'
import { fmtDate, fmtMoney, fmtQty } from '../lib/format'
import { Banner, ErrorBanner, Loading, Spinner } from '../components/ui'
import { useSession } from '../lib/session'
import { useDialog } from '../components/Dialog'

/**
 * One return, and what it did.
 *
 * Three things have to be visible here, because each of them is a question
 * somebody will ask weeks later with the document in front of them:
 *
 *   what came back        — the lines
 *   what went back on the shelf, and what did not — the restock flag, per line
 *   where the credit went — the bill it was put against
 *
 * The third is the one that would otherwise be invisible. A credit that has
 * been allocated looks exactly like a credit that has not, unless the screen
 * says so.
 */

interface Row {
  return_id: string
  doc_no: string
  return_date: string
  party_id: string
  party_code: string
  party_name: string
  route_name: string
  invoice_id: string | null
  invoice_no: string | null
  master_name: string | null
  total_value: number
  reason: string
  remarks: string | null
  status: string
  created_by_name: string | null
  qty_base: number
  qty_restocked: number
  qty_written_off: number
  allocated: number
  unallocated: number
}

interface LineRow {
  id: string
  line_no: number
  qty: number
  qty_base: number
  uom: string
  rate: number
  amount: number
  restock: boolean
  product: { code: string; name: string; base_uom: string } | null
}

interface AllocRow {
  invoice_id: string
  amount: number
  invoice: { doc_no: string; invoice_date: string } | null
}

export default function ReturnView() {
  const { id } = useParams()
  const nav = useNavigate()
  const { can } = useSession()
  const state = useLocation().state as
    | { justSaved?: string; allocNote?: string | null }
    | null
  const mayEdit = can('ACCOUNTS', 'ADMIN')
  const { dialog, ask } = useDialog()

  const [row, setRow] = useState<Row | null>(null)
  const [lines, setLines] = useState<LineRow[]>([])
  const [allocs, setAllocs] = useState<AllocRow[]>([])
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    if (!id) return
    setError(null)
    const [h, l, a] = await Promise.all([
      supabase.from('v_return_list').select('*').eq('return_id', id).single(),
      supabase
        .from('sales_return_line')
        .select('id, line_no, qty, qty_base, uom, rate, amount, restock,' +
                ' product:product_id (code, name, base_uom)')
        .eq('return_id', id)
        .order('line_no'),
      supabase
        .from('credit_allocation')
        .select('invoice_id, amount, invoice:invoice_id (doc_no, invoice_date)')
        .eq('sales_return_id', id),
    ])
    if (h.error) { setError(friendlyMessage(h.error)); return }
    setRow(h.data as Row)
    setLines(((l.data ?? []) as unknown) as LineRow[])
    setAllocs(((a.data ?? []) as unknown) as AllocRow[])
  }, [id])

  useEffect(() => { void load() }, [load])

  const cancel = useCallback(() => {
    if (!row) return
    ask({
      title: `Cancel return ${row.doc_no}?`,
      tone: 'bad',
      body: (
        <>
          <p style={{ marginTop: 0 }}>
            The goods that went back on the shelf come out of stock again, and
            the credit against {row.party_name} is withdrawn — so{' '}
            {row.invoice_no ?? 'the bill'} goes back to owing{' '}
            {fmtMoney(row.allocated)} more.
          </p>
          <p style={{ marginBottom: 0 }}>
            The document itself is kept, marked cancelled.
          </p>
        </>
      ),
      ask: { label: 'Why is it being cancelled', required: true },
      actions: [
        { label: 'Keep it', tone: 'plain' },
        {
          label: 'Cancel the return',
          tone: 'danger',
          onPick: async (reason) => {
            setBusy(true)
            const { error } = await supabase.rpc('cancel_sales_return', {
              p_return_id: row.return_id,
              p_reason: reason.trim(),
            })
            setBusy(false)
            if (error) {
              setError(friendlyMessage(error))
              throw new Error(friendlyMessage(error))
            }
            await load()
          },
        },
      ],
    })
  }, [row, ask, load])

  if (!row) {
    return error ? <ErrorBanner error={error} /> : <Loading what="Loading the return" />
  }

  const cancelled = row.status === 'CANCELLED'

  return (
    <>
      {dialog}

      <div className="page-head">
        <h1>Return {row.doc_no}</h1>
        <span style={{ marginLeft: 'auto', display: 'flex', gap: 8, flexWrap: 'wrap' }}>
          <button onClick={() => nav('/returns')}>All returns</button>
          {mayEdit && !cancelled && (
            <button onClick={() => nav(`/returns/new?party=${row.party_id}`)}>
              New return
            </button>
          )}
          {mayEdit && !cancelled && (
            <button onClick={cancel} disabled={busy}>
              {busy ? <Spinner /> : 'Cancel return'}
            </button>
          )}
        </span>
      </div>

      <ErrorBanner error={error} />

      {state?.justSaved && !state.allocNote && (
        <Banner tone="info">
          Return <strong>{state.justSaved}</strong> recorded.
          {row.allocated > 0 && row.invoice_no && (
            <> {fmtMoney(row.allocated)} has come off {row.invoice_no}.</>
          )}
          {row.unallocated > 0 && (
            <> {fmtMoney(row.unallocated)} is left as credit for another bill.</>
          )}
        </Banner>
      )}

      {state?.allocNote && (
        <Banner tone="warn">
          The return was saved, but putting its credit against{' '}
          {row.invoice_no ?? 'the bill'} did not go through: {state.allocNote} The
          credit is sitting against {row.party_name} and can be applied from the
          Payments screen.
        </Banner>
      )}

      {cancelled && (
        <Banner tone="bad">
          This return is cancelled. The goods came back out of stock and the
          credit was withdrawn.
        </Banner>
      )}

      <div className="card card-pad">
        <div className="facts">
          <div className="fact">
            <span className="fact-label">Customer</span>
            <span className="fact-value">
              <Link to={`/parties/${row.party_id}/ledger`}>{row.party_name}</Link>
              <span className="muted"> · {row.party_code} · {row.route_name}</span>
            </span>
          </div>
          <div className="fact">
            <span className="fact-label">Came back on</span>
            <span className="fact-value">{fmtDate(row.return_date)}</span>
          </div>
          <div className="fact">
            <span className="fact-label">Off bill</span>
            <span className="fact-value">
              {row.invoice_id ? (
                <Link to={`/invoices/${row.invoice_id}`}>{row.invoice_no}</Link>
              ) : (
                <span className="muted">not against a bill</span>
              )}
            </span>
          </div>
          <div className="fact">
            <span className="fact-label">Reason</span>
            <span className="fact-value">{row.reason}</span>
          </div>
          {row.remarks && (
            <div className="fact">
              <span className="fact-label">Remarks</span>
              <span className="fact-value">{row.remarks}</span>
            </div>
          )}
          {row.master_name && (
            <div className="fact">
              <span className="fact-label">Group</span>
              <span className="fact-value">{row.master_name}</span>
            </div>
          )}
          <div className="fact">
            <span className="fact-label">Entered by</span>
            <span className="fact-value">{row.created_by_name ?? '—'}</span>
          </div>
        </div>
      </div>

      <div className="card" style={{ marginTop: 12 }}>
        <table className="data">
          <thead>
            <tr>
              <th>Item</th>
              <th className="num">Quantity</th>
              <th className="num">Rate</th>
              <th>Stock</th>
              <th className="num">Credit</th>
            </tr>
          </thead>
          <tbody>
            {lines.map((l) => (
              <tr key={l.id}>
                <td className="primary-cell">
                  <span className="strong">{l.product?.name}</span>
                  <br />
                  <span className="muted" style={{ fontSize: 12.5 }}>{l.product?.code}</span>
                </td>
                <td data-label="Quantity" className="num">
                  {fmtQty(l.qty_base)} {l.product?.base_uom}
                </td>
                <td data-label="Rate" className="num">{fmtMoney(l.rate)}</td>
                <td data-label="Stock">
                  {l.restock ? (
                    <span className="pill good">back on the shelf</span>
                  ) : (
                    <span className="pill warn">written off</span>
                  )}
                </td>
                <td data-label="Credit" className="num">{fmtMoney(l.amount)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="card card-pad" style={{ marginTop: 12 }}>
        <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap' }}>
          <div>
            <div className="sub">Credited</div>
            <div className="strong">{fmtMoney(row.total_value)}</div>
          </div>
          <div>
            <div className="sub">Back on the shelf</div>
            <div className="strong">{fmtQty(row.qty_restocked)}</div>
          </div>
          {Number(row.qty_written_off) > 0 && (
            <div>
              <div className="sub">Written off</div>
              <div className="strong">{fmtQty(row.qty_written_off)}</div>
            </div>
          )}
          <div>
            <div className="sub">Put against bills</div>
            <div className="strong">{fmtMoney(row.allocated)}</div>
          </div>
          {Number(row.unallocated) > 0 && !cancelled && (
            <div>
              <div className="sub">Still loose</div>
              <div className="strong warn">{fmtMoney(row.unallocated)}</div>
            </div>
          )}
        </div>

        {allocs.length > 0 && (
          <p className="hint" style={{ marginTop: 10 }}>
            Taken off{' '}
            {allocs.map((a, i) => (
              <span key={a.invoice_id}>
                {i > 0 && ', '}
                <Link to={`/invoices/${a.invoice_id}`}>{a.invoice?.doc_no}</Link>{' '}
                {fmtMoney(a.amount)}
              </span>
            ))}
            .
          </p>
        )}

        {Number(row.unallocated) > 0 && !cancelled && (
          <p className="hint" style={{ marginTop: 10 }}>
            The rest is credit against {row.party_name}. Put it on a bill from the
            Payments screen whenever you like — it already counts towards what
            they owe in total.
          </p>
        )}
      </div>
    </>
  )
}
