-- =============================================================================
-- 014_order_discount_tests.sql
-- Discounts on orders, and how they reach the bill (migration 029).
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
  ('11111111-1111-1111-1111-111111111111', 'admin@test.local');
insert into public.app_user (id, full_name, role) values
  ('11111111-1111-1111-1111-111111111111', 'Admin User', 'ADMIN');
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

do $$
begin
  perform public.import_masters('route', '[{"code":"R1","name":"Town"}]'::jsonb, false);
  perform public.import_masters('product_group',
    '[{"code":"GC","name":"Candy","master_code":"CURRENT"}]'::jsonb, false);
  perform public.import_masters('party',
    '[{"code":"C1","name":"Ram Store","route_code":"R1"}]'::jsonb, false);
  perform public.import_masters('product',
    '[{"code":"P1","name":"Banana Candy","group_code":"GC","base_uom":"PCS",
       "sale_price":"20","opening_qty":"1000","opening_price":"16",
       "opening_date":"2026-04-01"},
      {"code":"P2","name":"Mango Candy","group_code":"GC","base_uom":"PCS",
       "sale_price":"10","opening_qty":"1000","opening_price":"8",
       "opening_date":"2026-04-01"}]'::jsonb, false);
  perform public.post_opening_stock();
end $$;

create or replace function pg_temp.pid(p_code text) returns uuid
language sql stable as $$ select id from public.product where code = p_code; $$;


-- =============================================================================
-- 1. A percentage on a line becomes an amount, and both are kept
-- =============================================================================
do $$
declare v_party uuid; r jsonb; v_order uuid;
begin
  select id into v_party from public.party where code = 'C1';

  r := public.create_sales_order(v_party, current_date,
    jsonb_build_array(
      jsonb_build_object('product_id', pg_temp.pid('P1'), 'uom', 'BASE',
                         'qty', 100, 'rate', 20, 'line_discount_pct', 5),
      jsonb_build_object('product_id', pg_temp.pid('P2'), 'uom', 'BASE',
                         'qty', 50, 'rate', 10)));
  v_order := (r ->> 'order_id')::uuid;

  perform pg_temp.eq((select line_discount_amount from public.sales_order_line
                       where order_id = v_order and line_no = 1),
                     100::numeric, '5% of 2,000 is 100');
  perform pg_temp.eq((select line_discount_pct from public.sales_order_line
                       where order_id = v_order and line_no = 1),
                     5::numeric, 'and the percentage is kept as typed');
  perform pg_temp.eq((select line_discount_amount from public.sales_order_line
                       where order_id = v_order and line_no = 2),
                     0::numeric, 'a line without a discount gets none');

  perform pg_temp.eq((select gross_value from public.v_sales_order_summary
                       where order_id = v_order),
                     2500::numeric, 'gross before discount');
  perform pg_temp.eq((select order_value from public.v_sales_order_summary
                       where order_id = v_order),
                     2400::numeric, 'and the order is worth what was quoted');
  perform pg_temp.pass('a percentage on a line becomes an amount, both kept');
end $$;


-- =============================================================================
-- 2. An amount typed instead gets its percentage worked out
--
-- This is what makes a part-bill possible later: the percentage is the thing
-- that can be split, so it has to exist even when nobody typed one.
-- =============================================================================
do $$
declare v_party uuid; r jsonb; v_order uuid;
begin
  select id into v_party from public.party where code = 'C1';

  r := public.create_sales_order(v_party, current_date,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.pid('P1'), 'uom', 'BASE', 'qty', 100, 'rate', 20,
      'line_discount_amount', 200)));
  v_order := (r ->> 'order_id')::uuid;

  perform pg_temp.eq((select line_discount_amount from public.sales_order_line
                       where order_id = v_order),
                     200::numeric, 'the amount is kept as typed');
  perform pg_temp.eq((select line_discount_pct from public.sales_order_line
                       where order_id = v_order),
                     10::numeric, 'and 200 off 2,000 is worked out as 10%');
  perform pg_temp.pass('an amount gets its percentage worked out');
end $$;


