-- =============================================================================
-- 030_bill_discount_from_order_tests.sql
-- A bill raised from an order keeps the order's bill-wide discount (049).
--
-- This is the suite for a bug that lived in the CALLER, not in the database.
-- Nothing stored was ever wrong: the Orders screen billed with a hardcoded
-- zero where the order's discount should have gone, so the shop was charged
-- more than it was quoted and the bill looked fine because its LINE discounts
-- had carried. No database test could have caught that, which is the reason
-- the rule moved into the engine — so that there is something to assert.
--
-- The three cases, and all three matter:
--
--   nothing said      both arguments null, on a bill from an order
--                     -> the order's percentage is applied
--   a figure given    the bill screen sending what is in its box
--                     -> that figure, and the order is not consulted
--   an explicit zero  the office stripping the discount off this bill
--                     -> no discount, and it STAYS off
--
-- The third is not a technicality. If "nothing said" and "no discount" were
-- the same thing, there would be no way to remove a discount from one bill.
--
-- One product, one price, no purchases, so every figure below is arithmetic
-- anybody can check:
--
--   order     100 pcs at 50 = 5,000, line discount 2% = 100, order-wide 3%
--   so a full bill is       5,000 - 100 = 4,900, less 3% = 147  ->  4,753
--   and a 60-piece bill is  3,000 -  60 = 2,940, less 3% =  88.20 -> 2,852
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
  ('11111111-1111-1111-1111-111111111111', 'Owner', 'ADMIN');

set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

do $$
begin
  perform public.import_masters('route', '[{"code":"R1","name":"Town"}]'::jsonb, false);
  perform public.import_masters('product_group',
    '[{"code":"GS","name":"Snacks","master_code":"PARLE"}]'::jsonb, false);
  perform public.import_masters('party',
    '[{"code":"C1","name":"Ram Store","route_code":"R1"}]'::jsonb, false);
  perform public.import_masters('product',
    ('[{"code":"P1","name":"Chips","group_code":"GS","base_uom":"PCS",
        "sale_price":50,"purchase_price":30,
        "opening_qty":9000,"opening_rate":30,
        "opening_date":"' || (current_date - 40)::text || '"}]')::jsonb, false);
  perform public.post_opening_stock();
end $$;

create or replace function pg_temp.party() returns uuid
language sql as $$ select id from public.party where code = 'C1' $$;
create or replace function pg_temp.prod() returns uuid
language sql as $$ select id from public.product where code = 'P1' $$;

-- An order of 100 at 50, 2% off the line and 3% off the order.
create or replace function pg_temp.an_order() returns uuid
language plpgsql as $$
declare v_o uuid;
begin
  v_o := (public.create_sales_order(
            pg_temp.party(), current_date - 3,
            jsonb_build_array(jsonb_build_object(
              'product_id', pg_temp.prod(), 'uom', 'BASE',
              'qty', 100, 'rate', 50, 'line_discount_pct', 2)),
            null, 0, 3) ->> 'order_id')::uuid;
  return v_o;
end $$;

-- The lines the app sends when billing an order, for a given quantity.
create or replace function pg_temp.bill_lines(p_order uuid, p_qty numeric)
returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object(
    'product_id', pg_temp.prod(), 'uom', 'BASE',
    'qty', p_qty, 'rate', 50, 'line_discount_pct', 2,
    'order_line_id', (select id from public.sales_order_line
                       where order_id = p_order limit 1)))
$$;

create or replace function pg_temp.bill(p_id uuid) returns public.sales_invoice
language sql as $$ select * from public.sales_invoice where id = p_id $$;

-- -----------------------------------------------------------------------------
-- The order itself
-- -----------------------------------------------------------------------------

do $$
declare v_o uuid; r record;
begin
  v_o := pg_temp.an_order();
  select * into r from public.sales_order where id = v_o;

  perform pg_temp.eq(r.bill_discount_pct, 3::numeric, 'the order-wide percentage');
  -- 029 fills in the other one whichever way it was entered, which is what
  -- guarantees there is always a percentage for a bill to carry.
  perform pg_temp.eq(r.bill_discount_amount, 147::numeric, 'the order-wide amount');
  perform pg_temp.pass('an order stores the bill-wide discount as both a percentage and an amount');
