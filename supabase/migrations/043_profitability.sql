-- =============================================================================
-- 043_profitability.sql
-- What each item and each group actually earned. Admin only.
--
-- Run this in the Supabase SQL Editor. Committing it to git does nothing to
-- the database.
--
-- There has been an "indicative margin" on the Product sales report since 015,
-- and the word indicative was doing a lot of work: it valued every sale at the
-- product's CURRENT purchase price. Raise a buying price today and last
-- quarter's profit changed with it. Two people running the same report a month
-- apart got different answers, and neither was wrong about the data.
--
-- THE COST BASIS, which he chose: the average of what was actually paid.
--
-- Every receipt into stock carries its cost — opening stock at the cost
-- imported at go-live, a purchase at its real cost (net of discount, since
-- 041). A sale takes the average cost in force at that moment. So:
--
--     bought 10 ctn at 1,900 and 10 at 2,000  ->  average cost 1,950
--     sold 5 ctn at 2,600                     ->  earned 3,250
--     buying price rises to 2,100 next month  ->  that 3,250 does not move
--
-- Weighted average, not FIFO. For fast-moving goods bought in whole loads the
-- two differ by very little, and an average is a figure that can be explained
-- to the person whose money it is.
--
-- FOUR CONSEQUENCES WORTH KNOWING BEFORE READING THE REPORT.
--
-- 1. Only an OPENING or a PURCHASE sets a cost. Everything else that moves
--    stock — a return coming back, a stock adjustment, a cancellation putting
--    goods back — moves at the cost already in force, so it changes quantity
--    and value together and leaves the average alone. Goods coming back do not
--    re-enter stock at the price they were sold for, which is what the ledger
--    happens to record against a return and would badly inflate cost.
--
-- 2. A return that was WRITTEN OFF costs the business the goods. There is no
--    stock movement to reverse, so the credit comes off the earnings and the
--    cost stays spent. That is the correct answer and it is asserted in the
--    tests, because it is the one case where the margin on a product can go
--    negative without anything being wrong.
--
-- 3. `other_charges` on a purchase — freight, loading — is NOT part of cost
--    here, exactly as it is not part of stock cost (041). Earnings are
--    measured on the goods. Freight on a mixed load cannot be attributed to
--    one product honestly, and guessing would make every figure softer.
--
-- 4. The figures before the first purchase entry of a product lean on the
--    opening cost imported at go-live. That is as good as the data gets, and
--    it is the answer he asked for rather than leaving old bills blank.
--
-- ADMIN ONLY, and in the database rather than only hidden on screen. Cost is
-- the one figure in this app that a rep or the office should not be able to
-- read, and a view that merely isn't linked anywhere is still a URL. So the
-- figures come out of a SECURITY DEFINER function that refuses anyone who is
-- not an Admin, and the indicative margin is removed from Product sales, where
-- Accounts could see it until now.
--
-- WHERE THIS WILL HURT, EVENTUALLY. The cost of a sale is worked out by
-- walking the stock ledger rather than stored on the bill line. That is what
-- lets it answer for every bill already raised, which is what he wanted, and
-- the walk is one step per purchase rather than per sale so it stays cheap for
-- a long time. If it ever does get slow, the fix is not to optimise this: it is
-- to snapshot the cost onto `sales_invoice_line` when the bill is raised, and
-- have this read that for new bills and the ledger for old ones.
--
-- Safe to run twice. Nothing already stored changes; this only reads.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Admin, and nobody else
-- -----------------------------------------------------------------------------

create or replace function app.require_admin()
returns uuid
language plpgsql
stable
as $$
declare v_id uuid := app.require_signed_in();
begin
  if not app.is_admin() then
    raise exception 'Profitability is for Admin only' using errcode = 'SA003';
  end if;
  return v_id;
end;
$$;

comment on function app.require_admin() is
  'Raises SA003 unless the caller is an Admin. Used by the profitability
   figures, which are the one thing in the app that Accounts may not read.';