-- =============================================================================
-- 3. A discount on the whole order, both ways round
-- =============================================================================
do $$
declare v_party uuid; r jsonb; v_a uuid; v_b uuid;
begin
  select id into v_party from public.party where code = 'C1';

  -- As a percentage.
  r := public.create_sales_order(v_party, current_date,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.pid('P1'), 'uom', 'BASE', 'qty', 50, 'rate', 20)),
    null, 0, 10);
  v_a := (r ->> 'order_id')::uuid;

  perform pg_temp.eq((select bill_discount_amount from public.sales_order where id = v_a),
                     100::numeric, '10% of 1,000');
  perform pg_temp.eq((select order_value from public.v_sales_order_summary where order_id = v_a),
                     900::numeric, 'and the order is worth 900');

  -- As an amount.
  r := public.create_sales_order(v_party, current_date,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.pid('P1'), 'uom', 'BASE', 'qty', 50, 'rate', 20)),
    null, 250);
  v_b := (r ->> 'order_id')::uuid;

  perform pg_temp.eq((select bill_discount_amount from public.sales_order where id = v_b),
                     250::numeric, 'the amount as typed');
  perform pg_temp.eq((select bill_discount_pct from public.sales_order where id = v_b),
                     25::numeric, 'with its percentage worked out');
  perform pg_temp.pass('an order-level discount works as a percentage or an amount');
end $$;


-- =============================================================================
-- 4. A discount cannot be bigger than what it comes off
-- =============================================================================
do $$
declare v_party uuid; v_msg text;
begin
  select id into v_party from public.party where code = 'C1';

  begin
    perform public.create_sales_order(v_party, current_date,
      jsonb_build_array(jsonb_build_object(
        'product_id', pg_temp.pid('P1'), 'uom', 'BASE', 'qty', 10, 'rate', 20,
        'line_discount_amount', 500)));
    raise exception 'FAIL  a line discount larger than the line was accepted';
  exception when sqlstate 'SA004' then
    get stacked diagnostics v_msg = message_text;
  end;
  if v_msg not like '%larger than the line%' then
    raise exception 'FAIL  unexpected message: %', v_msg;
  end if;

  begin
    perform public.create_sales_order(v_party, current_date,
      jsonb_build_array(jsonb_build_object(
        'product_id', pg_temp.pid('P1'), 'uom', 'BASE', 'qty', 10, 'rate', 20)),
      null, 5000);
    raise exception 'FAIL  an order discount larger than the order was accepted';
  exception when sqlstate 'SA004' then
    get stacked diagnostics v_msg = message_text;
  end;
  if v_msg not like '%larger than the order%' then
    raise exception 'FAIL  unexpected message: %', v_msg;
  end if;

  perform pg_temp.pass('a discount cannot exceed what it comes off');
end $$;


-- =============================================================================
-- 5. Changing an order changes its discounts, and keeps them when not told to
-- =============================================================================
do $$
declare v_party uuid; r jsonb; v_order uuid;
begin
  select id into v_party from public.party where code = 'C1';

  r := public.create_sales_order(v_party, current_date,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.pid('P1'), 'uom', 'BASE', 'qty', 50, 'rate', 20)),
    null, 0, 10);
  v_order := (r ->> 'order_id')::uuid;

  -- Lines changed, discount not mentioned: the order keeps what it had.
  perform public.modify_sales_order(v_order,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.pid('P1'), 'uom', 'BASE', 'qty', 60, 'rate', 20)));

  perform pg_temp.eq((select bill_discount_amount from public.sales_order where id = v_order),
                     100::numeric, 'the discount survives a change it was not part of');

  -- Now change it explicitly.
  perform public.modify_sales_order(v_order,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.pid('P1'), 'uom', 'BASE', 'qty', 60, 'rate', 20,
      'line_discount_pct', 5)),
    0, 5);

  perform pg_temp.eq((select line_discount_amount from public.sales_order_line
                       where order_id = v_order),
                     60::numeric, '5% of 1,200 on the line');
  perform pg_temp.eq((select bill_discount_amount from public.sales_order where id = v_order),
                     57::numeric, 'and 5% of the 1,140 left after it');
  perform pg_temp.eq((select order_value from public.v_sales_order_summary
                       where order_id = v_order),
                     1083::numeric, 'leaving 1,083');
  perform pg_temp.pass('modifying an order handles its discounts');
end $$;


