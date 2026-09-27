-- =============================================================================
-- 032_cash_sales_and_order_rounding.sql
--
-- Run this in the Supabase SQL Editor. Committing it to git does nothing to
-- the database.
--
-- Two things.
--
-- 1. AN ORDER ROUNDS LIKE A BILL DOES
--
-- Bills have rounded to the nearest rupee since the beginning, through
-- app_setting.round_invoice_total. Orders never did, so a rep quoted 1,169.60
-- at the counter and the office billed 1,170 — a figure the shopkeeper had not
-- been told. Same setting, same rounding, so the quote and the bill agree.
--
-- The rounding is stored on the order rather than worked out when it is
-- displayed, because what the rep said out loud is a fact about that order and
-- should not change if the setting is ever turned off.
--
-- 2. A BILL CAN BE A CASH SALE
--
-- Until now every bill was credit: the goods went out, the customer owed the
-- money, and somebody entered a payment later. Most counter sales are not like
-- that. The money is handed over as the goods are.
--
-- A cash bill therefore books its own receipt, for its own full amount,
-- against itself, in the same transaction. The customer's dues, the ageing
-- report and the day book's "Received" figure are all right immediately and
-- nobody has to remember a second step. Either both the bill and the payment
-- exist, or neither does.
--
-- What deliberately does NOT happen: cancelling a cash bill does not cancel
-- the receipt. The money physically changed hands, and a cancellation is not
-- a refund. The payment stays on the customer's account as credit against
-- their next bill, which is what the existing cancellation already does with
-- any money applied to a bill. Handing cash back is a decision for a person.
--
-- Correcting a cash bill on the same day is different, and does need work —
-- see part 3.
--
-- Safe to run twice.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Orders round
-- -----------------------------------------------------------------------------

alter table public.sales_order
  add column if not exists round_off numeric(14,2) not null default 0;