-- -----------------------------------------------------------------------------
-- 2. Every stock movement, in order, marked with the cost event it follows
-- -----------------------------------------------------------------------------
-- The ordering has to be total, not just by date: a purchase and a sale of the
-- same product on the same day have to fall in a definite order or the cost of
-- that day's sale depends on which row the planner happens to read first.
-- `created_at` then `id` settles it, and `id` is there only to break a tie
-- between two rows written in the same instant.

-- A CANCELLED DOCUMENT IS LEFT OUT ENTIRELY, both the movement and the
-- movement that reversed it. They net to zero in quantity, so dropping the
-- pair changes nothing about what is on the shelf — but it matters a great
-- deal to cost, and it is not optional.
--
-- A cancellation is dated the day it is made, while the document it cancels
-- keeps its own date. Correct a purchase from last Tuesday (044) and the
-- ledger reads: Tuesday's purchase, Tuesday's replacement, then today's
-- cancellation. In date order the wrong purchase is still sitting in front of
-- the right one, so the average comes out halfway between the rate that was
-- keyed and the rate that was meant — and the cancellation never fully
-- undoes it, because by then it is taken out at the blended cost rather than
-- at the cost it went in at.
--
-- A purchase cannot be cancelled once its goods have gone out, so nothing was
-- ever sold out of one, and leaving it out of the costing loses nothing real.
-- The same reasoning covers a cancelled bill and a cancelled return. This was
-- found by a test, after 044 made it easy to produce.

create or replace view app.v_ledger_marked as
select
  sl.id,
  sl.product_id,
  sl.movement_date,
  sl.created_at,
  sl.qty_in,
  sl.qty_out,
  sl.rate,
  sl.doc_type,
  sl.doc_id,
  sl.doc_line_id,
  (sl.doc_type in ('OPENING', 'PURCHASE'))            as sets_cost,
  sum(case when sl.doc_type in ('OPENING', 'PURCHASE') then 1 else 0 end)
    over (partition by sl.product_id
          order by sl.movement_date, sl.created_at, sl.id
          rows between unbounded preceding and current row) as event_no
from public.stock_ledger sl
where
  -- A purchase and its cancellation both carry the purchase's id.
  not (sl.doc_type in ('PURCHASE', 'PURCHASE_CANCEL')
       and exists (select 1 from public.purchase p
                    where p.id = sl.doc_id and p.status = 'CANCELLED'))
  -- A sale's cancellation carries the cancellation document's id, not the
  -- bill's, so both are tied back through the bill LINE instead.
  and not (sl.doc_type in ('SALE', 'SALE_CANCEL')
           and exists (select 1 from public.sales_invoice_line sil
                         join public.sales_invoice si on si.id = sil.invoice_id
                        where sil.id = sl.doc_line_id
                          and si.status = 'CANCELLED'))
  and not (sl.doc_type in ('SALE_RETURN', 'SALE_RETURN_CANCEL')
           and exists (select 1 from public.sales_return sr
                        where sr.id = sl.doc_id and sr.status = 'CANCELLED'));


-- -----------------------------------------------------------------------------
-- 3. The average cost after each cost event
-- -----------------------------------------------------------------------------
-- Because a sale leaves at the average, it takes quantity and value away in
-- the same proportion and the average does not move. So the state only has to
-- be carried forward from one purchase to the next, and the whole of it is two
-- numbers: how much is on hand, and what it is worth each.
--
--     on hand before this purchase = on hand after the last one, plus
--                                    everything that moved in between
--     new average = (that quantity at the old average + this purchase)
--                   / the total quantity
--
-- If stock had run down to nothing, the new purchase simply sets the cost.