end $$;

-- -----------------------------------------------------------------------------
-- Nothing said: the bug this migration is about
-- -----------------------------------------------------------------------------

do $$
declare v_o uuid; v_inv uuid; r public.sales_invoice;
begin
  v_o := pg_temp.an_order();
  v_inv := (public.create_sales_invoice(
    current_date - 2, pg_temp.bill_lines(v_o, 100),
    v_o, null, null, null, null) ->> 'invoice_id')::uuid;

  r := pg_temp.bill(v_inv);
  perform pg_temp.eq(r.gross_total,          5000::numeric, 'gross');
  perform pg_temp.eq(r.line_discount_total,   100::numeric, 'the line discount');
  perform pg_temp.eq(r.bill_discount_amount,  147::numeric, 'the bill-wide discount');
  perform pg_temp.eq(r.net_total,            4753::numeric, 'what the shop owes');
  perform pg_temp.pass('a caller that says nothing gets the order''s 3% — 147, net 4,753');
end $$;

-- The discount has to reach the LINES too, or the cost side of profitability
-- and the per-line figures on the printed bill disagree with the total.
do $$
declare v_o uuid; v_inv uuid;
begin
  v_o := pg_temp.an_order();
  v_inv := (public.create_sales_invoice(
    current_date - 2, pg_temp.bill_lines(v_o, 100),
    v_o, null, null, null, null) ->> 'invoice_id')::uuid;

  perform pg_temp.eq(
    (select sum(allocated_bill_discount) from public.sales_invoice_line
      where invoice_id = v_inv), 147::numeric, 'the discount allocated to lines');
  perform pg_temp.eq(
    (select sum(effective_amount) from public.sales_invoice_line
      where invoice_id = v_inv), 4753::numeric, 'the lines after everything');
  perform pg_temp.pass('and it is allocated onto the lines, which sum to the same 4,753');
end $$;

-- -----------------------------------------------------------------------------
-- A figure given, and an explicit zero
-- -----------------------------------------------------------------------------

do $$
declare v_o uuid; v_inv uuid; r public.sales_invoice;
begin
  -- The bill screen, box filled in: the same 3%, passed rather than inherited.
  v_o := pg_temp.an_order();
  v_inv := (public.create_sales_invoice(
    current_date - 2, pg_temp.bill_lines(v_o, 100),
    v_o, null, 0, 3, null) ->> 'invoice_id')::uuid;
  r := pg_temp.bill(v_inv);
  perform pg_temp.eq(r.bill_discount_amount, 147::numeric, 'a percentage passed in');
  perform pg_temp.pass('a figure given is used, the same as before');

  -- A different figure, to prove the order is not consulted when one is given.
  v_o := pg_temp.an_order();
  v_inv := (public.create_sales_invoice(
    current_date - 2, pg_temp.bill_lines(v_o, 100),
    v_o, null, 0, 5, null) ->> 'invoice_id')::uuid;
  r := pg_temp.bill(v_inv);
  perform pg_temp.eq(r.bill_discount_amount, 245::numeric, '5% rather than the order''s 3%');
  perform pg_temp.pass('and it overrides the order rather than being added to it');

  -- An amount, not a percentage.
  v_o := pg_temp.an_order();
  v_inv := (public.create_sales_invoice(
    current_date - 2, pg_temp.bill_lines(v_o, 100),
    v_o, null, 200, null, null) ->> 'invoice_id')::uuid;
  r := pg_temp.bill(v_inv);
  perform pg_temp.eq(r.bill_discount_amount, 200::numeric, 'an amount passed in');
  perform pg_temp.pass('an amount is taken as it stands');
end $$;

-- THE ONE THAT KEEPS THE FIX HONEST. If an explicit zero inherited, there
-- would be no way to take a discount off a single bill.
do $$
declare v_o uuid; v_inv uuid; r public.sales_invoice;
begin
  v_o := pg_temp.an_order();
  v_inv := (public.create_sales_invoice(
    current_date - 2, pg_temp.bill_lines(v_o, 100),
    v_o, null, 0, null, null) ->> 'invoice_id')::uuid;

  r := pg_temp.bill(v_inv);
  perform pg_temp.eq(r.bill_discount_amount, 0::numeric, 'an explicit zero');
  perform pg_temp.eq(r.net_total,         4900::numeric, 'what the shop owes');
  perform pg_temp.eq(r.line_discount_total, 100::numeric, 'the line discount still there');
  perform pg_temp.pass('an explicit zero still means no discount — it stays off');
