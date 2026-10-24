-- =============================================================================
-- check_cost_basis.sql
--
-- Run the WHOLE file in the Supabase SQL Editor. It changes nothing.
-- Run it ONCE, before trusting the Profitability report.
--
-- The report values every sale at the average of what was actually paid, which
-- it works out from the stock ledger. That is only as good as the costs in the
-- ledger, and there is one way they can be wrong that is easy to miss:
--
--   **opening stock with no cost against it.** `opening_rate` was an optional
--   column on the import sheet and it defaults to zero. A product whose
--   opening stock went in at zero looks like it cost nothing, so everything
--   sold out of that opening stock shows as pure profit — and it keeps
--   dragging the average down until the opening quantity has been sold
--   through.
--
-- Each row this returns is a product worth looking at. `issue` says which kind:
--
--   no cost on opening stock   opening_qty > 0 but opening_rate = 0
--   never costed               nothing has ever come in with a cost, so every
--                              sale of it is valued at 0
--   bought much cheaper/dearer the current average is a long way from the
--                              product master's purchase price, which is
--                              usually either a genuine price move or an
--                              opening cost that was a guess
--
-- No rows means the cost basis is sound and the report can be read as it
-- stands.
--
-- Nothing here can be fixed by editing opening stock — it is posted and
-- `post_opening_stock` cannot be run twice. If a product's opening cost is
-- wrong, the honest options are to read its margin only from the date of its
-- first real purchase, or to post a stock adjustment; send me the list and we
-- will work out which.
--
-- One SELECT on purpose — the SQL Editor only shows the last statement's
-- result.
-- =============================================================================

with latest as (
  select ce.product_id, ce.unit_cost, ce.event_no
    from app.v_cost_events ce
    join (
      select product_id, max(event_no) as event_no
        from app.v_cost_events group by product_id
    ) m on m.product_id = ce.product_id and m.event_no = ce.event_no
),
costed_in as (
  select product_id, count(*) as receipts
    from public.stock_ledger
   where doc_type in ('OPENING', 'PURCHASE')
     and rate > 0
   group by product_id
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
  case
    when pr.opening_qty > 0 and pr.opening_rate = 0 then 'no cost on opening stock'
    when coalesce(ci.receipts, 0) = 0               then 'never costed'
    else 'bought much cheaper/dearer'
  end                                   as issue,
  pr.code                               as product_code,
  pr.name                               as product_name,
  pg.name                               as group_name,
  pr.opening_qty,
  pr.opening_rate,
  pr.purchase_rate                      as master_cost_per_unit,
  round(l.unit_cost, 4)                 as average_cost_now,
  coalesce(s.qty_sold, 0)               as qty_sold_so_far
from public.product pr
join public.product_group pg on pg.id = pr.group_id
left join latest l     on l.product_id = pr.id
left join costed_in ci on ci.product_id = pr.id
left join sold s       on s.product_id = pr.id
where
  -- Opening stock entered with no cost.
  (pr.opening_qty > 0 and pr.opening_rate = 0)
  -- Or nothing costed has ever come in, so every sale is valued at nothing.
  or coalesce(ci.receipts, 0) = 0
  -- Or the average is more than a quarter away from the master's own figure,
  -- which is worth a look either way round.
  or (l.unit_cost is not null
      and pr.purchase_rate > 0
      and abs(l.unit_cost - pr.purchase_rate) / pr.purchase_rate > 0.25)
order by 1, coalesce(s.qty_sold, 0) desc, pr.code;
