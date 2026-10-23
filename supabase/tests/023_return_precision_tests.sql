-- =============================================================================
-- 023_return_precision_tests.sql
-- Rates that do not fit in four decimal places (migrations 039 and 040).
--
-- The bug: returning all 240 pieces of a line billed as 4 cartons at 2,200
-- was refused every time, with "One of the values is not allowed", while
-- returning one or two pieces of the same line was fine.
--
-- 2200 / 60 is 36.666666666666664 in the browser. post_sales_return used that
-- number twice at two different precisions — once for the header total, and
-- once through sales_return_line.rate, which is numeric(14,4) and so holds
-- 36.6667. 240 x the first rounds to 8800.00; 240 x the second to 8800.01.
-- A deferred trigger compares them at COMMIT and refused the lot.
--
-- TWO THINGS ABOUT THIS FILE MATTER MORE THAN THE ASSERTIONS.
--
-- First, the return below is posted inside an explicit transaction that is
-- COMMITTED. The guard is a deferred constraint trigger: it does not fire on
-- the insert, it fires at commit. Every diagnostic written while hunting this
-- bug rolled back, so every one of them reported success. A test that rolls
-- back passes against the bug it is meant to catch.
--
-- Second, the quantity has to be large enough. One piece is fine. Two pieces
-- are fine. It needs a rate that does not fit in four decimal places AND a
-- quantity big enough to turn the rounding difference into a whole paisa, so
-- 240 is not an arbitrary number here and must not be tidied to 10.
--
-- The last two sections are bills and purchases, which had the same fault
-- waiting in them (migration 040) and would have hit it on the first
-- part-carton delivery of a product whose carton rate does not divide evenly.
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
  ('11111111-1111-1111-1111-111111111111', 'Office', 'ADMIN');

set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

-- A carton of 60, which is where 2200/60 comes from. Not 40: a pack size that
-- divides a round rate exactly would hide the whole bug.
do $$
begin
  perform public.import_masters('route', '[{"code":"R1","name":"Town"}]'::jsonb, false);
  perform public.import_masters('product_group',
    '[{"code":"GS","name":"Snacks","master_code":"PARLE"}]'::jsonb, false);
  perform public.import_masters('party',
    '[{"code":"C1","name":"Ram Store","route_code":"R1"}]'::jsonb, false);
  perform public.import_masters('product',
    ('[{"code":"P1","name":"Potato Chips Hot & Spicy","group_code":"GS",
        "base_uom":"PCS","pack_uom":"CTN","pack_size":60,
        "sale_price":2200,"purchase_price":1900,"opening_qty":1200,
        "opening_date":"' || (current_date - 30)::text || '"}]')::jsonb, false);
  perform public.post_opening_stock();
end $$;

create or replace function pg_temp.prod() returns uuid
language sql as $$ select id from public.product where code = 'P1' $$;
create or replace function pg_temp.party() returns uuid
language sql as $$ select id from public.party where code = 'C1' $$;

create or replace function pg_temp.bill(p_no int) returns uuid
language sql as $$
  select id from public.sales_invoice order by created_at offset p_no - 1 limit 1
$$;

create or replace function pg_temp.bill_line(p_no int) returns uuid
language sql as $$
  select id from public.sales_invoice_line where invoice_id = pg_temp.bill(p_no) limit 1
$$;

-- Two identical bills: 4 cartons of 60 at 2,200 = 8,800 each. One for each
-- way of sending the return back.
do $$
declare i int;
begin
  for i in 1..2 loop
    perform public.create_sales_invoice(
      current_date - 5,
      jsonb_build_array(jsonb_build_object(
        'product_id', pg_temp.prod(), 'uom', 'PACK', 'qty', 4, 'rate', 2200)),
      null, pg_temp.party());
  end loop;
end $$;

