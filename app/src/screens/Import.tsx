import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase, asDbError, friendlyMessage } from '../lib/supabase'
import { parseWorkbook, ENTITIES } from '../lib/workbook'
import type { ImportReport, ParsedSheet } from '../lib/workbook'
import { Banner, ErrorBanner, Spinner } from '../components/ui'
import { fmtMoney } from '../lib/format'

type Status = 'pending' | 'checking' | 'problems' | 'ready' | 'importing' | 'done' | 'blocked'

/** What to do about a code that is already in the database. */
type Existing = 'stop' | 'skip' | 'update'

interface SheetState {
  sheet: ParsedSheet
  status: Status
  report: ImportReport | null
  message: string | null
  open: boolean
}

export default function Import() {
  const fileRef = useRef<HTMLInputElement>(null)
  const [fileName, setFileName] = useState<string | null>(null)
  const [states, setStates] = useState<SheetState[]>([])
  const [ignored, setIgnored] = useState<string[]>([])
  const [existing, setExisting] = useState<Existing>('stop')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [finished, setFinished] = useState(false)
  const [openingPosted, setOpeningPosted] = useState<number | null>(null)
  // The other half of go-live: the money customers already owed.
  const [balancesPosted, setBalancesPosted] = useState<number | null>(null)
  const [daysOld, setDaysOld] = useState('16')
  const [balances, setBalances] = useState<{
    waiting: number
    waiting_value: number
    posted: number
    missing_date: number
  } | null>(null)
  // Products carrying an opening quantity that has not reached the ledger yet.
  // Counted on its own, because opening stock is just as often typed into the
  // product form as imported from a workbook.
  const [waiting, setWaiting] = useState<number | null>(null)

  const countWaiting = useCallback(async () => {
    const { count, error } = await supabase
      .from('v_product_master')
      .select('id', { count: 'exact', head: true })
      .gt('opening_qty', 0)
      .eq('opening_locked', false)
    if (!error) setWaiting(count ?? 0)

    const { data } = await supabase.from('v_opening_balance_status').select('*').single()
    if (data) setBalances(data as typeof balances)
  }, [])

  useEffect(() => {
    void countWaiting()
  }, [countWaiting])

  const reset = () => {
    setStates([])
    setIgnored([])
    setError(null)
    setFinished(false)
    setOpeningPosted(null)
  }

  const onFile = useCallback(async (file: File) => {
    reset()
    setFileName(file.name)
    setBusy(true)
    try {
      const { sheets, ignored } = await parseWorkbook(file)
      setIgnored(ignored)
      setStates(
        sheets.map((sheet) => ({
          sheet,
          status: 'pending' as Status,
          report: null,
          message: null,
          open: false,
        })),
      )
      if (sheets.length === 0) {
        setError(
          'No sheets in that file looked like Master Groups, Routes, Product ' +
            'Groups, Suppliers, Parties or Products. Is it the master data template?',
        )
      }
    } catch (e) {
      setError(
        `That file could not be read as a spreadsheet. ${
          e instanceof Error ? e.message : ''
        }`,
      )
    } finally {
      setBusy(false)
    }
  }, [])

  const patch = (i: number, p: Partial<SheetState>) =>
    setStates((s) => s.map((st, j) => (j === i ? { ...st, ...p } : st)))

  /**
   * Walks the sheets in dependency order. Each one is checked, and only
   * committed if it is clean — so Routes exist by the time Parties are checked
   * against them. A sheet with problems stops the run there, because anything
   * after it may depend on what did not import.
   */
  const run = useCallback(async () => {
    setBusy(true)
    setError(null)
    setFinished(false)

    const order = [...states].sort(
      (a, b) =>
        ENTITIES.find((e) => e.entity === a.sheet.entity)!.order -
        ENTITIES.find((e) => e.entity === b.sheet.entity)!.order,
    )

    let stopped = false

    for (const st of order) {
      const i = states.indexOf(st)

      if (st.sheet.rows.length === 0) {
        patch(i, { status: 'done', message: 'Empty sheet — nothing to import.' })
        continue
      }

      if (stopped) {
        patch(i, {
          status: 'blocked',
          message: 'Not attempted, because an earlier sheet did not import.',
        })
        continue
      }

      patch(i, { status: 'checking', message: null })

      // Check first.
      const check = await supabase.rpc('import_masters', {
        p_entity: st.sheet.entity,
        p_rows: st.sheet.rows,
        p_dry_run: true,
        p_skip_existing: existing === 'skip',
        p_update_existing: existing === 'update',
      })

      if (check.error) {
        patch(i, { status: 'problems', message: friendlyMessage(check.error), open: true })
        stopped = true
        continue
      }

      const report = check.data as ImportReport

      if (report.errors > 0) {
        patch(i, { status: 'problems', report, open: true })
        stopped = true
        continue
      }

      if ((report.would_import ?? 0) + (report.would_update ?? 0) === 0) {
        patch(i, {
          status: 'done',
          report,
          message: report.note ?? 'Everything in this sheet is already in the database.',
        })
        continue
      }

      // Then commit.
      patch(i, { status: 'importing' })

      const write = await supabase.rpc('import_masters', {
        p_entity: st.sheet.entity,
        p_rows: st.sheet.rows,
        p_dry_run: false,
        p_skip_existing: existing === 'skip',
        p_update_existing: existing === 'update',
      })

      if (write.error) {
        const de = asDbError(write.error)
        patch(i, {
          status: 'problems',
          report: (de.details as ImportReport) ?? null,
          message: friendlyMessage(write.error),
          open: true,
        })
        stopped = true
        continue
      }

      patch(i, { status: 'done', report: write.data as ImportReport })
    }

    setBusy(false)
    setFinished(!stopped)
  }, [states, existing])

  const postBalances = useCallback(async () => {
    setBusy(true)
    setError(null)
    const n = Number(daysOld)
    if (!Number.isFinite(n) || n < 0) {
      setError('Days must be a whole number, 0 or more.')
      setBusy(false)
      return
    }
    const { data, error } = await supabase.rpc('post_opening_balances', { p_days_old: n })
    if (error) setError(friendlyMessage(error))
    else setBalancesPosted(data as number)
    setBusy(false)
    await countWaiting()
  }, [countWaiting, daysOld])

  const postOpening = useCallback(async () => {
    setBusy(true)
    setError(null)
    const { data, error } = await supabase.rpc('post_opening_stock')
    if (error) setError(friendlyMessage(error))
    else setOpeningPosted(data as number)
    setBusy(false)
    await countWaiting()
  }, [countWaiting])

  const anyExisting = states.some((s) => (s.report?.already_exists ?? 0) > 0)
  const totalRows = states.reduce((n, s) => n + s.sheet.rows.length, 0)
  const canRun = states.length > 0 && totalRows > 0 && !busy

  return (
    <>
      <div className="page-head">
        <h1>Import master data</h1>
        <span className="sub">Routes, groups, suppliers, customers and products</span>
      </div>

      <ErrorBanner error={error} />

      <div className="card card-pad">
        <h2>1. Choose your workbook</h2>
        <p className="sub" style={{ marginTop: 4, marginBottom: 14 }}>
          The file from the master data template. Sheets are matched by name, so
          keep them called Master Groups, Routes, Product Groups, Suppliers,
          Parties and Products.
        </p>

        <input
          ref={fileRef}
          type="file"
          accept=".xlsx,.xlsm"
          style={{ display: 'none' }}
          onChange={(e) => {
            const f = e.target.files?.[0]
            if (f) void onFile(f)
          }}
        />
        <button className="primary" onClick={() => fileRef.current?.click()} disabled={busy}>
          {fileName ? 'Choose a different file' : 'Choose file'}
        </button>
        {fileName && (
          <span style={{ marginLeft: 12, color: 'var(--ink-3)', fontSize: 14 }}>
            {fileName}
          </span>
        )}
      </div>

      {states.length > 0 && (
        <>
          <div className="card card-pad">
            <h2>2. Check the contents</h2>
            <p className="sub" style={{ marginTop: 4 }}>
              Each sheet is checked in full before any of it is written, and the
              sheets are done in order — routes and groups first, because
              customers and products point at them.
            </p>

            <h3 style={{ marginTop: 18 }}>If a code is already in the database</h3>

            <Choice
              name="existing"
              value="stop"
              current={existing}
              onPick={setExisting}
              disabled={busy}
              title="Stop and tell me"
              detail="Nothing is written. Use this when you are adding to the list and
                      a repeat means something is wrong."
            />
            <Choice
              name="existing"
              value="skip"
              current={existing}
              onPick={setExisting}
              disabled={busy}
              title="Leave it as it is, import the rest"
              detail="For re-running after fixing a few rows. You will be told exactly
                      which ones were left alone."
            />
            <Choice
              name="existing"
              value="update"
              current={existing}
              onPick={setExisting}
              disabled={busy}
              title="Replace it with what the sheet says"
              detail="For when the spreadsheet is the list — putting opening balances
                      on customers who are already in the app, or repricing products.
                      Codes are matched; everything else on the row is overwritten."
            />

            {existing === 'update' && (
              <Banner tone="warn">
                Rows that match by code will be <strong>overwritten</strong> —
                names, routes, prices, opening balances, the lot. Blank cells
                overwrite too. Make sure the sheet is the version you want to
                keep.
              </Banner>
            )}
          </div>

          <div style={{ marginTop: 12 }}>
            {states.map((st, i) => (
              <SheetCard key={st.sheet.sheetName} st={st} onToggle={() => patch(i, { open: !st.open })} />
            ))}
          </div>

          {ignored.length > 0 && (
            <p className="sub" style={{ marginTop: 10 }}>
              Ignored sheet{ignored.length === 1 ? '' : 's'}: {ignored.join(', ')}
            </p>
          )}

          <div className="card card-pad" style={{ marginTop: 12 }}>
            <button className="primary" onClick={() => void run()} disabled={!canRun}>
              {busy ? <Spinner /> : 'Check and import'}
            </button>
            {totalRows === 0 && (
              <span style={{ marginLeft: 12, color: 'var(--ink-3)', fontSize: 14 }}>
                Every sheet is empty.
              </span>
            )}

            {anyExisting && existing === 'stop' && (
              <Banner tone="warn">
                Some rows are already in the database. Choose{' '}
                <strong>Leave it as it is</strong> above to import only what is
                new, or <strong>Replace it with what the sheet says</strong> to
                overwrite them from the sheet.
              </Banner>
            )}
          </div>
        </>
      )}

      <div className="card card-pad" style={{ marginTop: 12 }}>
        <h2>{finished ? '3. Post opening stock' : 'Post opening stock'}</h2>
        <p className="sub" style={{ marginTop: 4, marginBottom: 14 }}>
          Opening quantities — whether imported from the workbook or typed into
          a product — only become real stock once they are posted. This does
          that. It is safe to run more than once: anything already posted is
          left alone.
        </p>

        {waiting !== null && waiting > 0 && (
          <Banner tone="warn">
            {waiting} product{waiting === 1 ? '' : 's'} carry an opening quantity
            that is <strong>not in stock yet</strong>.
          </Banner>
        )}

        {openingPosted === null ? (
          <button className="primary" onClick={() => void postOpening()} disabled={busy}>
            {busy ? <Spinner /> : 'Post opening stock'}
          </button>
        ) : (
          <Banner tone="info">
            {openingPosted === 0
              ? 'Nothing to post — opening stock was already in the ledger.'
              : `Opening stock posted for ${openingPosted} product${openingPosted === 1 ? '' : 's'}. Check the Stock screen.`}
          </Banner>
        )}

        {waiting === 0 && openingPosted === null && (
          <p className="hint" style={{ marginTop: 10 }}>
            Nothing is waiting. Every product with an opening quantity has been
            posted already.
          </p>
        )}
      </div>

      <div className="card card-pad" style={{ marginTop: 12 }}>
        <h2>Post opening balances</h2>
        <p className="sub" style={{ marginTop: 4, marginBottom: 14 }}>
          Turns what each customer already owed into a document you can age and
          settle. Until this is done an opening balance shows in the total but
          cannot be paid off, because a payment is applied to a document.
        </p>

        {balances && balances.waiting > 0 && (
          <Banner tone="warn">
            {balances.waiting} customer{balances.waiting === 1 ? '' : 's'} carrying{' '}
            <strong>{fmtMoney(balances.waiting_value)}</strong> that cannot be
            settled yet.
          </Banner>
        )}

        {balances && balances.missing_date > 0 && (
          <Banner tone="bad">
            {balances.missing_date} customer
            {balances.missing_date === 1 ? ' has' : 's have'} an opening balance
            with no date, so there is nothing to age it from. Add
            opening_balance_date on the Parties sheet and import again with{' '}
            <strong>Replace it with what the sheet says</strong>.
          </Banner>
        )}

        <label className="inline-field" style={{ marginBottom: 12 }}>
          <span>How old to treat them as</span>
          <input
            type="number"
            min={0}
            step={1}
            value={daysOld}
            onChange={(e) => setDaysOld(e.target.value)}
            style={{ width: 90 }}
            disabled={busy}
          />
          <span className="muted">days</span>
        </label>
        <p className="hint" style={{ marginTop: 0, marginBottom: 14 }}>
          An opening balance carries no bill date, so one is chosen: this many
          days before the date the balance was struck. At 16 it lands in the
          16–30 bucket today and ages normally from there, so old money never
          looks fresher than last week&rsquo;s bill.
        </p>

        {balancesPosted === null ? (
          <button
            className="primary"
            onClick={() => void postBalances()}
            disabled={busy || (balances?.waiting ?? 0) === 0}
          >
            {busy ? <Spinner /> : 'Post opening balances'}
          </button>
        ) : (
          <Banner tone="info">
            {balancesPosted === 0
              ? 'Nothing to post — every opening balance is already a document.'
              : `Opening balances posted for ${balancesPosted} customer${balancesPosted === 1 ? '' : 's'}. They now appear in Bills, in ageing, and on the payment screen.`}
          </Banner>
        )}

        {balances && balances.waiting === 0 && balancesPosted === null && (
          <p className="hint" style={{ marginTop: 10 }}>
            {balances.posted > 0
              ? `Nothing is waiting. ${balances.posted} customer${balances.posted === 1 ? '' : 's'} already posted.`
              : 'No customer has an opening balance to post.'}
          </p>
        )}
      </div>
    </>
  )
}

