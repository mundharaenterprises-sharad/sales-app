import { useCallback, useEffect, useState } from 'react'
import { supabase } from './supabase'

/**
 * Master groups — Parle, Current, Others.
 *
 * The top of the product hierarchy, and the axis half the app can be filtered
 * by, so the list is loaded once per screen that needs it and handed round.
 * There are three of them, so this is deliberately not cached anywhere clever.
 */

export interface MasterGroup {
  id: string
  code: string
  name: string
  sort_order: number
  is_active: boolean
}

export function useMasterGroups(): {
  masters: MasterGroup[]
  reload: () => Promise<void>
} {
  const [masters, setMasters] = useState<MasterGroup[]>([])

  const reload = useCallback(async () => {
    const { data } = await supabase
      .from('master_group')
      .select('id, code, name, sort_order, is_active')
      .order('sort_order')
      .order('name')
    setMasters((data ?? []) as MasterGroup[])
  }, [])

  useEffect(() => {
    void reload()
  }, [reload])

  return { masters, reload }
}

/**
 * The filter control. One per screen that lists documents, always worded the
 * same way, because "All groups" meaning something different on two screens is
 * how people stop trusting a filter.
 */
export function MasterFilter({
  masters,
  value,
  onChange,
  label = 'Group',
}: {
  masters: MasterGroup[]
  /** '' means every group. */
  value: string
  onChange: (code: string) => void
  label?: string
}) {
  if (masters.length < 2) return null
  return (
    <select
      aria-label={label}
      value={value}
      onChange={(e) => onChange(e.target.value)}
      style={{ width: 'auto', minWidth: 140 }}
    >
      <option value="">All groups</option>
      {masters.map((m) => (
        <option key={m.id} value={m.code}>
          {m.name}
        </option>
      ))}
    </select>
  )
}

/** A small tag showing which master group something belongs to. */
export function MasterTag({ code, name }: { code?: string | null; name?: string | null }) {
  if (!code) return null
  return (
    <span className="pill flat" title={`Master group: ${name ?? code}`}>
      {name ?? code}
    </span>
  )
}
