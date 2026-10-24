-- =============================================================================
-- 026_profitability_tests.sql
-- What each item earned, at weighted average cost (migration 043).
--
-- Every number below is worked out by hand in the comments before it, because
-- a costing test that only compares the code against itself proves nothing.
-- The whole point of the figure is that somebody will make a pricing decision
-- on it.
--
-- The scenario, one product, in order:
--
--   day -40  opening   600 pcs at cost 30      on hand 600, average 30.00
--   day -20  purchase  600 pcs at cost 35      on hand 1200, average 32.50
--                                              (18,000 + 21,000) / 1,200
--   day -10  sale      300 pcs at 50           earned 15,000, cost  9,750.00
--   day  -5  purchase  360 pcs at cost 40      on hand 1260, average 34.6429
--                                              (900 x 32.50 + 360 x 40) / 1260
--   day  -2  sale      200 pcs at 55           earned 11,000, cost  6,928.58
--   day  -1  return      50 pcs, back on shelf earned -2,750, cost -1,732.15
--   day  -1  return      20 pcs, written off   earned -1,100, cost      0.00
--
--   earned 22,150.00   cost 14,946.43   margin 7,203.57
--
-- A sale does not move the average — it takes quantity and value away in the
-- same proportion — which is why the 300 pcs sold on day -10 are costed at the
-- average set on day -20 and the average on day -5 is computed from the 900
-- that were left.
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

-- Opening stock has to carry an opening_rate or it enters at nothing. That is
-- not a hypothetical: `opening_rate` is an optional import column and defaults
-- to 0, so a sheet that left it out puts stock in at zero cost and makes the
-- first months look wildly profitable. `check_cost_basis.sql` is the script
-- that finds it on live data.
do $$
begin
  perform public.import_masters('route', '[{"code":"R1","name":"Town"}]'::jsonb, false);
  perform public.import_masters('product_group',
    '[{"code":"GS","name":"Snacks","master_code":"PARLE"},
      {"code":"GB","name":"Biscuits","master_code":"CURRENT"}]'::jsonb, false);
  perform public.import_masters('supplier',
    '[{"code":"S1","name":"Parle Depot"}]'::jsonb, false);
  perform public.import_masters('party',
    '[{"code":"C1","name":"Ram Store","route_code":"R1"}]'::jsonb, false);
  perform public.import_masters('product',
    ('[{"code":"P1","name":"Chips","group_code":"GS","base_uom":"PCS",
        "pack_uom":"CTN","pack_size":60,"sale_price":3000,"purchase_price":1800,
        "opening_qty":600,"opening_rate":30,
        "opening_date":"' || (current_date - 40)::text || '"},
       {"code":"P2","name":"Biscuit","group_code":"GB","base_uom":"PCS",
        "pack_uom":"CTN","pack_size":40,"sale_price":1600,"purchase_price":1200,
        "opening_qty":400,"opening_rate":30,
        "opening_date":"' || (current_date - 40)::text || '"}]')::jsonb, false);
  perform public.post_opening_stock();
end $$;

create or replace function pg_temp.party() returns uuid
language sql as $$ select id from public.party where code = 'C1' $$;
create or replace function pg_temp.sup() returns uuid
language sql as $$ select id from public.supplier where code = 'S1' $$;
create or replace function pg_temp.prod(p_code text) returns uuid
language sql as $$ select id from public.product where code = p_code $$;

create or replace function pg_temp.cost(p_code text) returns numeric
language sql as $$
  select unit_cost from app.v_cost_events
   where product_id = pg_temp.prod(p_code)
   order by event_no desc limit 1
$$;

-- -----------------------------------------------------------------------------
-- The average cost, step by step
-- -----------------------------------------------------------------------------

do $$
begin
  perform pg_temp.eq(pg_temp.cost('P1'), 30::numeric, 'cost after opening stock');
  perform pg_temp.pass('opening stock sets the first cost — 30.00');
end $$;

-- 600 at 30 plus 600 at 35 = 39,000 over 1,200 = 32.50
do $$
begin
  perform public.post_purchase(
    p_supplier_id   => pg_temp.sup(),
    p_purchase_date => current_date - 20,
    p_lines         => jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod('P1'), 'uom', 'PACK', 'qty', 10, 'rate', 2100)));

  perform pg_temp.eq(pg_temp.cost('P1'), 32.5::numeric, 'cost after the first purchase');
  perform pg_temp.pass('a purchase at 35 against stock at 30 averages to 32.50');
end $$;

do $$
begin
  perform public.create_sales_invoice(
    current_date - 10,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod('P1'), 'uom', 'BASE', 'qty', 300, 'rate', 50)),
    null, pg_temp.party());

  perform pg_temp.eq(pg_temp.cost('P1'), 32.5::numeric, 'cost after a sale');
  perform pg_temp.pass('and a sale does not move it — 32.50 still');
