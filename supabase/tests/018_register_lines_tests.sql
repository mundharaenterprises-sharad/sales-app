-- =============================================================================
-- 018_register_lines_tests.sql
-- The line-level sales register (migration 034).
--
-- The one thing that must hold: the product summary and the bill list are two
-- views of the same sales. If they ever disagree about a total, somebody sends
-- the company a figure the office cannot reproduce.
-- =============================================================================

\set QUIET on
set client_min_messages = notice;

create or replace function pg_temp.pass(msg text) returns void
language plpgsql as $$ begin raise notice 'PASS  %', msg; end; $$;

create or replace function pg_temp.eq(got anyelement, want anyelement, what text)
returns void language plpgsql as $$
begin
  if got is distinct from want then
    raise exception 'FAIL  %: expected %, got %', what, want, got;
  end if;
end; $$;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'admin@test.local'),
  ('22222222-2222-2222-2222-222222222222', 'ram@test.local');
insert into public.app_user (id, full_name, role) values
  ('11111111-1111-1111-1111-111111111111', 'Office', 'ADMIN'),
  ('22222222-2222-2222-2222-222222222222', 'Ram Bahadur', 'REP');

create or replace function pg_temp.be(p_user uuid) returns void
language plpgsql as $$
begin execute format('set request.jwt.claim.sub = %L', p_user); end; $$;

select pg_temp.be('11111111-1111-1111-1111-111111111111');

do $$
begin
  perform public.import_masters('route', '[{"code":"R1","name":"Town"}]'::jsonb, false);
  perform public.import_masters('product_group',
    '[{"code":"GB","name":"Biscuits","master_code":"PARLE"}]'::jsonb, false);
  perform public.import_masters('party',
    '[{"code":"C1","name":"Ram Store","route_code":"R1"},
      {"code":"C2","name":"Shyam Store","route_code":"R1"}]'::jsonb, false);
  -- 40 to a carton, so 100 pieces is 2 cartons and 20 loose — the example
  -- Sharad gave, and the only interesting case for the split.
  perform public.import_masters('product',
    '[{"code":"P1","name":"Parle G 42gm","group_code":"GB","base_uom":"PCS",
       "pack_uom":"CTN","pack_size":"40","sale_price":"10","pack_price":"400",
       "opening_qty":"5000","opening_price":"8","opening_date":"2026-04-01"},
      {"code":"P2","name":"Krackjack","group_code":"GB","base_uom":"PCS",
       "sale_price":"20","opening_qty":"5000","opening_price":"16",
       "opening_date":"2026-04-01"}]'::jsonb, false);
  perform public.post_opening_stock();
end $$;

create or replace function pg_temp.pid(c text) returns uuid
language sql stable as $$ select id from public.product where code = c; $$;
create or replace function pg_temp.party(c text) returns uuid
language sql stable as $$ select id from public.party where code = c; $$;


-- =============================================================================
-- 1. A line carries everything the register filters by
-- =============================================================================
do $$
declare r jsonb; v_inv uuid; l record;
begin
  r := public.create_sales_invoice(current_date,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.pid('P1'), 'uom', 'BASE', 'qty', 100, 'rate', 10)),
    null, pg_temp.party('C1'));
  v_inv := (r ->> 'invoice_id')::uuid;

  select * into l from public.v_sales_register_lines where invoice_id = v_inv;
  perform pg_temp.eq(l.party_name, 'Ram Store', 'the line names the customer');
  perform pg_temp.eq(l.route_name, 'Town', 'and the route');
  perform pg_temp.eq(l.master_code, 'PARLE', 'and the master group');
  perform pg_temp.eq(l.product_code, 'P1', 'and the product');
  perform pg_temp.eq(l.qty_base, 100::numeric, 'and what went out, in base units');
  perform pg_temp.eq(l.pack_size, 40::numeric, 'and how many to a pack');
  perform pg_temp.eq(l.pack_uom, 'CTN', 'and what the pack is called');
  perform pg_temp.eq(l.net_amount, 1000::numeric, 'and what it came to');

  perform pg_temp.pass('a line carries every column the register filters by');
end $$;


-- =============================================================================
-- 2. The product totals add up to the bill totals — the whole point
-- =============================================================================
do $$
declare v_lines numeric; v_bills numeric;
begin
  -- A second bill, a second party, two products, one of them discounted.
  perform public.create_sales_invoice(current_date,
    jsonb_build_array(
      jsonb_build_object('product_id', pg_temp.pid('P1'), 'uom', 'PACK',
                         'qty', 3, 'rate', 400, 'line_discount_pct', 5),
      jsonb_build_object('product_id', pg_temp.pid('P2'), 'uom', 'BASE',
                         'qty', 7, 'rate', 20)),
    null, pg_temp.party('C2'), 50);

  select coalesce(sum(net_amount), 0) into v_lines
    from public.v_sales_register_lines;
  select coalesce(sum(net_total), 0) into v_bills
    from public.v_sales_register where status <> 'CANCELLED';

  -- Rounding on the bill is a bill-level adjustment and belongs to no line,
  -- so the comparison is against the figure before it.
  declare v_round numeric;
  begin
    select coalesce(sum(round_off), 0) into v_round
      from public.sales_invoice where status <> 'CANCELLED';
    perform pg_temp.eq(v_lines, v_bills - v_round,
      'the lines and the bills agree on the money');
  end;

  perform pg_temp.pass('product totals reconcile to bill totals');