-- =============================================================================
-- 6. The discount reaches the bill, and survives being billed in halves
--
-- The reason percentages travel rather than amounts. A rep quotes 10% on 100
-- pieces; the office bills 60 now and 40 later. Both bills must carry 10%,
-- and the two together must come to what the rep quoted.
-- =============================================================================
do $$
declare v_party uuid; r jsonb; v_order uuid; v_line uuid;
        v_inv1 uuid; v_inv2 uuid;
begin
  select id into v_party from public.party where code = 'C1';

  r := public.create_sales_order(v_party, current_date,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.pid('P1'), 'uom', 'BASE', 'qty', 100, 'rate', 20,
      'line_discount_pct', 10)));
  v_order := (r ->> 'order_id')::uuid;
  select id into v_line from public.sales_order_line where order_id = v_order;

  perform pg_temp.eq((select order_value from public.v_sales_order_summary
                       where order_id = v_order),
                     1800::numeric, 'the rep quoted 1,800');

  -- Sixty now, carrying the percentage the billing screen reads off the order.
  r := public.create_sales_invoice(current_date,
        jsonb_build_array(jsonb_build_object(
          'order_line_id', v_line, 'product_id', pg_temp.pid('P1'),
          'uom', 'BASE', 'qty', 60, 'rate', 20,
          'line_discount_pct', (select line_discount_pct from public.v_order_line_billing
                                 where order_line_id = v_line))),
        v_order, null);
  v_inv1 := (r ->> 'invoice_id')::uuid;

  perform pg_temp.eq((select net_total from public.sales_invoice where id = v_inv1),
                     1080::numeric, '60 at 20 less 10% is 1,080');

  -- Forty later.
  r := public.create_sales_invoice(current_date,
        jsonb_build_array(jsonb_build_object(
          'order_line_id', v_line, 'product_id', pg_temp.pid('P1'),
          'uom', 'BASE', 'qty', 40, 'rate', 20,
          'line_discount_pct', (select line_discount_pct from public.v_order_line_billing
                                 where order_line_id = v_line))),
        v_order, null);
  v_inv2 := (r ->> 'invoice_id')::uuid;

  perform pg_temp.eq((select net_total from public.sales_invoice where id = v_inv2),
                     720::numeric, 'and the rest is 720');

  perform pg_temp.eq(
    (select sum(net_total) from public.sales_invoice where id in (v_inv1, v_inv2)),
    1800::numeric, 'the two bills together are exactly what the rep quoted');

  perform pg_temp.pass('a percentage survives a part bill, and the halves add up');
end $$;


-- =============================================================================
-- 7. The day book shows an order at what it was quoted for
-- =============================================================================
do $$
declare v_party uuid; r jsonb; v_order uuid;
begin
  select id into v_party from public.party where code = 'C1';

  r := public.create_sales_order(v_party, current_date,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.pid('P2'), 'uom', 'BASE', 'qty', 10, 'rate', 10,
      'line_discount_pct', 20)));
  v_order := (r ->> 'order_id')::uuid;

  perform pg_temp.eq((select amount from public.v_day_book
                       where doc_id = v_order and doc_type = 'ORDER'),
                     80::numeric, 'the day book shows 80, not 100');
  perform pg_temp.pass('the day book shows an order net of its discount');
end $$;


-- =============================================================================
-- 8. An order with no discount behaves exactly as it always did
-- =============================================================================
do $$
declare v_party uuid; r jsonb; v_order uuid;
begin
  select id into v_party from public.party where code = 'C1';

  r := public.create_sales_order(v_party, current_date,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.pid('P2'), 'uom', 'BASE', 'qty', 10, 'rate', 10)));
  v_order := (r ->> 'order_id')::uuid;

  perform pg_temp.eq((select order_value from public.v_sales_order_summary
                       where order_id = v_order),
                     100::numeric, 'worth its gross');
  perform pg_temp.eq((select discount_value from public.v_sales_order_summary
                       where order_id = v_order),
                     0::numeric, 'with nothing taken off');
  perform pg_temp.eq((select line_discount_pct from public.sales_order_line
                       where order_id = v_order),
                     null, 'and no percentage invented for it');
  perform pg_temp.pass('an order without discounts is unchanged');
end $$;


\echo 'All order discount tests passed.'
