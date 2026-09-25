import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase, friendlyMessage } from '../../lib/supabase'
import { fmtMoney } from '../../lib/format'
import { Report } from '../../components/Report'
import type { ReportColumn } from '../../components/Report'
import { Check } from '../../components/FormSheet'
import { useMasterGroups, MasterFilter } from '../../lib/masters'

/**
 * Who owes what, and for how long.
 *
 * By party normally; by route when the question is which round to chase. The
 * buckets come from the database so that this agrees with every other place
 * ageing is shown.
 */

interface PartyRow {
  party_id: string
  party_code: string
  party_name: string
  route_name: string
  total_outstanding: number
  b_0_15: number
  b_16_30: number
  b_31_45: number
  b_46_plus: number
  oldest_days: number
  open_invoices: number
}

/** The same row, one per party per master group. */
interface PartyMasterRow extends PartyRow {
  master_code: string
  master_name: string
}

interface RouteRow {
  route_id: string
  route_name: string
  total_outstanding: number
  b_0_15: number
  b_16_30: number
  b_31_45: number
  b_46_plus: number
  parties_owing: number
}

export default function AgeingReport() {
  const [byRoute, setByRoute] = useState(false)
  const [overdueOnly, setOverdueOnly] = useState(false)
  const [route, setRoute] = useState('')
  const [master, setMaster] = useState('')
  const [splitGroups, setSplitGroups] = useState(false)
  const [q, setQ] = useState('')
  const { masters } = useMasterGroups()

  const [parties, setParties] = useState<PartyRow[] | null>(null)
  const [pmRows, setPmRows] = useState<PartyMasterRow[] | null>(null)
  const [routes, setRoutes] = useState<RouteRow[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    setError(null)
    const [p, r, pm] = await Promise.all([
      supabase.from('v_ageing_by_party').select('*').order('total_outstanding', { ascending: false }),
      supabase.from('v_ageing_by_route').select('*').order('total_outstanding', { ascending: false }),
      supabase.from('v_ageing_by_party_master').select('*')
        .order('total_outstanding', { ascending: false }),
    ])
    if (p.error || r.error) {
      setError(friendlyMessage(p.error ?? r.error))
      setParties([])
      setRoutes([])
      return
    }
    setParties((p.data ?? []) as PartyRow[])
    setRoutes((r.data ?? []) as RouteRow[])
    setPmRows((pm.data ?? []) as PartyMasterRow[])
  }, [])

  useEffect(() => {
    void load()
  }, [load])

  const routeNames = useMemo(
    () => (parties ? Array.from(new Set(parties.map((p) => p.route_name))).sort() : []),
    [parties],
  )

  // Narrowing to one master group, or splitting a party across its groups,
  // both mean reading the finer view. Otherwise the plain one, so a party with
  // Parle and Current dues stays on a single line.
  const useMaster = splitGroups || master !== ''
  const showGroup = splitGroups

  const partyRows = useMemo(() => {
    const source: PartyRow[] | null = useMaster
      ? (pmRows ?? null) && (pmRows as PartyMasterRow[]).filter(
          (r) => !master || r.master_code === master)
      : parties
    if (!source) return null
    const needle = q.trim().toLowerCase()
    return source.filter((p) => {
      if (needle && !`${p.party_name} ${p.party_code} ${p.route_name}`
            .toLowerCase().includes(needle)) {
        return false
      }
      if (route && p.route_name !== route) return false
      // "Overdue" means anything past the first bucket.
      if (overdueOnly && Number(p.b_16_30) + Number(p.b_31_45) + Number(p.b_46_plus) <= 0) {
        return false
      }
      return true
    })
  }, [parties, pmRows, route, overdueOnly, useMaster, master, q])

  // With a group chosen, the route summary has to be rebuilt from the finer
  // rows — the stored one covers every group at once.
  const routeRows = useMemo(() => {
    if (!master) return routes
    if (!pmRows) return null
    const acc = new Map<string, RouteRow>()
    for (const r of pmRows.filter((x) => x.master_code === master)) {
      const cur = acc.get(r.route_name) ?? {
        route_id: r.route_name, route_name: r.route_name,
        total_outstanding: 0, b_0_15: 0, b_16_30: 0, b_31_45: 0, b_46_plus: 0,
        parties_owing: 0,
      }
      cur.total_outstanding += Number(r.total_outstanding || 0)
      cur.b_0_15   += Number(r.b_0_15 || 0)
      cur.b_16_30  += Number(r.b_16_30 || 0)
      cur.b_31_45  += Number(r.b_31_45 || 0)
      cur.b_46_plus += Number(r.b_46_plus || 0)
      cur.parties_owing += 1
      acc.set(r.route_name, cur)
    }
    return [...acc.values()].sort((a, b) => b.total_outstanding - a.total_outstanding)
  }, [routes, pmRows, master])

  const partyCols: ReportColumn<PartyRow>[] = [
    {
      header: 'Party',
      value: (r) => r.party_name,
      width: 26,
      cell: (r) => (
        <>
          <Link to={`/parties/${r.party_id}/ledger`} className="strong">{r.party_name}</Link>
          <br />
          <span className="muted" style={{ fontSize: 12.5 }}>{r.party_code}</span>
        </>
      ),
    },
    { header: 'Route', value: (r) => r.route_name },
    ...(showGroup
      ? [{
          header: 'Group',
          value: (r: PartyRow) => (r as PartyMasterRow).master_name,
          width: 14,
        } as ReportColumn<PartyRow>]
      : []),
    { header: '0–15', value: (r) => Number(r.b_0_15 ?? 0), type: 'money', align: 'right' },
    { header: '16–30', value: (r) => Number(r.b_16_30 ?? 0), type: 'money', align: 'right' },
    { header: '31–45', value: (r) => Number(r.b_31_45 ?? 0), type: 'money', align: 'right' },
    { header: '46+', value: (r) => Number(r.b_46_plus ?? 0), type: 'money', align: 'right' },
    {
      header: 'Total',
      value: (r) => Number(r.total_outstanding),
      type: 'money',
      align: 'right',
      cell: (r) => <span className="strong">{fmtMoney(r.total_outstanding)}</span>,
    },
    { header: 'Oldest', value: (r) => Number(r.oldest_days), type: 'number', align: 'right',
      cell: (r) => <>{r.oldest_days} d</> },
    { header: 'Bills', value: (r) => Number(r.open_invoices), type: 'number', align: 'right' },
  ]

  const routeCols: ReportColumn<RouteRow>[] = [
    { header: 'Route', value: (r) => r.route_name, width: 24 },
    { header: '0–15', value: (r) => Number(r.b_0_15 ?? 0), type: 'money', align: 'right' },
    { header: '16–30', value: (r) => Number(r.b_16_30 ?? 0), type: 'money', align: 'right' },
    { header: '31–45', value: (r) => Number(r.b_31_45 ?? 0), type: 'money', align: 'right' },
    { header: '46+', value: (r) => Number(r.b_46_plus ?? 0), type: 'money', align: 'right' },
    { header: 'Total', value: (r) => Number(r.total_outstanding), type: 'money', align: 'right' },
    { header: 'Parties', value: (r) => Number(r.parties_owing), type: 'number', align: 'right' },
  ]

  const sum = <T,>(rows: T[] | null, pick: (r: T) => number) =>
    (rows ?? []).reduce((s, r) => s + Number(pick(r) || 0), 0)

  const filters = (
    <>
      <MasterFilter masters={masters} value={master} onChange={setMaster} />
      <Check id="by-route" checked={byRoute} onChange={setByRoute}>
        Summarise by route
      </Check>
      {!byRoute && (
        <>
          <span className="grow" style={{ minWidth: 180 }}>
            <label className="sr-only" htmlFor="age-party">Find a customer</label>
            <input
              id="age-party"
              type="search"
              autoComplete="off"
              placeholder="Find a customer"
              value={q}
              onChange={(e) => setQ(e.target.value)}
            />
          </span>
          <select value={route} onChange={(e) => setRoute(e.target.value)} aria-label="Filter by route">
            <option value="">All routes</option>
            {routeNames.map((r) => (
              <option key={r} value={r}>{r}</option>
            ))}
          </select>
          <Check id="split-groups" checked={splitGroups} onChange={setSplitGroups}>
            A line per group
          </Check>
          <Check id="overdue" checked={overdueOnly} onChange={setOverdueOnly}>
            Past 15 days only
          </Check>
        </>
      )}
    </>
  )

  return byRoute ? (
    <Report<RouteRow>
      title="Outstanding by route"
      subtitle={`${master ? `${master} · ` : ''}as at ${new Date().toLocaleDateString('en-GB')}`}
      filters={filters}
      columns={routeCols}
      rows={routeRows}
      error={error}
      fileName="outstanding-by-route"
      empty="Nobody owes anything."
      totals={[
        'Total',
        sum(routeRows, (r) => r.b_0_15),
        sum(routeRows, (r) => r.b_16_30),
        sum(routeRows, (r) => r.b_31_45),
        sum(routeRows, (r) => r.b_46_plus),
        sum(routeRows, (r) => r.total_outstanding),
        null,
      ]}
    />
  ) : (
    <Report<PartyRow>
      title="Outstanding by party"
      subtitle={`${master ? `${master} · ` : ''}as at ${new Date().toLocaleDateString('en-GB')}`}
      filters={filters}
      columns={partyCols}
      rows={partyRows}
      error={error}
      fileName="outstanding-by-party"
      empty="Nobody owes anything."
      totals={[
        'Total',
        null,
        ...(showGroup ? [null] : []),
        sum(partyRows, (r) => r.b_0_15),
        sum(partyRows, (r) => r.b_16_30),
        sum(partyRows, (r) => r.b_31_45),
        sum(partyRows, (r) => r.b_46_plus),
        sum(partyRows, (r) => r.total_outstanding),
        null,
        null,
      ]}
    />
  )
}
