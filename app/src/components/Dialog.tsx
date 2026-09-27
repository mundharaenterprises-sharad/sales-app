import { useCallback, useEffect, useState } from 'react'
import type { ReactNode } from 'react'
import { Spinner } from './ui'

/**
 * A question that stops the screen, and always offers the way out.
 *
 * Errors used to appear as a red strip at the top of the page. On a phone the
 * rep is looking at the bottom of a long order when the save fails, so the
 * explanation is a screen and a half away — and even when it is read, a strip
 * of text only says what went wrong. Somebody still has to work out what to do
 * about it, usually while a shopkeeper waits.
 *
 * So the app asks instead of announcing. Every dialog names the problem in one
 * line and then offers the two or three things a person could actually do
 * about it — reduce the quantity, drop the item, keep it and fix it later —
 * with the safest one plain and the destructive one marked. A dialog with only
 * "OK" on it is a red strip that took an extra tap, and should be a banner.
 *
 * It also replaces the browser's own prompt box, which is where the
 * cancellation reason used to be typed: unstyled, untranslatable, and on some
 * phones a modal that freezes everything behind it.
 */

export interface DialogAction {
  label: string
  /** primary: the expected answer. danger: the one that destroys something. */
  tone?: 'primary' | 'plain' | 'danger'
  /**
   * What to do. The dialog closes when this resolves; throw to keep it open.
   * Receives whatever was typed, when the dialog asks for something.
   */
  onPick?: (answer: string) => void | Promise<void>
}

export interface DialogSpec {
  title: string
  tone?: 'info' | 'warn' | 'bad'
  body?: ReactNode
  actions: DialogAction[]
  /** Ask for a line of text — a cancellation reason, say — before answering. */
  ask?: { label: string; placeholder?: string; required?: boolean }
  /** What the Escape key and the backdrop do. Defaults to the last action. */
  onDismiss?: () => void
}

/**
 * Put `dialog` somewhere in the screen's markup and call `ask(spec)` when
 * there is something to ask. One at a time, deliberately: a second question
 * stacked on the first is how people end up answering the wrong one.
 */
export function useDialog() {
  const [spec, setSpec] = useState<DialogSpec | null>(null)

  const ask = useCallback((s: DialogSpec) => setSpec(s), [])
  const close = useCallback(() => setSpec(null), [])

  const dialog = spec ? <Dialog spec={spec} onClose={close} /> : null
  return { dialog, ask, close, isOpen: spec !== null }
}

export function Dialog({ spec, onClose }: { spec: DialogSpec; onClose: () => void }) {
  const [answer, setAnswer] = useState('')
  const [busy, setBusy] = useState<number | null>(null)
  const [problem, setProblem] = useState<string | null>(null)

  const dismiss = useCallback(() => {
    if (busy !== null) return
    if (spec.onDismiss) spec.onDismiss()
    onClose()
  }, [busy, spec, onClose])

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') dismiss()
    }
    document.addEventListener('keydown', onKey)
    const prev = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => {
      document.removeEventListener('keydown', onKey)
      document.body.style.overflow = prev
    }
  }, [dismiss])

  const run = async (a: DialogAction, i: number) => {
    if (spec.ask?.required && !answer.trim()) {
      setProblem(`${spec.ask.label} is needed.`)
      return
    }
    setProblem(null)
    if (!a.onPick) return onClose()
    setBusy(i)
    try {
      await a.onPick(answer.trim())
      onClose()
    } catch (e) {
      // Throwing keeps the dialog open so the person can try the other answer.
      setProblem(e instanceof Error ? e.message : String(e))
      setBusy(null)
    }
  }

  return (
    <div
      className="sheet-backdrop"
      onMouseDown={(e) => { if (e.target === e.currentTarget) dismiss() }}
    >
      <div className="sheet sheet-dialog" role="alertdialog" aria-modal="true">
        <div className={`sheet-head dialog-head${spec.tone ? ` ${spec.tone}` : ''}`}>
          <h2>{spec.title}</h2>
        </div>

        <div className="sheet-body dialog-body">
          {spec.body}

          {spec.ask && (
            <div className="field" style={{ marginTop: spec.body ? 14 : 0 }}>
              <label htmlFor="dialog-ask">{spec.ask.label}</label>
              <input
                id="dialog-ask"
                type="text"
                autoFocus
                value={answer}
                placeholder={spec.ask.placeholder}
                onChange={(e) => setAnswer(e.target.value)}
              />
            </div>
          )}

          {problem && <div className="dialog-problem">{problem}</div>}
        </div>

        <div className="sheet-foot dialog-foot">
          {spec.actions.map((a, i) => (
            <button
              key={a.label}
              className={
                a.tone === 'primary' ? 'primary' : a.tone === 'danger' ? 'ghost danger' : 'ghost'
              }
              disabled={busy !== null}
              onClick={() => void run(a, i)}
            >
              {busy === i ? <Spinner /> : a.label}
            </button>
          ))}
        </div>
      </div>
    </div>
  )
}
