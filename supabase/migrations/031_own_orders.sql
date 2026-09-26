-- =============================================================================
-- 031_own_orders.sql
--
-- Run this in the Supabase SQL Editor. Committing it to git does nothing to
-- the database.
--
-- A rep may change and cancel the orders they raised. Not anyone else's.
--
-- Until now any signed-in user could modify or cancel any order that was still
-- awaiting its bill, because until now no rep had a way to try: there was no
-- edit screen, and the database was the only thing that could have said no.
-- Giving reps an edit screen makes the question real, and out in the field two
-- reps working the same list is how one of them quietly rewrites the other's
-- order.
--
-- Accounts and admin are untouched. They see the whole book by design: the
-- office corrects what the field got wrong, and having to find which rep took
-- an order before fixing a quantity would be an obstacle with no purpose.
--
-- The check is here rather than only in the app because the app is a
-- suggestion — anyone signed in can call these functions directly. A rule that
-- only the screen enforces is not a rule.
--
-- Safe to run twice.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- The rule, in one place, so the two functions cannot drift apart.
-- -----------------------------------------------------------------------------

create or replace function app.require_own_order_if_rep(p_order_id uuid, p_verb text)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_me    uuid := app.require_signed_in();
  v_owner uuid;
  v_who   text;
begin
  if app.current_role() <> 'REP' then
    return;
  end if;

  select so.created_by, coalesce(u.full_name, 'another rep')
    into v_owner, v_who
    from public.sales_order so
    left join public.app_user u on u.id = so.created_by
   where so.id = p_order_id;

  -- An order with no recorded author (imported, or raised before users were
  -- tracked) belongs to nobody, so there is nobody to protect it from.
  if v_owner is null or v_owner = v_me then
    return;
  end if;

  raise exception
    'This order was taken by %, so you cannot % it. Ask the office.', v_who, p_verb
    using errcode = 'SA003';
end;
$$;

comment on function app.require_own_order_if_rep(uuid, text) is
  'Refuses when a REP acts on an order somebody else raised. Silent for
   ACCOUNTS and ADMIN, who work the whole book.';

revoke all on function app.require_own_order_if_rep(uuid, text) from public, anon;


-- -----------------------------------------------------------------------------
-- Apply it. Both function bodies are otherwise exactly as 029 and 013 left
-- them; the only change is the one line after the order is located.
-- -----------------------------------------------------------------------------

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

  perform app.require_own_order_if_rep(p_order_id, 'change');

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


create or replace function public.cancel_sales_order(
  p_order_id uuid,
  p_reason   text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user   uuid := app.require_signed_in();
  v_status app.order_status;
begin
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'A cancellation reason is required' using errcode = 'SA004';
  end if;

  select status into v_status from public.sales_order where id = p_order_id for update;

  if not found then
    raise exception 'Unknown order' using errcode = 'SA005';
  end if;

  -- Cancelling is the more destructive of the two, so it cannot be looser than
  -- editing: a rep who may not change another's order may not scrap it either.
  perform app.require_own_order_if_rep(p_order_id, 'cancel');

  if v_status in ('CANCELLED', 'INVOICED') then
    raise exception 'This order is already %', lower(v_status::text)
      using errcode = 'SA002';
  end if;

  perform app.release_order_reservation(p_order_id);

  -- Whatever was never invoiced is now formally dropped.
  update public.sales_order_line
     set qty_cancelled_base = qty_cancelled_base + qty_pending_base
   where order_id = p_order_id
     and qty_pending_base > 0;

  update public.sales_order
     set status = 'CANCELLED', cancelled_at = now(),
         cancelled_by = v_user, cancel_reason = p_reason
   where id = p_order_id;

  return jsonb_build_object('order_id', p_order_id, 'status', 'CANCELLED');
end;
$$;


-- -----------------------------------------------------------------------------
-- The edit screen needs to read an order back as the rep typed it. Lines alone
-- are not enough: the screen has to know whose order it is before it offers an
-- Edit button, and whether it is still editable at all.
-- -----------------------------------------------------------------------------

drop view if exists public.v_order_for_edit;

create view public.v_order_for_edit as
select
  so.id                as order_id,
  so.doc_no,
  so.order_date,
  so.status,
  so.remarks,
  so.party_id,
  p.code               as party_code,
  p.name               as party_name,
  rt.name              as route_name,
  so.created_by        as rep_id,
  u.full_name          as rep_name,
  so.bill_discount_pct,
  so.bill_discount_amount,
  so.status = 'SUBMITTED'
    and not exists (select 1 from public.sales_invoice si where si.order_id = so.id)
                       as is_editable
from public.sales_order so
join public.party p on p.id = so.party_id
left join public.route rt on rt.id = p.route_id
left join public.app_user u on u.id = so.created_by;

alter view public.v_order_for_edit set (security_invoker = true);
grant select on public.v_order_for_edit to authenticated;

comment on view public.v_order_for_edit is
  'One row per order, carrying who raised it and whether it can still be
   changed, so the Orders screen can decide whether to offer Edit.';

-- -----------------------------------------------------------------------------
-- The Orders list needs two things it did not have.
--
-- `rep_id`, so the screen can tell whose order it is looking at and stop
-- offering a rep buttons the database is going to refuse. A button that always
-- fails is worse than no button.
--
-- And a corrected `order_value`. 029 gave orders discounts and taught
-- v_sales_order_summary to report them, but this view was missed: it still
-- sums qty x rate, so the Orders screen has been showing the gross figure
-- while the day book shows the net one. Two screens disagreeing about what an
-- order is worth is the kind of thing that gets an app distrusted, and the one
-- that is wrong is this one — nobody quoted the customer the gross.
-- -----------------------------------------------------------------------------

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
  count(sol.id)                                   as lines,
  sum(sol.qty_pending_base)                       as qty_pending_base,
  greatest(
    sum(round(sol.qty * sol.rate, 2) - sol.line_discount_amount)
      - so.bill_discount_amount,
    0)                                            as order_value,
  sum(round(sol.qty * sol.rate, 2))               as gross_value,
  case when so.expires_at < now() + interval '1 day'
       then true else false end                   as expiring_soon
from public.sales_order so
join public.party p        on p.id  = so.party_id
join public.route rt       on rt.id = p.route_id
left join public.app_user rep on rep.id = so.created_by
join public.sales_order_line sol on sol.order_id = so.id
where so.status in ('SUBMITTED', 'PARTIALLY_INVOICED')
group by so.id, p.code, p.name, rt.name, rep.full_name;

alter view public.v_pending_orders set (security_invoker = true);
grant select on public.v_pending_orders to authenticated;

notify pgrst, 'reload schema';
