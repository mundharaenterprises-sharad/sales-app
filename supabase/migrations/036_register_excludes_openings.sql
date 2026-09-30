-- =============================================================================
-- 036_register_excludes_openings.sql
--
-- Run this in the Supabase SQL Editor. Committing it to git does nothing to
-- the database.
--
-- Opening balances were showing up in the sales register.
--
-- They are real documents — 026 made them so, deliberately, because a balance
-- brought forward has to age like anything else and a payment has to have
-- something to settle. Each one is a bill with no lines, numbered OPN-<code>,
-- dated sixteen days before the balance was struck.
--
-- What they are not is a sale. Nothing left the building, no goods were
-- priced, no rep earned anything. A register that counts them overstates the
-- period by the whole of the opening book, and the figure it prints is one
-- nobody can reconcile against anything.
--
-- The view has simply never known about them: v_sales_register was last built
-- in 024, and is_opening arrived in 026, two migrations later. So this adds
-- the one condition that was missing.
--
-- v_sales_register_lines needs nothing. It is built from bill LINES, and an
-- opening document has none — so those bills have always been absent from the
-- product-wise and salesman sheets. That is worth knowing, because it means
-- the two sheets of a download have been disagreeing with the bill list all
-- along, and after this they agree.
--
-- The Bills list, the party ledger and the ageing report are untouched. You
-- still need to see what a shop owed at cutover; you just do not need it
-- counted as this month's trade.
--
-- Nothing else changes: same columns, same order, one fewer kind of row.
--
-- Safe to run twice.
-- =============================================================================

drop view if exists public.v_sales_register;

create view public.v_sales_register as
select
  si.id           as invoice_id,
  si.doc_no,
  si.invoice_date,
  p.code          as party_code,
  p.name          as party_name,
  rt.name         as route_name,
  mg.code         as master_code,
  mg.name         as master_name,
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
left join public.master_group mg on mg.id = si.master_group_id
left join public.app_user u   on u.id = si.created_by
left join public.sales_order so on so.id = si.order_id
left join public.app_user rep on rep.id = so.created_by
-- The whole of this migration.
where not si.is_opening;

alter view public.v_sales_register set (security_invoker = true);
grant select on public.v_sales_register to authenticated;

comment on view public.v_sales_register is
  'Every bill raised in a period, for the sales register. Opening balance
   documents are excluded: they are bills so that they can age and be settled,
   but they are not sales and must not be counted as turnover.';

notify pgrst, 'reload schema';
