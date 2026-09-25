-- =============================================================================
-- 027_purchases_and_daybook.sql
-- Purchases get a way back out, a master group, and a screen worth of views.
-- The day book gets built.
--
-- Purchases could always be posted — post_purchase has been there since 013 —
-- but there was no way to take one back, so a mistyped purchase was permanent
-- stock. cancel_purchase reverses it, and refuses if the goods have already
-- been sold, because pretending they came back would make stock lie.
--
-- Purchases also join everything else in carrying a master group, so "what did
-- we buy from Parle this month" is the same question as "what did we sell".
--
-- The day book is one page for one day: every document raised, with the three
-- totals that matter — what was sold, what was bought, what came in as cash.
-- It is built as views so the screen, the Excel export and the printout all
-- read from one definition.
--
-- Run this file once in the Supabase SQL Editor. Safe to run more than once.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Purchases carry a master group, like every other document
-- -----------------------------------------------------------------------------

alter table public.purchase
  add column if not exists master_group_id uuid references public.master_group (id);

create index if not exists purchase_master_idx on public.purchase (master_group_id);

update public.purchase pu
   set master_group_id = x.mg
  from (select pl.purchase_id, min(pg.master_group_id::text)::uuid as mg
          from public.purchase_line pl
          join public.product pr       on pr.id = pl.product_id
          join public.product_group pg on pg.id = pr.group_id
         group by pl.purchase_id) x
 where pu.id = x.purchase_id and pu.master_group_id is null;

drop trigger if exists purchase_line_master on public.purchase_line;
create trigger purchase_line_master
  after insert on public.purchase_line
  for each row execute function app.enforce_one_master_group('purchase', 'purchase_id', 'purchase');


-- -----------------------------------------------------------------------------
-- 2. Taking a purchase back
--
-- The goods go out again on today's date, not the purchase date: the ledger
-- records when something happened, and this is happening now.
--
-- It is refused when the stock is no longer there. The CHECK on product_stock
-- would catch it anyway, but as a constraint violation naming a column — this
-- names the products and the shortfall, which is what somebody needs in order
-- to work out what to do instead.
-- -----------------------------------------------------------------------------

