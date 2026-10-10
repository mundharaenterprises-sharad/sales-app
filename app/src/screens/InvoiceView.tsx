import { useCallback, useEffect, useRef, useState } from 'react'
import { Link, useLocation, useNavigate, useParams } from 'react-router-dom'
import { supabase, friendlyMessage } from '../lib/supabase'
import { fmtMoney, fmtQty, isoDate } from '../lib/format'
import { Banner, ErrorBanner, Loading, Spinner } from '../components/ui'
import { BillSheet, BILL_SELECT } from '../components/BillSheet'
import type { Bill } from '../components/BillSheet'
import { useSession } from '../lib/session'
import { useBillPage, useDocumentTitle } from '../lib/printpage'
import { shareElementAsImage, canShareFiles } from '../lib/sharebill'

/**
 * One bill, laid out as it prints.
 *
 * The same markup serves the screen and the printer: everything marked
 * `no-print` drops away and the sheet sizes itself to A5. What the customer
 * gets is therefore what the office sees, which is the only way a reprint can
 * be trusted to match the original.
 */
export default function InvoiceView() {
  useBillPage()
  const { id } = useParams()
  const nav = useNavigate()
  const { can } = useSession()
  const navState = useLocation().state as
    | { justCreated?: string; replaced?: string }
    | null
  const justCreated = navState?.justCreated
  const replaced = navState?.replaced
  // What has come back against this bill. Worth saying out loud: a bill whose
  // balance has dropped with no payment against it otherwise reads as an error.
  const [returned, setReturned] = useState<{
    returns: number; return_nos: string; qty_base: number; value: number
  } | null>(null)

  const [inv, setInv] = useState<Bill | null>(null)
  const [link, setLink] = useState<{
    replaces_doc_no: string | null
    replaced_by_doc_no: string | null
    replaced_by_invoice_id: string | null
    replaces_invoice_id: string | null
  } | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [sharing, setSharing] = useState(false)
  const [shareNote, setShareNote] = useState<string | null>(null)
  const sheetRef = useRef<HTMLDivElement>(null)

  /**
   * Send the bill to the shopkeeper as a picture.
   *
   * Drawn from the sheet that prints, so the copy they get is the document,
   * not a retelling of it.
   */
  const share = useCallback(async () => {
    const node = sheetRef.current?.querySelector<HTMLElement>('.sheet-a5')
    if (!node || !inv) return
    setShareNote(null)
    setSharing(true)
    try {
      const outcome = await shareElementAsImage(node, {
        filename: `${inv.doc_no}.png`,
        title: inv.doc_no,
        text: `${inv.doc_no} — ${inv.party.name} — ${fmtMoney(inv.net_total)}`,
      })
      if (outcome === 'downloaded') {
        setShareNote('Saved as a picture — attach it from your downloads.')
      }
    } catch (e) {
      setShareNote(friendlyMessage(e))
    } finally {
      setSharing(false)
    }
  }, [inv])

  // If the browser insists on printing a title, let it be the bill's number.
  useDocumentTitle(inv?.doc_no ?? null)

  const load = useCallback(async () => {
    setError(null)
    const [i, l, ret] = await Promise.all([
      supabase.from('sales_invoice').select(BILL_SELECT).eq('id', id).single(),
      supabase
        .from('v_invoice_list')
        .select(
          'replaces_doc_no, replaces_invoice_id, replaced_by_doc_no, replaced_by_invoice_id',
        )
        .eq('invoice_id', id)
        .single(),
      supabase
        .from('v_invoice_returns')
        .select('returns, return_nos, qty_base, value')
        .eq('invoice_id', id)
        .maybeSingle(),
    ])

    if (i.error) {
      setError(friendlyMessage(i.error))
      return
    }
    // Defensive, and it earned its place: a reply that is not a bill used to
    // render as a white screen with a console error, because everything below
    // reads bill.party.name. A missing bill should say so.
    const row = i.data as unknown as Bill | null
    if (!row || !row.doc_no || !row.party) {
      setError('That bill could not be found.')
      return
    }
    setInv(row)
    if (!l.error) setLink(l.data as typeof link)
    setReturned(ret.error ? null : (ret.data as typeof returned))
  }, [id])

  useEffect(() => {
    void load()
  }, [load])

  const cancel = useCallback(async () => {
    if (!inv) return
    const reason = window.prompt(
      `Cancel bill ${inv.doc_no} for ${inv.party.name}?\n\n` +
        'The goods go back into stock and the customer stops owing it. The bill ' +
        'itself is kept and can still be printed, marked cancelled. Say why:',
    )
    if (reason === null) return
    if (!reason.trim()) {
      setError('A cancellation needs a reason.')
      return
    }

    setBusy(true)
    const { error } = await supabase.rpc('cancel_sales_invoice', {
      p_invoice_id: inv.id,
      p_reason: reason.trim(),
    })
    setBusy(false)

    if (error) setError(friendlyMessage(error))
    else await load()
  }, [inv, load])

  // A mistake can be corrected on the day the bill was raised, and only while
  // no payment has been put against it. The database has the final say; this
  // just decides whether to offer the button.
  const invParty = (inv as unknown as { party_id?: string } | null)?.party_id ?? ''
  const today = isoDate()
  const canCorrect =
    inv != null && inv.status === 'ACTIVE' && inv.invoice_date === today

  // A balance brought forward is not a bill: nothing was sold, so there is
  // nothing to print, correct or cancel. It can only be paid.
  const opening = (inv as unknown as { is_opening?: boolean } | null)?.is_opening === true

  if (!inv && !error) return <Loading what="Loading bill" />

  return (
    <>
      <div className="page-head no-print">
        <h1>{opening ? 'Opening balance' : `Bill ${inv?.doc_no ?? ''}`}</h1>
        <span style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
          <button onClick={() => nav('/invoices')}>All bills</button>
          {/*
            Billing a round is one bill after another. Landing on the preview
            and having to go back to the list for each one turns a rhythm into
            a chore, so the next bill starts from here.
          */}
          {can('ACCOUNTS', 'ADMIN') && (
            <button onClick={() => nav('/invoices/new')}>New bill</button>
          )}
          {!opening && (
            <button onClick={() => void share()} disabled={!inv || sharing}>
              {sharing ? <Spinner /> : canShareFiles() ? 'Send' : 'Save as picture'}
            </button>
          )}
          {!opening && (
            <button className="primary" onClick={() => window.print()} disabled={!inv}>
              Print
            </button>
          )}
          {can('ACCOUNTS', 'ADMIN') && inv?.status !== 'CANCELLED' && (
            <button
              className={opening ? 'primary' : undefined}
              onClick={() => nav(`/receipts/new?party=${invParty}&invoice=${inv!.id}`)}
            >
              Record payment
            </button>
          )}
          {can('ACCOUNTS', 'ADMIN') && canCorrect && !opening && (
            <button onClick={() => nav(`/invoices/new?revise=${inv!.id}`)} disabled={busy}>
              Correct bill
            </button>
          )}
          {can('ACCOUNTS', 'ADMIN') && inv?.status !== 'CANCELLED' && !opening && (
            <button onClick={() => void cancel()} disabled={busy}>
              {busy ? <Spinner /> : 'Cancel bill'}
            </button>
          )}
        </span>
      </div>

      <div className="no-print">
        <ErrorBanner error={error} />

        {inv?.is_cash && inv.status !== 'CANCELLED' && (
          <Banner tone="info">
            <strong>Cash sale.</strong> The money was taken with the bill, so this
            customer owes nothing for it. Cancelling the bill will not hand the
            cash back — it stays on their account as credit.
          </Banner>
        )}
        {justCreated && (
          <Banner tone="info">
            Bill <strong>{justCreated}</strong> saved. The goods have left stock and
            the customer now owes it.
            {replaced && (
              <> It replaces <strong>{replaced}</strong>, which is now cancelled.</>
            )}
            {canCorrect && ' Typed something wrongly? Use Correct bill — today only.'}
          </Banner>
        )}
        {inv?.status === 'CANCELLED' && (
          <Banner tone="bad">
            This bill is cancelled. It is kept for the record and the goods went back
            into stock.
            {link?.replaced_by_doc_no && (
              <>
                {' '}It was corrected — the bill that replaced it is{' '}
                <Link to={`/invoices/${link.replaced_by_invoice_id}`}>
                  {link.replaced_by_doc_no}
                </Link>
                .
              </>
            )}
          </Banner>
        )}
        {link?.replaces_doc_no && inv?.status !== 'CANCELLED' && (
          <Banner tone="info">
            This bill corrects{' '}
            <Link to={`/invoices/${link.replaces_invoice_id}`}>{link.replaces_doc_no}</Link>,
            which is cancelled.
          </Banner>
        )}
        {inv?.status === 'PARTIALLY_CANCELLED' && (
          <Banner tone="warn">
            Part of this bill has been cancelled. {fmtMoney(inv.cancelled_value)} of{' '}
            {fmtMoney(inv.net_total)} was taken off.
          </Banner>
        )}
        {returned && Number(returned.value) > 0 && (
          <Banner tone="warn">
            {fmtQty(returned.qty_base)} came back against this bill on{' '}
            {returned.returns === 1 ? 'return' : 'returns'}{' '}
            <strong>{returned.return_nos}</strong>, crediting{' '}
            {fmtMoney(returned.value)}. The bill itself is unchanged — the
            credit is against what the customer owes.
          </Banner>
        )}
      </div>

      {inv && opening ? (
        <div className="card card-pad">
          <h2>{inv.doc_no}</h2>
          <p className="sub" style={{ marginTop: 4 }}>
            What this customer owed when the app started. It is not a bill — no
            goods were sold against it — so there is nothing to print. Settle it
            with a payment like any other.
          </p>
          <div className="tiles" style={{ marginTop: 14 }}>
            <div className="tile">
              <h3>Amount brought forward</h3>
              <div className="stat">{fmtMoney(inv.net_total)}</div>
              <p>{inv.remarks ?? ''}</p>
            </div>
          </div>
        </div>
      ) : (
        // The wrapper is what `share` reaches into: the picture is drawn from
        // the very sheet that prints, so the copy the shopkeeper gets and the
        // copy in the file are the same document.
        inv && <div ref={sheetRef}><BillSheet bill={inv} /></div>
      )}

      {shareNote && (
        <p className="sub no-print" style={{ marginTop: 12 }}>{shareNote}</p>
      )}

      <p className="sub no-print" style={{ marginTop: 12 }}>
        <Link to="/invoices">Back to bills</Link>
      </p>
    </>
  )
}
