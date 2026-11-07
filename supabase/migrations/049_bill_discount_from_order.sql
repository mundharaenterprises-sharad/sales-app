-- =============================================================================
-- 049_bill_discount_from_order.sql
-- A bill raised from an order keeps the order's bill-wide discount.
--
-- Run this in the Supabase SQL Editor. Committing it to git does nothing to
-- the database.
--
-- WHAT WENT WRONG. There are two ways to bill an order. Through the bill
-- screen, which reads the order's bill-wide discount, fills the box in and
-- passes it on. And through the Orders screen, selecting orders and billing
-- them in a run — which passed a hardcoded **zero**. So the discount the rep
-- agreed on the whole order was dropped, and the shop was charged more than
-- it was quoted, with nothing on the bill to say a discount had ever existed.
--
-- The per-LINE discounts carried on both paths, which is what made this hard
-- to see: a bill came out with discounts on it, just not all of them.
-- Reproduced before fixing, the same order billed both ways:
--
--                                  line disc   bill-wide disc      net
--   through the bill screen          100.00          147.00     4,753.00
--   through the Orders screen        100.00            0.00     4,900.00
--
-- This is what he reported on 1 October — "some bills had lost their order's
-- discount" — and it stayed unfound because it is not visible in the database
-- alone. Nothing was wrong with any stored value. The caller simply did not
-- pass one.
--
-- THE FIX, AND WHY IT IS HERE AND NOT ONLY IN THE APP. Changing the Orders
-- screen to pass the figure would fix today's bug and leave tomorrow's in
-- place: every new screen that bills an order would have to remember, and
-- there is no test that can catch forgetting. So the rule moves into the
-- engine, where there is one of it:
--
--   **A caller that says nothing at all about the bill-wide discount, on a
--   bill raised from an order, gets the order's own percentage.**
--
-- Saying nothing is both arguments null — which is now also what the defaults
-- are. An explicit 0 still means no discount, so a bill the office
-- deliberately strips the discount off stays stripped, and the bill screen,
-- which always sends what is in its box, is unaffected.
--
-- A PERCENTAGE, not an amount, for the reason percentages have always been
-- what travels here: an amount agreed on 100 pieces is wrong on a bill for 60.
-- `sales_order.bill_discount_pct` is filled in by 029 whichever way the
-- discount was entered, so there is always a percentage to carry.
--
-- `modify_sales_order` has followed this exact rule since 029 — "left out
-- entirely, the order keeps the discount it already had". The billing side
-- simply never did.
--
-- WHAT THIS DOES NOT DO. It does not touch bills already raised. Those are
-- immutable by design and some have been paid against. What to do about them
-- is a decision, not a migration: `supabase/deploy/check_order_discounts.sql`
-- lists every one and what it is short by.
--
-- Both functions are rebuilt in full from their latest definitions — the core
-- from 040, the wrapper from 032 — with one line of logic changed and the two
-- defaults. The diff was printed and read before this was shipped. Neither
-- signature changes, so there is no overload to drop.
--
-- Safe to run twice.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. The engine
-- -----------------------------------------------------------------------------

create or replace function app.create_sales_invoice_core(
  p_invoice_date         date,
  p_lines                jsonb,
  p_order_id             uuid    default null,
  p_party_id             uuid    default null,
  p_bill_discount_amount numeric default null,
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
  v_bill_pct   numeric;
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
      -- See 039. Rounded to what the columns hold before any total is
      -- computed from them: a rate of 2200/60 arrives here with seventeen
      -- digits, is stored with four, and the two do not agree on 250 pieces.
      round(x.qty, 4)                        as qty,
      round(coalesce(x.rate, sol.rate), 4)   as rate,
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

  -- A CALLER THAT SAYS NOTHING AT ALL inherits the order's own bill-wide
  -- discount. Saying nothing is both arguments null; an explicit 0 still means
  -- no discount, so a bill the office deliberately strips the discount off
  -- stays stripped. This is the same rule `modify_sales_order` has always
  -- followed, and it is why the discount is now carried in one place rather
  -- than by whichever screen happens to be calling.
  if p_bill_discount_amount is null
     and p_bill_discount_pct is null
     and p_order_id is not null then
    select so.bill_discount_pct into v_bill_pct
      from public.sales_order so
     where so.id = p_order_id;
  else
    v_bill_pct := p_bill_discount_pct;
  end if;

  v_bill_disc := coalesce(
    nullif(p_bill_discount_amount, 0),
    round((v_gross - v_line_disc) * coalesce(v_bill_pct, 0) / 100, 2)
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
-- 2. The public wrapper, for the default only
-- -----------------------------------------------------------------------------
-- Unchanged apart from `p_bill_discount_amount` defaulting to null instead of
-- 0, so that omitting it means "nothing said" here too. Its cash-sale half is
-- untouched.

create or replace function public.create_sales_invoice(
  p_invoice_date         date,
  p_lines                jsonb,
  p_order_id             uuid    default null,
  p_party_id             uuid    default null,
  p_bill_discount_amount numeric default null,
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

comment on function app.create_sales_invoice_core(date, jsonb, uuid, uuid, numeric, numeric, text) is
  'Raises a bill, from an order or as a counter sale. A caller that passes
   neither bill-discount argument, on a bill from an order, inherits the
   order''s bill_discount_pct; an explicit 0 means no discount. See 049.';

notify pgrst, 'reload schema';
