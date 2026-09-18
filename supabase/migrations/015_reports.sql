-- =============================================================================
-- 015_reports.sql
-- Reporting views.
--
-- All are security_invoker, so a rep sees exactly what RLS allows them to see
-- and no more. A view without it becomes a hole straight through RLS.
--
-- What counts as money, consistently across every view below:
--   * an invoice is owed at net_total minus whatever has been cancelled
--   * a receipt is a credit unless it is cancelled or its cheque bounced
--   * a sales return is a credit unless it is cancelled
--   * a PENDING cheque is treated as money, because it has been received;
--     v_pending_cheques exists so that exposure is visible separately
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Live credits: receipts and returns in one shape, so every downstream view
-- treats them identically.
-- -----------------------------------------------------------------------------

create or replace view public.v_credit as
select
  r.id             as credit_id,
  'RECEIPT'::text  as credit_type,
  r.doc_no,
  r.party_id,
  r.receipt_date   as credit_date,
  r.amount         as credit_amount,
  r.mode::text     as mode,
  r.collected_by
from public.receipt r
where r.status = 'ACTIVE'
  and coalesce(r.clearing_status, 'CLEARED') <> 'BOUNCED'

union all

select
  sr.id,
  'RETURN',
  sr.doc_no,
  sr.party_id,
  sr.return_date,
  sr.total_value,
  'GOODS RETURNED',
  null
from public.sales_return sr
where sr.status = 'ACTIVE';

-- -----------------------------------------------------------------------------
-- Invoice outstanding
-- -----------------------------------------------------------------------------

create or replace view public.v_invoice_outstanding as
select
  si.id            as invoice_id,
  si.doc_no,
  si.party_id,
  p.code           as party_code,
  p.name           as party_name,
  p.route_id,
  rt.name          as route_name,
  si.invoice_date,
  si.net_total,
  si.cancelled_value,
  si.effective_total,
  coalesce(ca.allocated, 0)                     as settled,
  si.effective_total - coalesce(ca.allocated, 0) as outstanding,
  current_date - si.invoice_date                as days_outstanding,
  si.status
from public.sales_invoice si
join public.party p  on p.id  = si.party_id
join public.route rt on rt.id = p.route_id
left join (
  select invoice_id, sum(amount) as allocated
    from public.credit_allocation
   group by invoice_id
) ca on ca.invoice_id = si.id
where si.status <> 'CANCELLED';

-- -----------------------------------------------------------------------------
-- Ageing
--
-- Buckets measured in days from the invoice date: 0-15, 16-30, 31-45, 46+.
-- -----------------------------------------------------------------------------

create or replace view public.v_ageing as
select
  io.*,
  case
    when io.days_outstanding <= 15 then '0-15'
    when io.days_outstanding <= 30 then '16-30'
    when io.days_outstanding <= 45 then '31-45'
    else '46+'
  end as bucket
from public.v_invoice_outstanding io
where io.outstanding > 0;

create or replace view public.v_ageing_by_party as
select
  party_id, party_code, party_name, route_id, route_name,
  sum(outstanding)                                          as total_outstanding,
  sum(outstanding) filter (where bucket = '0-15')  as b_0_15,
  sum(outstanding) filter (where bucket = '16-30') as b_16_30,
  sum(outstanding) filter (where bucket = '31-45') as b_31_45,
  sum(outstanding) filter (where bucket = '46+')   as b_46_plus,
  max(days_outstanding)                                     as oldest_days,
  count(*)                                                  as open_invoices
from public.v_ageing
group by party_id, party_code, party_name, route_id, route_name;

create or replace view public.v_ageing_by_route as
select
  route_id, route_name,
  sum(total_outstanding) as total_outstanding,
  sum(b_0_15)            as b_0_15,
  sum(b_16_30)           as b_16_30,
  sum(b_31_45)           as b_31_45,
  sum(b_46_plus)         as b_46_plus,
  count(*)               as parties_owing
from public.v_ageing_by_party
group by route_id, route_name;

-- -----------------------------------------------------------------------------
-- Unallocated credit — money received but not yet applied to any invoice.
--
-- With manual allocation this is the queue Accounts works through, so it is a
-- screen in its own right, not just a number.
-- -----------------------------------------------------------------------------

