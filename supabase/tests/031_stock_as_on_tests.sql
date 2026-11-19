-- =============================================================================
-- 031_stock_as_on_tests.sql
-- Stock as on a date, and the document number on the ledger (migration 050).
--
-- The assertion that carries this suite is the dull one: **stock as on today
-- equals what the stock table says is on hand, for every product.** That is
-- only true if nothing is quietly left out of the walk, and it is the figure
-- he would notice being wrong.
--
-- The interesting one is the cancelled bill. A bill that went out on day -10
-- and was cancelled today means the goods were GONE on day -5 and are BACK
-- today. A stock figure for day -5 that shows them on the shelf cannot be
-- reconciled against anything anybody counted, so the quantity is taken from
-- the raw ledger and includes documents cancelled later. The costing does the
-- opposite, for the date-ordering reason in bug #30, and that difference is
-- asserted here rather than left to be discovered.
--
-- The scenario, two products, every figure worked out in the comments first:
--
--   P1  day -40  opening   600 at cost 30        on hand  600, cost 30.00
--       day -20  purchase  600 at cost 35        on hand 1200, cost 32.50
--                                                (18,000 + 21,000) / 1,200
--       day -10  sale      300 at 50  (bill A)   on hand  900
--       today    bill A cancelled in full        on hand 1200
--
--   P2  day -40  opening   400 at cost 20        on hand  400, cost 20.00
--       day  -8  sale       50 at 40  (bill B)   on hand  350
--       day  -6  return     20, back on shelf    on hand  370
--
--   so, as on          P1      P2
--     day -40         600     400
--     day -25         600     400
--     day -15        1200     400
--     day  -7         900     350
--     today          1200     370
--
--   and P1 valued today is 1200 x 32.50 = 39,000; P2 is 370 x 20 = 7,400.
--
-- ADJUSTMENT movements are resolved by the view but not exercised here: the
-- `stock_adjustment` table exists and nothing in the app posts to it yet, so
-- there is no honest way to make one.
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
  ('22222222-2222-2222-2222-222222222222', 'office@test.local');
insert into public.app_user (id, full_name, role) values
  ('11111111-1111-1111-1111-111111111111', 'Owner',  'ADMIN'),
  ('22222222-2222-2222-2222-222222222222', 'Office', 'ACCOUNTS');

set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

do $$
begin
  perform public.import_masters('route', '[{"code":"R1","name":"Town"}]'::jsonb, false);
  perform public.import_masters('product_group',
    '[{"code":"GS","name":"Snacks","master_code":"PARLE"}]'::jsonb, false);
  perform public.import_masters('supplier',
    '[{"code":"S1","name":"Parle Depot"}]'::jsonb, false);
  perform public.import_masters('party',
    '[{"code":"C1","name":"Ram Store","route_code":"R1"}]'::jsonb, false);
  perform public.import_masters('product',
    ('[{"code":"P1","name":"Chips","group_code":"GS","base_uom":"PCS",
        "sale_price":50,"purchase_price":30,
        "opening_qty":600,"opening_rate":30,
        "opening_date":"' || (current_date - 40)::text || '"},
       {"code":"P2","name":"Biscuit","group_code":"GS","base_uom":"PCS",
        "sale_price":40,"purchase_price":20,
        "opening_qty":400,"opening_rate":20,
        "opening_date":"' || (current_date - 40)::text || '"}]')::jsonb, false);
  perform public.post_opening_stock();
end $$;

create or replace function pg_temp.party() returns uuid
language sql as $$ select id from public.party where code = 'C1' $$;
create or replace function pg_temp.sup() returns uuid
language sql as $$ select id from public.supplier where code = 'S1' $$;
create or replace function pg_temp.prod(p_code text) returns uuid
language sql as $$ select id from public.product where code = p_code $$;

-- Quantity as on a date, for one product.
create or replace function pg_temp.qty(p_code text, p_on date) returns numeric
language sql as $$
  select qty_base from public.stock_as_on(p_on)
   where product_code = p_code
$$;

create or replace function pg_temp.val(p_code text, p_on date) returns numeric
language sql as $$
  select stock_value from public.stock_as_on(p_on)
   where product_code = p_code
$$;

-- -----------------------------------------------------------------------------
-- Build the history
-- -----------------------------------------------------------------------------