end $$;

-- 900 left at 32.50 = 29,250, plus 360 at 40 = 14,400, over 1,260 = 34.642857
do $$
begin
  perform public.post_purchase(
    p_supplier_id   => pg_temp.sup(),
    p_purchase_date => current_date - 5,
    p_lines         => jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod('P1'), 'uom', 'PACK', 'qty', 6, 'rate', 2400)));

  perform pg_temp.eq(pg_temp.cost('P1'), 34.6429::numeric,
    'cost after the second purchase');
  perform pg_temp.pass('the second purchase averages against what was LEFT, not what was bought');
end $$;

-- -----------------------------------------------------------------------------
-- The margin on each sale
-- -----------------------------------------------------------------------------

do $$
declare r record;
begin
  select * into r from public.profit_lines()
   where kind = 'SALE' and doc_date = current_date - 10;

  perform pg_temp.eq(r.qty_base, 300::numeric, 'quantity on the first sale');
  perform pg_temp.eq(r.net_sales, 15000::numeric, 'what the first sale earned');
  perform pg_temp.eq(r.cost_amount, 9750::numeric, 'what the first sale cost');
  perform pg_temp.eq(r.margin, 5250::numeric, 'the margin on the first sale');
  perform pg_temp.pass('300 at 50 against cost 32.50 — earned 15,000, margin 5,250');
end $$;

do $$
declare r record;
begin
  perform public.create_sales_invoice(
    current_date - 2,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod('P1'), 'uom', 'BASE', 'qty', 200, 'rate', 55)),
    null, pg_temp.party());

  select * into r from public.profit_lines()
   where kind = 'SALE' and doc_date = current_date - 2;

  perform pg_temp.eq(r.net_sales, 11000::numeric, 'what the second sale earned');
  perform pg_temp.eq(r.cost_amount, 6928.58::numeric, 'what the second sale cost');
  perform pg_temp.eq(r.margin, 4071.42::numeric, 'the margin on the second sale');
  perform pg_temp.pass('200 at 55 against cost 34.6429 — cost 6,928.58, margin 4,071.42');
end $$;

-- -----------------------------------------------------------------------------
-- Goods coming back
-- -----------------------------------------------------------------------------

do $$
declare v_line uuid; r record;
begin
  select sil.id into v_line
    from public.sales_invoice_line sil
    join public.sales_invoice si on si.id = sil.invoice_id
   where si.invoice_date = current_date - 2;

  perform public.post_sales_return(
    pg_temp.party(), current_date - 1,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod('P1'), 'invoice_line_id', v_line,
      'uom', 'BASE', 'qty', 50, 'rate', 55, 'restock', true)),
    'Over-ordered');

  select * into r from public.profit_lines()
   where kind = 'RETURN' and net_sales = -2750;

  perform pg_temp.eq(r.qty_base, -50::numeric, 'the returned quantity');
  perform pg_temp.eq(r.cost_amount, -1732.15::numeric, 'the cost put back');
  perform pg_temp.eq(r.margin, -1017.85::numeric, 'the margin given back');
  perform pg_temp.pass('50 back on the shelf gives back the credit AND the cost');

  -- Still 34.6429: goods coming back do NOT re-enter at the price they were
  -- sold for, which is what the stock ledger records against a return.
  perform pg_temp.eq(pg_temp.cost('P1'), 34.6429::numeric,
    'the average cost after a return');
  perform pg_temp.pass('and a return at a selling rate of 55 leaves cost alone');
end $$;

-- The one case where a product's margin can go properly negative and nothing
-- is wrong: the customer is credited and the goods are gone.
do $$
declare v_line uuid; r record;
begin
  select sil.id into v_line
    from public.sales_invoice_line sil
    join public.sales_invoice si on si.id = sil.invoice_id
   where si.invoice_date = current_date - 2;

  perform public.post_sales_return(
    pg_temp.party(), current_date - 1,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod('P1'), 'invoice_line_id', v_line,
      'uom', 'BASE', 'qty', 20, 'rate', 55, 'restock', false)),
    'Crushed in transit');

  select * into r from public.profit_lines()
   where kind = 'RETURN' and net_sales = -1100;

  perform pg_temp.eq(r.cost_amount, 0::numeric, 'cost relief on a write-off');
  perform pg_temp.eq(r.margin, -1100::numeric, 'the margin on a write-off');
  perform pg_temp.pass('a written-off return costs the credit and keeps the cost spent');
end $$;

-- -----------------------------------------------------------------------------
-- The totals, which are what he will actually read
-- -----------------------------------------------------------------------------

do $$
declare r record;
begin
  select sum(net_sales) as sales, sum(cost_amount) as cost, sum(margin) as margin
    into r from public.profit_lines();

  perform pg_temp.eq(r.sales,  22150::numeric,   'everything earned');
  perform pg_temp.eq(r.cost,   14946.43::numeric, 'everything it cost');
  perform pg_temp.eq(r.margin, 7203.57::numeric,  'the margin overall');
  perform pg_temp.pass('the whole period adds up — 22,150 less 14,946.43 is 7,203.57');
