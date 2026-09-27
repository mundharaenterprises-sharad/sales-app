import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Banner, Spinner } from './ui'
import {
  onSaveState,
  dismissSaveState,
  undoLastSave,
  retrySave,
  type SaveState,
} from '../lib/ordersave'

/**
 * What became of the order that was just sent.
 *
 * It sits in the layout rather than on the order screen, because by the time
 * the database answers the screen has usually closed. An answer that appeared
 * only on the screen the rep has left would be no answer at all.
 *
 * Undo survives the return of the Submit button. Pressing Submit is a decision
 * and needs no apology, but the rep who realises two seconds later that it was
 * the wrong shop should not have to hunt for a Cancel button on a list.
 */
export default function OrderSaveBanner() {
  const [s, setS] = useState<SaveState | null>(null)
  const [busy, setBusy] = useState(false)
  const nav = useNavigate()

  useEffect(() => onSaveState(setS), [])

  if (!s) return null

  if (s.state === 'saving') {
    return (
      <Banner tone="info">
        <Spinner /> Saving the order for <strong>{s.draft.party?.party_name}</strong>…
      </Banner>
    )
  }

  if (s.state === 'waiting') {
    return (
      <Banner tone="warn">
        <strong>No signal.</strong> The order for {s.draft.party?.party_name} is kept
        on this phone and will go as soon as you are back on the network. Don't
        close the app.
        <div style={{ marginTop: 8, display: 'flex', gap: 8 }}>
          <button
            onClick={() => {
              setBusy(true)
              void retrySave().finally(() => setBusy(false))
            }}
            disabled={busy}
          >
            {busy ? <Spinner /> : 'Try now'}
          </button>
        </div>
      </Banner>
    )
  }

  if (s.state === 'failed') {
    return (
      <Banner tone="bad">
        <strong>The order for {s.draft.party?.party_name} was not saved</strong> —{' '}
        {s.message}. Nothing has been reserved.
        <div style={{ marginTop: 8, display: 'flex', gap: 8, flexWrap: 'wrap' }}>
          <button
            className="primary"
            onClick={() => nav(s.draft.orderId ? `/orders/${s.draft.orderId}/edit` : '/orders/new')}
          >
            Reopen it
          </button>
          <button
            onClick={() => {
              setBusy(true)
              void retrySave().finally(() => setBusy(false))
            }}
            disabled={busy}
          >
            {busy ? <Spinner /> : 'Try again'}
          </button>
          <button className="ghost" onClick={dismissSaveState}>
            Throw it away
          </button>
        </div>
      </Banner>
    )
  }

  if (s.state === 'undone') {
    return (
      <Banner tone="info">
        <strong>{s.docNo}</strong> undone.
        <button className="ghost" style={{ marginLeft: 10 }} onClick={dismissSaveState}>
          Dismiss
        </button>
      </Banner>
    )
  }

  return (
    <Banner tone="info">
      <strong>{s.docNo}</strong> {s.edited ? 'updated' : 'saved'} for{' '}
      {s.draft.party?.party_name}.{' '}
      {s.edited ? 'The reservation has been adjusted.' : 'The stock on it is now reserved.'}
      <div style={{ marginTop: 8, display: 'flex', gap: 8 }}>
        <button
          onClick={() => {
            setBusy(true)
            void undoLastSave().finally(() => setBusy(false))
          }}
          disabled={busy}
        >
          {busy ? <Spinner /> : s.edited ? 'Undo the change' : 'Undo — I did not mean to'}
        </button>
        <button className="ghost" onClick={dismissSaveState}>
          Dismiss
        </button>
      </div>
    </Banner>
  )
}
