import { useCallback, useEffect, useState } from 'react'

/**
 * Moving through a list with the keyboard.
 *
 * Type into the search box, then press Down: the first match is highlighted,
 * Down and Up walk through them, Enter opens the highlighted one, Escape lets
 * go. The highlight scrolls itself into view, so the list moves under the
 * keyboard without ever touching the mouse — which is the whole point when
 * somebody is working through a list of shops one after another.
 *
 * It listens on the window during the capture phase so that it gets the key
 * before the browser decides to do something else with it, such as opening its
 * own suggestion box or scrolling some container the focus happens to sit in.
 */
export function useListKeys<T>({
  items,
  onOpen,
  enabled = true,
}: {
  items: T[]
  onOpen?: (item: T, index: number) => void
  enabled?: boolean
}) {
  const [active, setActive] = useState(-1)

  // A changed list makes the old position meaningless.
  useEffect(() => {
    setActive(-1)
  }, [items.length])

  useEffect(() => {
    if (!enabled) return

    const onKey = (e: KeyboardEvent) => {
      if (e.ctrlKey || e.metaKey || e.altKey) return

      const t = e.target as HTMLElement | null
      const tag = t?.tagName
      // Leave the keys alone where they mean something else.
      if (t?.isContentEditable || tag === 'TEXTAREA' || tag === 'SELECT') return
      if (tag === 'INPUT') {
        const type = (t as HTMLInputElement).type
        if (['date', 'datetime-local', 'month', 'week', 'time', 'number', 'range'].includes(type)) {
          return
        }
      }

      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        if (items.length === 0) return
        e.preventDefault()
        e.stopPropagation()
        setActive((i) => {
          const next = e.key === 'ArrowDown' ? i + 1 : i - 1
          if (next < 0) return 0
          if (next > items.length - 1) return items.length - 1
          return next
        })
        return
      }

      if (e.key === 'Enter' && active >= 0 && active < items.length) {
        e.preventDefault()
        e.stopPropagation()
        onOpen?.(items[active], active)
        return
      }

      if (e.key === 'Escape' && active >= 0) {
        setActive(-1)
      }
    }

    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  }, [items, active, onOpen, enabled])

  /**
   * Put on each row. Gives the highlight its styling and keeps the highlighted
   * row on screen as it moves.
   */
  const rowProps = useCallback(
    (index: number) => ({
      className: index === active ? 'active-row' : undefined,
      ref: (el: HTMLElement | null) => {
        if (el && index === active) el.scrollIntoView({ block: 'nearest' })
      },
    }),
    [active],
  )

  return { active, setActive, rowProps }
}
