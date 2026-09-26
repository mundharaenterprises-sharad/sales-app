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
import Invoices from './screens/Invoices'
import NewInvoice from './screens/NewInvoice'
import InvoiceView from './screens/InvoiceView'
import InvoicePrintBatch from './screens/InvoicePrintBatch'
import Receipts from './screens/Receipts'
import NewReceipt from './screens/NewReceipt'
import ReceiptView from './screens/ReceiptView'
import PartyLedger from './screens/PartyLedger'
import Purchases from './screens/Purchases'
import NewPurchase from './screens/NewPurchase'
import PurchaseView from './screens/PurchaseView'
import DayBook from './screens/DayBook'
import Suppliers from './screens/Suppliers'
import Reports from './screens/Reports'
import AgeingReport from './screens/reports/Ageing'
import SalesRegister from './screens/reports/SalesRegister'
import Collections from './screens/reports/Collections'
import ProductSales from './screens/reports/ProductSales'
import StockReport from './screens/reports/StockReport'
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
        {/* Same screen. An order is the same thing whether it is being taken
            or corrected, and two screens would drift apart within a month. */}
        <Route path="orders/:id/edit" element={<NewOrder />} />
        <Route path="invoices" element={<Invoices />} />
        <Route
          path="invoices/new"
          element={
            user?.role === 'REP' ? <Navigate to="/invoices" replace /> : <NewInvoice />
          }
        />
        <Route path="invoices/print" element={<InvoicePrintBatch />} />
        <Route path="invoices/:id" element={<InvoiceView />} />
        <Route path="receipts" element={<Receipts />} />
        <Route
          path="receipts/new"
          element={user?.role === 'REP' ? <Navigate to="/receipts" replace /> : <NewReceipt />}
        />
        <Route path="receipts/:id" element={<ReceiptView />} />
        <Route
          path="day-book"
          element={user?.role === 'REP' ? <Navigate to="/" replace /> : <DayBook />}
        />
        <Route
          path="purchases"
          element={user?.role === 'REP' ? <Navigate to="/" replace /> : <Purchases />}
        />
        <Route
          path="suppliers"
          element={user?.role === 'REP' ? <Navigate to="/" replace /> : <Suppliers />}
        />
        <Route
          path="purchases/new"
          element={user?.role === 'REP' ? <Navigate to="/" replace /> : <NewPurchase />}
        />
        <Route
          path="purchases/:id"
          element={user?.role === 'REP' ? <Navigate to="/" replace /> : <PurchaseView />}
        />
        <Route path="parties" element={<Parties />} />
        <Route path="parties/:id/ledger" element={<PartyLedger />} />
        <Route path="reports" element={<Reports />} />
        <Route path="reports/ageing" element={<AgeingReport />} />
        <Route path="reports/sales" element={<SalesRegister />} />
        <Route path="reports/collections" element={<Collections />} />
        <Route path="reports/products" element={<ProductSales />} />
        <Route path="reports/stock" element={<StockReport />} />
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
