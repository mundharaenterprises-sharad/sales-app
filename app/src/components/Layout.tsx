import { NavLink, Outlet } from 'react-router-dom'
import { useSession, useOnline } from '../lib/session'
import { Banner } from './ui'
import type { Role } from '../lib/supabase'

interface NavItem {
  to: string
  label: string
  roles: Role[]
}

const NAV: NavItem[] = [
  { to: '/',      label: 'Home',   roles: ['REP', 'ACCOUNTS', 'ADMIN'] },
  { to: '/orders', label: 'Orders', roles: ['REP', 'ACCOUNTS', 'ADMIN'] },
  { to: '/invoices', label: 'Bills', roles: ['REP', 'ACCOUNTS', 'ADMIN'] },
  { to: '/receipts', label: 'Payments', roles: ['REP', 'ACCOUNTS', 'ADMIN'] },
  { to: '/stock', label: 'Stock',  roles: ['REP', 'ACCOUNTS', 'ADMIN'] },
  { to: '/parties', label: 'Parties', roles: ['REP', 'ACCOUNTS', 'ADMIN'] },
  { to: '/products', label: 'Products', roles: ['REP', 'ACCOUNTS', 'ADMIN'] },
  { to: '/import', label: 'Import', roles: ['ADMIN'] },
]

export default function Layout() {
  const { user, signOut } = useSession()
  const online = useOnline()

  const items = NAV.filter((i) => user && i.roles.includes(user.role))

  return (
    <div className="app">
      <header className="topbar">
        <span className="brand">Sales App</span>
        {user && (
          <span className="who">
            <strong>{user.full_name}</strong>
            {user.role.charAt(0) + user.role.slice(1).toLowerCase()}
          </span>
        )}
        <button
          className="ghost"
          style={{ color: '#fff', minHeight: 36, padding: '6px 10px' }}
          onClick={() => void signOut()}
        >
          Sign out
        </button>
      </header>

      <nav className="nav">
        {items.map((i) => (
          <NavLink key={i.to} to={i.to} end={i.to === '/'}>
            {i.label}
          </NavLink>
        ))}
      </nav>

      <main>
        {!online && (
          <Banner tone="warn">
            <strong>You are offline.</strong> You can look at customers and stock
            saved on this device, but the figures may have moved on. Taking an
            order needs a connection.
          </Banner>
        )}
        <Outlet />
      </main>
    </div>
  )
}