create or replace function public.cancel_purchase(
  p_purchase_id uuid,
  p_reason      text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user  uuid := app.require_back_office();
  v_pur   public.purchase%rowtype;
  v_short jsonb;
begin
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'A cancellation needs a reason' using errcode = 'SA004';
  end if;

  select * into v_pur from public.purchase where id = p_purchase_id for update;

  if not found then
    raise exception 'That purchase does not exist' using errcode = 'SA005';
  end if;

  if v_pur.status <> 'ACTIVE' then
    raise exception '% is already cancelled', v_pur.doc_no using errcode = 'SA002';
  end if;

  -- Locked in product order, the same order every other stock operation uses,
  -- so two of them running at once queue instead of deadlocking.
  perform 1
     from public.product_stock ps
    where ps.product_id in (select distinct pl.product_id
                              from public.purchase_line pl
                             where pl.purchase_id = p_purchase_id)
    order by ps.product_id
      for update;

  select coalesce(jsonb_agg(jsonb_build_object(
           'product', pr.name, 'taking_back', x.qty, 'in_stock', ps.on_hand)), '[]'::jsonb)
    into v_short
    from (select pl.product_id, sum(pl.qty_base) as qty
            from public.purchase_line pl
           where pl.purchase_id = p_purchase_id
           group by pl.product_id) x
    join public.product_stock ps on ps.product_id = x.product_id
    join public.product pr       on pr.id = x.product_id
   where ps.on_hand < x.qty;

  if jsonb_array_length(v_short) > 0 then
    raise exception
      'Some of what this purchase brought in has already gone out, so it cannot be cancelled.'
      using errcode = 'SA001', detail = v_short::text;
  end if;

  insert into public.stock_ledger
    (product_id, movement_date, qty_out, rate, doc_type, doc_id, doc_line_id, created_by)
  select pl.product_id, current_date, pl.qty_base,
         case when pl.qty_base > 0 then round(pl.amount / pl.qty_base, 4) else 0 end,
         'PURCHASE_CANCEL', v_pur.id, pl.id, v_user
    from public.purchase_line pl
   where pl.purchase_id = p_purchase_id;

  update public.purchase
     set status        = 'CANCELLED',
         cancelled_at  = now(),
         cancelled_by  = v_user,
         cancel_reason = btrim(p_reason)
   where id = p_purchase_id;

  return jsonb_build_object(
    'purchase_id', p_purchase_id, 'doc_no', v_pur.doc_no, 'net_total', v_pur.net_total);
end;
$$;

revoke all on function public.cancel_purchase(uuid, text) from public, anon;
grant execute on function public.cancel_purchase(uuid, text) to authenticated;

comment on function public.cancel_purchase(uuid, text) is
  'Reverses a purchase: the goods go back out of stock on today''s date and the
   document is marked cancelled. Refused if the stock is no longer there.';


-- -----------------------------------------------------------------------------
-- 3. What the Purchases screen reads
-- -----------------------------------------------------------------------------

drop view if exists public.v_purchase_list;

create view public.v_purchase_list as
select
  pu.id            as purchase_id,
  pu.doc_no,
  pu.purchase_date,
  pu.supplier_id,
  s.code           as supplier_code,
  s.name           as supplier_name,
  pu.supplier_bill_no,
  pu.supplier_bill_date,
  pu.master_group_id,
  mg.code          as master_code,
  mg.name          as master_name,
  pu.gross_total,
  pu.other_charges,
  pu.net_total,
  pu.status,
  pu.cancel_reason,
  pu.remarks,
  u.full_name      as created_by_name,
  pu.created_at,
  coalesce(l.lines, 0) as line_count,
  coalesce(l.qty_base, 0) as qty_base
from public.purchase pu
join public.supplier s on s.id = pu.supplier_id
left join public.master_group mg on mg.id = pu.master_group_id
left join public.app_user u on u.id = pu.created_by
left join (
  select purchase_id, count(*) as lines, sum(qty_base) as qty_base
    from public.purchase_line
   group by purchase_id
) l on l.purchase_id = pu.id;


-- =============================================================================
-- 4. The day book
--
-- One row per document, whatever kind. A day of trading reads down the page in
-- the order it happened, and the three figures anybody actually asks for —
-- sold, bought, collected — come off the summary beside it.
--
-- Money in and money out are not netted against each other. A day with a
-- 50,000 bill and a 50,000 purchase is not a quiet day, and a single "total"
-- would say it was.
-- =============================================================================

-- v_day_summary is built on this one, so it goes first.
drop view if exists public.v_day_summary;
drop view if exists public.v_day_book;

create view public.v_day_book as

-- Sold. Opening documents are excluded: they are balances carried in, dated
-- before the app existed, and counting them as a day's sales would be wrong.
select
  si.invoice_date                as entry_date,
  1                              as sort_key,
  'BILL'::text                   as doc_type,
  si.doc_no,
  si.id                          as doc_id,
  p.name                         as who,
  p.code                         as who_code,
  rt.name                        as route_name,
  si.master_group_id,
  mg.code                        as master_code,
  mg.name                        as master_name,
  si.net_total                   as amount,
  si.status::text                as status,
  u.full_name                    as entered_by,
  si.created_at
from public.sales_invoice si
join public.party p   on p.id  = si.party_id
join public.route rt  on rt.id = p.route_id
left join public.master_group mg on mg.id = si.master_group_id
left join public.app_user u on u.id = si.created_by
where not si.is_opening

union all

-- Collected.
select
  r.receipt_date, 2, 'PAYMENT', r.doc_no, r.id,
  p.name, p.code, rt.name,
  null::uuid, null::text, null::text,
  r.amount, r.status::text,
  coalesce(c.full_name, u.full_name), r.created_at
from public.receipt r
join public.party p  on p.id  = r.party_id
join public.route rt on rt.id = p.route_id
left join public.app_user c on c.id = r.collected_by
left join public.app_user u on u.id = r.created_by

union all

-- Bought.
select
  pu.purchase_date, 3, 'PURCHASE', pu.doc_no, pu.id,
  s.name, s.code, null::text,
  pu.master_group_id, mg.code, mg.name,
  pu.net_total, pu.status::text,
  u.full_name, pu.created_at
from public.purchase pu
join public.supplier s on s.id = pu.supplier_id
left join public.master_group mg on mg.id = pu.master_group_id
left join public.app_user u on u.id = pu.created_by

union all

-- Taken by the reps.
select
  so.order_date, 4, 'ORDER', so.doc_no, so.id,
  p.name, p.code, rt.name,
  so.master_group_id, mg.code, mg.name,
  coalesce(os.order_value, 0), so.status::text,
  u.full_name, so.created_at
from public.sales_order so
join public.party p   on p.id  = so.party_id
join public.route rt  on rt.id = p.route_id
left join public.master_group mg on mg.id = so.master_group_id
left join public.v_sales_order_summary os on os.order_id = so.id
left join public.app_user u on u.id = so.created_by

union all

-- Come back.
select
  sr.return_date, 5, 'RETURN', sr.doc_no, sr.id,
  p.name, p.code, rt.name,
  sr.master_group_id, mg.code, mg.name,
  sr.total_value, sr.status::text,
  u.full_name, sr.created_at
from public.sales_return sr
join public.party p   on p.id  = sr.party_id
join public.route rt  on rt.id = p.route_id
left join public.master_group mg on mg.id = sr.master_group_id
left join public.app_user u on u.id = sr.created_by

union all

-- Undone.
select
  ic.cancellation_date, 6, 'CANCELLATION', ic.doc_no, ic.id,
  p.name, p.code, rt.name,
  si.master_group_id, mg.code, mg.name,
  ic.cancelled_value, 'ACTIVE',
  u.full_name, ic.created_at
from public.invoice_cancellation ic
join public.sales_invoice si on si.id = ic.invoice_id
join public.party p   on p.id  = si.party_id
join public.route rt  on rt.id = p.route_id
left join public.master_group mg on mg.id = si.master_group_id
left join public.app_user u on u.id = ic.created_by;


-- -----------------------------------------------------------------------------
-- The day's figures
--
-- Cancelled documents count as zero rather than being left out, so the counts
-- still say how many were raised. A day where three bills were raised and one
-- was corrected is a day with three bills on the page.
-- -----------------------------------------------------------------------------

create view public.v_day_summary as
select
  entry_date,
  sum(amount) filter (where doc_type = 'BILL'     and status <> 'CANCELLED') as sales,
  sum(amount) filter (where doc_type = 'PURCHASE' and status <> 'CANCELLED') as purchases,
  sum(amount) filter (where doc_type = 'PAYMENT'  and status <> 'CANCELLED') as receipts,
  sum(amount) filter (where doc_type = 'RETURN'   and status <> 'CANCELLED') as returns,
  sum(amount) filter (where doc_type = 'CANCELLATION')                       as cancelled,
  sum(amount) filter (where doc_type = 'ORDER'    and status <> 'CANCELLED') as orders,
  count(*) filter (where doc_type = 'BILL')     as bill_count,
  count(*) filter (where doc_type = 'PURCHASE')  as purchase_count,
  count(*) filter (where doc_type = 'PAYMENT')   as payment_count,
  count(*) filter (where doc_type = 'ORDER')     as order_count,
  count(*)                                       as entry_count
from public.v_day_book
group by entry_date;


-- -----------------------------------------------------------------------------
-- Security and grants
-- -----------------------------------------------------------------------------

do $$
declare v text;
begin
  foreach v in array array[
    'v_purchase_list', 'v_day_book', 'v_day_summary'
  ] loop
    execute format('alter view public.%I set (security_invoker = true)', v);
    execute format('grant select on public.%I to authenticated', v);
  end loop;
end;
$$;
