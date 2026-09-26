-- =============================================================================
-- 029_order_discounts.sql
-- A rep can give a discount when taking the order.
--
-- Until now an order line was product, unit, quantity and rate. The bill had
-- both a per-line discount and one on the whole bill; the order had neither.
-- So a rep who agreed 5% with a shop wrote it on a piece of paper, and the
-- office found out when the shop refused to pay the full amount.
--
-- Orders now carry the same two kinds of discount as bills, stored the same
-- way, so nothing has to be translated between them.
--
-- HOW IT REACHES THE BILL. Percentages travel; amounts do not. A bill often
-- covers only part of an order — half the goods today, the rest when stock
-- arrives — and "200 off" cannot be split honestly across two bills, while
-- "5%" can. So both are stored, and it is the percentage that is carried
-- forward. Where a rep typed an amount, the percentage it worked out to is
-- stored alongside it and that is what travels.
--
-- The office can still change it on the bill. A rep's discount is what was
-- agreed at the shop, not a rule the office cannot correct — but the bill
-- screen shows what the rep had quoted, so changing it is a decision rather
-- than an accident.
--
-- Run this file once in the Supabase SQL Editor. Safe to run more than once.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Columns — mirroring sales_invoice_line, deliberately
-- -----------------------------------------------------------------------------

alter table public.sales_order_line
  add column if not exists line_discount_pct    numeric(7,4),
  add column if not exists line_discount_amount numeric(14,2) not null default 0;

alter table public.sales_order_line
  drop constraint if exists sales_order_line_discount_pct_range;
alter table public.sales_order_line
  add constraint sales_order_line_discount_pct_range
  check (line_discount_pct is null or line_discount_pct between 0 and 100);

alter table public.sales_order_line
  drop constraint if exists sales_order_line_discount_not_negative;
alter table public.sales_order_line
  add constraint sales_order_line_discount_not_negative
  check (line_discount_amount >= 0);

-- A discount cannot exceed the line it is taken off.
alter table public.sales_order_line
  drop constraint if exists sales_order_line_discount_not_over;
alter table public.sales_order_line
  add constraint sales_order_line_discount_not_over
  check (line_discount_amount <= round(qty * rate, 2));

alter table public.sales_order
  add column if not exists bill_discount_pct    numeric(7,4),
  add column if not exists bill_discount_amount numeric(14,2) not null default 0;

alter table public.sales_order
  drop constraint if exists sales_order_bill_discount_valid;
alter table public.sales_order
  add constraint sales_order_bill_discount_valid
  check (
    bill_discount_amount >= 0
    and (bill_discount_pct is null or bill_discount_pct between 0 and 100)
  );

comment on column public.sales_order_line.line_discount_pct is
  'The percentage, whether typed as one or worked out from an amount. This is
   what carries to the bill, because a bill may cover only part of the order.';
comment on column public.sales_order.bill_discount_amount is
  'A discount on the order as a whole, as agreed at the shop. Carried to the
   bill as a percentage so a part-bill takes a proportional share.';


-- -----------------------------------------------------------------------------
-- 2. Taking an order with discounts
--
-- Same shape as create_sales_invoice: a line may carry a percentage, an
-- amount, or neither. Given a percentage, the amount is worked out; given an
-- amount, the percentage is worked out. Both end up stored, so neither the
-- printed order nor the bill has to guess what was meant.
-- -----------------------------------------------------------------------------

create or replace function app.order_line_discounts()
returns void
language plpgsql
as $$
begin
  -- Fill in whichever of the pair was not given, on the temp table the two
  -- order functions both build. Kept in one place so they cannot drift.
  execute $q$
    alter table pg_temp._ord_stage
      add column if not exists gross numeric(14,2);
    update pg_temp._ord_stage
       set gross = round(qty * coalesce(rate, 0), 2);

    update pg_temp._ord_stage
       set line_discount_amount =
             case
               when line_discount_amount is not null then round(line_discount_amount, 2)
               when line_discount_pct is not null
                 then round(gross * line_discount_pct / 100, 2)
               else 0
             end;

    update pg_temp._ord_stage
       set line_discount_pct =
             case
               when line_discount_pct is not null then line_discount_pct
               when gross > 0 and line_discount_amount > 0
                 then round(line_discount_amount * 100 / gross, 4)
               else line_discount_pct
             end;
  $q$;
