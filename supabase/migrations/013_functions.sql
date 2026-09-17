-- =============================================================================
-- 013_functions.sql
-- Business logic. Every operation that moves stock or money lives here.
--
-- All of these are SECURITY DEFINER: they bypass RLS and do their own
-- permission check, so the tables themselves can stay read-only to clients.
-- Each runs in a single transaction and locks the product stock rows it
-- touches, in product_id order, before reading availability.
--
-- Error codes returned to the client:
--   SA001  insufficient stock  (DETAIL carries a JSON array of shortfalls)
--   SA002  invalid state for the requested operation
--   SA003  permission denied
--   SA004  invalid input
--   SA005  not found
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Guards
-- -----------------------------------------------------------------------------

create or replace function app.require_signed_in()
returns uuid
language plpgsql
stable
as $$
declare v_id uuid := auth.uid();
begin
  if v_id is null or app.current_role() is null then
    raise exception 'Not signed in' using errcode = 'SA003';
  end if;
  return v_id;
end;
$$;

create or replace function app.require_back_office()
returns uuid
language plpgsql
stable
as $$
declare v_id uuid := app.require_signed_in();
begin
  if not app.is_back_office() then
    raise exception 'This action is for Accounts or Admin only'
      using errcode = 'SA003';
  end if;
  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Deterministic locking.
--
-- Two transactions touching the same two products in opposite orders would
-- deadlock. Sorting the ids first means every transaction takes its locks in
-- the same sequence, so one simply waits for the other.
-- -----------------------------------------------------------------------------