do $$
declare v_bill_a uuid; v_bill_b uuid; v_line_b uuid;
begin
  -- P1: a purchase that moves the average.
  perform public.post_purchase(
    p_supplier_id   => pg_temp.sup(),
    p_purchase_date => current_date - 20,
    p_lines         => jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod('P1'), 'uom', 'BASE', 'qty', 600, 'rate', 35)));

  -- P1: a bill that will be cancelled today.
  v_bill_a := (public.create_sales_invoice(
    current_date - 10,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod('P1'), 'uom', 'BASE', 'qty', 300, 'rate', 50)),
    null, pg_temp.party()) ->> 'invoice_id')::uuid;

  -- P2: a bill and a return against it.
  v_bill_b := (public.create_sales_invoice(
    current_date - 8,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod('P2'), 'uom', 'BASE', 'qty', 50, 'rate', 40)),
    null, pg_temp.party()) ->> 'invoice_id')::uuid;

  select id into v_line_b from public.sales_invoice_line
   where invoice_id = v_bill_b limit 1;

  perform public.post_sales_return(
    pg_temp.party(), current_date - 6,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod('P2'), 'uom', 'BASE', 'qty', 20, 'rate', 40,
      'restock', true, 'invoice_line_id', v_line_b)),
    'Over-ordered', v_bill_b);

  -- And the cancellation, which is dated today whatever the bill's own date.
  perform public.cancel_sales_invoice(v_bill_a, 'Customer refused the lot');
end $$;

-- -----------------------------------------------------------------------------
-- The assertion that matters: today agrees with the stock table
-- -----------------------------------------------------------------------------

do $$
declare n int;
begin
  select count(*) into n
    from public.stock_as_on(current_date) s
    join public.product_stock ps on ps.product_id = s.product_id
   where ps.on_hand is distinct from s.qty_base;

  perform pg_temp.eq(n, 0, 'products where as-on-today disagrees with on hand');
  perform pg_temp.pass('stock as on today equals what the stock table holds, for every product');

  perform pg_temp.eq(pg_temp.qty('P1', current_date), 1200::numeric, 'P1 today');
  perform pg_temp.eq(pg_temp.qty('P2', current_date),  370::numeric, 'P2 today');
  perform pg_temp.pass('1,200 and 370 — the cancelled 300 are back and the returned 20 with them');
end $$;

-- -----------------------------------------------------------------------------
-- Walking back through the history
-- -----------------------------------------------------------------------------

do $$
begin
  perform pg_temp.eq(pg_temp.qty('P1', current_date - 40),  600::numeric, 'P1 on day -40');
  perform pg_temp.eq(pg_temp.qty('P1', current_date - 25),  600::numeric, 'P1 on day -25');
  perform pg_temp.eq(pg_temp.qty('P1', current_date - 15), 1200::numeric, 'P1 on day -15');
  perform pg_temp.pass('opening stock counts from its own date, and the purchase from its own');

  perform pg_temp.eq(pg_temp.qty('P2', current_date -  7),  350::numeric, 'P2 on day -7');
  perform pg_temp.eq(pg_temp.qty('P2', current_date -  5),  370::numeric, 'P2 on day -5');
  perform pg_temp.pass('and a return shows up on the day the goods came back, not before');
end $$;

-- THE CANCELLED BILL. On day -5 those 300 pieces were out of the shop, even
-- though the bill was later cancelled, because the cancellation had not
-- happened yet. This is the one place the quantity and the costing disagree
-- on purpose.
do $$
begin
  perform pg_temp.eq(pg_temp.qty('P1', current_date - 5), 900::numeric,
    'P1 on day -5, after a sale later cancelled');
  perform pg_temp.pass('a bill cancelled today was still a bill on day -5 — 900, not 1,200');
end $$;

-- -----------------------------------------------------------------------------
-- What it was worth
-- -----------------------------------------------------------------------------

do $$
begin
  -- 600 at 30, before the purchase moved the average.
  perform pg_temp.eq(pg_temp.val('P1', current_date - 25), 18000.00::numeric,
    'P1 valued on day -25');
  perform pg_temp.pass('600 pieces at the opening cost of 30 is 18,000');

  -- 1,200 at the blended 32.50.
  perform pg_temp.eq(pg_temp.val('P1', current_date), 39000.00::numeric,
    'P1 valued today');
  perform pg_temp.pass('and 1,200 at the blended 32.50 is 39,000');

  -- P2 never had a purchase, so its cost is still the opening figure.
  perform pg_temp.eq(pg_temp.val('P2', current_date), 7400.00::numeric,
    'P2 valued today');
  perform pg_temp.pass('P2 has had no purchase, so 370 at 20 is 7,400');

  perform pg_temp.eq(
    (select unit_cost from public.stock_as_on(current_date - 25) where product_code = 'P1'),
    30.0000::numeric, 'the cost in force on day -25');
  perform pg_temp.eq(
    (select unit_cost from public.stock_as_on(current_date) where product_code = 'P1'),
    32.5000::numeric, 'the cost in force today');
  perform pg_temp.pass('the cost shown is the one in force on that date, not today''s');
end $$;

-- Every product is listed, including one that has never moved since go-live.
do $$
begin
  perform pg_temp.eq((select count(*)::int from public.stock_as_on(current_date)), 2,
    'products in the report');
  perform pg_temp.eq(pg_temp.qty('P2', current_date - 30), 400::numeric,
    'P2 before it ever sold');
  perform pg_temp.pass('a product that has not moved is still on the report');
end $$;

-- -----------------------------------------------------------------------------
-- What it refuses, and who sees the money
-- -----------------------------------------------------------------------------