end;
$$;

create or replace function public.create_sales_order(
  p_party_id             uuid,
  p_order_date           date,
  p_lines                jsonb,
  p_remarks              text    default null,
  p_bill_discount_amount numeric default 0,
  p_bill_discount_pct    numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user     uuid := app.require_signed_in();
  v_doc_no   text;
  v_id       uuid;
  v_days     smallint := (app.settings()).reservation_expiry_days;
  v_net      numeric(14,2);
  v_billdisc numeric(14,2);
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'An order needs at least one line' using errcode = 'SA004';
  end if;

  if not exists (select 1 from public.party where id = p_party_id and is_active) then
    raise exception 'Unknown or inactive party' using errcode = 'SA005';
  end if;

  drop table if exists _ord_stage;
  create temp table _ord_stage on commit drop as
  select
    row_number() over ()                   as line_no,
    x.product_id,
    x.uom,
    x.qty,
    app.pack_size_for(x.product_id, x.uom) as pack_size,
    coalesce(x.rate, (select sale_rate from public.product where id = x.product_id)) as rate,
    x.line_discount_pct,
    x.line_discount_amount
  from jsonb_to_recordset(p_lines) as x(
         product_id           uuid,
         uom                  app.uom_type,
         qty                  numeric,
         rate                 numeric,
         line_discount_pct    numeric,
         line_discount_amount numeric);

  if exists (select 1 from pg_temp._ord_stage where qty is null or qty <= 0) then
    raise exception 'Every line needs a quantity above zero' using errcode = 'SA004';
  end if;

  perform app.order_line_discounts();

  if exists (select 1 from pg_temp._ord_stage where line_discount_amount > gross) then
    raise exception 'A line discount is larger than the line itself'
      using errcode = 'SA004';
  end if;

  select coalesce(sum(gross - line_discount_amount), 0) into v_net from pg_temp._ord_stage;

  v_billdisc := coalesce(
    round(nullif(p_bill_discount_amount, 0), 2),
    round(v_net * coalesce(p_bill_discount_pct, 0) / 100, 2));

  if v_billdisc > v_net then
    raise exception 'The discount on the order is larger than the order itself'
      using errcode = 'SA004';
  end if;

  v_doc_no := app.next_doc_no('SALES_ORDER');

  insert into public.sales_order
    (doc_no, party_id, order_date, status, submitted_at, expires_at, remarks,
     created_by, bill_discount_amount, bill_discount_pct)
  values
    (v_doc_no, p_party_id, p_order_date, 'SUBMITTED', now(),
     now() + make_interval(days => v_days), p_remarks, v_user,
     v_billdisc,
     coalesce(p_bill_discount_pct,
              case when v_net > 0 and v_billdisc > 0
                   then round(v_billdisc * 100 / v_net, 4) end))
  returning id into v_id;

  insert into public.sales_order_line
    (order_id, line_no, product_id, uom, qty, pack_size, rate,
     line_discount_pct, line_discount_amount)
  select v_id, line_no, product_id, uom, qty, pack_size, rate,
         line_discount_pct, line_discount_amount
    from pg_temp._ord_stage;

  perform app.reserve_for_order(v_id);

  return jsonb_build_object('order_id', v_id, 'doc_no', v_doc_no,
                            'expires_at', (select expires_at from public.sales_order where id = v_id));
end;
$$;

create or replace function public.modify_sales_order(
  p_order_id             uuid,
  p_lines                jsonb,
  p_bill_discount_amount numeric default null,
  p_bill_discount_pct    numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user     uuid := app.require_signed_in();
  v_status   app.order_status;
  v_net      numeric(14,2);
  v_billdisc numeric(14,2);
begin
  select status into v_status from public.sales_order where id = p_order_id for update;

  if not found then
    raise exception 'Unknown order' using errcode = 'SA005';
  end if;

  if v_status <> 'SUBMITTED' then
    raise exception
      'This order is %, so it can no longer be modified. Cancel the pending quantity instead.',
      lower(replace(v_status::text, '_', ' '))
      using errcode = 'SA002';
  end if;

  if exists (select 1 from public.sales_invoice where order_id = p_order_id) then
    raise exception 'This order has already been invoiced and cannot be modified'
      using errcode = 'SA002';
  end if;

  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'An order needs at least one line' using errcode = 'SA004';
  end if;

  perform app.release_order_reservation(p_order_id);

  drop table if exists _ord_stage;
  create temp table _ord_stage on commit drop as
  select
    row_number() over ()                   as line_no,
    x.product_id,
    x.uom,
    x.qty,
    app.pack_size_for(x.product_id, x.uom) as pack_size,
    coalesce(x.rate, (select sale_rate from public.product where id = x.product_id)) as rate,
    x.line_discount_pct,
    x.line_discount_amount
  from jsonb_to_recordset(p_lines) as x(
         product_id           uuid,
         uom                  app.uom_type,
         qty                  numeric,
         rate                 numeric,
         line_discount_pct    numeric,
         line_discount_amount numeric);

  if exists (select 1 from pg_temp._ord_stage where qty is null or qty <= 0) then
    raise exception 'Every line needs a quantity above zero' using errcode = 'SA004';
  end if;

  perform app.order_line_discounts();

  if exists (select 1 from pg_temp._ord_stage where line_discount_amount > gross) then
    raise exception 'A line discount is larger than the line itself'
      using errcode = 'SA004';
  end if;

  select coalesce(sum(gross - line_discount_amount), 0) into v_net from pg_temp._ord_stage;

  -- Left out entirely, the order keeps the discount it already had.
  if p_bill_discount_amount is null and p_bill_discount_pct is null then
    select bill_discount_amount into v_billdisc
      from public.sales_order where id = p_order_id;
    v_billdisc := least(coalesce(v_billdisc, 0), v_net);
  else
    v_billdisc := coalesce(
      round(nullif(p_bill_discount_amount, 0), 2),
      round(v_net * coalesce(p_bill_discount_pct, 0) / 100, 2));
  end if;

  if v_billdisc > v_net then
    raise exception 'The discount on the order is larger than the order itself'
      using errcode = 'SA004';
  end if;

  delete from public.sales_order_line where order_id = p_order_id;

  insert into public.sales_order_line
    (order_id, line_no, product_id, uom, qty, pack_size, rate,
     line_discount_pct, line_discount_amount)
  select p_order_id, line_no, product_id, uom, qty, pack_size, rate,
         line_discount_pct, line_discount_amount
    from pg_temp._ord_stage;

  perform app.reserve_for_order(p_order_id);

  update public.sales_order
     set updated_at           = now(),
         bill_discount_amount = v_billdisc,
         bill_discount_pct    = coalesce(
           p_bill_discount_pct,
           case when v_net > 0 and v_billdisc > 0
                then round(v_billdisc * 100 / v_net, 4) end)
   where id = p_order_id;

  return jsonb_build_object('order_id', p_order_id, 'modified', true);
end;
$$;

-- The old signatures would otherwise sit alongside the new ones and make every
-- call ambiguous.
drop function if exists public.create_sales_order(uuid, date, jsonb, text);
drop function if exists public.modify_sales_order(uuid, jsonb);

revoke all on function
  public.create_sales_order(uuid, date, jsonb, text, numeric, numeric) from public, anon;
revoke all on function
  public.modify_sales_order(uuid, jsonb, numeric, numeric) from public, anon;
grant execute on function
  public.create_sales_order(uuid, date, jsonb, text, numeric, numeric) to authenticated;
grant execute on function
  public.modify_sales_order(uuid, jsonb, numeric, numeric) to authenticated;


-- -----------------------------------------------------------------------------
-- 3. What an order is worth, now that it can be discounted
--
-- order_value becomes the figure the customer was actually quoted. Anything
-- reading it — the Orders screen, the day book — should show what was agreed,
-- not a gross figure nobody ever said out loud. The gross and the discount are
-- there beside it for anyone who wants the breakdown.
-- -----------------------------------------------------------------------------

drop view if exists public.v_day_summary;
drop view if exists public.v_day_book;
drop view if exists public.v_sales_order_summary;

create view public.v_sales_order_summary as
select
  so.id                        as order_id,
  so.doc_no,
  so.party_id,
  so.order_date,
  so.status,
  so.expires_at,
  so.created_by                as rep_id,
  count(sol.id)                as line_count,
  coalesce(sum(round(sol.qty * sol.rate, 2)), 0)               as gross_value,
  coalesce(sum(sol.line_discount_amount), 0) + so.bill_discount_amount as discount_value,
  greatest(
    coalesce(sum(round(sol.qty * sol.rate, 2) - sol.line_discount_amount), 0)
      - so.bill_discount_amount,
    0)                                                          as order_value,
  so.bill_discount_amount,
  so.bill_discount_pct,
  coalesce(sum(sol.qty_pending_base), 0)         as qty_pending_base,
  case
    when so.status in ('SUBMITTED', 'PARTIALLY_INVOICED')
    then coalesce(sum(sol.qty_pending_base), 0)
    else 0
  end                          as qty_reserved_base
from public.sales_order so
left join public.sales_order_line sol on sol.order_id = so.id
group by so.id;

alter view public.v_sales_order_summary set (security_invoker = true);
grant select on public.v_sales_order_summary to authenticated;

-- Rebuilt unchanged; it only had to go so the view underneath could be replaced.
create view public.v_day_book as
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

create view public.v_day_summary as
select
  entry_date,
  sum(amount) filter (where doc_type = 'BILL'     and status <> 'CANCELLED') as sales,
  sum(amount) filter (where doc_type = 'PURCHASE' and status <> 'CANCELLED') as purchases,
  sum(amount) filter (where doc_type = 'PAYMENT'  and status <> 'CANCELLED') as receipts,
  sum(amount) filter (where doc_type = 'RETURN'   and status <> 'CANCELLED') as returns,
  sum(amount) filter (where doc_type = 'CANCELLATION')                       as cancelled,
  sum(amount) filter (where doc_type = 'ORDER'    and status <> 'CANCELLED') as orders,
  count(*) filter (where doc_type = 'BILL')      as bill_count,
  count(*) filter (where doc_type = 'PURCHASE')  as purchase_count,
  count(*) filter (where doc_type = 'PAYMENT')   as payment_count,
  count(*) filter (where doc_type = 'ORDER')     as order_count,
  count(*)                                       as entry_count
from public.v_day_book
group by entry_date;

do $$
declare v text;
begin
  foreach v in array array['v_day_book', 'v_day_summary'] loop
    execute format('alter view public.%I set (security_invoker = true)', v);
    execute format('grant select on public.%I to authenticated', v);
  end loop;
end;
$$;


-- -----------------------------------------------------------------------------
-- 4. What the billing screen reads, so the bill can start where the rep left off
-- -----------------------------------------------------------------------------

drop view if exists public.v_order_line_billing;

create view public.v_order_line_billing as
select
  sol.id                as order_line_id,
  sol.order_id,
  sol.line_no,
  sol.product_id,
  sol.uom,
  sol.qty,
  sol.pack_size,
  sol.rate,
  sol.line_discount_pct,
  sol.line_discount_amount,
  sol.qty_base,
  sol.qty_pending_base,
  round(sol.qty * sol.rate, 2) as gross_amount,
  round(sol.qty * sol.rate, 2) - sol.line_discount_amount as net_amount,
  pr.code               as product_code,
  pr.name               as product_name,
  pr.base_uom,
  pr.pack_uom,
  pr.pack_size          as product_pack_size
from public.sales_order_line sol
join public.product pr on pr.id = sol.product_id;

alter view public.v_order_line_billing set (security_invoker = true);
grant select on public.v_order_line_billing to authenticated;