end $$;


-- =============================================================================
-- 3. Cancelled bills are out of both, and a part-cancelled line is reduced
-- =============================================================================
do $$
declare
  r jsonb; v_inv uuid; v_line uuid; v_qty numeric; v_amt numeric; n integer;
begin
  r := public.create_sales_invoice(current_date,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.pid('P2'), 'uom', 'BASE', 'qty', 10, 'rate', 20)),
    null, pg_temp.party('C1'));
  v_inv := (r ->> 'invoice_id')::uuid;
  select id into v_line from public.sales_invoice_line where invoice_id = v_inv;

  -- Take 4 of the 10 back.
  perform public.cancel_sales_invoice(v_inv, 'Short delivered',
    jsonb_build_array(jsonb_build_object('invoice_line_id', v_line, 'qty_base', 4)));

  select qty_base, net_amount into v_qty, v_amt
    from public.v_sales_register_lines where invoice_id = v_inv;
  perform pg_temp.eq(v_qty, 6::numeric, 'a part-cancelled line shows what was kept');
  perform pg_temp.eq(v_amt, 120::numeric, 'and is worth only that much');

  -- Now cancel the rest, and the line should leave entirely.
  perform public.cancel_sales_invoice(v_inv, 'Returned');
  select count(*) into n from public.v_sales_register_lines where invoice_id = v_inv;
  perform pg_temp.eq(n, 0, 'a fully cancelled bill contributes nothing');

  perform pg_temp.pass('cancellations are taken off the product totals');
end $$;


-- =============================================================================
-- 4. The rep is the one who took the order, as the register means it
-- =============================================================================
do $$
declare r jsonb; v_order uuid; v_line uuid; v_inv uuid; l record; b record;
begin
  perform pg_temp.be('22222222-2222-2222-2222-222222222222');
  r := public.create_sales_order(pg_temp.party('C1'), current_date,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.pid('P1'), 'uom', 'BASE', 'qty', 5, 'rate', 10)));
  v_order := (r ->> 'order_id')::uuid;
  select id into v_line from public.sales_order_line where order_id = v_order;

  -- Billed by the office, but sold by the rep.
  perform pg_temp.be('11111111-1111-1111-1111-111111111111');
  r := public.create_sales_invoice(current_date,
    jsonb_build_array(jsonb_build_object(
      'order_line_id', v_line, 'product_id', pg_temp.pid('P1'),
      'uom', 'BASE', 'qty', 5, 'rate', 10)),
    v_order);
  v_inv := (r ->> 'invoice_id')::uuid;

  select * into l from public.v_sales_register_lines where invoice_id = v_inv;
  select * into b from public.v_sales_register where invoice_id = v_inv;

  perform pg_temp.eq(l.rep_name, 'Ram Bahadur', 'the line credits the rep who sold it');
  perform pg_temp.eq(l.rep_name, b.rep_name, 'and agrees with the bill list');
  perform pg_temp.eq(l.created_by_name, 'Office', 'while still recording who billed it');

  perform pg_temp.pass('the rep on a line is the rep on the bill');
end $$;


-- =============================================================================
-- 5. One product, many bills: the summary is the sum
-- =============================================================================
do $$
declare v_qty numeric; v_val numeric;
begin
  select sum(qty_base), sum(net_amount) into v_qty, v_val
    from public.v_sales_register_lines
   where product_code = 'P1';

  -- 100 + (3 x 40) + 5 = 225 pieces of Parle G across three bills.
  perform pg_temp.eq(v_qty, 225::numeric, 'the quantity is the sum across bills');
  if v_val <= 0 then
    raise exception 'FAIL  the value should be above zero, got %', v_val;
  end if;

  -- 225 pieces at 40 to the carton is 5 cartons and 25 loose, which is the
  -- arithmetic the report does. Proved here so the rule is written down.
  perform pg_temp.eq(floor(v_qty / 40)::int, 5, 'five full cartons');
  perform pg_temp.eq((v_qty % 40)::int, 25, 'and twenty-five loose');

  perform pg_temp.pass('a product''s total is the sum across every bill');
end $$;


-- =============================================================================
-- 6. A product with no pack is not forced into one
-- =============================================================================
do $$
declare l record;
begin
  select * into l from public.v_sales_register_lines
   where product_code = 'P2' limit 1;

  if l.pack_uom is not null then
    raise exception 'FAIL  a product sold only loose should have no pack unit, got %',
      l.pack_uom;
  end if;
  perform pg_temp.eq(l.pack_size, 1::numeric, 'and a pack size of one');

  perform pg_temp.pass('a product with no pack reports none');
end $$;

\echo '  6 of 6 passed.'
