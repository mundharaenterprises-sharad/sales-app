-- =============================================================================
-- 048_profit_summary.sql
-- The Profitability report adds up every line, not the first thousand of them.
--
-- Run this in the Supabase SQL Editor. Committing it to git does nothing to
-- the database.
--
-- WHAT WENT WRONG. `public.profit_lines(from, to)` returns ONE ROW PER BILL
-- LINE and per return line. The Profitability screen asked for all of them in
-- a single request and added them up in the browser. PostgREST caps a response
-- at around a thousand rows and reports nothing — no error, no marker, just
-- fewer rows than exist. So the screen was totalling a slice of the period.
--
-- The dangerous part is not that it was wrong. It is that it looked right.
-- Truncation takes earnings and cost away together, so the MARGIN PERCENTAGE
-- stayed correct while every rupee figure came out short. Parle read 5.9% —
-- which is what the business actually earns — beside a margin of 13,950 where
-- 12,50,000 of sales at 5.9% is about 74,000. A percentage that agrees with
-- what you know, next to a total that is a fifth of the truth, is worse than
-- an obvious error.
--
-- This is the sales register's fault of 24 October (bug #31) in the one report
-- that never got `lib/fetchall.ts`: Profitability was written the day before
-- that fix.
--
-- THE FIX, AND WHY IT IS NOT PAGING. The screen never shows a bill line. It
-- shows one row per product, per product group or per master group, and the
-- group views are roll-ups of the product one. Sending thousands of lines to
-- the browser to build at most eighty-odd rows was the wrong shape to begin
-- with. So the grouping moves into the database:
--
--   public.profit_summary(from, to)   one row per product, ~82 of them
--
-- Nowhere near any cap, so there is nothing to page and nothing to truncate,
-- and the screen stops carrying a month of bill lines around to add them up.
--
-- `profit_lines` is UNCHANGED and stays the detail. The summary is defined as
-- a sum over it rather than as a second copy of the same query, so the two can
-- never drift: one rule, one place. Test 029 asserts they agree, product by
-- product, which is the assertion that keeps it true.
--
-- ADMIN ONLY, still, and by the same single check. `profit_lines` raises SA003
-- for anyone who is not an Admin (043), and the summary reaches its figures
-- only through it, so the permission is enforced once rather than twice. The
-- test asserts all three roles against the new function too, because a rule
-- inherited is still a rule that has to be proved.
--
-- Safe to run twice.
-- =============================================================================

create or replace function public.profit_summary(
  p_from date default null,
  p_to   date default null
)
returns table (
  product_id    uuid,
  product_code  text,
  product_name  text,
  group_code    text,
  group_name    text,
  master_code   text,
  master_name   text,
  base_uom      text,
  qty_base      numeric,
  net_sales     numeric,
  cost_amount   numeric,
  margin        numeric
)
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
  select
    l.product_id,
    l.product_code,
    l.product_name,
    l.group_code,
    l.group_name,
    l.master_code,
    l.master_name,
    l.base_uom,
    sum(l.qty_base)    as qty_base,
    sum(l.net_sales)   as net_sales,
    sum(l.cost_amount) as cost_amount,
    sum(l.margin)      as margin
  from public.profit_lines(p_from, p_to) l
  group by
    l.product_id, l.product_code, l.product_name,
    l.group_code, l.group_name, l.master_code, l.master_name, l.base_uom;
$$;

revoke all on function public.profit_summary(date, date) from public, anon;
grant execute on function public.profit_summary(date, date) to authenticated;

comment on function public.profit_summary(date, date) is
  'What each product earned in a period: one row per product, which is what the
   Profitability report shows. Admin only, inherited from profit_lines, which
   it sums rather than duplicates. Use this and not profit_lines from the app:
   profit_lines returns a row per bill line and a single request does not
   return every row.';

notify pgrst, 'reload schema';