create or replace view public.v_unallocated_credit as
select
  c.credit_id, c.credit_type, c.doc_no, c.party_id,
  p.code  as party_code,
  p.name  as party_name,
  c.credit_date, c.mode,
  c.credit_amount,
  coalesce(a.allocated, 0)                  as allocated,
  c.credit_amount - coalesce(a.allocated, 0) as unallocated,
  current_date - c.credit_date              as days_waiting
from public.v_credit c
join public.party p on p.id = c.party_id
left join (
  select coalesce(receipt_id, sales_return_id) as credit_id, sum(amount) as allocated
    from public.credit_allocation
   group by coalesce(receipt_id, sales_return_id)
) a on a.credit_id = c.credit_id
where c.credit_amount - coalesce(a.allocated, 0) > 0;

-- -----------------------------------------------------------------------------
-- Party balance
--
--   opening + what is still owed on invoices - credit not yet applied
--
-- Which is the same as: opening + invoices - credits. The test suite proves
-- both routes agree, because a divergence here means money has gone missing.
-- -----------------------------------------------------------------------------

create or replace view public.v_party_balance as
select
  p.id                as party_id,
  p.code              as party_code,
  p.name              as party_name,
  p.route_id,
  rt.name             as route_name,
  p.credit_limit,
  p.credit_days,
  p.opening_balance,
  coalesce(inv.owed, 0)                          as invoice_outstanding,
  coalesce(cr.unapplied, 0)                      as on_account,
  p.opening_balance + coalesce(inv.owed, 0) - coalesce(cr.unapplied, 0) as balance,
  case
    when p.credit_limit > 0
     and p.opening_balance + coalesce(inv.owed, 0) - coalesce(cr.unapplied, 0)
         > p.credit_limit
    then true else false
  end                 as over_credit_limit,
  p.is_active
from public.party p
join public.route rt on rt.id = p.route_id
left join (
  select party_id, sum(outstanding) as owed
    from public.v_invoice_outstanding
   group by party_id
) inv on inv.party_id = p.id
left join (
  select party_id, sum(unallocated) as unapplied
    from public.v_unallocated_credit
   group by party_id
) cr on cr.party_id = p.id;

-- -----------------------------------------------------------------------------
-- Party ledger
--
-- One row per document, oldest first, with a running balance. Invoices are
-- shown at their issued value and cancellations as separate credit lines, so
-- the ledger reads the way a paper one would rather than silently restating
-- history.
-- -----------------------------------------------------------------------------

create or replace view public.v_party_ledger as
with entries as (
  select p.id as party_id, p.opening_balance_date as entry_date, 0 as sort_key,
         'OPENING'::text as doc_type, 'Opening balance'::text as doc_no,
         p.opening_balance as debit, 0::numeric as credit, null::uuid as doc_id
    from public.party p
   where p.opening_balance <> 0

  union all

  select si.party_id, si.invoice_date, 1, 'INVOICE', si.doc_no,
         si.net_total, 0, si.id
    from public.sales_invoice si

  union all

  select si.party_id, ic.cancellation_date, 2, 'CANCELLATION', ic.doc_no,
         0, ic.cancelled_value, ic.id
    from public.invoice_cancellation ic
    join public.sales_invoice si on si.id = ic.invoice_id

  union all

  select sr.party_id, sr.return_date, 3, 'RETURN', sr.doc_no,
         0, sr.total_value, sr.id
    from public.sales_return sr
   where sr.status = 'ACTIVE'

  union all

  select r.party_id, r.receipt_date, 4, 'RECEIPT', r.doc_no,
         0, r.amount, r.id
    from public.receipt r
   where r.status = 'ACTIVE'
     and coalesce(r.clearing_status, 'CLEARED') <> 'BOUNCED'
)
select
  e.party_id,
  p.code as party_code,
  p.name as party_name,
  e.entry_date,
  e.doc_type,
  e.doc_no,
  e.doc_id,
  e.debit,
  e.credit,
  sum(e.debit - e.credit) over (
    partition by e.party_id
    order by e.entry_date, e.sort_key, e.doc_no
    rows between unbounded preceding and current row
  ) as running_balance
