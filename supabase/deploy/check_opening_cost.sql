-- =============================================================================
-- check_opening_cost.sql
--
-- Run the WHOLE file in the Supabase SQL Editor. It changes nothing.
--
-- WHY THIS EXISTS. The Parle margin read 2.9% against an expected 6%, and
-- Parle G — three quarters of the Parle turnover — read 2.0% against an
-- expected 4%. Nothing about the report was wrong. The cost was.
--
-- Parle G's ledger says it plainly:
--
--     20 Sep   Opening    3,684 DZN at 98.31      <- entered at go-live
--     29 Sep   Purchase   4,224 DZN at 93.39
--     16 Oct   Purchase   1,680 DZN at 93.39
--
-- Every real purchase is 93.39. The opening stock went in at 98.31, which is
-- ABOVE the 97.08 it sells for — so every dozen of that opening stock reports
-- a loss, and drags the blended average to 95.13 while it sells through. That
-- is 4.92 a dozen too dear across 3,684 dozen: about 18,000 rupees of cost
-- that was never actually spent.
--
-- This lists every product where the same thing is true, worst first, so the
-- size of it across the business is one query rather than one product at a
-- time.
--
-- HOW TO READ IT.
--
--   opening_rate        what the go-live sheet said each base unit cost
--   bought_at           the weighted average of what has ACTUALLY been paid
--                       since, from real purchases
--   over_per_unit       how much dearer the opening cost is. Positive means
--                       the opening stock is overstating cost and hiding
--                       margin; negative means the opposite
--   phantom_cost        over_per_unit x the opening quantity — the money the
--                       report thinks was spent and was not
--   sells_for           the current selling rate per base unit. **An
--                       opening_rate at or above this is the giveaway**: no
--                       one buys at more than they sell for
--   still_on_hand       how much stock is left; the drag lasts until the
--                       opening quantity has washed through
--
-- Products never purchased since go-live have no `bought_at` to compare
-- against, so they are listed separately at the end with a null — their
-- opening cost is all the cost there is, and nothing here can tell you whether
-- it is right.
--
-- NOTHING IS FIXED BY RUNNING THIS. Opening stock is posted once and the stock
-- ledger is append-only, so an opening cost cannot simply be edited. Send me
-- what this returns and we will work out the repair — it is a short, careful
-- job, and it is worth doing properly because every margin figure in the
-- business leans on it.
--
-- One SELECT on purpose: the SQL Editor only shows the last statement.
-- =============================================================================

with bought as (
  -- What has actually been paid since go-live, weighted by quantity. Cancelled
  -- purchases are left out, the same way the profitability report leaves them
  -- out (043).
  select
    sl.product_id,
    sum(sl.qty_in * sl.rate) / nullif(sum(sl.qty_in), 0) as rate,
    sum(sl.qty_in)                                       as qty,
    count(*)                                             as purchases
  from public.stock_ledger sl
  join public.purchase p on p.id = sl.doc_id
  where sl.doc_type = 'PURCHASE'
    and p.status <> 'CANCELLED'
    and sl.qty_in > 0
  group by sl.product_id
),
sold as (
  select sil.product_id,
         sum(sil.qty_base - sil.qty_cancelled_base) as qty_sold
    from public.sales_invoice_line sil
    join public.sales_invoice si on si.id = sil.invoice_id
   where si.status <> 'CANCELLED' and not si.is_opening
   group by sil.product_id
)
select
  pr.code                                   as product_code,
  pr.name                                   as product_name,
  pg.name                                   as group_name,
  mg.name                                   as master_name,
  pr.base_uom,
  pr.opening_qty,
  round(pr.opening_rate, 4)                 as opening_rate,
  round(b.rate, 4)                          as bought_at,
  round(pr.opening_rate - b.rate, 4)        as over_per_unit,
  round((pr.opening_rate - b.rate) * pr.opening_qty, 2) as phantom_cost,
  round(pr.sale_rate, 4)                    as sells_for,
  -- The sanity check that needs no opinion about buying prices at all.
  case when pr.opening_rate >= pr.sale_rate and pr.sale_rate > 0
       then 'opening cost is at or above the selling price'
       else '' end                          as note,
  coalesce(ps.on_hand, 0)                   as still_on_hand,
  coalesce(s.qty_sold, 0)                   as sold_since,
  b.purchases                               as purchases_since
from public.product pr
join public.product_group pg on pg.id = pr.group_id
join public.master_group mg  on mg.id = pg.master_group_id
left join bought b           on b.product_id = pr.id
left join sold s             on s.product_id = pr.id
left join public.product_stock ps on ps.product_id = pr.id
where pr.opening_qty > 0
  and (
    -- Opening cost is dearer than what has actually been paid, by enough to
    -- matter on the quantity involved.
    (b.rate is not null and abs(pr.opening_rate - b.rate) * pr.opening_qty >= 500)
    -- Or it is at or above the selling price, which is wrong at any size.
    or (pr.sale_rate > 0 and pr.opening_rate >= pr.sale_rate)
    -- Or nothing has been bought since, so it has never been checked at all.
    or b.rate is null
  )
order by
  (b.rate is null),                                   -- the comparable ones first
  round((pr.opening_rate - coalesce(b.rate, pr.opening_rate)) * pr.opening_qty, 2) desc,
  pr.code;
