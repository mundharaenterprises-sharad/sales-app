-- =============================================================================
-- 040_document_rate_precision.sql
--
-- Run this in the Supabase SQL Editor, after 039. Committing it to git does
-- nothing to the database.
--
-- 039 fixed this for returns. This is the same fault in the other three
-- places it lives: orders, bills and purchases.
--
-- A carton of 60 at 2,200 is 36.666666666666664 a piece, because that is what
-- binary floating point makes of two thirds. The screens divide a carton rate
-- to get a piece rate whenever the quantity is not a whole number of cartons.
-- That number then gets used twice at two different precisions: once for the
-- document's header total, and once through the line's rate column, which is
-- numeric(14,4) and holds 36.6667.
--
-- On small quantities the two agree. On 250 pieces they do not:
--
--     Invoice INV-000001 gross_total 9166.67 <> line sum 9166.68
--
-- and a deferred trigger refuses the whole bill at COMMIT. On screen that is
-- "One of the values is not allowed", with nothing to act on.
--
-- Nobody has hit this on a bill yet. It needs a part-carton quantity of a
-- product whose carton rate does not divide evenly, which is an ordinary
-- Tuesday rather than an edge case, so it is worth closing before it happens
-- rather than after.
--
-- The change is one line in each of four functions: quantities and rates are
-- brought to the four decimal places their columns hold BEFORE any total is
-- computed from them. Then the header and the lines are two sums over the same
-- numbers, which is the only way they can be relied on to agree.
--
-- Nothing else about these functions changes. No signature changes, so
-- existing grants carry over untouched. Safe to run twice. Nothing already
-- stored changes.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- An order as the rep sends it
-- ---------------------------------------------------------------------------

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
    -- Rounded to the four decimal places the columns hold, BEFORE anything is
    -- totalled from them. Otherwise the header is summed from one rate and the
    -- lines from another, and on a large enough quantity they differ by a
    -- paisa — which the deferred total check refuses outright. See 039.
    round(x.qty, 4)                        as qty,
    app.pack_size_for(x.product_id, x.uom) as pack_size,
    round(coalesce(x.rate,
            (select sale_rate from public.product where id = x.product_id)), 4) as rate,
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

-- ---------------------------------------------------------------------------
-- The same order edited (this is 037 plus the rounding, nothing else)
-- ---------------------------------------------------------------------------

create or replace function public.modify_sales_order(
  p_order_id             uuid,
  p_lines                jsonb,
  p_bill_discount_amount numeric default null,
  p_bill_discount_pct    numeric default null,
  -- null: leave the remark as it is. '': clear it. Anything else: replace it.
  p_remarks              text default null
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
    -- Rounded to the four decimal places the columns hold, BEFORE anything is
    -- totalled from them. Otherwise the header is summed from one rate and the
    -- lines from another, and on a large enough quantity they differ by a
    -- paisa — which the deferred total check refuses outright. See 039.
    round(x.qty, 4)                        as qty,
    app.pack_size_for(x.product_id, x.uom) as pack_size,
    round(coalesce(x.rate,
            (select sale_rate from public.product where id = x.product_id)), 4) as rate,
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
         -- The one new line. nullif('') turns a cleared box into a null
         -- remark rather than an empty string, so "no remark" is one thing in
         -- the database and not two.
         remarks              = case when p_remarks is null then remarks
                                     else nullif(btrim(p_remarks), '') end,
         bill_discount_pct    = coalesce(
           p_bill_discount_pct,
           case when v_net > 0 and v_billdisc > 0
                then round(v_billdisc * 100 / v_net, 4) end)
   where id = p_order_id;

  return jsonb_build_object('order_id', p_order_id, 'modified', true,
                            'round_off', v_round);
end;
$$;

-- ---------------------------------------------------------------------------
-- Bills: the one that would have bitten first, since part-carton deliveries
-- are normal and whole-carton ones are the special case
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Purchases, for completeness: rates here are typed by hand so they rarely
-- have more than two decimals, but the fault is identical
-- ---------------------------------------------------------------------------

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
    -- Rounded to the four decimal places the columns hold, BEFORE anything is
    -- totalled from them. Otherwise the header is summed from one rate and the
    -- lines from another, and on a large enough quantity they differ by a
    -- paisa — which the deferred total check refuses outright. See 039.
    round(x.qty, 4)                             as qty,
    app.pack_size_for(x.product_id, x.uom)      as pack_size,
    round(x.rate, 4)                            as rate
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

notify pgrst, 'reload schema';