from entries e
join public.party p on p.id = e.party_id;

-- -----------------------------------------------------------------------------
-- Sales register
-- -----------------------------------------------------------------------------

create or replace view public.v_sales_register as
select
  si.id           as invoice_id,
  si.doc_no,
  si.invoice_date,
  p.code          as party_code,
  p.name          as party_name,
  rt.name         as route_name,
  u.full_name     as created_by_name,
  so.doc_no       as order_no,
  rep.full_name   as rep_name,
  si.gross_total,
  si.line_discount_total,
  si.bill_discount_amount,
  si.round_off,
  si.net_total,
  si.cancelled_value,
  si.effective_total,
  si.status
from public.sales_invoice si
join public.party p       on p.id  = si.party_id
join public.route rt      on rt.id = p.route_id
left join public.app_user u   on u.id = si.created_by
left join public.sales_order so on so.id = si.order_id
left join public.app_user rep on rep.id = so.created_by;

-- -----------------------------------------------------------------------------
-- Product-wise sales and margin
--
-- NOTE: margin uses the product's CURRENT purchase_rate, not the cost at the
-- time of sale, which the schema does not yet capture. It is therefore an
-- estimate and will drift if buying prices move. Treat it as indicative until
-- a costing method is chosen.
-- -----------------------------------------------------------------------------

create or replace view public.v_product_sales as
select
  pr.id            as product_id,
  pr.code          as product_code,
  pr.name          as product_name,
  pg.name          as group_name,
  pr.base_uom,
  si.invoice_date,
  sum(sil.qty_base - sil.qty_cancelled_base)     as qty_sold_base,
  sum(sil.effective_amount
      - round(sil.effective_amount * sil.qty_cancelled_base
              / nullif(sil.qty_base, 0), 2))     as net_sales,
  sum((sil.qty_base - sil.qty_cancelled_base) * pr.purchase_rate) as est_cost,
  sum(sil.effective_amount
      - round(sil.effective_amount * sil.qty_cancelled_base
              / nullif(sil.qty_base, 0), 2))
    - sum((sil.qty_base - sil.qty_cancelled_base) * pr.purchase_rate)
                                                  as est_margin
from public.sales_invoice_line sil
join public.sales_invoice si on si.id = sil.invoice_id
join public.product pr       on pr.id = sil.product_id
join public.product_group pg on pg.id = pr.group_id
where si.status <> 'CANCELLED'
group by pr.id, pr.code, pr.name, pg.name, pr.base_uom, si.invoice_date;

-- -----------------------------------------------------------------------------
-- Collections
--
-- days_in_transit is the gap between the date the customer paid and the date
-- the receipt was entered. For cash a rep collected and later handed over,
-- that gap is how long the money sat with them. It is the only visibility the
-- system has into that, because Accounts enters receipts on handover; if a
-- rep never hands cash over, no receipt exists and nothing here will show it.
-- -----------------------------------------------------------------------------

create or replace view public.v_collection_report as
select
  r.id            as receipt_id,
  r.doc_no,
  r.receipt_date,
  r.created_at::date as entered_on,
  (r.created_at::date - r.receipt_date) as days_in_transit,
  p.code          as party_code,
  p.name          as party_name,
  rt.name         as route_name,
  r.mode,
  r.amount,
  r.clearing_status,
  coll.full_name  as collected_by_name,
  coll.role       as collected_by_role,
  ent.full_name   as entered_by_name,
  r.status
from public.receipt r
join public.party p       on p.id  = r.party_id
join public.route rt      on rt.id = p.route_id
left join public.app_user coll on coll.id = r.collected_by
left join public.app_user ent  on ent.id  = r.created_by;

create or replace view public.v_collection_by_collector as
select
  coalesce(coll.full_name, 'Unattributed') as collected_by_name,
  r.collected_by,
  r.receipt_date,
  r.mode,
  count(*)                                 as receipts,
  sum(r.amount)                            as collected,
  round(avg(r.created_at::date - r.receipt_date), 1) as avg_days_in_transit