create or replace view app.v_cost_events as
with recursive
events as (
  select product_id, event_no, movement_date, qty_in, rate
    from app.v_ledger_marked
   where sets_cost
),
-- What moved between one cost event and the next, net. Rows before the first
-- cost event carry event_no 0 and are never joined, which is correct: there is
-- no cost to value them at.
moved as (
  select product_id, event_no, sum(qty_in - qty_out) as net_qty
    from app.v_ledger_marked
   where not sets_cost
   group by product_id, event_no
),
walk as (
  -- Both terms cast explicitly: a recursive CTE insists the two halves agree
  -- on type, and the columns arrive as numeric(14,4) while the arithmetic
  -- below widens to plain numeric.
  select e.product_id,
         e.event_no,
         e.qty_in::numeric               as qty_after,
         round(e.rate, 4)::numeric       as unit_cost
    from events e
   where e.event_no = 1

  union all

  select e.product_id,
         e.event_no,
         greatest(w.qty_after + coalesce(m.net_qty, 0), 0) + e.qty_in,
         case
           when greatest(w.qty_after + coalesce(m.net_qty, 0), 0) + e.qty_in <= 0
             then round(e.rate, 4)
           else round(
                  (greatest(w.qty_after + coalesce(m.net_qty, 0), 0) * w.unit_cost
                   + e.qty_in * e.rate)
                  / (greatest(w.qty_after + coalesce(m.net_qty, 0), 0) + e.qty_in), 4)
         end
    from walk w
    join events e
      on e.product_id = w.product_id
     and e.event_no   = w.event_no + 1
    left join moved m
      on m.product_id = w.product_id
     and m.event_no   = w.event_no
)
select product_id, event_no, qty_after, unit_cost from walk;


-- -----------------------------------------------------------------------------
-- 4. Every movement, with the cost it moved at
-- -----------------------------------------------------------------------------

create or replace view app.v_ledger_cost as
select
  m.id,
  m.product_id,
  m.movement_date,
  m.doc_type,
  m.doc_id,
  m.doc_line_id,
  m.qty_in,
  m.qty_out,
  m.event_no,
  coalesce(c.unit_cost, 0) as unit_cost
from app.v_ledger_marked m
left join app.v_cost_events c
       on c.product_id = m.product_id
      and c.event_no   = m.event_no;

comment on view app.v_ledger_cost is
  'Each stock movement with the weighted average cost in force when it
   happened. unit_cost is 0 only for a movement before the product had any
   costed receipt at all, which should not happen.';


-- -----------------------------------------------------------------------------
-- 5. What the Admin reads
-- -----------------------------------------------------------------------------
-- One row per bill line and per return line, with every dimension the report
-- groups by. Returns are negative rows rather than a separate figure, so a
-- group total is a single sum and the arithmetic on screen cannot drift from
-- the arithmetic here.
--
-- Partly cancelled bill lines are netted on the line — quantity, earnings and
-- cost all scaled to what stayed sold — rather than by chasing the
-- cancellation's own stock rows. The cost of the cancelled part is taken at the
-- same average as the sale, which is what a moving average means.