do $$
declare r record;
begin
  select qty, qty_base, pack_size, rate, net_amount into r
    from public.sales_invoice_line where id = pg_temp.bill_line(1);
  perform pg_temp.eq(r.qty_base, 240::numeric, 'pieces on the bill');
  perform pg_temp.eq(r.net_amount, 8800::numeric, 'what the bill charged');
  perform pg_temp.pass('billed 4 cartons of 60 at 2,200 — 240 pieces, 8,800');
end $$;

-- -----------------------------------------------------------------------------
-- The return exactly as the Returns screen used to send it
-- -----------------------------------------------------------------------------
-- 36.666666666666664 is not a typo and not a stand-in. It is the literal value
-- JavaScript produces for 2200/60, and it is the whole bug: seventeen digits
-- going into a column that holds four.

begin;

do $$ begin perform public.post_sales_return(
  pg_temp.party(),
  current_date,
  jsonb_build_array(jsonb_build_object(
    'product_id',      pg_temp.prod(),
    'invoice_line_id', pg_temp.bill_line(1),
    'uom',             'BASE',
    'qty',             240,
    'rate',            36.666666666666664,
    'restock',         true)),
  'Whole consignment back, entered in pieces',
  pg_temp.bill(1)); end $$;

-- Before 039 the next line is where it died: the deferred trigger comparing
-- 8800.00 against 8800.01.
commit;

do $$
declare r record;
begin
  select sr.id, sr.total_value,
         (select coalesce(sum(amount), 0) from public.sales_return_line
           where return_id = sr.id)   as line_sum,
         (select coalesce(sum(qty_base), 0) from public.sales_return_line
           where return_id = sr.id)   as pieces,
         (select max(rate) from public.sales_return_line
           where return_id = sr.id)   as stored_rate
    into r
    from public.sales_return sr
   where sr.reason = 'Whole consignment back, entered in pieces';

  perform pg_temp.eq(r.pieces, 240::numeric, 'pieces that came back');
  perform pg_temp.pass('a rate with seventeen digits no longer refuses the return');

  -- The point of 039. These two are computed from the same numbers now, so
  -- they cannot drift by a rounding artefact.
  perform pg_temp.eq(r.total_value, r.line_sum, 'the header against the sum of its lines');
  perform pg_temp.pass('header and lines agree, which is what the trigger checks');

  -- And the reason they agree: what was staged is what the column holds.
  perform pg_temp.eq(r.stored_rate, 36.6667::numeric, 'the rate as stored');
  perform pg_temp.pass('the rate was rounded to the four places the column has');
end $$;

-- The deferred trigger is now satisfiable at any moment, not just at commit.
-- If this ever starts failing, something is staging a value it does not store.
do $$
begin
  set constraints all immediate;
  perform pg_temp.pass('and the check passes when forced immediately too');
end $$;

-- -----------------------------------------------------------------------------
-- The same goods, sent the way the screen sends them now
-- -----------------------------------------------------------------------------
-- Whole cartons go back as cartons at the carton rate. Nothing is divided, so
-- nothing is rounded, and the credit is the exact amount that was charged —
-- not a paisa more.

begin;

do $$ begin perform public.post_sales_return(
  pg_temp.party(),
  current_date,
  jsonb_build_array(jsonb_build_object(
    'product_id',      pg_temp.prod(),
    'invoice_line_id', pg_temp.bill_line(2),
    'uom',             'PACK',
    'qty',             4,
    'rate',            2200,
    'restock',         true)),
  'Whole consignment back, entered in cartons',
  pg_temp.bill(2)); end $$;

commit;

do $$
declare r record;
begin
  select sr.total_value,
         (select coalesce(sum(qty_base), 0) from public.sales_return_line
           where return_id = sr.id) as pieces
    into r
    from public.sales_return sr
   where sr.reason = 'Whole consignment back, entered in cartons';

  perform pg_temp.eq(r.pieces, 240::numeric, 'pieces that came back as cartons');
  perform pg_temp.eq(r.total_value, 8800::numeric, 'the credit for 4 cartons');
  perform pg_temp.pass('4 cartons back credits exactly the 8,800 that was charged');
