-- =============================================================================
-- 038_returns_views.sql
--
-- Run this in the Supabase SQL Editor. Committing it to git does nothing to
-- the database.
--
-- Goods coming back from a shop.
--
-- The document itself has existed since 008 and has worked since 014:
-- post_sales_return writes the return, puts the resaleable part back into
-- stock on the day it came back, leaves damaged goods out of stock while still
-- crediting the customer, and the credit can then be settled against the bill
-- it came from with allocate_credit. The party ledger has always shown a
-- return as a credit, and v_invoice_outstanding has always counted an
-- allocated return against what a bill still owes.
--
-- What has never existed is any way to SEE one. There is no screen, because
-- there was nothing to read a return back out of — this migration is the
-- missing half: two views, so the app can list returns and show a bill what
-- has come back against it.
--
-- Nothing here changes any figure. Both views read what is already stored.
--
-- Safe to run twice.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Every return, for the list screen
--
-- `allocated` and `unallocated` are the important pair. A return credits the
-- customer the moment it is posted, but until it is put against a bill it is
-- money floating against the account rather than against the debt it came
-- from — so the list has to show which returns are still loose.
-- -----------------------------------------------------------------------------

drop view if exists public.v_return_list;

create view public.v_return_list as
select
  sr.id                                   as return_id,
  sr.doc_no,
  sr.return_date,
  sr.party_id,
  p.code                                  as party_code,
  p.name                                  as party_name,
  rt.name                                 as route_name,
  sr.invoice_id,
  si.doc_no                               as invoice_no,
  si.invoice_date,
  sr.master_group_id,
  mg.code                                 as master_code,
  mg.name                                 as master_name,
  sr.total_value,
  sr.reason,
  sr.remarks,
  sr.status,
  u.full_name                             as created_by_name,
  sr.created_at,
  count(srl.id)                           as lines,
  coalesce(sum(srl.qty_base), 0)                             as qty_base,
  coalesce(sum(srl.qty_base) filter (where srl.restock), 0)  as qty_restocked,
  -- Goods credited but not put back on the shelf: damaged, expired, or opened.
  -- Worth its own column, because it is the number that explains why a credit
  -- and a stock increase do not match.
  coalesce(sum(srl.qty_base) filter (where not srl.restock), 0) as qty_written_off,
  coalesce(a.allocated, 0)                                   as allocated,
  sr.total_value - coalesce(a.allocated, 0)                  as unallocated
from public.sales_return sr
join public.party p   on p.id  = sr.party_id
join public.route rt  on rt.id = p.route_id
left join public.sales_invoice si on si.id = sr.invoice_id
left join public.master_group mg  on mg.id = sr.master_group_id
left join public.app_user u on u.id = sr.created_by
left join public.sales_return_line srl on srl.return_id = sr.id
left join (
  select sales_return_id, sum(amount) as allocated
    from public.credit_allocation
   where sales_return_id is not null
   group by sales_return_id
) a on a.sales_return_id = sr.id
group by sr.id, p.code, p.name, rt.name, si.doc_no, si.invoice_date,
         mg.code, mg.name, u.full_name, a.allocated;

alter view public.v_return_list set (security_invoker = true);
grant select on public.v_return_list to authenticated;

comment on view public.v_return_list is
  'Every sales return with what came back, how much of it went onto the shelf
   again, and how much of the credit has been put against a bill.';


-- -----------------------------------------------------------------------------
-- What has come back against a bill
--
-- One row per bill that has had anything returned against it. The bill screen
-- reads this to say so, which matters because a bill whose outstanding has
-- dropped without a payment against it otherwise looks like an error.
--
-- Only ACTIVE returns count. A cancelled return took its own goods back out of
-- stock and released its allocation, so including it would describe something
-- that has been undone.
-- -----------------------------------------------------------------------------

drop view if exists public.v_invoice_returns;

create view public.v_invoice_returns as
select
  sr.invoice_id,
  count(distinct sr.id)                   as returns,
  string_agg(distinct sr.doc_no, ', ')    as return_nos,
  max(sr.return_date)                     as last_return_date,
  coalesce(sum(srl.qty_base), 0)          as qty_base,
  coalesce(sum(srl.amount), 0)            as value
from public.sales_return sr
join public.sales_return_line srl on srl.return_id = sr.id
where sr.status = 'ACTIVE'
  and sr.invoice_id is not null
group by sr.invoice_id;

alter view public.v_invoice_returns set (security_invoker = true);
grant select on public.v_invoice_returns to authenticated;

comment on view public.v_invoice_returns is
  'What has been returned against each bill, so the bill can say so rather than
   simply showing a smaller balance than it was raised for.';

notify pgrst, 'reload schema';