comment on column public.sales_order.round_off is
  'What was added or dropped to bring the order to a whole rupee. Stored, not
   derived: it is what the rep quoted.';


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
  v_round    numeric(14,2) := 0;
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

  -- To the nearest rupee, by the same setting that rounds a bill.
  if (app.settings()).round_invoice_total then
    v_round := round(v_net - v_billdisc, 0) - (v_net - v_billdisc);
  end if;

  v_doc_no := app.next_doc_no('SALES_ORDER');

  insert into public.sales_order
    (doc_no, party_id, order_date, status, submitted_at, expires_at, remarks,
     created_by, bill_discount_amount, bill_discount_pct, round_off)
  values
    (v_doc_no, p_party_id, p_order_date, 'SUBMITTED', now(),
     now() + make_interval(days => v_days), p_remarks, v_user,
     v_billdisc,
     coalesce(p_bill_discount_pct,
              case when v_net > 0 and v_billdisc > 0
                   then round(v_billdisc * 100 / v_net, 4) end),
     v_round)
  returning id into v_id;

  insert into public.sales_order_line
    (order_id, line_no, product_id, uom, qty, pack_size, rate,
     line_discount_pct, line_discount_amount)
  select v_id, line_no, product_id, uom, qty, pack_size, rate,
         line_discount_pct, line_discount_amount
    from pg_temp._ord_stage;

  perform app.reserve_for_order(v_id);

  return jsonb_build_object('order_id', v_id, 'doc_no', v_doc_no,
                            'round_off', v_round,
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
  v_round    numeric(14,2) := 0;
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

  if (app.settings()).round_invoice_total then
    v_round := round(v_net - v_billdisc, 0) - (v_net - v_billdisc);
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
         round_off            = v_round,
         bill_discount_pct    = coalesce(
           p_bill_discount_pct,
           case when v_net > 0 and v_billdisc > 0
                then round(v_billdisc * 100 / v_net, 4) end)
   where id = p_order_id;

  return jsonb_build_object('order_id', p_order_id, 'modified', true,
                            'round_off', v_round);
end;
$$;


-- -----------------------------------------------------------------------------
-- 2. Cash sales
-- -----------------------------------------------------------------------------

alter table public.sales_invoice
  add column if not exists is_cash boolean not null default false;

alter table public.sales_invoice
  add column if not exists cash_receipt_id uuid references public.receipt (id);

comment on column public.sales_invoice.is_cash is
  'Paid as it was raised. The receipt that paid it is cash_receipt_id.';
comment on column public.sales_invoice.cash_receipt_id is
  'The receipt this cash bill booked for itself. Named explicitly rather than
   inferred from the allocations, so correcting the bill knows exactly which
   payment belongs to it.';


-- The billing engine itself moves into app.create_sales_invoice_core,
-- byte for byte as migration 013 wrote it. Nothing about how a bill is
-- calculated changes here; it simply stops being the thing the app calls
-- directly, so that the public function can do something afterwards without
-- there being two copies of three hundred lines of pricing to keep in step.
--
-- It is in the app schema because nobody outside this file should call it: a
-- bill raised through it would skip the cash handling below.

create or replace function app.create_sales_invoice_core(
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

revoke all on function
  app.create_sales_invoice_core(date, jsonb, uuid, uuid, numeric, numeric, text)
from public, anon;


create or replace function public.create_sales_invoice(
  p_invoice_date         date,
  p_lines                jsonb,
  p_order_id             uuid    default null,
  p_party_id             uuid    default null,
  p_bill_discount_amount numeric default 0,
  p_bill_discount_pct    numeric default null,
  p_remarks              text    default null,
  p_is_cash              boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_res     jsonb;
  v_id      uuid;
  v_party   uuid;
  v_net     numeric(14,2);
  v_receipt jsonb;
begin
  -- The whole of the original function, unchanged, still does the work. Only
  -- what happens afterwards is new, so there is one implementation of
  -- billing and not two that drift.
  v_res := app.create_sales_invoice_core(
    p_invoice_date, p_lines, p_order_id, p_party_id,
    p_bill_discount_amount, p_bill_discount_pct, p_remarks);

  if not p_is_cash then
    return v_res;
  end if;

  v_id := (v_res ->> 'invoice_id')::uuid;

  select party_id, net_total into v_party, v_net
    from public.sales_invoice where id = v_id;

  -- Paid in full, against itself, now. If this fails the bill fails with it:
  -- a cash sale where the cash was not recorded is not a cash sale.
  v_receipt := public.receive_payment(
    v_party,
    p_invoice_date,
    v_net,
    jsonb_build_array(jsonb_build_object('invoice_id', v_id, 'amount', v_net)),
    app.require_signed_in(),
    'Cash sale');

  update public.sales_invoice
     set is_cash         = true,
         cash_receipt_id = (v_receipt ->> 'receipt_id')::uuid
   where id = v_id;

  return v_res || jsonb_build_object(
    'is_cash',        true,
    'receipt_id',     v_receipt ->> 'receipt_id',
    'receipt_doc_no', v_receipt ->> 'doc_no');
end;
$$;

-- The seven-argument form would otherwise sit alongside the new one and make
-- every call ambiguous.
drop function if exists public.create_sales_invoice(date, jsonb, uuid, uuid, numeric, numeric, text);

revoke all on function
  public.create_sales_invoice(date, jsonb, uuid, uuid, numeric, numeric, text, boolean)
from public, anon;
grant execute on function
  public.create_sales_invoice(date, jsonb, uuid, uuid, numeric, numeric, text, boolean)
to authenticated;


-- -----------------------------------------------------------------------------
-- 3. Correcting a cash bill on the same day
--
-- revise_sales_invoice refuses outright when money has been applied to a bill,
-- and rightly: silently moving somebody's payment around is worse than making
-- them undo it by hand. But a cash bill always has money applied to it — its
-- own — so under that rule a cash sale with a typo in it could never be
-- corrected at all, and the only way out would be a cancellation and a fresh
-- bill with a new number.
--
-- The bill's own receipt is the one payment we can move without asking,
-- because we know exactly what it is for. So it is cancelled, the correction
-- runs as it always has, and the replacement bill books its own fresh receipt
-- for the corrected amount. Any other money on the bill still stops the
-- correction dead.
-- -----------------------------------------------------------------------------

create or replace function public.revise_sales_invoice(
  p_invoice_id           uuid,
  p_lines                jsonb,
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
  v_user    uuid := app.require_back_office();
  v_inv     public.sales_invoice%rowtype;
  v_own     numeric(14,2) := 0;
  v_settled numeric(14,2);
  v_new     jsonb;
begin
  select * into v_inv from public.sales_invoice where id = p_invoice_id for update;

  if not found then
    raise exception 'Unknown bill' using errcode = 'SA005';
  end if;

  if v_inv.status <> 'ACTIVE' then
    raise exception 'Bill % has already been cancelled in part or in full, so it cannot be corrected.',
      v_inv.doc_no using errcode = 'SA002';
  end if;

  if v_inv.invoice_date <> current_date or v_inv.created_at::date <> current_date then
    raise exception 'Bill % was not raised today. Raise a sales return or a cancellation instead.',
      v_inv.doc_no using errcode = 'SA002';
  end if;

  -- Its own cash receipt is ours to move: we know exactly what it was for.
  -- Cancelling it releases what it had applied here, which is what lets the
  -- check below pass. Anyone else's money still stops the correction dead.
  if v_inv.is_cash and v_inv.cash_receipt_id is not null then
    select coalesce(sum(amount), 0) into v_own
      from public.credit_allocation
     where invoice_id = p_invoice_id
       and receipt_id = v_inv.cash_receipt_id;

    perform public.cancel_receipt(
      v_inv.cash_receipt_id,
      'Cash bill ' || v_inv.doc_no || ' corrected on the same day');
  end if;

  select coalesce(sum(amount), 0) into v_settled
    from public.credit_allocation where invoice_id = p_invoice_id;

  if v_settled > 0 then
    raise exception 'Bill % already has % applied to it. Undo the allocation first.',
      v_inv.doc_no, v_settled using errcode = 'SA002';
  end if;

  if jsonb_typeof(coalesce(p_lines, 'null'::jsonb)) <> 'array'
     or jsonb_array_length(p_lines) = 0 then
    raise exception 'A corrected bill still needs at least one line' using errcode = 'SA004';
  end if;

  perform public.cancel_sales_invoice(
    p_invoice_id,
    'Corrected on the same day, replaced by a new bill');

  -- Cancelling a bill deliberately does NOT hand quantities back to its order:
  -- normally a cancellation ends the matter and the goods become free stock.
  -- A correction is the one case where the order should reopen, because the
  -- replacement bill is about to be raised against it. Reservations are
  -- released and retaken around the change so that `reserved` never counts the
  -- same goods twice.
  if v_inv.order_id is not null then
    perform app.release_order_reservation(v_inv.order_id);

    update public.sales_order_line sol
       set qty_invoiced_base = greatest(sol.qty_invoiced_base - x.qty, 0)
      from (select order_line_id, sum(qty_base) as qty
              from public.sales_invoice_line
             where invoice_id = p_invoice_id
               and order_line_id is not null
             group by order_line_id) x
     where sol.id = x.order_line_id;

    update public.sales_order so
       set status = case
                      when exists (select 1 from public.sales_order_line
                                    where order_id = v_inv.order_id
                                      and qty_invoiced_base > 0)
                      then 'PARTIALLY_INVOICED'::app.order_status
                      else 'SUBMITTED'::app.order_status
                    end,
           closed_at = null
     where so.id = v_inv.order_id;

    perform app.reserve_for_order(v_inv.order_id);
  end if;

  v_new := public.create_sales_invoice(
    v_inv.invoice_date,
    p_lines,
    v_inv.order_id,
    case when v_inv.order_id is null then v_inv.party_id end,
    p_bill_discount_amount,
    p_bill_discount_pct,
    coalesce(p_remarks, v_inv.remarks),
    v_inv.is_cash);

  -- The one new line: remember which bill this one replaced.
  update public.sales_invoice
     set replaces_invoice_id = p_invoice_id
   where id = (v_new ->> 'invoice_id')::uuid;

  return v_new || jsonb_build_object(
    'replaced_invoice_id', p_invoice_id,
    'replaced_doc_no',     v_inv.doc_no,
    'cash_re_receipted',   v_own > 0);
end;
$$;

revoke all on function
  public.revise_sales_invoice(uuid, jsonb, numeric, numeric, text) from public, anon;
grant execute on function
  public.revise_sales_invoice(uuid, jsonb, numeric, numeric, text) to authenticated;


-- -----------------------------------------------------------------------------
-- 4. The views that carry these figures
-- -----------------------------------------------------------------------------

drop view if exists public.v_day_summary;
drop view if exists public.v_day_book;
drop view if exists public.v_sales_order_summary;
drop view if exists public.v_pending_orders;

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
  so.round_off,
  greatest(
    coalesce(sum(round(sol.qty * sol.rate, 2) - sol.line_discount_amount), 0)
      - so.bill_discount_amount + so.round_off,
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
      - so.bill_discount_amount + so.round_off,
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

-- Rebuilt unchanged: they only had to go so the views underneath them could be
-- replaced. An order's value in the day book now carries its rounding, because
-- v_sales_order_summary does.
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
-- 5. The bills list has to say which sales were cash
--
-- Otherwise the only way to tell is that the bill shows nothing outstanding,
-- which is also what a credit bill looks like once somebody has paid it. Those
-- are different facts about a business and the list should not blur them.
-- -----------------------------------------------------------------------------

drop view if exists public.v_invoice_list;

create view public.v_invoice_list as
select
  si.id            as invoice_id,
  si.doc_no,
  si.party_id,
  p.code           as party_code,
  p.name           as party_name,
  p.route_id,
  rt.name          as route_name,
  si.master_group_id,
  mg.code          as master_code,
  mg.name          as master_name,
  si.is_opening,
  si.invoice_date,
  si.net_total,
  si.cancelled_value,
  si.effective_total,
  coalesce(ca.allocated, 0)                      as settled,
  si.effective_total - coalesce(ca.allocated, 0) as outstanding,
  current_date - si.invoice_date                 as days_outstanding,
  si.status,
  si.is_cash,
  so.doc_no        as order_no,
  old.doc_no       as replaces_doc_no,
  si.replaces_invoice_id,
  new_one.doc_no   as replaced_by_doc_no,
  new_one.id       as replaced_by_invoice_id
from public.sales_invoice si
join public.party p   on p.id  = si.party_id
join public.route rt  on rt.id = p.route_id
left join public.master_group mg on mg.id = si.master_group_id
left join public.sales_order so on so.id = si.order_id
left join public.sales_invoice old     on old.id = si.replaces_invoice_id
left join public.sales_invoice new_one on new_one.replaces_invoice_id = si.id
left join (
  select invoice_id, sum(amount) as allocated
    from public.credit_allocation
   group by invoice_id
) ca on ca.invoice_id = si.id;
alter view public.v_invoice_list set (security_invoker = true);
grant select on public.v_invoice_list to authenticated;


notify pgrst, 'reload schema';
