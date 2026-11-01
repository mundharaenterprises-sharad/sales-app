-- =============================================================================
-- 029_profit_summary_tests.sql
-- One row per product, whatever the number of bill lines (migration 048).
--
-- The report used to ask for every bill line and add them up in the browser,
-- which silently stopped at the response cap and under-reported every rupee
-- figure while leaving the margin percentage looking right. So the assertion
-- that matters here is not an arithmetic one — 026 already covers the costing.
-- It is that **the summary equals the sum of the lines, product by product**,
-- and that it is ONE ROW per product however many lines went into it.
--
-- The scenario, deliberately many lines for one product:
--
--   day -40  P1 opening  600 pcs at cost 30      no purchases, so cost stays 30
--   day -40  P2 opening  400 pcs at cost 20
--   days -20..-16  FIVE bills of P1, 100 pcs at 50 each
--                        earned 25,000  cost 15,000  margin 10,000  qty 500
--   day -15  P2 one bill, 50 pcs at 40
--                        earned  2,000  cost  1,000  margin  1,000  qty  50
--   day -10  P1 return 20 pcs at 50, back on shelf
--                        earned -1,000  cost   -600  margin   -400  qty -20
--   day  -9  P1 return 10 pcs at 50, written off
--                        earned   -500  cost      0  margin   -500  qty -10
--   day  -5  P1 bill of 100 pcs at 50, then CANCELLED — in neither figure
--
--   P1 total   earned 23,500   cost 14,400   margin 9,100   qty 470
--   P2 total   earned  2,000   cost  1,000   margin 1,000   qty  50
--
-- There are no purchases, so the average cost never moves off the opening
-- figure and every line above can be checked in the head. That is on purpose:
-- this suite is about the shape of the answer, not the costing.
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
  ('22222222-2222-2222-2222-222222222222', 'office@test.local'),
  ('33333333-3333-3333-3333-333333333333', 'rep@test.local');
insert into public.app_user (id, full_name, role) values
  ('11111111-1111-1111-1111-111111111111', 'Owner',  'ADMIN'),
  ('22222222-2222-2222-2222-222222222222', 'Office', 'ACCOUNTS'),
  ('33333333-3333-3333-3333-333333333333', 'Rep',    'REP');

set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

do $$
begin
  perform public.import_masters('route', '[{"code":"R1","name":"Town"}]'::jsonb, false);
  perform public.import_masters('product_group',
    '[{"code":"GS","name":"Snacks","master_code":"PARLE"},
      {"code":"GB","name":"Biscuits","master_code":"CURRENT"}]'::jsonb, false);
  perform public.import_masters('party',
    '[{"code":"C1","name":"Ram Store","route_code":"R1"}]'::jsonb, false);
  perform public.import_masters('product',
    ('[{"code":"P1","name":"Chips","group_code":"GS","base_uom":"PCS",
        "sale_price":50,"purchase_price":30,
        "opening_qty":600,"opening_rate":30,
        "opening_date":"' || (current_date - 40)::text || '"},
       {"code":"P2","name":"Biscuit","group_code":"GB","base_uom":"PCS",
        "sale_price":40,"purchase_price":20,
        "opening_qty":400,"opening_rate":20,
        "opening_date":"' || (current_date - 40)::text || '"}]')::jsonb, false);
  perform public.post_opening_stock();
end $$;

create or replace function pg_temp.party() returns uuid
language sql as $$ select id from public.party where code = 'C1' $$;
create or replace function pg_temp.prod(p_code text) returns uuid
language sql as $$ select id from public.product where code = p_code $$;

-- -----------------------------------------------------------------------------
-- Five bills of one product, one of another
-- -----------------------------------------------------------------------------

do $$
declare i int;
begin
  for i in 0 .. 4 loop
    perform public.create_sales_invoice(
      current_date - 20 + i,
      jsonb_build_array(jsonb_build_object(
        'product_id', pg_temp.prod('P1'), 'uom', 'BASE', 'qty', 100, 'rate', 50)),
      null, pg_temp.party());
  end loop;

  perform public.create_sales_invoice(
    current_date - 15,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod('P2'), 'uom', 'BASE', 'qty', 50, 'rate', 40)),
    null, pg_temp.party());

  perform pg_temp.eq((select count(*)::int from public.profit_lines()), 6,
    'bill lines in the period');
  perform pg_temp.pass('six bill lines across two products');
