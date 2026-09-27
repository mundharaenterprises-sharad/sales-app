-- =============================================================================
-- 033_orders_by_master_group.sql
--
-- Run this in the Supabase SQL Editor. Committing it to git does nothing to
-- the database.
--
-- The Orders screen is the one list that cannot be filtered by master group.
-- Bills, Purchases, the day book, the sales register and the ageing report all
-- can; orders were missed, because when the filters were built they went onto
-- the screens the office reads and Orders looked like the reps' screen.
--
-- It is the office's screen too, and arguably the one where it matters most:
-- billing a round means working through Parle and then Current, and a list
-- that mixes them makes the person doing it hold the separation in their head.
--
-- The view is the reason it could not simply be added to the screen —
-- v_pending_orders never carried the group, though the order itself has had
-- one since 024. So it does now, along with the rep, which was already there.
--
-- Nothing else changes: same rows, same figures, two more columns.
--
-- Safe to run twice.
-- =============================================================================

drop view if exists public.v_pending_orders;

create view public.v_pending_orders as
select
  so.id        as order_id,
  so.doc_no,
  so.order_date,
  so.status,
  so.expires_at,
  p.code       as party_code,
  p.name       as party_name,
  rt.name      as route_name,
  so.created_by as rep_id,
  rep.full_name as rep_name,
  mg.code      as master_code,
  mg.name      as master_name,
  count(sol.id)                                   as lines,
  sum(sol.qty_pending_base)                       as qty_pending_base,
  greatest(
    sum(round(sol.qty * sol.rate, 2) - sol.line_discount_amount)
      - so.bill_discount_amount + so.round_off,
    0)                                            as order_value,
  sum(round(sol.qty * sol.rate, 2))               as gross_value,
  case when so.expires_at < now() + interval '1 day'
       then true else false end                   as expiring_soon
from public.sales_order so
join public.party p        on p.id  = so.party_id
join public.route rt       on rt.id = p.route_id
left join public.app_user rep on rep.id = so.created_by
left join public.master_group mg on mg.id = so.master_group_id
join public.sales_order_line sol on sol.order_id = so.id
where so.status in ('SUBMITTED', 'PARTIALLY_INVOICED')
group by so.id, p.code, p.name, rt.name, rep.full_name, mg.code, mg.name;

alter view public.v_pending_orders set (security_invoker = true);
grant select on public.v_pending_orders to authenticated;

comment on view public.v_pending_orders is
  'Orders holding stock, with the master group and the rep who took them, so
   the office can work through one group at a time.';

notify pgrst, 'reload schema';