create or replace function app.lock_products(p_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_sorted uuid[];
  v_id     uuid;
begin
  select array_agg(distinct u order by u) into v_sorted from unnest(p_ids) u;

  foreach v_id in array coalesce(v_sorted, '{}'::uuid[]) loop
    perform 1 from public.product_stock where product_id = v_id for update;
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- Resolve the pack size to snapshot for a line.
-- -----------------------------------------------------------------------------

create or replace function app.pack_size_for(p_product_id uuid, p_uom app.uom_type)
returns numeric
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
declare v_pack numeric;
begin
  select pack_size into v_pack from public.product where id = p_product_id;

  if not found then
    raise exception 'Unknown product %', p_product_id using errcode = 'SA005';
  end if;

  if p_uom = 'PACK' and v_pack <= 1 then
    raise exception 'Product % has no pack unit defined', p_product_id
      using errcode = 'SA004';
  end if;

  return case when p_uom = 'PACK' then v_pack else 1 end;
end;
$$;

-- =============================================================================
-- PURCHASE
-- =============================================================================

create or replace function public.post_purchase(
  p_supplier_id        uuid,
  p_purchase_date      date,
  p_lines              jsonb,
  p_other_charges      numeric default 0,
  p_supplier_bill_no   text    default null,
  p_supplier_bill_date date    default null,
  p_remarks            text    default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user   uuid := app.require_back_office();
  v_doc_no text;
  v_id     uuid;
  v_gross  numeric(14,2);
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'A purchase needs at least one line' using errcode = 'SA004';
  end if;

  drop table if exists _pur_lines;
  create temp table _pur_lines on commit drop as
  select
    row_number() over ()                        as line_no,
    x.product_id,
    x.uom,
    x.qty,
    app.pack_size_for(x.product_id, x.uom)      as pack_size,
    x.rate
  from jsonb_to_recordset(p_lines)
       as x(product_id uuid, uom app.uom_type, qty numeric, rate numeric);

  if exists (select 1 from pg_temp._pur_lines where qty is null or qty <= 0) then
    raise exception 'Every purchase line needs a quantity above zero'
      using errcode = 'SA004';
  end if;

  if exists (select 1 from pg_temp._pur_lines where rate is null or rate < 0) then
    raise exception 'Every purchase line needs a rate' using errcode = 'SA004';
  end if;

  select coalesce(sum(round(qty * rate, 2)), 0) into v_gross from pg_temp._pur_lines;

  v_doc_no := app.next_doc_no('PURCHASE');

  insert into public.purchase
    (doc_no, supplier_id, purchase_date, supplier_bill_no, supplier_bill_date,
     gross_total, other_charges, net_total, remarks, created_by)
  values
    (v_doc_no, p_supplier_id, p_purchase_date, p_supplier_bill_no,
     p_supplier_bill_date, v_gross, coalesce(p_other_charges, 0),
     v_gross + coalesce(p_other_charges, 0), p_remarks, v_user)
  returning id into v_id;

  insert into public.purchase_line
    (purchase_id, line_no, product_id, uom, qty, pack_size, rate)
  select v_id, line_no, product_id, uom, qty, pack_size, rate
    from pg_temp._pur_lines;

  -- Stock in.
  insert into public.stock_ledger
    (product_id, movement_date, qty_in, rate, doc_type, doc_id, doc_line_id, created_by)
  select pl.product_id, p_purchase_date, pl.qty_base,
         case when pl.qty_base > 0 then round(pl.amount / pl.qty_base, 4) else 0 end,
         'PURCHASE', v_id, pl.id, v_user
    from public.purchase_line pl
   where pl.purchase_id = v_id;

  return jsonb_build_object('purchase_id', v_id, 'doc_no', v_doc_no,
                            'net_total', v_gross + coalesce(p_other_charges, 0));
end;
$$;

-- =============================================================================
-- SALES ORDER
-- =============================================================================

-- Releases whatever an order still holds. Safe to call more than once.
create or replace function app.release_order_reservation(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare v_ids uuid[];
begin
  select array_agg(product_id) into v_ids
    from public.sales_order_line where order_id = p_order_id;

  perform app.lock_products(coalesce(v_ids, '{}'::uuid[]));

  update public.product_stock ps
     set reserved   = greatest(ps.reserved - sol.qty_pending_base, 0),
         updated_at = now()
    from public.sales_order_line sol
   where sol.order_id = p_order_id
     and ps.product_id = sol.product_id
     and sol.qty_pending_base > 0;
end;
$$;

-- Takes the reservation for an order's pending quantity, or raises SA001 with
-- a per-line breakdown of what is short.
create or replace function app.reserve_for_order(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_ids       uuid[];
  v_shortfall jsonb;
begin
  select array_agg(product_id) into v_ids
    from public.sales_order_line where order_id = p_order_id;

  perform app.lock_products(coalesce(v_ids, '{}'::uuid[]));

  select jsonb_agg(jsonb_build_object(
           'product_id',   sol.product_id,
           'product_code', p.code,
           'product_name', p.name,
           'base_uom',     p.base_uom,
           'requested',    sol.qty_pending_base,
           'available',    greatest(ps.available, 0)
         ) order by p.name)
    into v_shortfall
    from public.sales_order_line sol
    join public.product       p  on p.id  = sol.product_id
    join public.product_stock ps on ps.product_id = sol.product_id
   where sol.order_id = p_order_id
     and sol.qty_pending_base > ps.available;

  if v_shortfall is not null then
    raise exception 'Not enough stock for this order'
      using errcode = 'SA001', detail = v_shortfall::text;
  end if;

  update public.product_stock ps
     set reserved   = ps.reserved + sol.qty_pending_base,
         updated_at = now()
    from public.sales_order_line sol
   where sol.order_id = p_order_id
     and ps.product_id = sol.product_id
     and sol.qty_pending_base > 0;
end;
$$;

create or replace function public.create_sales_order(
  p_party_id   uuid,
  p_order_date date,
  p_lines      jsonb,
  p_remarks    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user   uuid := app.require_signed_in();
  v_doc_no text;
  v_id     uuid;
  v_days   smallint := (app.settings()).reservation_expiry_days;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'An order needs at least one line' using errcode = 'SA004';
  end if;

  if not exists (select 1 from public.party where id = p_party_id and is_active) then
    raise exception 'Unknown or inactive party' using errcode = 'SA005';
  end if;

  drop table if exists _ord_lines;
  create temp table _ord_lines on commit drop as
  select
    row_number() over ()                   as line_no,
    x.product_id,
    x.uom,
    x.qty,
    app.pack_size_for(x.product_id, x.uom) as pack_size,
    x.rate
  from jsonb_to_recordset(p_lines)
       as x(product_id uuid, uom app.uom_type, qty numeric, rate numeric);

  if exists (select 1 from pg_temp._ord_lines where qty is null or qty <= 0) then
    raise exception 'Every line needs a quantity above zero' using errcode = 'SA004';
  end if;

  if exists (select 1 from pg_temp._ord_lines
              group by product_id having count(*) > 1) then
    raise exception 'The same product appears more than once on this order'
      using errcode = 'SA004';
  end if;

  if exists (select 1 from pg_temp._ord_lines l
              join public.product p on p.id = l.product_id
             where not p.is_active) then
    raise exception 'An inactive product is on this order' using errcode = 'SA004';
  end if;

  v_doc_no := app.next_doc_no('SALES_ORDER');

  insert into public.sales_order
    (doc_no, party_id, order_date, status, remarks,
     submitted_at, expires_at, created_by)
  values
    (v_doc_no, p_party_id, p_order_date, 'SUBMITTED', p_remarks,
     now(), now() + make_interval(days => v_days), v_user)
  returning id into v_id;

  insert into public.sales_order_line
    (order_id, line_no, product_id, uom, qty, pack_size, rate)
  select v_id, line_no, product_id, uom, qty, pack_size,
         coalesce(rate, (select sale_rate from public.product where id = product_id))
    from pg_temp._ord_lines;

  perform app.reserve_for_order(v_id);

  return jsonb_build_object('order_id', v_id, 'doc_no', v_doc_no,
                            'expires_at', (select expires_at from public.sales_order where id = v_id));
end;
$$;

-- Replaces an order's lines wholesale. Only while nothing has been invoiced.
create or replace function public.modify_sales_order(
  p_order_id uuid,
  p_lines    jsonb
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

  -- Give back what it currently holds, then re-reserve against the new lines.
  perform app.release_order_reservation(p_order_id);

  drop table if exists _mod_lines;
  create temp table _mod_lines on commit drop as
  select
    row_number() over ()                   as line_no,
    x.product_id,
    x.uom,
    x.qty,
    app.pack_size_for(x.product_id, x.uom) as pack_size,
    x.rate
  from jsonb_to_recordset(p_lines)
       as x(product_id uuid, uom app.uom_type, qty numeric, rate numeric);

  if exists (select 1 from pg_temp._mod_lines where qty is null or qty <= 0) then
    raise exception 'Every line needs a quantity above zero' using errcode = 'SA004';
  end if;

  if exists (select 1 from pg_temp._mod_lines
              group by product_id having count(*) > 1) then
    raise exception 'The same product appears more than once on this order'
      using errcode = 'SA004';
  end if;

  delete from public.sales_order_line where order_id = p_order_id;

  insert into public.sales_order_line
    (order_id, line_no, product_id, uom, qty, pack_size, rate)
  select p_order_id, line_no, product_id, uom, qty, pack_size,
         coalesce(rate, (select sale_rate from public.product where id = product_id))
    from pg_temp._mod_lines;

  perform app.reserve_for_order(p_order_id);

  update public.sales_order set updated_at = now() where id = p_order_id;

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

-- The daily job. Releases reservations on orders that were submitted and then
-- never invoiced within the window.
create or replace function public.expire_stale_orders()
returns integer
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_id    uuid;
  v_count integer := 0;
begin
  for v_id in
    select id from public.sales_order
     where status = 'SUBMITTED'
       and expires_at is not null
       and expires_at < now()
     order by expires_at
     for update skip locked
  loop
    perform app.release_order_reservation(v_id);

    update public.sales_order
       set status = 'EXPIRED', closed_at = now()
     where id = v_id;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- Puts an expired order back into play, if stock allows.
create or replace function public.reinstate_sales_order(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user   uuid := app.require_back_office();
  v_status app.order_status;
  v_days   smallint := (app.settings()).reservation_expiry_days;
begin
  select status into v_status from public.sales_order where id = p_order_id for update;

  if not found then
    raise exception 'Unknown order' using errcode = 'SA005';
  end if;

  if v_status <> 'EXPIRED' then
    raise exception 'Only an expired order can be reinstated' using errcode = 'SA002';
  end if;

  update public.sales_order
     set status = 'SUBMITTED', closed_at = null,
         submitted_at = now(), expires_at = now() + make_interval(days => v_days)
   where id = p_order_id;

  -- Raises SA001 with the shortfall if stock has since gone.
  perform app.reserve_for_order(p_order_id);

  return jsonb_build_object('order_id', p_order_id, 'status', 'SUBMITTED');
end;
$$;

-- =============================================================================
-- SALES INVOICE
-- =============================================================================

create or replace function public.create_sales_invoice(
  p_invoice_date         date,
  p_lines                jsonb,
  p_order_id             uuid    default null,
  p_party_id             uuid    default null,
  p_bill_discount_amount numeric default 0,
  p_bill_discount_pct    numeric default null,
  p_remarks              text    default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user       uuid := app.require_back_office();
  v_doc_no     text;
  v_id         uuid;
  v_party      uuid;
  v_status     app.order_status;
  v_gross      numeric(14,2);
  v_line_disc  numeric(14,2);
  v_bill_disc  numeric(14,2);
  v_effective  numeric(14,2);
  v_net        numeric(14,2);
  v_round      numeric(14,2) := 0;
  v_ids        uuid[];
  v_shortfall  jsonb;
  v_over       jsonb;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'An invoice needs at least one line' using errcode = 'SA004';
  end if;

  -- Either invoice an order, or raise a direct counter sale for a named party.
  if p_order_id is not null then
    select party_id, status into v_party, v_status
      from public.sales_order where id = p_order_id for update;

    if not found then
      raise exception 'Unknown order' using errcode = 'SA005';
    end if;

    if v_status not in ('SUBMITTED', 'PARTIALLY_INVOICED') then
      raise exception 'Order is %, so it cannot be invoiced',
        lower(replace(v_status::text, '_', ' ')) using errcode = 'SA002';
    end if;
  else
    if p_party_id is null then
      raise exception 'A direct invoice needs a party' using errcode = 'SA004';
    end if;
    v_party := p_party_id;
  end if;

  -- ---------------------------------------------------------------------------
  -- Resolve each line: product, pack, quantities, line discount.
  -- ---------------------------------------------------------------------------
  drop table if exists _inv_lines;
  create temp table _inv_lines on commit drop as
  with raw as (
    select
      row_number() over ()   as line_no,
      x.order_line_id,
      coalesce(x.product_id, sol.product_id) as product_id,
      coalesce(x.uom, sol.uom, 'BASE')       as uom,
      x.qty,
      coalesce(x.rate, sol.rate)             as rate,
      x.line_discount_pct,
      x.line_discount_amount
    from jsonb_to_recordset(p_lines) as x(
           order_line_id        uuid,
           product_id           uuid,
           uom                  app.uom_type,
           qty                  numeric,
           rate                 numeric,
           line_discount_pct    numeric,
           line_discount_amount numeric)
    left join public.sales_order_line sol on sol.id = x.order_line_id
  ),
  sized as (
    select r.*,
           app.pack_size_for(r.product_id, r.uom) as pack_size
      from raw r
  )
  select
    s.line_no, s.order_line_id, s.product_id, s.uom, s.qty, s.pack_size, s.rate,
    s.qty * case when s.uom = 'PACK' then s.pack_size else 1 end as qty_base,
    round(s.qty * s.rate, 2)                                     as gross,
    s.line_discount_pct,
    coalesce(
      s.line_discount_amount,
      round(round(s.qty * s.rate, 2) * coalesce(s.line_discount_pct, 0) / 100, 2)
    )                                                            as line_discount_amount
  from sized s;

  if exists (select 1 from pg_temp._inv_lines where qty is null or qty <= 0) then
    raise exception 'Every line needs a quantity above zero' using errcode = 'SA004';
  end if;

  if exists (select 1 from pg_temp._inv_lines where rate is null) then
    raise exception 'Every line needs a rate' using errcode = 'SA004';
  end if;

  if exists (select 1 from pg_temp._inv_lines
              where line_discount_amount > gross) then
    raise exception 'A line discount is larger than the line itself'
      using errcode = 'SA004';
  end if;

  if p_order_id is not null
     and exists (select 1 from pg_temp._inv_lines where order_line_id is null) then
    raise exception 'Every line of an order-based invoice must reference an order line'
      using errcode = 'SA004';
  end if;

  -- ---------------------------------------------------------------------------
  -- Never invoice more than the order actually has pending.
  -- ---------------------------------------------------------------------------
  if p_order_id is not null then
    select jsonb_agg(jsonb_build_object(
             'product_name', p.name,
             'requested',    il.qty_base,
             'pending',      sol.qty_pending_base))
      into v_over
      from pg_temp._inv_lines il
      join public.sales_order_line sol on sol.id = il.order_line_id
      join public.product p on p.id = il.product_id
     where sol.order_id <> p_order_id
        or il.qty_base > sol.qty_pending_base;

    if v_over is not null then
      raise exception 'Invoiced quantity exceeds what the order has pending'
        using errcode = 'SA002', detail = v_over::text;
    end if;
  end if;

  -- ---------------------------------------------------------------------------
  -- Lock stock, then check it. Order matters: checking before locking is the
  -- classic oversell race.
  -- ---------------------------------------------------------------------------
  select array_agg(product_id) into v_ids from pg_temp._inv_lines;
  perform app.lock_products(v_ids);

  select jsonb_agg(jsonb_build_object(
           'product_code', p.code,
           'product_name', p.name,
           'base_uom',     p.base_uom,
           'requested',    t.needed,
           'on_hand',      ps.on_hand) order by p.name)
    into v_shortfall
    from (select product_id, sum(qty_base) as needed
            from pg_temp._inv_lines group by product_id) t
    join public.product       p  on p.id = t.product_id
    join public.product_stock ps on ps.product_id = t.product_id
   where t.needed > ps.on_hand;

  if v_shortfall is not null then
    raise exception 'Not enough stock on hand to raise this invoice'
      using errcode = 'SA001', detail = v_shortfall::text;
  end if;

  -- ---------------------------------------------------------------------------
  -- Totals, then allocate the bill discount across lines by largest remainder
  -- so the parts sum to the whole exactly.
  -- ---------------------------------------------------------------------------
  select coalesce(sum(gross), 0), coalesce(sum(line_discount_amount), 0)
    into v_gross, v_line_disc
    from pg_temp._inv_lines;

  v_bill_disc := coalesce(
    nullif(p_bill_discount_amount, 0),
    round((v_gross - v_line_disc) * coalesce(p_bill_discount_pct, 0) / 100, 2)
  );
  v_bill_disc := coalesce(v_bill_disc, 0);

  if v_bill_disc > (v_gross - v_line_disc) then
    raise exception 'The bill discount is larger than the invoice'
      using errcode = 'SA004';
  end if;

  drop table if exists _inv_alloc;
  create temp table _inv_alloc on commit drop as
  with base as (
    select line_no, (gross - line_discount_amount) as net
      from pg_temp._inv_lines
  ),
  tot as (select coalesce(sum(net), 0) as s from base),
  exact as (
    select b.line_no, b.net,
           case when t.s = 0 then 0 else v_bill_disc * b.net / t.s end as ex
      from base b cross join tot t
  ),
  floored as (
    select e.*,
           trunc(e.ex * 100) / 100                as flo,
           e.ex - trunc(e.ex * 100) / 100         as rem
      from exact e
  ),
  ranked as (
    select f.*,
           row_number() over (order by f.rem desc, f.net desc, f.line_no) as rk,
           round((v_bill_disc - sum(f.flo) over ()) * 100)::int           as spare
      from floored f
  )
  select line_no,
         (flo + case when rk <= spare then 0.01 else 0 end)::numeric(14,2) as alloc
    from ranked;

  select coalesce(sum(il.gross - il.line_discount_amount - a.alloc), 0)
    into v_effective
    from pg_temp._inv_lines il
    join pg_temp._inv_alloc a on a.line_no = il.line_no;

  if (app.settings()).round_invoice_total then
    v_net   := round(v_effective, 0);
    v_round := v_net - v_effective;
  else
    v_net   := v_effective;
    v_round := 0;
  end if;

  -- ---------------------------------------------------------------------------
  -- Write it
  -- ---------------------------------------------------------------------------
  v_doc_no := app.next_doc_no('SALES_INVOICE');

  insert into public.sales_invoice
    (doc_no, party_id, order_id, invoice_date, gross_total, line_discount_total,
     bill_discount_amount, round_off, net_total, remarks, created_by)
  values
    (v_doc_no, v_party, p_order_id, p_invoice_date, v_gross, v_line_disc,
     v_bill_disc, v_round, v_net, p_remarks, v_user)
  returning id into v_id;

  insert into public.sales_invoice_line
    (invoice_id, line_no, order_line_id, product_id, uom, qty, pack_size, rate,
     line_discount_pct, line_discount_amount, allocated_bill_discount)
  select v_id, il.line_no, il.order_line_id, il.product_id, il.uom, il.qty,
         il.pack_size, il.rate, il.line_discount_pct, il.line_discount_amount,
         a.alloc
    from pg_temp._inv_lines il
    join pg_temp._inv_alloc a on a.line_no = il.line_no;

  -- Stock out.
  insert into public.stock_ledger
    (product_id, movement_date, qty_out, rate, doc_type, doc_id, doc_line_id, created_by)
  select sil.product_id, p_invoice_date, sil.qty_base, sil.rate,
         'SALE', v_id, sil.id, v_user
    from public.sales_invoice_line sil
   where sil.invoice_id = v_id;

  -- ---------------------------------------------------------------------------
  -- Consume the order: the invoiced quantity stops being reserved and is now
  -- simply gone from on_hand, so availability is unchanged by invoicing.
  -- ---------------------------------------------------------------------------
  if p_order_id is not null then
    update public.sales_order_line sol
       set qty_invoiced_base = sol.qty_invoiced_base + il.qty_base
      from pg_temp._inv_lines il
     where sol.id = il.order_line_id;

    update public.product_stock ps
       set reserved   = greatest(ps.reserved - t.qty, 0),
           updated_at = now()
      from (select product_id, sum(qty_base) as qty
              from pg_temp._inv_lines group by product_id) t
     where ps.product_id = t.product_id;

    update public.sales_order so
       set status = case
                      when not exists (select 1 from public.sales_order_line
                                        where order_id = p_order_id
                                          and qty_pending_base > 0)
                      then 'INVOICED'::app.order_status
                      else 'PARTIALLY_INVOICED'::app.order_status
                    end,
           closed_at = case
                         when not exists (select 1 from public.sales_order_line
                                           where order_id = p_order_id
                                             and qty_pending_base > 0)
                         then now() else null
                       end
     where so.id = p_order_id;
  end if;

  return jsonb_build_object(
    'invoice_id', v_id, 'doc_no', v_doc_no,
    'gross_total', v_gross, 'bill_discount', v_bill_disc,
    'round_off', v_round, 'net_total', v_net);
end;
$$;

-- -----------------------------------------------------------------------------
-- Cancellation
--
-- p_lines null  -> cancel everything still standing on the invoice
-- p_lines given -> [{"invoice_line_id": "...", "qty_base": 5}, ...]
-- -----------------------------------------------------------------------------

create or replace function public.cancel_sales_invoice(
  p_invoice_id uuid,
  p_reason     text,
  p_lines      jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user      uuid := app.require_back_office();
  v_inv       public.sales_invoice%rowtype;
  v_doc_no    text;
  v_can_id    uuid;
  v_value     numeric(14,2);
  v_is_full   boolean;
  v_ids       uuid[];
  v_allocated numeric(14,2);
  v_excess    numeric(14,2);
  v_released  numeric(14,2) := 0;
  r           record;
begin
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'A cancellation reason is required' using errcode = 'SA004';
  end if;

  select * into v_inv from public.sales_invoice where id = p_invoice_id for update;

  if not found then
    raise exception 'Unknown invoice' using errcode = 'SA005';
  end if;

  if v_inv.status = 'CANCELLED' then
    raise exception 'This invoice is already fully cancelled' using errcode = 'SA002';
  end if;

  -- ---------------------------------------------------------------------------
  -- What is being cancelled, and what it is worth.
  --
  -- Value is derived from the cumulative cancelled quantity rather than this
  -- slice alone, so a series of partial cancels that ends up covering the whole
  -- line credits back exactly the line's value, with no rounding residue.
  -- ---------------------------------------------------------------------------
  drop table if exists _can_lines;
  create temp table _can_lines on commit drop as
  with picked as (
    select
      sil.id                as invoice_line_id,
      sil.product_id,
      sil.qty_base,
      sil.effective_amount,
      sil.qty_cancelled_base                        as already_base,
      least(coalesce(x.qty_base, sil.qty_base - sil.qty_cancelled_base),
            sil.qty_base - sil.qty_cancelled_base)  as cancel_base
    from public.sales_invoice_line sil
    left join lateral (
      select (e ->> 'qty_base')::numeric as qty_base
        from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e
       where (e ->> 'invoice_line_id')::uuid = sil.id
    ) x on true
    where sil.invoice_id = p_invoice_id
      and (p_lines is null or x.qty_base is not null)
      and sil.qty_base > sil.qty_cancelled_base
  )
  select
    p.*,
    -- Pro-rate from the cumulative cancelled quantity rather than this slice,
    -- so partial cancels that eventually cover the line credit back exactly
    -- the line's value with no rounding residue.
    (round(p.effective_amount * (p.already_base + p.cancel_base) / p.qty_base, 2)
     - round(p.effective_amount * p.already_base / p.qty_base, 2))::numeric(14,2)
      as value_now
  from picked p
  where p.cancel_base > 0;

  if not exists (select 1 from pg_temp._can_lines) then
    raise exception 'Nothing on this invoice is left to cancel' using errcode = 'SA002';
  end if;

  select coalesce(sum(value_now), 0) into v_value from pg_temp._can_lines;

  -- Is the whole invoice now accounted for?
  v_is_full := not exists (
    select 1
      from public.sales_invoice_line sil
      left join pg_temp._can_lines cl on cl.invoice_line_id = sil.id
     where sil.invoice_id = p_invoice_id
       and sil.qty_base > sil.qty_cancelled_base + coalesce(cl.cancel_base, 0)
  );

  -- A fully cancelled invoice must give back its rounding adjustment too,
  -- otherwise cancelled_value could never equal net_total.
  if v_is_full then
    v_value := v_inv.net_total - v_inv.cancelled_value;
  end if;

  -- ---------------------------------------------------------------------------
  -- Release any payment this cancellation would strand, newest allocation
  -- first. The money returns to the party's on-account balance by virtue of
  -- no longer being allocated.
  -- ---------------------------------------------------------------------------
  select coalesce(sum(amount), 0) into v_allocated
    from public.credit_allocation where invoice_id = p_invoice_id;

  v_excess := v_allocated - (v_inv.net_total - v_inv.cancelled_value - v_value);

  if v_excess > 0 then
    for r in
      select id, amount from public.credit_allocation
       where invoice_id = p_invoice_id
       order by created_at desc, id desc
    loop
      exit when v_excess <= 0;

      if r.amount <= v_excess then
        delete from public.credit_allocation where id = r.id;
        v_excess   := v_excess - r.amount;
        v_released := v_released + r.amount;
      else
        update public.credit_allocation
           set amount = r.amount - v_excess where id = r.id;
        v_released := v_released + v_excess;
        v_excess   := 0;
      end if;
    end loop;
  end if;

  -- ---------------------------------------------------------------------------
  -- Write the cancellation document
  -- ---------------------------------------------------------------------------
  v_doc_no := app.next_doc_no('INVOICE_CANCELLATION');

  insert into public.invoice_cancellation
    (doc_no, invoice_id, cancellation_date, is_full, cancelled_value, reason, created_by)
  values
    (v_doc_no, p_invoice_id, current_date, v_is_full, v_value, p_reason, v_user)
  returning id into v_can_id;

  insert into public.invoice_cancellation_line
    (cancellation_id, invoice_line_id, product_id, qty_base, cancelled_value)
  select v_can_id, invoice_line_id, product_id, cancel_base, value_now
    from pg_temp._can_lines;

  -- Stock back in, as free stock. It does not return to the order's reservation.
  select array_agg(distinct product_id) into v_ids from pg_temp._can_lines;
  perform app.lock_products(v_ids);

  insert into public.stock_ledger
    (product_id, movement_date, qty_in, rate, doc_type, doc_id, doc_line_id, created_by)
  select cl.product_id, current_date, cl.cancel_base, 0,
         'SALE_CANCEL', v_can_id, cl.invoice_line_id, v_user
    from pg_temp._can_lines cl;

  update public.sales_invoice_line sil
     set qty_cancelled_base = sil.qty_cancelled_base + cl.cancel_base
    from pg_temp._can_lines cl
   where sil.id = cl.invoice_line_id;

  update public.sales_invoice
     set cancelled_value = cancelled_value + v_value,
         status = case
                    when v_is_full then 'CANCELLED'::app.invoice_status
                    else 'PARTIALLY_CANCELLED'::app.invoice_status
                  end
   where id = p_invoice_id;

  return jsonb_build_object(
    'cancellation_id', v_can_id, 'doc_no', v_doc_no,
    'cancelled_value', v_value, 'is_full', v_is_full,
    'payment_released_to_on_account', v_released);
end;
$$;

-- =============================================================================
-- Grants
-- =============================================================================

grant execute on function
  public.post_purchase(uuid, date, jsonb, numeric, text, date, text),
  public.create_sales_order(uuid, date, jsonb, text),
  public.modify_sales_order(uuid, jsonb),
  public.cancel_sales_order(uuid, text),
  public.reinstate_sales_order(uuid),
  public.create_sales_invoice(date, jsonb, uuid, uuid, numeric, numeric, text),
  public.cancel_sales_invoice(uuid, text, jsonb),
  public.post_opening_stock()
to authenticated;

-- expire_stale_orders is for the scheduler, not for clients.
revoke all on function public.expire_stale_orders() from authenticated;