from public.receipt r
left join public.app_user coll on coll.id = r.collected_by
where r.status = 'ACTIVE'
group by coll.full_name, r.collected_by, r.receipt_date, r.mode;

-- -----------------------------------------------------------------------------
-- Pending cheques
-- -----------------------------------------------------------------------------

create or replace view public.v_pending_cheques as
select
  r.id           as receipt_id,
  r.doc_no,
  r.receipt_date,
  r.instrument_date,
  r.reference_no as cheque_no,
  r.bank_name,
  p.code         as party_code,
  p.name         as party_name,
  r.amount,
  current_date - coalesce(r.instrument_date, r.receipt_date) as days_since_instrument
from public.receipt r
join public.party p on p.id = r.party_id
where r.mode = 'CHEQUE'
  and r.clearing_status = 'PENDING'
  and r.status = 'ACTIVE';

-- -----------------------------------------------------------------------------
-- Stock
-- -----------------------------------------------------------------------------

create or replace view public.v_stock_report as
select
  pr.id        as product_id,
  pr.code      as product_code,
  pr.name      as product_name,
  pg.name      as group_name,
  pr.base_uom,
  pr.pack_uom,
  pr.pack_size,
  ps.on_hand,
  ps.reserved,
  ps.available,
  case when pr.pack_size > 1
       then floor(ps.available / pr.pack_size) else null end as available_packs,
  pr.sale_rate,
  pr.purchase_rate,
  ps.on_hand * pr.purchase_rate as stock_value_at_cost,
  ps.updated_at,
  pr.is_active
from public.product pr
join public.product_group pg on pg.id = pr.group_id
join public.product_stock ps on ps.product_id = pr.id;

-- Orders holding stock that is about to be released.
create or replace view public.v_pending_orders as
select
  so.id        as order_id,
  so.doc_no,
  so.order_date,
  so.status,
  so.expires_at,
  p.code       as party_code,
  p.name       as party_name,
  rt.name      as route_name,
  rep.full_name as rep_name,
  count(sol.id)                                   as lines,
  sum(sol.qty_pending_base)                       as qty_pending_base,
  sum(round(sol.qty * sol.rate, 2))               as order_value,
  case when so.expires_at < now() + interval '1 day'
       then true else false end                   as expiring_soon
from public.sales_order so
join public.party p        on p.id  = so.party_id
join public.route rt       on rt.id = p.route_id
left join public.app_user rep on rep.id = so.created_by
join public.sales_order_line sol on sol.order_id = so.id
where so.status in ('SUBMITTED', 'PARTIALLY_INVOICED')
group by so.id, p.code, p.name, rt.name, rep.full_name;

-- -----------------------------------------------------------------------------
-- Purchase register
-- -----------------------------------------------------------------------------

create or replace view public.v_purchase_register as
select
  pu.id        as purchase_id,
  pu.doc_no,
  pu.purchase_date,
  s.code       as supplier_code,
  s.name       as supplier_name,
  pu.supplier_bill_no,
  pu.supplier_bill_date,
  pu.gross_total,
  pu.other_charges,
  pu.net_total,
  pu.status,
  u.full_name  as created_by_name
from public.purchase pu
join public.supplier s on s.id = pu.supplier_id
left join public.app_user u on u.id = pu.created_by;

-- =============================================================================
-- Security and grants
--
-- security_invoker means each view runs with the caller's permissions, so RLS
-- on the underlying tables still applies. Without it, any of these would let a
-- rep read everything.
-- =============================================================================

do $$
declare v text;
begin
  foreach v in array array[
    'v_credit', 'v_invoice_outstanding', 'v_ageing', 'v_ageing_by_party',
    'v_ageing_by_route', 'v_unallocated_credit', 'v_party_balance',
    'v_party_ledger', 'v_sales_register', 'v_product_sales',
    'v_collection_report', 'v_collection_by_collector', 'v_pending_cheques',
    'v_stock_report', 'v_pending_orders', 'v_purchase_register'
  ] loop
    execute format('alter view public.%I set (security_invoker = true)', v);
    execute format('grant select on public.%I to authenticated', v);
  end loop;
end;
$$;
