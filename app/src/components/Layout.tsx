import { useEffect } from 'react'
import { NavLink, Outlet, useLocation } from 'react-router-dom'
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
  { to: '/reports', label: 'Reports', roles: ['REP', 'ACCOUNTS', 'ADMIN'] },
  { to: '/import', label: 'Import', roles: ['ADMIN'] },
]

/** Keys that should always move the page, wherever the focus happens to be. */
const SCROLL_KEYS = ['ArrowDown', 'ArrowUp', 'PageDown', 'PageUp', 'Home', 'End']

export default function Layout() {
  const { user, signOut } = useSession()
  const online = useOnline()
  const location = useLocation()

  /**
   * Arrow keys scroll the page.
   *
   * The browser sends them to whatever scrollable box the focus sits in. Click
   * a tab and that box is the tab bar, which scrolls sideways and has nothing
   * to scroll down — so the page sat still and the keys appeared dead. Rather
   * than chase every such container, the page takes these keys itself, unless
   * something is being typed into or a dialog is open, where they mean
   * something else.
   */
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.defaultPrevented || e.ctrlKey || e.metaKey || e.altKey) return
      if (!SCROLL_KEYS.includes(e.key)) return

      const t = e.target as HTMLElement | null
      const tag = t?.tagName
      if (t?.isContentEditable || tag === 'TEXTAREA' || tag === 'SELECT' || tag === 'OPTION') {
        return
      }
      // A one-line text box has no use for up and down: the browser only
      // offers its own suggestion list, which is not what anyone wants while
      // reading a list of parties. Leave the keys alone where they do mean
      // something — a date steps a day, a number box steps a value.
      if (tag === 'INPUT') {
        const type = (t as HTMLInputElement).type
        const passThrough = ['date', 'datetime-local', 'month', 'week', 'time', 'number', 'range']
        if (passThrough.includes(type)) return
      }
      // A dialog does its own scrolling.
      if (document.querySelector('.sheet-backdrop')) return

      const page = Math.max(window.innerHeight - 80, 200)
      const by =
        e.key === 'ArrowDown' ? 72
        : e.key === 'ArrowUp' ? -72
        : e.key === 'PageDown' ? page
        : e.key === 'PageUp' ? -page
        : 0

      e.preventDefault()
      if (e.key === 'Home') window.scrollTo({ top: 0 })
      else if (e.key === 'End') window.scrollTo({ top: document.body.scrollHeight })
      else window.scrollBy({ top: by })
    }

    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  /**
   * Moving to another screen starts at the top, with the page scrollable.
   * A dialog left mid-navigation could otherwise leave the body locked.
   */
  useEffect(() => {
    document.body.style.overflow = ''
    window.scrollTo({ top: 0 })
  }, [location.pathname])

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
