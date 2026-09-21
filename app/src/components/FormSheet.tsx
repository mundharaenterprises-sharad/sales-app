import { useEffect } from 'react'
import type { ReactNode } from 'react'
import { ErrorBanner, Spinner } from './ui'

/**
 * A dialog holding a form: full height on a phone, centred on a desktop.
 *
 * With `onSubmit` left out it is a read-only view — the same layout, one Close
 * button. Reps look at a party the same way Admin edits one.
 */
export function FormSheet({
  title,
  onClose,
  onSubmit,
  busy = false,
  error = null,
  submitLabel = 'Save',
  children,
}: {
  title: string
  onClose: () => void
  onSubmit?: () => void
  busy?: boolean
  error?: string | null
  submitLabel?: string
  children: ReactNode
}) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !busy) onClose()
    }
    document.addEventListener('keydown', onKey)
    const prev = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => {
      document.removeEventListener('keydown', onKey)
      document.body.style.overflow = prev
    }
  }, [onClose, busy])

  return (
    <div className="sheet-backdrop">
      <form
        className="sheet"
        role="dialog"
        aria-modal="true"
        aria-label={title}
        noValidate
        onSubmit={(e) => {
          e.preventDefault()
          if (onSubmit && !busy) onSubmit()
        }}
      >
        <div className="sheet-head">
          <h2>{title}</h2>
          <button type="button" className="ghost" onClick={onClose} disabled={busy}>
            Close
          </button>
        </div>

        <div className="sheet-body" style={{ padding: 16 }}>
          <ErrorBanner error={error} />
          {children}
        </div>

        <div className="sheet-foot">
          <button type="button" onClick={onClose} disabled={busy}>
            {onSubmit ? 'Cancel' : 'Close'}
          </button>
          {onSubmit && (
            <button type="submit" className="primary" style={{ marginLeft: 'auto' }} disabled={busy}>
              {busy ? <Spinner /> : submitLabel}
            </button>
          )}
        </div>
      </form>
    </div>
  )
}

/** A labelled input row. `hint` sits under the box in small print. */
export function Field({
  label,
  htmlFor,
  hint,
  children,
}: {
  label: string
  htmlFor: string
  hint?: ReactNode
  children: ReactNode
}) {
  return (
    <div className="field">
      <label htmlFor={htmlFor}>{label}</label>
      {children}
      {hint && <div className="hint">{hint}</div>}
    </div>
  )
}

/** Two fields side by side on wider screens, stacked on a phone. */
export function Row({ children }: { children: ReactNode }) {
  return <div className="form-row">{children}</div>
}

export function Check({
  id,
  checked,
  onChange,
  disabled,
  children,
}: {
  id: string
  checked: boolean
  onChange: (v: boolean) => void
  disabled?: boolean
  children: ReactNode
}) {
  return (
    <label className="check" htmlFor={id}>
      <input
        id={id}
        type="checkbox"
        checked={checked}
        disabled={disabled}
        onChange={(e) => onChange(e.target.checked)}
      />
      <span>{children}</span>
    </label>
  )
}

/**
 * Reads a number from a text box. Blank is `blank`; anything that is not a
 * plain number is NaN, so the caller can say which box is wrong.
 */
export function num(s: string, blank = 0): number {
  const t = s.trim()
  if (t === '') return blank
  if (!/^-?\d+(\.\d+)?$/.test(t)) return NaN
  return Number(t)
}

/** A text box value, or null when left blank. */
export function text(s: string): string | null {
  const t = s.trim()
  return t === '' ? null : t
}
