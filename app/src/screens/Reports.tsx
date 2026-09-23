import { Link } from 'react-router-dom'
import { useSession } from '../lib/session'

const REPORTS = [
  { to: '/reports/ageing', title: 'Outstanding & ageing', what: 'Who owes what, in 0–15, 16–30, 31–45 and 46+ day buckets. By party or by route.' },
  { to: '/reports/sales', title: 'Sales register', what: 'Every bill in a period, with discounts, cancellations and what was actually billed.' },
  { to: '/reports/collections', title: 'Collections', what: 'Money received in a period, who collected it, and how long it took to reach the office.' },
  { to: '/reports/products', title: 'Product sales', what: 'What sold, in quantity and value, with an indicative margin.' },
  { to: '/reports/stock', title: 'Stock', what: 'On hand, reserved and available, with stock value at cost.' },
]

export default function Reports() {
  const { user } = useSession()

  return (
    <>
      <div className="page-head">
        <h1>Reports</h1>
        <span className="sub">Every one exports to Excel, or prints as PDF</span>
      </div>

      <div className="report-cards">
        {REPORTS.map((r) => (
          <Link className="tile" to={r.to} key={r.to}>
            <h3>{r.title}</h3>
            <p>{r.what}</p>
          </Link>
        ))}
      </div>

      <p className="sub" style={{ marginTop: 14 }}>
        For a PDF, choose <strong>PDF / Print</strong> and then "Save as PDF" as the
        printer. A customer's own ledger is on their party, under Parties.
        {user?.role === 'REP' && ' Cost and margin figures are kept for the office.'}
      </p>
    </>
  )
}
