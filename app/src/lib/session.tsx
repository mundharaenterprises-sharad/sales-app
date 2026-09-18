import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react'
import type { ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase, type AppUser, type Role } from './supabase'
import { clearSnapshots } from './cache'

interface SessionState {
  session: Session | null
  user: AppUser | null
  loading: boolean
  /** Set when a login succeeds but the account has no app_user row. */
  notProvisioned: boolean
  signOut: () => Promise<void>
  can: (...roles: Role[]) => boolean
}

const Ctx = createContext<SessionState | null>(null)

export function SessionProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [user, setUser] = useState<AppUser | null>(null)
  const [loading, setLoading] = useState(true)
  const [notProvisioned, setNotProvisioned] = useState(false)

  const loadProfile = useCallback(async (s: Session | null) => {
    if (!s) {
      setUser(null)
      setNotProvisioned(false)
      return
    }

    const { data, error } = await supabase
      .from('app_user')
      .select('id, full_name, role, is_active')
      .eq('id', s.user.id)
      .maybeSingle()

    if (error || !data) {
      // Authentication succeeded but nobody has given this login a role, so
      // row-level security will refuse everything. Say that plainly rather
      // than showing an app full of empty screens.
      setUser(null)
      setNotProvisioned(true)
      return
    }

    setNotProvisioned(false)
    setUser(data as AppUser)
  }, [])

  useEffect(() => {
    let alive = true

    supabase.auth.getSession().then(async ({ data }) => {
      if (!alive) return
      setSession(data.session)
      await loadProfile(data.session)
      if (alive) setLoading(false)
    })

    const { data: sub } = supabase.auth.onAuthStateChange(async (_event, s) => {
      if (!alive) return
      setSession(s)
      await loadProfile(s)
      setLoading(false)
    })

    return () => {
      alive = false
      sub.subscription.unsubscribe()
    }
  }, [loadProfile])

  const signOut = useCallback(async () => {
    // Cached parties and stock belong to the person who was signed in.
    await clearSnapshots()
    await supabase.auth.signOut()
  }, [])

  const can = useCallback(
    (...roles: Role[]) => (user ? roles.includes(user.role) : false),
    [user],
  )

  const value = useMemo(
    () => ({ session, user, loading, notProvisioned, signOut, can }),
    [session, user, loading, notProvisioned, signOut, can],
  )

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

export function useSession(): SessionState {
  const v = useContext(Ctx)
  if (!v) throw new Error('useSession must be used inside SessionProvider')
  return v
}

/** True while the browser believes it has a connection. */
export function useOnline(): boolean {
  const [online, setOnline] = useState(() => navigator.onLine)

  useEffect(() => {
    const up = () => setOnline(true)
    const down = () => setOnline(false)
    window.addEventListener('online', up)
    window.addEventListener('offline', down)
    return () => {
      window.removeEventListener('online', up)
      window.removeEventListener('offline', down)
    }
  }, [])

  return online
}
