import { useEffect, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { supabase, friendlyMessage } from '../lib/supabase'
import { BillSheet, BILL_SELECT } from '../components/BillSheet'
import type { Bill } from '../components/BillSheet'
import { Empty, ErrorBanner, Loading } from '../components/ui'
import { useBillPage, useDocumentTitle } from '../lib/printpage'

/**
 * Several bills as one print job: one bill per A5 sheet, one trip to the
 * printer. The office bills a rep's round in the morning and prints the lot.
 */
export default function InvoicePrintBatch() {
  useBillPage()
  const [params] = useSearchParams()
  const nav = useNavigate()
  const ids = (params.get('ids') ?? '').split(',').filter(Boolean)

  const [bills, setBills] = useState<Bill[] | null>(null)

  // If the browser insists on printing a title, let it be about the bills.
  useDocumentTitle(bills && bills.length ? `${bills.length} bills` : null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let alive = true

    async function load() {
      if (ids.length === 0) {
        setBills([])
        return
      }
      const i = await supabase.from('sales_invoice').select(BILL_SELECT).in('id', ids)
      if (!alive) return
      if (i.error) {
        setError(friendlyMessage(i.error))
        setBills([])
        return
      }
      const rows = (i.data ?? []) as unknown as Bill[]
      // Print in the order they were asked for, not whatever the database
      // hands back, so the pile matches the list on screen.
      rows.sort((a, b) => ids.indexOf(a.id) - ids.indexOf(b.id))
      setBills(rows)
    }

    void load()
    return () => {
      alive = false
    }
    // Runs once per set of ids. Re-fetching on anything else would reorder
    // a pile of bills somebody is halfway through printing.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [params])

  if (bills === null && !error) return <Loading what="Loading bills" />

  return (
    <>
      <div className="page-head no-print">
        <h1>Print bills</h1>
        <span className="sub">
          {bills?.length ?? 0} bill{bills?.length === 1 ? '' : 's'} · one per A5 page
        </span>
        <span style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
          <button onClick={() => nav('/invoices')}>Back</button>
          <button
            className="primary"
            onClick={() => window.print()}
            disabled={!bills || bills.length === 0}
          >
            Print all
          </button>
        </span>
      </div>

      <div className="no-print">
        <ErrorBanner error={error} />
      </div>

      {bills && bills.length === 0 ? (
        <Empty title="Nothing to print">
          Go back to Bills, tick the ones you want, and choose Print selected.
        </Empty>
      ) : (
        <div className="print-stack">
          {bills?.map((b, i) => (
            <BillSheet key={b.id} bill={b} pageBreak={i > 0} />
          ))}
        </div>
      )}
    </>
  )
}