end $$;

-- Earnings less cost, line by line, must equal the margin column. Cheap, and
-- it is the one way a rounding slip in either column shows itself.
do $$
declare n int;
begin
  select count(*) into n from public.profit_lines()
   where margin is distinct from (net_sales - cost_amount);
  perform pg_temp.eq(n, 0, 'lines where the margin does not match its own columns');
  perform pg_temp.pass('margin equals earnings less cost on every line');
end $$;

-- -----------------------------------------------------------------------------
-- Grouping
-- -----------------------------------------------------------------------------
-- The report rolls up by product group and by master group, so both have to be
-- on every row and both have to be right.

do $$
declare r record;
begin
  perform public.create_sales_invoice(
    current_date - 3,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod('P2'), 'uom', 'BASE', 'qty', 100, 'rate', 45)),
    null, pg_temp.party());

  select sum(margin) as m into r from public.profit_lines() where group_code = 'GB';
  -- 100 at 45 = 4,500, cost 100 at 30 = 3,000.
  perform pg_temp.eq(r.m, 1500::numeric, 'the Biscuits margin');

  select sum(margin) as m into r from public.profit_lines() where master_code = 'PARLE';
  perform pg_temp.eq(r.m, 7203.57::numeric, 'the Parle margin');
  perform pg_temp.pass('rolls up by product group and by master group');
end $$;

-- -----------------------------------------------------------------------------
-- A date range means the document's own date
-- -----------------------------------------------------------------------------
-- A return dated when the goods came back belongs to that period, not to the
-- period of the bill it came off — the same rule stock already follows.

do $$
declare r record;
begin
  select coalesce(sum(net_sales), 0) as sales, count(*) as lines
    into r from public.profit_lines(current_date - 1, current_date - 1);

  perform pg_temp.eq(r.lines, 2::bigint, 'documents dated yesterday');
  perform pg_temp.eq(r.sales, -3850::numeric, 'what yesterday earned');
  perform pg_temp.pass('a return falls in the period it came back in');
end $$;

do $$
declare n bigint;
begin
  select count(*) into n from public.profit_lines(current_date - 11, current_date - 9);
  perform pg_temp.eq(n, 1::bigint, 'documents in a three-day window');
  perform pg_temp.pass('and a date range only returns what is in it');
end $$;

-- -----------------------------------------------------------------------------
-- A cancelled bill earns nothing, and a part-cancelled one earns the rest
-- -----------------------------------------------------------------------------

do $$
declare v_inv uuid; v_before numeric; v_after numeric;
begin
  select coalesce(sum(margin), 0) into v_before from public.profit_lines();

  select si.id into v_inv from public.sales_invoice si
   where si.invoice_date = current_date - 3;
  perform public.cancel_sales_invoice(v_inv, 'Entered against the wrong shop');

  select coalesce(sum(margin), 0) into v_after from public.profit_lines();
  perform pg_temp.eq(v_after, v_before - 1500, 'the margin after cancelling');
  perform pg_temp.pass('a cancelled bill stops counting entirely');
end $$;

-- -----------------------------------------------------------------------------
-- Admin only, in the database
-- -----------------------------------------------------------------------------
-- The point of doing this here rather than hiding a menu item: a view nobody
-- links to is still a URL, and the office can read anything the office's token
-- can read.

do $$
begin
  set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
  begin
    perform * from public.profit_lines();
    raise exception 'FAIL  Accounts could read the profitability figures';
  exception when sqlstate 'SA003' then
    perform pg_temp.pass('Accounts cannot read it — cost is Admin only');
  end;

  set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
  begin
    perform * from public.profit_lines();
    raise exception 'FAIL  a rep could read the profitability figures';
  exception when sqlstate 'SA003' then
    perform pg_temp.pass('nor can a rep');
  end;

  set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
  perform * from public.profit_lines();
  perform pg_temp.pass('and the Admin can');
end $$;

-- Cost has also come off the one place Accounts could see it before.
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public'
                and table_name = 'v_product_sales'
                and column_name in ('est_cost', 'est_margin')) then
    raise exception 'FAIL  the indicative margin is still on v_product_sales';
  end if;
  perform pg_temp.pass('the old indicative margin is gone from Product sales');
end $$;

-- And the master group survived the rebuild of that view — the mistake 043
-- was specifically avoiding.
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public'
                    and table_name = 'v_product_sales'
                    and column_name = 'master_code') then
    raise exception 'FAIL  rebuilding v_product_sales lost the master group';
  end if;
  perform pg_temp.pass('and rebuilding it did not lose the master group');
end $$;

\echo '  20 of 20 passed.'
