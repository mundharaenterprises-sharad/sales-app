import { useState } from 'react'
import { supabase, configError, friendlyMessage } from '../lib/supabase'
import { Banner, Spinner } from '../components/ui'

export default function Login() {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    setError(null)
    setBusy(true)

    const { error } = await supabase.auth.signInWithPassword({
      email: email.trim(),
      password,
    })

    if (error) {
      // Supabase says "Invalid login credentials" for both a wrong password and
      // an unknown email, deliberately. Keep that — naming which one is wrong
      // tells an attacker which emails exist.
      setError(
        error.message === 'Invalid login credentials'
          ? 'That email and password do not match.'
          : friendlyMessage(error),
      )
      setBusy(false)
      return
    }
    // The session listener takes over from here.
  }

  return (
    <div className="login-wrap">
      <div className="login-card">
        <div className="mark">S</div>
        <h1>Sign in</h1>
        <p className="sub">Orders, billing and collections</p>

        {configError && (
          <Banner tone="bad">
            <strong>Not configured.</strong> {configError}. Create{' '}
            <code>app/.env.local</code> from <code>.env.example</code> and put your
            Supabase project URL and anon key in it, then restart.
          </Banner>
        )}

        {error && <Banner tone="bad">{error}</Banner>}

        <form onSubmit={submit}>
          <div className="field">
            <label htmlFor="email">Email</label>
            <input
              id="email"
              type="email"
              value={email}
              autoComplete="username"
              autoCapitalize="none"
              autoCorrect="off"
              required
              onChange={(e) => setEmail(e.target.value)}
            />
          </div>

          <div className="field">
            <label htmlFor="password">Password</label>
            <input
              id="password"
              type="password"
              value={password}
              autoComplete="current-password"
              required
              onChange={(e) => setPassword(e.target.value)}
            />
          </div>

          <button
            className="primary block"
            type="submit"
            disabled={busy || !!configError}
          >
            {busy ? <Spinner /> : 'Sign in'}
          </button>
        </form>
      </div>
    </div>
  )
}
