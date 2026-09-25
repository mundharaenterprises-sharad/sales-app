import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { supabase, friendlyMessage } from '../lib/supabase'
import { fmtDate, fmtMoney } from '../lib/format'
import { Banner, ErrorBanner, Loading } from '../components/ui'
import { Report } from '../components/Report'
import type { ReportColumn } from '../components/Report'
import { AgePill } from '../components/AgePill'
import { BUCKET_LABEL } from '../lib/ageing'

/**
 * One customer's account: what they owe, how old it is, and every document
 * that got them there.
 *
 * The ageing sits at the top because that is the question being asked when
 * somebody opens a ledger — not "what happened" but "how bad is it".
 */

interface Entry {
  entry_date: string
  doc_type: string
  doc_no: string
  doc_id: string | null
  master_code: string | null
  master_name: string | null
  debit: number
  credit: number
  running_balance: number
}

/** What this customer owes, split by master group. */
interface Dues {
  master_code: string
  master_name: string
  sort_order: number
  opening_balance: number
  invoice_outstanding: number
  due: number
}

interface Balance {
  opening_balance: number
  invoice_outstanding: number
  on_account: number
  balance: number
}

interface Ageing {
  total_outstanding: number
  b_0_15: number
  b_16_30: number
  b_31_45: number
  b_46_plus: number
  oldest_days: number
  open_invoices: number
}

interface OpenBill {
  invoice_id: string
  doc_no: string
  master_name: string | null
  invoice_date: string
  effective_total: number
  settled: number
  outstanding: number
  days_outstanding: number
}

const DOC_LABEL: Record<string, string> = {
  OPENING: 'Opening balance',
  INVOICE: 'Bill',
  CANCELLATION: 'Bill cancelled',
  RETURN: 'Return',
  RECEIPT: 'Payment',
}

