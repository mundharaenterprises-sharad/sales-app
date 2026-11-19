-- =============================================================================
-- 050_stock_as_on_and_doc_no.sql
-- The document number on every stock movement, and stock as on a past date.
--
-- Run this in the Supabase SQL Editor. Committing it to git does nothing to
-- the database.
--
-- TWO THINGS HE ASKED FOR, 18 November:
--
--   "Stock ledgers should also show bill no. against the qty."
--   "Allow me to see stock summary as on date as well."
--
-- -----------------------------------------------------------------------------
-- 1. THE DOCUMENT NUMBER ON THE STOCK LEDGER
-- -----------------------------------------------------------------------------
-- `v_stock_ledger` carried `doc_type` and `doc_id` but no number, so the screen
-- could say a movement was a SALE and link to it, and still not tell you WHICH
-- bill without opening it. Eight movement types, each with its number in a
-- different table, so the view resolves them with one left join each.
--
-- **A cancellation needs two numbers, not one.** `doc_id` on a SALE_CANCEL row
-- is the cancellation document, not the bill — that is why 043 had to tie
-- cancelled sales back through `doc_line_id` instead. So the number of the
-- document itself goes in `doc_no`, and `ref_doc_no` carries the bill it
-- cancelled, which is the thing anybody reading the ledger actually wants to
-- see. For every other type `ref_doc_no` is null.
--
-- Columns are APPENDED, never inserted, because `create or replace view`
-- cannot move a column and the app selects by name anyway (bug #9). Rebuilt in
-- full from 047, its latest definition, including the OPENING rate that reads
-- `product.opening_rate` so the screen and the costing agree (bug #23).
--
-- -----------------------------------------------------------------------------
-- 2. STOCK AS ON A DATE
-- -----------------------------------------------------------------------------
-- `public.stock_as_on(date)` — one row per product: how much was on the shelf
-- at the end of that day, and what it was worth.
--
-- **The quantity comes from the raw ledger, including documents later
-- cancelled.** That is deliberate and it is the opposite of what the costing
-- does. If a bill went out on 1 October and was cancelled on 5 November, then
-- on 10 October those goods were genuinely gone, and a stock figure for
-- 10 October that pretends otherwise cannot be reconciled against anything
-- anybody counted. The test that pins this down is the one that matters:
-- **`stock_as_on(today)` equals `product_stock.on_hand` for every product**,
-- which is only true if nothing is left out.
--
-- **The value uses the weighted average cost in force on that date** — the
-- same `app.v_cost_events` walk the Profitability report uses (043), which
-- does leave cancelled documents out, for the date-ordering reason in bug #30.
-- Each basis is right for its own question: quantity is a fact about what was
-- on the shelf, cost is an average over what was actually paid.
--
-- So the two differ only where a document was cancelled later, and only in the
-- window before the cancellation. That is a real property, not an oversight,
-- and it is written down here so nobody "fixes" one to match the other.
--
-- **The value is Admin only, the quantity is not.** Cost is the one figure
-- Accounts may not read, which is why Profitability is Admin only and why the
-- indicative margin was taken off Product sales. So the two cost columns come
-- back NULL for anyone who is not an Admin, rather than the whole report being
-- refused — the office has every reason to look at quantities on a date, and
-- none to see what the stock cost.
--
-- Safe to run twice.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. The document number
-- -----------------------------------------------------------------------------

create or replace view public.v_stock_ledger as
select
  sl.id,
  sl.product_id,
  pr.code                     as product_code,
  pr.name                     as product_name,
  pr.base_uom,
  pg.name                     as group_name,
  mg.code                     as master_code,
  mg.name                     as master_name,
  sl.movement_date,
  sl.doc_type,
  sl.doc_id,
  sl.qty_in,
  sl.qty_out,
  case when sl.doc_type = 'OPENING' then pr.opening_rate else sl.rate end as rate,
  sl.notes,
  u.full_name                 as entered_by,
  sl.created_at,
  sum(sl.qty_in - sl.qty_out) over (
    partition by sl.product_id
    order by sl.movement_date, sl.created_at, sl.id
    rows between unbounded preceding and current row
  )                           as balance_after,

  -- Appended from here. The number of the document this movement belongs to.
  case sl.doc_type
    when 'SALE'               then si.doc_no
    when 'SALE_CANCEL'        then ic.doc_no
    when 'SALE_RETURN'        then sr.doc_no
    when 'SALE_RETURN_CANCEL' then sr.doc_no
    when 'PURCHASE'           then pu.doc_no
    when 'PURCHASE_CANCEL'    then pu.doc_no
    when 'ADJUSTMENT'         then sa.doc_no
    else null
  end                         as doc_no,

  -- The bill a cancellation undid, because the cancellation's own number says
  -- nothing about which sale came back.
  case when sl.doc_type = 'SALE_CANCEL' then cbill.doc_no else null end
                              as ref_doc_no,
  case when sl.doc_type = 'SALE_CANCEL' then cbill.id     else null end
                              as ref_id
from public.stock_ledger sl
join public.product pr        on pr.id = sl.product_id
join public.product_group pg  on pg.id = pr.group_id
left join public.master_group mg on mg.id = pg.master_group_id
left join public.app_user u   on u.id = sl.created_by
left join public.sales_invoice si
       on sl.doc_type = 'SALE' and si.id = sl.doc_id
left join public.invoice_cancellation ic
       on sl.doc_type = 'SALE_CANCEL' and ic.id = sl.doc_id
left join public.sales_invoice cbill
       on sl.doc_type = 'SALE_CANCEL' and cbill.id = ic.invoice_id
left join public.sales_return sr
       on sl.doc_type in ('SALE_RETURN', 'SALE_RETURN_CANCEL') and sr.id = sl.doc_id
left join public.purchase pu
       on sl.doc_type in ('PURCHASE', 'PURCHASE_CANCEL') and pu.id = sl.doc_id
left join public.stock_adjustment sa
       on sl.doc_type = 'ADJUSTMENT' and sa.id = sl.doc_id;

alter view public.v_stock_ledger set (security_invoker = true);
grant select on public.v_stock_ledger to authenticated;

comment on view public.v_stock_ledger is
  'Every stock movement with a running balance. doc_no is the movement''s own
   document; ref_doc_no is the bill a SALE_CANCEL undid, which doc_id does not
   point at. The OPENING rate is read from product.opening_rate so the screen
   agrees with the costing (047).';


-- -----------------------------------------------------------------------------
-- 2. Stock as on a date
-- -----------------------------------------------------------------------------

create or replace function public.stock_as_on(
  p_as_on date default current_date
)
returns table (
  product_id    uuid,
  product_code  text,
  product_name  text,
  group_name    text,
  master_code   text,
  master_name   text,
  base_uom      text,
  pack_uom      text,
  pack_size     numeric,
  is_active     boolean,
  qty_base      numeric,
  unit_cost     numeric,
  stock_value   numeric
)
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
declare
  v_admin boolean;
begin
  perform app.require_signed_in();
  v_admin := app.is_admin();

  if p_as_on > current_date then
    raise exception 'There is no stock figure for a date in the future'
      using errcode = 'SA004';
  end if;

  return query
  with
  -- What was on the shelf. The raw ledger, so a document cancelled after this
  -- date still counts on this date — see the header.
  held as (
    select sl.product_id,
           sum(sl.qty_in - sl.qty_out) as qty
      from public.stock_ledger sl
     where sl.movement_date <= p_as_on
     group by sl.product_id
  ),
  -- The cost event in force on that date. event_no 0 means the product had no
  -- costed receipt yet, and joins to nothing, which is correct: there is no
  -- cost to value it at.
  evt as (
    select m.product_id, max(m.event_no) as event_no
      from app.v_ledger_marked m
     where m.movement_date <= p_as_on
     group by m.product_id
  ),
  cost as (
    select e.product_id, c.unit_cost
      from evt e
      join app.v_cost_events c
        on c.product_id = e.product_id
       and c.event_no   = e.event_no
  )
  select
    pr.id,
    pr.code,
    pr.name,
    pg.name,
    mg.code,
    mg.name,
    pr.base_uom,
    pr.pack_uom,
    pr.pack_size::numeric,
    pr.is_active,
    coalesce(h.qty, 0)::numeric,
    case when v_admin then round(coalesce(c.unit_cost, 0), 4) else null end,
    case when v_admin
         then round(coalesce(h.qty, 0) * coalesce(c.unit_cost, 0), 2)
         else null end
  from public.product pr
  join public.product_group pg on pg.id = pr.group_id
  left join public.master_group mg on mg.id = pg.master_group_id
  left join held h on h.product_id = pr.id
  left join cost c on c.product_id = pr.id
  order by pr.name;
end;
$$;

revoke all on function public.stock_as_on(date) from public, anon;
grant execute on function public.stock_as_on(date) to authenticated;

comment on function public.stock_as_on(date) is
  'Quantity on hand per product at the end of a given day, with its value at
   the weighted average cost in force then. The quantity comes from the raw
   ledger and so includes documents cancelled after that date; the value comes
   from the same walk Profitability uses, which excludes them. unit_cost and
   stock_value are NULL for anyone who is not an Admin.';

notify pgrst, 'reload schema';
