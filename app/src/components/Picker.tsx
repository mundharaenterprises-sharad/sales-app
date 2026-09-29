import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import { useListKeys } from '../lib/listkeys'

/**
 * A full-height searchable list for choosing a customer or a product.
 *
 * Full screen on a phone rather than a small dropdown: a rep is picking from
 * hundreds of names with one thumb, often in a hurry, and needs as many
 * results visible as will fit.
 *
 * It opens against the TOP of the screen, not the bottom. Sliding up from the
 * bottom is the usual way, and it was wrong here: the moment the rep types,
 * the keyboard comes up and eats the very results they are typing to find. The
 * list they narrowed to three names was behind the keys.
 *
 * The keyboard does not resize the window, it covers it, so no amount of vh
 * helps either. What does know about it is visualViewport — the part of the
 * page a person can actually see — so the sheet is measured against that and
 * ends where the keys begin. Where that is unavailable the sheet keeps a
 * sensible height and, being anchored at the top, still shows its first
 * results above the keyboard.
 */
export function Picker<T>({
  title,
  placeholder,
  items,
  keyOf,
  searchOf,
  render,
  onPick,
  onClose,
  emptyText,
  addLabel,
  onAdd,
}: {
  title: string
  placeholder: string
  items: T[]
  keyOf: (item: T) => string
  /** Everything this item should be findable by. */
  searchOf: (item: T) => string
  render: (item: T) => ReactNode
  onPick: (item: T) => void
  onClose: () => void
  emptyText?: string
  /**
   * An escape hatch for the thing that is not on the list.
   *
   * Offered both at the foot and, more importantly, in the empty state —
   * because the moment somebody discovers the shop is missing is the moment
   * they have typed its name and found nothing, and that is where the way
   * forward has to be. It receives what was typed, so the form starts with it.
   */
  addLabel?: string
  onAdd?: (typed: string) => void
}) {
  const [q, setQ] = useState('')
  const inputRef = useRef<HTMLInputElement>(null)
  const [visible, setVisible] = useState<number | null>(null)

  // How much of the window the keyboard has left us. Recomputed as it opens
  // and closes, and as the page is scrolled under it.
  useEffect(() => {
    const vv = window.visualViewport
    if (!vv) return
    const measure = () => setVisible(Math.round(vv.height - vv.offsetTop))
    measure()
    vv.addEventListener('resize', measure)
    vv.addEventListener('scroll', measure)
    return () => {
      vv.removeEventListener('resize', measure)
      vv.removeEventListener('scroll', measure)
    }
  }, [])

  useEffect(() => {
    // Opening the picker should put the cursor in the search box.
    inputRef.current?.focus()

    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    document.addEventListener('keydown', onKey)

    // Stop the page behind scrolling while this is open.
    const prev = document.body.style.overflow
    document.body.style.overflow = 'hidden'

    return () => {
      document.removeEventListener('keydown', onKey)
      document.body.style.overflow = prev
    }
  }, [onClose])

  const filtered = useMemo(() => {
    const needle = q.trim().toLowerCase()
    if (!needle) return items.slice(0, 200)
    // Every word must match somewhere, so "ram bir" finds "Ram Store, Biratnagar".
    const words = needle.split(/\s+/)
    return items
      .filter((it) => {
        const hay = searchOf(it).toLowerCase()
        return words.every((w) => hay.includes(w))
      })
      .slice(0, 200)
  }, [items, q, searchOf])

  const pick = useCallback(
    (it: T) => {
      onPick(it)
      onClose()
    },
    [onPick, onClose],
  )

  const { rowProps } = useListKeys<T>({ items: filtered, onOpen: pick })

  return (
    <div
      className="sheet-backdrop sheet-top"
      onMouseDown={(e) => { if (e.target === e.currentTarget) onClose() }}
    >
      <div
        className="sheet sheet-picker"
        role="dialog"
        aria-modal="true"
        aria-label={title}
        style={visible ? { maxHeight: visible - 12 } : undefined}
      >
        <div className="sheet-head">
          <h2>{title}</h2>
          <button className="ghost" onClick={onClose}>Close</button>
        </div>

        <div className="sheet-search">
          <input
            ref={inputRef}
            type="search"
            autoComplete="off"
            placeholder={placeholder}
            value={q}
            onChange={(e) => setQ(e.target.value)}
          />
        </div>

        <div className="sheet-body">
          {filtered.length === 0 ? (
            <div className="empty">
              <h3>Nothing found</h3>
              <p>{q ? `Nothing matches “${q}”.` : emptyText ?? 'There is nothing to choose from.'}</p>
              {onAdd && (
                <button className="primary" onClick={() => onAdd(q.trim())}>
                  {addLabel ?? 'Add a new one'}
                </button>
              )}
            </div>
          ) : (
            filtered.map((it, i) => (
              <button
                key={keyOf(it)}
                ref={rowProps(i).ref as unknown as React.Ref<HTMLButtonElement>}
                className={`sheet-row${rowProps(i).className ? ' ' + rowProps(i).className : ''}`}
                onClick={() => pick(it)}
              >
                {render(it)}
              </button>
            ))
          )}
          {filtered.length === 200 && (
            <p className="sub" style={{ padding: '10px 16px' }}>
              Showing the first 200. Keep typing to narrow it down.
            </p>
          )}
        </div>

        {onAdd && filtered.length > 0 && (
          <div className="sheet-foot">
            <button onClick={() => onAdd(q.trim())}>{addLabel ?? 'Add a new one'}</button>
          </div>
        )}
      </div>
    </div>
  )
}