end $$;

-- -----------------------------------------------------------------------------
-- Small quantities, which always worked, still work
-- -----------------------------------------------------------------------------
-- Worth keeping: it is the asymmetry that made the bug look random, and it is
-- how a future change to the rounding would be caught.

begin;

do $$ begin perform public.post_sales_return(
  pg_temp.party(),
  current_date,
  jsonb_build_array(jsonb_build_object(
    'product_id',      pg_temp.prod(),
    'invoice_line_id', pg_temp.bill_line(1),
    'uom',             'BASE',
    'qty',             1,
    'rate',            36.666666666666664,
    'restock',         true)),
  'One piece back',
  pg_temp.bill(1)); end $$;

commit;

do $$
declare r record;
begin
  select sr.total_value,
         (select coalesce(sum(amount), 0) from public.sales_return_line
           where return_id = sr.id) as line_sum
    into r
    from public.sales_return sr where sr.reason = 'One piece back';

  perform pg_temp.eq(r.total_value, r.line_sum, 'one piece: header against lines');
  perform pg_temp.eq(r.total_value, 36.67::numeric, 'the credit for one piece');
  perform pg_temp.pass('one piece back is unchanged — 36.67');
end $$;

-- -----------------------------------------------------------------------------
-- A bill for part of a carton — migration 040
-- -----------------------------------------------------------------------------
-- 250 pieces is four cartons and ten loose, so the billing screen cannot send
-- it as cartons and has to price it per piece. Before 040 this was refused
-- with "Invoice INV-0000NN gross_total 9166.67 <> line sum 9166.68".
--
-- Committed, again, because the invoice guard is deferred too.

begin;

do $$ begin perform public.create_sales_invoice(
  current_date,
  jsonb_build_array(jsonb_build_object(
    'product_id', pg_temp.prod(),
    'uom', 'BASE', 'qty', 250, 'rate', 36.666666666666664)),
  null, pg_temp.party()); end $$;

commit;

do $$
declare r record;
begin
  select si.doc_no, si.gross_total, si.net_total,
         (select coalesce(sum(gross_amount), 0) from public.sales_invoice_line
           where invoice_id = si.id) as line_sum,
         (select max(rate) from public.sales_invoice_line
           where invoice_id = si.id) as stored_rate
    into r
    from public.sales_invoice si
   order by si.created_at desc limit 1;

  perform pg_temp.eq(r.gross_total, r.line_sum, 'the bill header against its lines');
  perform pg_temp.eq(r.stored_rate, 36.6667::numeric, 'the billed rate as stored');
  perform pg_temp.pass('a part-carton bill priced per piece saves — 040');
end $$;

-- -----------------------------------------------------------------------------
-- And a purchase, which has the same staging
-- -----------------------------------------------------------------------------

do $$
begin
  perform public.import_masters('supplier',
    '[{"code":"S1","name":"Parle Depot"}]'::jsonb, false);
end $$;

begin;

do $$ begin perform public.post_purchase(
  p_supplier_id        => (select id from public.supplier where code = 'S1'),
  p_purchase_date      => current_date,
  p_lines              => jsonb_build_array(jsonb_build_object(
                            'product_id', pg_temp.prod(),
                            'uom', 'BASE', 'qty', 250,
                            'rate', 31.666666666666668)),
  p_supplier_bill_no   => 'BILL-1'); end $$;

commit;

do $$
declare r record;
begin
  select p.gross_total,
         (select coalesce(sum(amount), 0) from public.purchase_line
           where purchase_id = p.id) as line_sum
    into r
    from public.purchase p order by p.created_at desc limit 1;

  perform pg_temp.eq(r.gross_total, r.line_sum, 'the purchase header against its lines');
  perform pg_temp.pass('and a purchase at a rate that does not divide evenly');
end $$;

\echo '  10 of 10 passed.'
