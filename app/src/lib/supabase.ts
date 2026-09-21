import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL

// Supabase issues two generations of public key. The newer publishable key
// (sb_publishable_...) is the one to use; the older anon key is a long JWT
// starting eyJ and is being retired at the end of 2026. Either works here, so
// an existing setup keeps running, but the publishable one is preferred.
const key =
  import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY ||
  import.meta.env.VITE_SUPABASE_ANON_KEY

const looksUnset = (v: string | undefined) =>
  !v || v.includes('your-') || v.includes('<') || v.trim() === ''

// A missing key produces a blank screen and an opaque console error. Fail loudly
// at startup instead, naming the file to create.
export const configError: string | null = looksUnset(url)
  ? 'VITE_SUPABASE_URL is not set'
  : looksUnset(key)
    ? 'VITE_SUPABASE_PUBLISHABLE_KEY is not set'
    : null

// The secret key bypasses every security rule in the database. Anything in a
// VITE_ variable is visible to whoever opens the site, so this must never be
// one — say so rather than letting it silently ship.
export const usingSecretKey =
  !!key && (key.startsWith('sb_secret_') || key.includes('service_role'))

export const supabase = createClient(url ?? 'http://unset', key ?? 'unset', {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: false,
  },
})

export type Role = 'REP' | 'ACCOUNTS' | 'ADMIN'

export interface AppUser {
  id: string
  full_name: string
  role: Role
  is_active: boolean
}

/**
 * Errors raised by the database functions carry a code that says what kind of
 * problem it is, and often a `details` payload the screen can render — the
 * shortfall list behind a stock refusal, for instance.
 */
export interface DbError {
  code: string
  message: string
  details: unknown
}

export function asDbError(e: unknown): DbError {
  const err = e as { code?: string; message?: string; details?: string; hint?: string }
  let details: unknown = null
  if (err?.details) {
    try {
      details = JSON.parse(err.details)
    } catch {
      details = err.details
    }
  }
  return {
    code: err?.code ?? 'UNKNOWN',
    message: err?.message ?? 'Something went wrong',
    details,
  }
}

/** Turns a database error into something worth showing a person. */
export function friendlyMessage(e: unknown): string {
  const { code, message } = asDbError(e)
  switch (code) {
    case 'SA001':
      return 'There is not enough stock for this.'
    case 'SA002':
      return message
    case 'SA003':
      return 'You do not have permission to do that.'
    case 'SA004':
      return message
    case 'SA005':
      return 'That record could not be found.'
    case '23505':
      // Unique violation. Codes are the only unique thing a person types.
      return 'That code is already in use. Codes must be unique.'
    case '23514':
      return 'One of the values is not allowed. Check for negative numbers or a missing date.'
    case 'PGRST301':
    case '42501':
      return 'You do not have permission to see that.'
    default:
      return message || 'Something went wrong.'
  }
}