export default function PartyLedger() {
  const { id } = useParams()
  const nav = useNavigate()

  const [party, setParty] = useState<{ code: string; name: string; route_name: string } | null>(null)
  const [entries, setEntries] = useState<Entry[] | null>(null)
  const [ageing, setAgeing] = useState<Ageing | null>(null)
  const [bills, setBills] = useState<OpenBill[] | null>(null)
  const [dues, setDues] = useState<Dues[]>([])
  const [balance, setBalance] = useState<Balance | null>(null)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    setError(null)
    const [p, l, a, b, d, bal] = await Promise.all([
      supabase.from('v_party_master').select('code, name, route_name').eq('id', id).single(),
      supabase
        .from('v_party_ledger')
        .select('entry_date, doc_type, doc_no, doc_id, master_code, master_name, debit, credit, running_balance')
        .eq('party_id', id)
        .order('entry_date'),
      supabase.from('v_ageing_by_party').select('*').eq('party_id', id).maybeSingle(),
      supabase
        .from('v_invoice_list')
        .select('invoice_id, doc_no, master_name, invoice_date, effective_total, settled, outstanding, days_outstanding')
        .eq('party_id', id)
        .gt('outstanding', 0)
        .order('invoice_date'),
      supabase
        .from('v_party_dues_by_master')
        .select('master_code, master_name, sort_order, opening_balance, invoice_outstanding, due')
        .eq('party_id', id)
        .order('sort_order'),
      supabase
        .from('v_party_balance')
        .select('opening_balance, invoice_outstanding, on_account, balance')
        .eq('party_id', id)
        .maybeSingle(),
    ])

    if (p.error) {
      setError(friendlyMessage(p.error))
      return
    }
    setParty(p.data as { code: string; name: string; route_name: string })
    if (l.error) setError(friendlyMessage(l.error))
    else setEntries((l.data ?? []) as Entry[])
    setAgeing((a.data as Ageing) ?? null)
    setBills(((b.data ?? []) as unknown as OpenBill[]) ?? [])
    setDues(((d.data ?? []) as unknown as Dues[]) ?? [])
    setBalance((bal.data as Balance) ?? null)
  }, [id])

  useEffect(() => {
    void load()
  }, [load])

  const cols: ReportColumn<Entry>[] = useMemo(
    () => [
      { header: 'Date', value: (r) => r.entry_date, cell: (r) => fmtDate(r.entry_date), width: 14 },
      { header: 'Type', value: (r) => DOC_LABEL[r.doc_type] ?? r.doc_type },
      {
        header: 'Document',
        value: (r) => r.doc_no,
        cell: (r) =>
          r.doc_type === 'INVOICE' && r.doc_id ? (
            <Link to={`/invoices/${r.doc_id}`}>{r.doc_no}</Link>
          ) : r.doc_type === 'RECEIPT' && r.doc_id ? (
            <Link to={`/receipts/${r.doc_id}`}>{r.doc_no}</Link>
          ) : (
            r.doc_no
          ),
      },
      {
        header: 'Group',
        value: (r) => r.master_name,
        cell: (r) => r.master_name ?? <span className="muted">—</span>,
        width: 14,
      },
      { header: 'Charged', value: (r) => Number(r.debit) || null, type: 'money', align: 'right' },
      { header: 'Paid / credited', value: (r) => Number(r.credit) || null, type: 'money', align: 'right', width: 18 },
      {
        header: 'Balance',
        value: (r) => Number(r.running_balance),
        type: 'money',
        align: 'right',
        cell: (r) => <span className="strong">{fmtMoney(r.running_balance)}</span>,
      },
    ],
    [],
  )

  if (!party && !error) return <Loading what="Loading ledger" />

  const owed = Number(ageing?.total_outstanding ?? 0)

  return (
    <>
      <div className="no-print">
        <ErrorBanner error={error} />
      </div>

      {party && (
        <div className="card card-pad" style={{ marginBottom: 14 }}>
          <div className="page-head" style={{ marginBottom: 10 }}>
            <h2>{party.name}</h2>
            <span className="sub">{party.code} · {party.route_name}</span>
            <span className="no-print" style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
              <button onClick={() => nav('/parties')}>All parties</button>
              <button className="primary" onClick={() => nav(`/receipts/new?party=${id}`)}>
                Receive payment
              </button>
            </span>
          </div>

          <div className="tiles">
            <div className="tile">
              <h3>Owes in total</h3>
              <div className="stat">{fmtMoney(Number(balance?.balance ?? owed))}</div>
              <p>
                {ageing?.open_invoices ?? 0} open bill{(ageing?.open_invoices ?? 0) === 1 ? '' : 's'}
                {ageing?.oldest_days ? ` · oldest ${ageing.oldest_days} days` : ''}
              </p>
            </div>
            {dues.map((d) => (
              <div className="tile" key={d.master_code}>
                <h3>{d.master_name}</h3>
                <div className="stat">{fmtMoney(Number(d.due))}</div>
                <p>
                  {Number(d.opening_balance) !== 0
                    ? `includes ${fmtMoney(Number(d.opening_balance))} opening`
                    : `${fmtMoney(Number(d.invoice_outstanding))} on bills`}
                </p>
              </div>
            ))}
            {Number(balance?.on_account ?? 0) > 0 && (
              <div className="tile">
                <h3>Paid, not applied</h3>
                <div className="stat">{fmtMoney(Number(balance?.on_account))}</div>
                <p>Money in hand against no particular bill, so it counts to no group yet.</p>
              </div>
            )}
          </div>

          <div className="page-head" style={{ marginTop: 16, marginBottom: 8 }}>
            <h3 style={{ margin: 0 }}>Ageing of unpaid bills</h3>
            <span className="sub">An opening balance carries no bill date, so it is not aged</span>
          </div>

          <div className="tiles">
            {(
              [
                ['0-15', ageing?.b_0_15],
                ['16-30', ageing?.b_16_30],
                ['31-45', ageing?.b_31_45],
                ['46+', ageing?.b_46_plus],
              ] as const
            ).map(([b, v]) => (
              <div className="tile" key={b}>
                <h3>{BUCKET_LABEL[b]}</h3>
                <div className="stat">{fmtMoney(Number(v ?? 0))}</div>
                <p>
                  {owed > 0 ? `${Math.round((Number(v ?? 0) / owed) * 100)}% of what is owed` : '—'}
                </p>
              </div>
            ))}
          </div>
        </div>
      )}

      {bills && bills.length > 0 && (
        <div style={{ marginBottom: 18 }}>
          <div className="page-head">
            <h2>Unpaid bills</h2>
            <span className="sub">Oldest first</span>
          </div>
          <div className="card table-wrap">
            <table className="data">
              <thead>
                <tr>
                  <th>Bill</th>
                  <th>Group</th>
                  <th>Age</th>
                  <th className="num">Bill total</th>
                  <th className="num">Paid</th>
                  <th className="num">Owed</th>
                </tr>
              </thead>
              <tbody>
                {bills.map((b) => (
                  <tr key={b.invoice_id}>
                    <td className="primary-cell">
                      <Link to={`/invoices/${b.invoice_id}`} className="strong">{b.doc_no}</Link>
                      <br />
                      <span className="muted" style={{ fontSize: 12.5 }}>{fmtDate(b.invoice_date)}</span>
                    </td>
                    <td data-label="Group">{b.master_name ?? <span className="muted">—</span>}</td>
                    <td data-label="Age"><AgePill days={b.days_outstanding} /></td>
                    <td data-label="Bill total" className="num">{fmtMoney(b.effective_total)}</td>
                    <td data-label="Paid" className="num muted">{fmtMoney(b.settled)}</td>
                    <td data-label="Owed" className="num strong">{fmtMoney(b.outstanding)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {owed === 0 && bills?.length === 0 && (
        <Banner tone="info">Nothing outstanding — the account is clear.</Banner>
      )}

      <Report<Entry>
        title="Ledger"
        subtitle={party ? `${party.name} (${party.code})` : undefined}
        columns={cols}
        rows={entries}
        error={null}
        fileName={`ledger-${party?.code ?? 'party'}`}
        empty="Nothing on this account yet."
      />
    </>
  )
}