end $$;

-- -----------------------------------------------------------------------------
-- Part of an order
-- -----------------------------------------------------------------------------
-- The reason a PERCENTAGE is what carries and not the 147: an amount agreed on
-- 100 pieces is wrong on a bill for 60, and the two bills have to add up to
-- what was quoted.

do $$
declare v_o uuid; v_first uuid; v_second uuid; r public.sales_invoice;
begin
  v_o := pg_temp.an_order();

  v_first := (public.create_sales_invoice(
    current_date - 2, pg_temp.bill_lines(v_o, 60),
    v_o, null, null, null, null) ->> 'invoice_id')::uuid;

  r := pg_temp.bill(v_first);
  -- 3,000 less 60 = 2,940, less 3% = 88.20
  perform pg_temp.eq(r.bill_discount_amount, 88.20::numeric, 'the discount on 60 pieces');
  perform pg_temp.eq(r.net_total,          2852.00::numeric, 'the first bill');
  perform pg_temp.pass('60 of 100 pieces carries 3% of itself — 88.20, not the whole 147');

  v_second := (public.create_sales_invoice(
    current_date - 1, pg_temp.bill_lines(v_o, 40),
    v_o, null, null, null, null) ->> 'invoice_id')::uuid;

  r := pg_temp.bill(v_second);
  -- 2,000 less 40 = 1,960, less 3% = 58.80
  perform pg_temp.eq(r.bill_discount_amount, 58.80::numeric, 'the discount on the other 40');

  perform pg_temp.eq(
    (select sum(bill_discount_amount) from public.sales_invoice
      where order_id = v_o and status <> 'CANCELLED'), 147.00::numeric,
    'both bills together');
  perform pg_temp.eq(
    (select sum(net_total) from public.sales_invoice
      where order_id = v_o and status <> 'CANCELLED'), 4753.00::numeric,
    'what the shop owes on the whole order');
  perform pg_temp.pass('and billing it in two parts comes to exactly what was quoted');
end $$;

-- -----------------------------------------------------------------------------
-- An order with no discount, and a bill with no order
-- -----------------------------------------------------------------------------

do $$
declare v_o uuid; v_inv uuid; r public.sales_invoice;
begin
  v_o := (public.create_sales_order(
            pg_temp.party(), current_date - 3,
            jsonb_build_array(jsonb_build_object(
              'product_id', pg_temp.prod(), 'uom', 'BASE', 'qty', 100, 'rate', 50)),
            null, 0, null) ->> 'order_id')::uuid;

  v_inv := (public.create_sales_invoice(
    current_date - 2,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod(), 'uom', 'BASE', 'qty', 100, 'rate', 50,
      'order_line_id', (select id from public.sales_order_line
                         where order_id = v_o limit 1))),
    v_o, null, null, null, null) ->> 'invoice_id')::uuid;

  r := pg_temp.bill(v_inv);
  perform pg_temp.eq(r.bill_discount_amount, 0::numeric, 'nothing to inherit');
  perform pg_temp.eq(r.net_total,         5000::numeric, 'the bill');
  perform pg_temp.pass('an order with no discount gives the bill none');

  -- A counter sale has no order to read, and must not fall over looking.
  v_inv := (public.create_sales_invoice(
    current_date - 1,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod(), 'uom', 'BASE', 'qty', 10, 'rate', 50)),
    null, pg_temp.party(), null, null, null) ->> 'invoice_id')::uuid;

  r := pg_temp.bill(v_inv);
  perform pg_temp.eq(r.bill_discount_amount, 0::numeric, 'a counter sale');
  perform pg_temp.eq(r.net_total,          500::numeric, 'the counter sale');
  perform pg_temp.pass('and a bill with no order at all is unaffected');
end $$;

\echo '  11 of 11 passed.'
