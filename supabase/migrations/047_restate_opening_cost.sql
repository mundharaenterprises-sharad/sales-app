-- =============================================================================
-- 047_restate_opening_cost.sql
-- Correcting what opening stock cost, after it has been posted.
--
-- Run this in the Supabase SQL Editor. Committing it to git does nothing to
-- the database.
--
-- WHY. The go-live sheet's opening costs were worked out from selling prices
-- rather than taken from supplier invoices — across 53 Parle products the
-- opening cost sits at 90.5% to 92.0% of the list price, which is a formula,
-- not a set of invoices. Three of them could be checked against real purchases
-- and all three were too dear; one, Happy Happy 135gm, was entered at 113% of
-- its own selling price, which cannot be a cost at all.
--
-- Until that is corrected, every margin the business reads is understated, and
-- it does not wash out quickly: half of the Parle G opening stock is still on
-- the shelf, and several lines have not moved at all.
--
-- TWO GUARDS ARE DELIBERATELY IN THE WAY, AND BOTH STAY.
--
--   `app.product_guard` (019) refuses any change to opening_qty, opening_rate
--   or opening_date once the opening stock has been posted. Right: opening
--   figures are a go-live device and casually editing them would move stock
--   that has already been sold.
--
--   `stock_ledger` is append-only (`stock_ledger_no_update`, 004). Also right:
--   it is the record of what happened, and nothing that happened should be
--   rewritten later.
--
-- So this does not fight either of them. **The costing stops reading the
-- frozen rate on the OPENING ledger row and reads `product.opening_rate`
-- instead**, and that one column is made correctable through a narrow,
-- Admin-only door. The ledger is untouched and still append-only; the opening
-- QUANTITY and DATE stay locked, because those really would move stock; and
-- the change is recorded by the audit trigger that already watches `product`,
-- so who changed it, when, and from what are all answerable afterwards.
--
-- Restating a cost recomputes every margin that leans on it, back to go-live.
-- That is the point, and it is why it is Admin only.
--
-- WHAT IT DOES NOT TOUCH. `product.purchase_rate` is what the goods cost to
-- buy TODAY and is used to price a new purchase line; it has nothing to do
-- with what the opening stock cost, and is left alone. Stock quantities are
-- not affected at all — no ledger row is written, because nothing moved.
--
-- Safe to run twice. Nothing is restated by running it; it only opens the door.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. The door: a transaction-local flag the guard honours
-- -----------------------------------------------------------------------------
-- Narrow on purpose. The flag is set by the function below, lasts only for that
-- transaction, and even then the guard permits a change to the RATE alone —
-- quantity and date are still refused, because those are the two that would
-- move stock that has since been sold.

create or replace function app.product_guard()
returns trigger
language plpgsql
as $$
declare
  v_restating boolean := coalesce(
    current_setting('app.restating_opening_cost', true) = 'on', false);
begin
  if new.code is distinct from old.code then
    raise exception 'A product code cannot be changed (% stays %).', old.name, old.code
      using errcode = 'SA004';
  end if;

  -- The quantity and the date stay locked whatever else is going on: they
  -- decide how much stock exists and from when, and that has been sold against.
  if (new.opening_qty is distinct from old.opening_qty
      or new.opening_date is distinct from old.opening_date)
     and public.product_opening_posted(old.id) then
    raise exception 'The opening stock of % has already been posted and cannot be changed here.',
      old.name using errcode = 'SA002';
  end if;

  -- The rate is the one figure that can be restated, and only through
  -- public.restate_opening_cost().
  if new.opening_rate is distinct from old.opening_rate
     and public.product_opening_posted(old.id)
     and not v_restating then
    raise exception
      'The opening cost of % has been posted. Use Restate opening cost, which records who changed it and why.',
      old.name using errcode = 'SA002';
  end if;

  return new;
end;
$$;


-- -----------------------------------------------------------------------------
-- 2. The costing reads the product, not the frozen ledger row
-- -----------------------------------------------------------------------------
-- The OPENING row in `stock_ledger` keeps the rate it was posted with, because
-- that is what happened. What the cost of goods is worked out from is the
-- product's own opening cost, which is now correctable. For every other
-- movement the ledger row is still the authority — a purchase's cost belongs
-- to that purchase.
--
-- Rebuilt in full from 043, including the exclusion of cancelled documents
-- that 043 added after 044 exposed it. Bug #23.