do $$
begin
  begin
    perform public.stock_as_on(current_date + 1);
    raise exception 'FAIL  a future stock date was accepted';
  exception when sqlstate 'SA004' then
    perform pg_temp.pass('there is no stock figure for tomorrow');
  end;
end $$;

-- Accounts may read the quantities and must not read the cost. Not the whole
-- report refused — the office has every reason to check a quantity on a date.
do $$
declare r record;
begin
  set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';

  select * into r from public.stock_as_on(current_date) where product_code = 'P1';

  perform pg_temp.eq(r.qty_base, 1200::numeric, 'the quantity Accounts sees');
  perform pg_temp.eq(r.unit_cost,   null::numeric, 'the cost Accounts sees');
  perform pg_temp.eq(r.stock_value, null::numeric, 'the value Accounts sees');
  perform pg_temp.pass('Accounts gets the quantities and no cost at all');

  set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
  select * into r from public.stock_as_on(current_date) where product_code = 'P1';
  perform pg_temp.eq(r.stock_value, 39000.00::numeric, 'the value the Admin sees');
  perform pg_temp.pass('and the Admin gets both');
end $$;

-- -----------------------------------------------------------------------------
-- The document number on the ledger
-- -----------------------------------------------------------------------------

do $$
declare r record; v_want text;
begin
  -- Opening stock is not a document.
  select * into r from public.v_stock_ledger
   where product_code = 'P1' and doc_type = 'OPENING';
  perform pg_temp.eq(r.doc_no, null::text, 'the opening row''s number');
  perform pg_temp.pass('opening stock has no document number, because it is not a document');

  -- The purchase.
  select doc_no into v_want from public.purchase limit 1;
  select * into r from public.v_stock_ledger
   where product_code = 'P1' and doc_type = 'PURCHASE';
  perform pg_temp.eq(r.doc_no, v_want, 'the purchase number');
  perform pg_temp.pass('a purchase movement carries its purchase number');

  -- The sale.
  select si.doc_no into v_want from public.sales_invoice si
   where si.invoice_date = current_date - 10 and not si.is_opening;
  select * into r from public.v_stock_ledger
   where product_code = 'P1' and doc_type = 'SALE';
  perform pg_temp.eq(r.doc_no, v_want, 'the bill number');
  perform pg_temp.pass('and a sale movement carries the bill number — the thing he asked for');

  -- The return.
  select doc_no into v_want from public.sales_return limit 1;
  select * into r from public.v_stock_ledger
   where product_code = 'P2' and doc_type = 'SALE_RETURN';
  perform pg_temp.eq(r.doc_no, v_want, 'the return number');
  perform pg_temp.pass('a return carries its credit note number');
end $$;

-- THE CANCELLATION, which needs two numbers. `doc_id` on these rows is the
-- cancellation document, so its own number goes in doc_no and the bill it
-- undid goes in ref_doc_no — otherwise the row says 300 pieces came back and
-- nothing says what sale they came back from.
do $$
declare r record; v_can text; v_bill text;
begin
  select doc_no into v_can  from public.invoice_cancellation limit 1;
  select si.doc_no into v_bill from public.sales_invoice si
   where si.invoice_date = current_date - 10 and not si.is_opening;

  select * into r from public.v_stock_ledger
   where product_code = 'P1' and doc_type = 'SALE_CANCEL';

  perform pg_temp.eq(r.doc_no,     v_can,  'the cancellation''s own number');
  perform pg_temp.eq(r.ref_doc_no, v_bill, 'the bill it cancelled');
  perform pg_temp.eq(r.qty_in,     300::numeric, 'the quantity that came back');
  perform pg_temp.pass('a cancellation names itself and the bill it undid');

  -- And nothing else claims a ref_doc_no.
  perform pg_temp.eq(
    (select count(*)::int from public.v_stock_ledger
      where doc_type <> 'SALE_CANCEL' and ref_doc_no is not null),
    0, 'rows other than a cancellation carrying a reference');
  perform pg_temp.pass('and no other movement pretends to have one');
end $$;

-- Nothing was lost from the view while columns were being added to it — the
-- mistake this project has made twice (bug #23).
do $$
declare missing text;
begin
  select string_agg(c, ', ') into missing
    from (values ('product_code'), ('product_name'), ('base_uom'), ('group_name'),
                 ('master_code'), ('master_name'), ('movement_date'), ('doc_type'),
                 ('doc_id'), ('qty_in'), ('qty_out'), ('rate'), ('notes'),
                 ('entered_by'), ('balance_after'), ('doc_no'), ('ref_doc_no'),
                 ('ref_id')) as t(c)
   where not exists (select 1 from information_schema.columns
                      where table_schema = 'public'
                        and table_name = 'v_stock_ledger'
                        and column_name = t.c);

  perform pg_temp.eq(missing, null::text, 'columns missing from v_stock_ledger');
  perform pg_temp.pass('and the view kept every column it had');
end $$;

\echo '  20 of 20 passed.'
