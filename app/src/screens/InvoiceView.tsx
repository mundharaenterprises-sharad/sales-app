import { useCallback, useEffect, useState } from 'react'
import { Link, useLocation, useNavigate, useParams } from 'react-router-dom'
import { supabase, friendlyMessage } from '../lib/supabase'
import { fmtMoney } from '../lib/format'
import { Banner, ErrorBanner, Loading, Spinner } from '../components/ui'
import { BillSheet, BILL_SELECT } from '../components/BillSheet'
import type { Bill, BusinessSetting } from '../components/BillSheet'
import { useSession } from '../lib/session'

/**
 * One bill, laid out as it prints.
 *
 * The same markup serves the screen and the printer: everything marked
 * `no-print` drops away and the sheet sizes itself to A5. What the customer
 * gets is therefore what the office sees, which is the only way a reprint can
 * be trusted to match the original.
 */
export default function InvoiceView() {
  const { id } = useParams()
  const nav = useNavigate()
  const { can } = useSession()
  const navState = useLocation().state as
    | { justCreated?: string; replaced?: string }
    | null
  const justCreated = navState?.justCreated
  const replaced = navState?.replaced

  const [inv, setInv] = useState<Bill | null>(null)
  const [settings, setSettings] = useState<BusinessSetting | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    setError(null)
    const [i, s] = await Promise.all([
      supabase.from('sales_invoice').select(BILL_SELECT).eq('id', id).single(),
      supabase
        .from('app_setting')
        .select('business_name, business_address, business_phone')
        .single(),
    ])

    if (i.error) {
      setError(friendlyMessage(i.error))
      return
    }
    setInv(i.data as unknown as Bill)
    if (!s.error) setSettings(s.data as BusinessSetting)
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
  const today = new Date().toISOString().slice(0, 10)
  const canCorrect =
    inv != null && inv.status === 'ACTIVE' && inv.invoice_date === today

  if (!inv && !error) return <Loading what="Loading bill" />

  return (
    <>
      <div className="page-head no-print">
        <h1>Bill {inv?.doc_no}</h1>
        <span style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
          <button onClick={() => nav('/invoices')}>All bills</button>
          <button className="primary" onClick={() => window.print()} disabled={!inv}>
            Print
          </button>
          {can('ACCOUNTS', 'ADMIN') && canCorrect && (
            <button onClick={() => nav(`/invoices/new?revise=${inv!.id}`)} disabled={busy}>
              Correct bill
            </button>
          )}
          {can('ACCOUNTS', 'ADMIN') && inv?.status !== 'CANCELLED' && (
            <button onClick={() => void cancel()} disabled={busy}>
              {busy ? <Spinner /> : 'Cancel bill'}
            </button>
          )}
        </span>
      </div>

      <div className="no-print">
        <ErrorBanner error={error} />
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
          </Banner>
        )}
        {inv?.status === 'PARTIALLY_CANCELLED' && (
          <Banner tone="warn">
            Part of this bill has been cancelled. {fmtMoney(inv.cancelled_value)} of{' '}
            {fmtMoney(inv.net_total)} was taken off.
          </Banner>
        )}
      </div>

      {inv && <BillSheet bill={inv} settings={settings} />}

      <p className="sub no-print" style={{ marginTop: 12 }}>
        <Link to="/invoices">Back to bills</Link>
      </p>
    </>
  )
}
