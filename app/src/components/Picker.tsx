import { useEffect, useMemo, useRef, useState } from 'react'
import type { ReactNode } from 'react'

/**
 * A full-height searchable list for choosing a customer or a product.
 *
 * Full screen on a phone rather than a small dropdown: a rep is picking from
 * hundreds of names with one thumb, often in a hurry, and needs the search box
 * under the keyboard and as many results visible as will fit.
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
}) {
  const [q, setQ] = useState('')
  const inputRef = useRef<HTMLInputElement>(null)

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

  return (
    <div className="sheet-backdrop" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose() }}>
      <div className="sheet" role="dialog" aria-modal="true" aria-label={title}>
        <div className="sheet-head">
          <h2>{title}</h2>
          <button className="ghost" onClick={onClose}>Close</button>
        </div>

        <div className="sheet-search">
          <input
            ref={inputRef}
            type="search"
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
            </div>
          ) : (
            filtered.map((it) => (
              <button
                key={keyOf(it)}
                className="sheet-row"
                onClick={() => { onPick(it); onClose() }}
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
      </div>
    </div>
  )
}