/** One line of a radio group, with room for a sentence explaining itself. */
function Choice<T extends string>({
  name,
  value,
  current,
  onPick,
  title,
  detail,
  disabled,
}: {
  name: string
  value: T
  current: T
  onPick: (v: T) => void
  title: string
  detail: string
  disabled?: boolean
}) {
  return (
    <label
      style={{
        display: 'flex', alignItems: 'flex-start', gap: 10,
        marginTop: 12, cursor: disabled ? 'default' : 'pointer',
      }}
    >
      <input
        type="radio"
        name={name}
        checked={current === value}
        onChange={() => onPick(value)}
        style={{ width: 'auto', minHeight: 0, marginTop: 3 }}
        disabled={disabled}
      />
      <span style={{ fontSize: 14 }}>
        <strong>{title}</strong>
        <br />
        <span style={{ color: 'var(--ink-3)' }}>{detail}</span>
      </span>
    </label>
  )
}

function SheetCard({ st, onToggle }: { st: SheetState; onToggle: () => void }) {
  const { sheet, status, report, message } = st

  // "12 imported · 30 updated", leaving out whichever is zero.
  const outcome = report
    ? [
        report.imported > 0 ? `${report.imported} imported` : null,
        report.updated > 0 ? `${report.updated} updated` : null,
      ]
        .filter(Boolean)
        .join(' · ')
    : ''

  const pill = {
    pending:   <span className="pill flat">Not checked</span>,
    checking:  <span className="pill flat">Checking…</span>,
    importing: <span className="pill flat">Importing…</span>,
    problems:  <span className="pill bad">{report ? `${report.errors} problem${report.errors === 1 ? '' : 's'}` : 'Problem'}</span>,
    ready:     <span className="pill warn">Ready</span>,
    done:      <span className="pill good">{outcome || 'Done'}</span>,
    blocked:   <span className="pill flat">Skipped</span>,
  }[status]

  const hasDetail = (report?.error_detail?.length ?? 0) > 0

  return (
    <div className="card">
      <div
        className="card-pad"
        style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}
      >
        <div style={{ flex: '1 1 200px' }}>
          <h3>{sheet.label}</h3>
          <span className="sub">
            {sheet.sheetName} · {sheet.rows.length} row
            {sheet.rows.length === 1 ? '' : 's'}
            {report && report.skipped > 0 && ` · ${report.skipped} left alone`}
          </span>
        </div>
        {pill}
        {hasDetail && (
          <button className="ghost" onClick={onToggle} style={{ minHeight: 36 }}>
            {st.open ? 'Hide' : 'Show'} problems
          </button>
        )}
      </div>

      {message && (
        <div className="card-pad" style={{ paddingTop: 0 }}>
          <span className="sub">{message}</span>
        </div>
      )}

      {sheet.unknownColumns.length > 0 && status === 'pending' && (
        <div className="card-pad" style={{ paddingTop: 0 }}>
          <Banner tone="warn">
            {sheet.unknownColumns.length === 1 ? (
              <>
                The column <strong>{sheet.unknownColumns[0]}</strong> will be
                ignored. If it was meant to be imported, its header has been
                renamed — check it against the template.
              </>
            ) : (
              <>
                These columns will be ignored:{' '}
                <strong>{sheet.unknownColumns.join(', ')}</strong>. If any were
                meant to be imported, their headers have been renamed — check
                them against the template.
              </>
            )}
          </Banner>
        </div>
      )}

      {st.open && hasDetail && (
        <div className="table-wrap" style={{ borderTop: '1px solid var(--line)' }}>
          <table className="data">
            <thead>
              <tr>
                <th>Row</th>
                <th>Column</th>
                <th>Value</th>
                <th>Problem</th>
              </tr>
            </thead>
            <tbody>
              {report!.error_detail.map((e, k) => (
                <tr key={k}>
                  <td data-label="Row" className="strong">{e.row}</td>
                  <td data-label="Column"><code>{e.field}</code></td>
                  <td data-label="Value" className="muted">{e.value || '(blank)'}</td>
                  <td data-label="Problem">{e.message}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