create or replace view app.v_ledger_marked as
select
  sl.id,
  sl.product_id,
  sl.movement_date,
  sl.created_at,
  sl.qty_in,
  sl.qty_out,
  -- The one line this migration is about.
  case when sl.doc_type = 'OPENING' then pr.opening_rate else sl.rate end as rate,
  sl.doc_type,
  sl.doc_id,
  sl.doc_line_id,
  (sl.doc_type in ('OPENING', 'PURCHASE'))            as sets_cost,
  sum(case when sl.doc_type in ('OPENING', 'PURCHASE') then 1 else 0 end)
    over (partition by sl.product_id
          order by sl.movement_date, sl.created_at, sl.id
          rows between unbounded preceding and current row) as event_no
from public.stock_ledger sl
join public.product pr on pr.id = sl.product_id
where
  not (sl.doc_type in ('PURCHASE', 'PURCHASE_CANCEL')
       and exists (select 1 from public.purchase p
                    where p.id = sl.doc_id and p.status = 'CANCELLED'))
  and not (sl.doc_type in ('SALE', 'SALE_CANCEL')
           and exists (select 1 from public.sales_invoice_line sil
                         join public.sales_invoice si on si.id = sil.invoice_id
                        where sil.id = sl.doc_line_id
                          and si.status = 'CANCELLED'))
  and not (sl.doc_type in ('SALE_RETURN', 'SALE_RETURN_CANCEL')
           and exists (select 1 from public.sales_return sr
                        where sr.id = sl.doc_id and sr.status = 'CANCELLED'));


-- -----------------------------------------------------------------------------
-- 3. The stock ledger screen shows the same figure
-- -----------------------------------------------------------------------------
-- Otherwise the screen he reads the history on would say 98.31 while every
-- margin was worked out from the restated figure, and the two would quietly
-- disagree — which is exactly the kind of thing that costs an afternoon.
-- Rebuilt from 035, its latest definition.

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
  )                           as balance_after
from public.stock_ledger sl
join public.product pr        on pr.id = sl.product_id
join public.product_group pg  on pg.id = pr.group_id
left join public.master_group mg on mg.id = pg.master_group_id
left join public.app_user u   on u.id = sl.created_by;

alter view public.v_stock_ledger set (security_invoker = true);


-- -----------------------------------------------------------------------------
-- 4. Restating one
-- -----------------------------------------------------------------------------

create or replace function public.restate_opening_cost(
  p_product_id uuid,
  p_rate       numeric,
  p_reason     text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user uuid := app.require_admin();
  v_pr   public.product%rowtype;
  v_old  numeric;
begin
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'Say why the opening cost is being restated — it goes on the record'
      using errcode = 'SA004';
  end if;

  select * into v_pr from public.product where id = p_product_id for update;

  if not found then
    raise exception 'Unknown product' using errcode = 'SA005';
  end if;

  if v_pr.opening_qty <= 0 then
    raise exception '% has no opening stock, so it has no opening cost to restate',
      v_pr.name using errcode = 'SA004';
  end if;

  if p_rate is null or p_rate < 0 then
    raise exception 'An opening cost cannot be negative' using errcode = 'SA004';
  end if;

  -- Not a hard rule — a loss-leader is a real thing — but costing stock above
  -- what it sells for is how this was spotted in the first place, so it is
  -- worth refusing by accident and allowing on purpose.
  if v_pr.sale_rate > 0 and p_rate >= v_pr.sale_rate
     and p_reason not ilike '%sold at a loss%' then
    raise exception
      'That cost (%) is at or above the selling price (%). If it is really right, say "sold at a loss" in the reason.',
      round(p_rate, 4), round(v_pr.sale_rate, 4)
      using errcode = 'SA004';
  end if;

  v_old := v_pr.opening_rate;

  -- Transaction-local, so it cannot leak into anything else this session does.
  perform set_config('app.restating_opening_cost', 'on', true);
  update public.product
     set opening_rate = round(p_rate, 4)
   where id = p_product_id;
  perform set_config('app.restating_opening_cost', 'off', true);

  -- The audit row is written by the product_audit trigger, which has watched
  -- this table since 011 — old value, new value, who and when, for free.

  return jsonb_build_object(
    'product_id',   p_product_id,
    'product_code', v_pr.code,
    'product_name', v_pr.name,
    'was',          round(v_old, 4),
    'now',          round(p_rate, 4),
    'opening_qty',  v_pr.opening_qty,
    'cost_removed', round((v_old - p_rate) * v_pr.opening_qty, 2));
end;
$$;

revoke all on function public.restate_opening_cost(uuid, numeric, text) from public, anon;
grant execute on function public.restate_opening_cost(uuid, numeric, text) to authenticated;

comment on function public.restate_opening_cost(uuid, numeric, text) is
  'Corrects what opening stock cost, for Admin only. Moves no stock and writes
   no ledger row — nothing happened, a figure was wrong. Recomputes every
   margin that leans on it, back to go-live. The opening quantity and date stay
   locked.';

notify pgrst, 'reload schema';