end $$;

-- -----------------------------------------------------------------------------
-- The whole point: five lines of P1 become one row
-- -----------------------------------------------------------------------------

do $$
declare r record;
begin
  perform pg_temp.eq((select count(*)::int from public.profit_summary()), 2,
    'rows in the summary');
  perform pg_temp.pass('and the summary has two rows, one per product');

  select * into r from public.profit_summary() where product_code = 'P1';

  perform pg_temp.eq(r.qty_base,    500::numeric, 'P1 quantity');
  perform pg_temp.eq(r.net_sales, 25000::numeric, 'P1 earned');
  perform pg_temp.eq(r.cost_amount, 15000::numeric, 'P1 cost');
  perform pg_temp.eq(r.margin,    10000::numeric, 'P1 margin');
  perform pg_temp.pass('five bills of 100 at 50 add up to 25,000 earned on one row');
end $$;

-- Every dimension the report groups or filters by has to survive the grouping,
-- or the master-group filter quietly empties. Bug #23's shape.
do $$
declare r record;
begin
  select * into r from public.profit_summary() where product_code = 'P1';
  perform pg_temp.eq(r.product_name, 'Chips',    'the product name');
  perform pg_temp.eq(r.group_code,   'GS',       'the product group code');
  perform pg_temp.eq(r.group_name,   'Snacks',   'the product group name');
  perform pg_temp.eq(r.master_code,  'PARLE',    'the master group code');
  perform pg_temp.eq(r.master_name,  'Parle',    'the master group name');
  perform pg_temp.eq(r.base_uom,     'PCS',      'the base unit');
  perform pg_temp.pass('and it carries the group, the master group and the unit');
end $$;

-- -----------------------------------------------------------------------------
-- Returns, and a written-off one
-- -----------------------------------------------------------------------------

do $$
declare v_bill uuid;
begin
  select id into v_bill from public.sales_invoice
   where not is_opening and status <> 'CANCELLED'
   order by invoice_date limit 1;

  perform public.post_sales_return(
    pg_temp.party(), current_date - 10,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod('P1'), 'uom', 'BASE', 'qty', 20, 'rate', 50,
      'restock', true,
      'invoice_line_id', (select id from public.sales_invoice_line
                           where invoice_id = v_bill limit 1))),
    'Over-ordered', v_bill);

  perform public.post_sales_return(
    pg_temp.party(), current_date - 9,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod('P1'), 'uom', 'BASE', 'qty', 10, 'rate', 50,
      'restock', false,
      'invoice_line_id', (select id from public.sales_invoice_line
                           where invoice_id = v_bill limit 1))),
    'Damaged in transit', v_bill);
end $$;

do $$
declare r record;
begin
  select * into r from public.profit_summary() where product_code = 'P1';

  -- 25,000 - 1,000 - 500 earned; 15,000 - 600 - 0 cost.
  perform pg_temp.eq(r.qty_base,     470::numeric, 'P1 quantity after returns');
  perform pg_temp.eq(r.net_sales,  23500::numeric, 'P1 earned after returns');
  perform pg_temp.eq(r.cost_amount, 14400::numeric, 'P1 cost after returns');
  perform pg_temp.eq(r.margin,      9100::numeric, 'P1 margin after returns');
  perform pg_temp.pass('returns come off the same row — 23,500 earned, 9,100 margin');

  -- The written-off 10 pieces credited 500 and gave back no cost, so they are
  -- a 500 loss sitting inside that 9,100. Stated as its own assertion because
  -- it is the one case where cost does not follow the goods.
  perform pg_temp.eq(
    (select sum(margin) from public.profit_lines()
      where kind = 'RETURN' and doc_date = current_date - 9),
    -500::numeric, 'the written-off return');
  perform pg_temp.pass('and a written-off return is a straight loss of the credit');
