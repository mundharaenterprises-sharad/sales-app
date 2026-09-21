import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { SessionProvider, useSession } from './lib/session'
import Layout from './components/Layout'
import Login from './screens/Login'
import Home from './screens/Home'
import Stock from './screens/Stock'
import Import from './screens/Import'
import Orders from './screens/Orders'
import NewOrder from './screens/NewOrder'
import Parties from './screens/Parties'
import Products from './screens/Products'
import { Banner, Loading } from './components/ui'
import { supabase } from './lib/supabase'

function Gate() {
  const { session, user, loading, notProvisioned } = useSession()

  if (loading) return <Loading what="Starting" />

  if (!session) return <Login />

  // Signed in, but nobody has given this login a role. Row-level security will
  // refuse everything, so show the reason rather than a shell full of blanks.
  if (notProvisioned) {
    return (
      <div className="login-wrap">
        <div className="login-card">
          <div className="mark">S</div>
          <h1>Not set up yet</h1>
          <Banner tone="warn">
            You signed in, but this account has not been given a role. An
            administrator needs to add you before you can use the app.
          </Banner>
          <button className="block" onClick={() => void supabase.auth.signOut()}>
            Sign out
          </button>
        </div>
      </div>
    )
  }

  if (user && !user.is_active) {
    return (
      <div className="login-wrap">
        <div className="login-card">
          <div className="mark">S</div>
          <h1>Account disabled</h1>
          <Banner tone="bad">
            This account has been switched off. Speak to an administrator.
          </Banner>
          <button className="block" onClick={() => void supabase.auth.signOut()}>
            Sign out
          </button>
        </div>
      </div>
    )
  }

  return (
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<Home />} />
        <Route path="stock" element={<Stock />} />
        <Route path="orders" element={<Orders />} />
        <Route path="orders/new" element={<NewOrder />} />
        <Route path="parties" element={<Parties />} />
        <Route path="products" element={<Products />} />
        <Route
          path="import"
          element={user?.role === 'ADMIN' ? <Import /> : <Navigate to="/" replace />}
        />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  )
}

export default function App() {
  return (
    <BrowserRouter>
      <SessionProvider>
        <Gate />
      </SessionProvider>
    </BrowserRouter>
  )
}