create or replace function public.profit_lines(
  p_from date default null,
  p_to   date default null
)
returns table (
  kind          text,
  doc_no        text,
  doc_date      date,
  party_code    text,
  party_name    text,
  route_name    text,
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
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
begin
  perform app.require_admin();

  return query

  -- Sold
  select
    'SALE'::text,
    si.doc_no,
    si.invoice_date,
    pa.code,
    pa.name,
    coalesce(rt.name, ''),
    pr.id,
    pr.code,
    pr.name,
    pg.code,
    pg.name,
    mg.code,
    mg.name,
    pr.base_uom,
    (sil.qty_base - sil.qty_cancelled_base),
    (sil.effective_amount
      - round(sil.effective_amount * sil.qty_cancelled_base
              / nullif(sil.qty_base, 0), 2)),
    round((sil.qty_base - sil.qty_cancelled_base) * coalesce(lc.unit_cost, 0), 2),
    (sil.effective_amount
      - round(sil.effective_amount * sil.qty_cancelled_base
              / nullif(sil.qty_base, 0), 2))
      - round((sil.qty_base - sil.qty_cancelled_base) * coalesce(lc.unit_cost, 0), 2)
  from public.sales_invoice_line sil
  join public.sales_invoice si  on si.id = sil.invoice_id
  join public.party pa          on pa.id = si.party_id
  left join public.route rt     on rt.id = pa.route_id
  join public.product pr        on pr.id = sil.product_id
  join public.product_group pg  on pg.id = pr.group_id
  join public.master_group mg   on mg.id = pg.master_group_id
  left join app.v_ledger_cost lc
         on lc.doc_type = 'SALE'
        and lc.doc_line_id = sil.id
  where si.status <> 'CANCELLED'
    and not si.is_opening
    and (p_from is null or si.invoice_date >= p_from)
    and (p_to   is null or si.invoice_date <= p_to)
    and (sil.qty_base - sil.qty_cancelled_base) > 0

  union all

  -- Came back. Negative on both sides when the goods went back on the shelf;
  -- negative earnings and no cost relief when they were written off, because
  -- the goods are gone and the customer was still credited.
  select
    'RETURN'::text,
    sr.doc_no,
    sr.return_date,
    pa.code,
    pa.name,
    coalesce(rt.name, ''),
    pr.id,
    pr.code,
    pr.name,
    pg.code,
    pg.name,
    mg.code,
    mg.name,
    pr.base_uom,
    -srl.qty_base,
    -srl.amount,
    -round(srl.qty_base * coalesce(lc.unit_cost, 0), 2),
    -srl.amount + round(srl.qty_base * coalesce(lc.unit_cost, 0), 2)
  from public.sales_return_line srl
  join public.sales_return sr   on sr.id = srl.return_id
  join public.party pa          on pa.id = sr.party_id
  left join public.route rt     on rt.id = pa.route_id
  join public.product pr        on pr.id = srl.product_id
  join public.product_group pg  on pg.id = pr.group_id
  join public.master_group mg   on mg.id = pg.master_group_id
  left join app.v_ledger_cost lc
         on lc.doc_type = 'SALE_RETURN'
        and lc.doc_line_id = srl.id
  where sr.status <> 'CANCELLED'
    and (p_from is null or sr.return_date >= p_from)
    and (p_to   is null or sr.return_date <= p_to);
end;
$$;

revoke all on function public.profit_lines(date, date) from public, anon;
grant execute on function public.profit_lines(date, date) to authenticated;

comment on function public.profit_lines(date, date) is
  'One row per bill line and per return line, with earnings, cost at weighted
   average, and margin. Refuses anyone who is not an Admin. Returns are
   negative rows so that a group total is one sum.';


-- -----------------------------------------------------------------------------
-- 6. Cost comes off Product sales
-- -----------------------------------------------------------------------------
-- It had an indicative margin visible to Accounts, worked out at the product's
-- current purchase price. There is now one answer to "what did this earn" and
-- it is Admin only, so the old one goes rather than sitting beside it
-- disagreeing. Dropped and recreated because the two columns are being
-- removed, which `create or replace view` cannot do.
--
-- Rebuilt from 024's definition, not 015's — 024 added the master group, and
-- rebuilding from the older file would silently lose it. Bug #23.

drop view if exists public.v_product_sales;

create view public.v_product_sales as
select
  pr.id            as product_id,
  pr.code          as product_code,
  pr.name          as product_name,
  pg.name          as group_name,
  mg.code          as master_code,
  mg.name          as master_name,
  pr.base_uom,
  si.invoice_date,
  sum(sil.qty_base - sil.qty_cancelled_base)     as qty_sold_base,
  sum(sil.effective_amount
      - round(sil.effective_amount * sil.qty_cancelled_base
              / nullif(sil.qty_base, 0), 2))     as net_sales
from public.sales_invoice_line sil
join public.sales_invoice si on si.id = sil.invoice_id
join public.product pr       on pr.id = sil.product_id
join public.product_group pg on pg.id = pr.group_id
join public.master_group mg  on mg.id = pg.master_group_id
where si.status <> 'CANCELLED'
group by pr.id, pr.code, pr.name, pg.name, mg.code, mg.name,
         pr.base_uom, si.invoice_date;

alter view public.v_product_sales set (security_invoker = true);

notify pgrst, 'reload schema';