end $$;

-- -----------------------------------------------------------------------------
-- A cancelled bill is in neither
-- -----------------------------------------------------------------------------

do $$
declare v_inv uuid; r record;
begin
  v_inv := (public.create_sales_invoice(
    current_date - 5,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod('P1'), 'uom', 'BASE', 'qty', 100, 'rate', 50)),
    null, pg_temp.party()) ->> 'invoice_id')::uuid;

  perform public.cancel_sales_invoice(v_inv, 'Goods never dispatched');

  select * into r from public.profit_summary() where product_code = 'P1';
  perform pg_temp.eq(r.net_sales, 23500::numeric, 'P1 earned after a cancellation');
  perform pg_temp.eq(r.margin,     9100::numeric, 'P1 margin after a cancellation');
  perform pg_temp.pass('a cancelled bill changes neither figure');
end $$;

-- -----------------------------------------------------------------------------
-- The assertion that keeps the two from drifting apart
-- -----------------------------------------------------------------------------
-- The summary is defined as a sum over the lines, so this cannot fail today.
-- It is here for the day somebody rewrites one of them for speed.

do $$
declare n int;
begin
  select count(*) into n
    from (
      select product_id,
             sum(qty_base)    as q,
             sum(net_sales)   as s,
             sum(cost_amount) as c,
             sum(margin)      as m
        from public.profit_lines()
       group by product_id
    ) l
    full join public.profit_summary() s on s.product_id = l.product_id
   where l.product_id is null
      or s.product_id is null
      or s.qty_base    is distinct from l.q
      or s.net_sales   is distinct from l.s
      or s.cost_amount is distinct from l.c
      or s.margin      is distinct from l.m;

  perform pg_temp.eq(n, 0, 'products where the summary and the lines disagree');
  perform pg_temp.pass('the summary is exactly the lines, product by product');
end $$;

-- A master-group roll-up is what the report shows when it is set to master
-- group, and it is done in the browser from these rows. So it has to come out
-- of the summary the same as out of the lines.
do $$
begin
  perform pg_temp.eq(
    (select sum(margin) from public.profit_summary() where master_code = 'PARLE'),
    (select sum(margin) from public.profit_lines()   where master_code = 'PARLE'),
    'the Parle roll-up');
  perform pg_temp.eq(
    (select sum(net_sales) from public.profit_summary() where master_code = 'CURRENT'),
    2000::numeric, 'the Current roll-up');
  perform pg_temp.pass('and rolls up by master group to the same figures');
end $$;

-- -----------------------------------------------------------------------------
-- The date range
-- -----------------------------------------------------------------------------

do $$
begin
  -- The five P1 bills are days -20 to -16. Asking for -18 onward leaves three.
  perform pg_temp.eq(
    (select net_sales from public.profit_summary(current_date - 18, current_date - 16)
      where product_code = 'P1'),
    15000::numeric, 'P1 earned in a narrowed window');
  perform pg_temp.eq(
    (select count(*)::int from public.profit_summary(current_date - 18, current_date - 16)),
    1, 'rows in a window that only one product sold in');
  perform pg_temp.pass('a date range narrows it, and a product with nothing in the window drops out');
end $$;

-- -----------------------------------------------------------------------------
-- Admin only — inherited, and proved anyway
-- -----------------------------------------------------------------------------

do $$
begin
  set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
  begin
    perform public.profit_summary();
    raise exception 'FAIL  Accounts read the profit summary';
  exception when sqlstate 'SA003' then
    perform pg_temp.pass('Accounts cannot read it');
  end;

  set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
  begin
    perform public.profit_summary();
    raise exception 'FAIL  a rep read the profit summary';
  exception when sqlstate 'SA003' then
    perform pg_temp.pass('nor can a rep');
  end;

  set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
  perform pg_temp.eq((select count(*)::int from public.profit_summary()), 2,
    'the Admin still reads it');
  perform pg_temp.pass('and the Admin does');
end $$;

\echo '  13 of 13 passed.'
