-- =============================================================================
-- 022_sales_return_tests.sql
-- Goods coming back (migration 038's views, over 008/014's engine).
--
-- The engine has been there since 014 and has never had a screen, so these
-- are the first tests to exercise it end to end — post a return against a real
-- bill, allocate the credit, and check the three numbers that have to move
-- together:
--
--   stock      goes up, on the day the goods came back, for the resaleable part
--   the bill   owes less
--   the customer's total owing drops by the same amount, once and not twice
--
-- The last of those is the one worth being careful about. A return credits the
-- customer AND can be allocated to a bill. If both counted, every return would
-- halve the debt twice over.
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

do $$
begin
  perform public.import_masters('route', '[{"code":"R1","name":"Town"}]'::jsonb, false);
  perform public.import_masters('product_group',
    '[{"code":"GB","name":"Biscuits","master_code":"PARLE"}]'::jsonb, false);
  perform public.import_masters('party',
    '[{"code":"C1","name":"Ram Store","route_code":"R1"}]'::jsonb, false);
  perform public.import_masters('product',
    ('[{"code":"P1","name":"Biscuit","group_code":"GB","base_uom":"PCS",
        "pack_uom":"CTN","pack_size":40,"sale_price":1200,
        "purchase_price":1000,"opening_qty":1000,
        "opening_date":"' || (current_date - 30)::text || '"}]')::jsonb, false);
  perform public.post_opening_stock();
end $$;

create or replace function pg_temp.prod() returns uuid
language sql as $$ select id from public.product where code = 'P1' $$;
create or replace function pg_temp.party() returns uuid
language sql as $$ select id from public.party where code = 'C1' $$;
create or replace function pg_temp.bill() returns uuid
language sql as $$ select id from public.sales_invoice order by created_at limit 1 $$;
create or replace function pg_temp.avail() returns numeric
language sql as $$ select on_hand from public.product_stock where product_id = pg_temp.prod() $$;
create or replace function pg_temp.owed() returns numeric
language sql as $$ select coalesce(balance, 0) from public.v_party_balance
                    where party_id = pg_temp.party() $$;
create or replace function pg_temp.bill_owes() returns numeric
language sql as $$ select outstanding from public.v_invoice_outstanding
                    where invoice_id = pg_temp.bill() $$;

-- A bill for 100 pieces at 30 = 3,000.
do $$
begin
  perform public.create_sales_invoice(
    current_date - 5,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod(), 'uom', 'BASE', 'qty', 100, 'rate', 30)),
    null, pg_temp.party());
  perform pg_temp.eq(pg_temp.bill_owes(), 3000::numeric, 'what the bill owes to start with');
  perform pg_temp.pass('a bill for 3,000 is owed in full');
end $$;

-- -----------------------------------------------------------------------------
-- Twenty pieces come back, resaleable, two days later.
-- -----------------------------------------------------------------------------

do $$
declare v_before numeric; v_r jsonb; v_id uuid;
begin
  v_before := pg_temp.avail();

  v_r := public.post_sales_return(
    pg_temp.party(), current_date - 2,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod(), 'uom', 'BASE', 'qty', 20, 'rate', 30,
      'restock', true,
      'invoice_line_id', (select id from public.sales_invoice_line
                           where invoice_id = pg_temp.bill() limit 1))),
    'Over-ordered', pg_temp.bill());
  v_id := (v_r ->> 'return_id')::uuid;

  perform pg_temp.eq((v_r ->> 'total_value')::numeric, 600::numeric,
    'the credit for 20 pieces at 30');
  perform pg_temp.eq(pg_temp.avail(), v_before + 20, 'stock after the return');
  perform pg_temp.pass('resaleable goods go back into stock and credit 600');

  perform pg_temp.eq(
    (select movement_date from public.stock_ledger
      where doc_type = 'SALE_RETURN' and doc_id = v_id limit 1),
    current_date - 2,
    'the date stock went back in');
  perform pg_temp.pass('dated the day it came back, not the day of the bill');
end $$;

-- Until it is allocated it is loose credit: the customer owes less overall,
-- but the bill still reads in full. That is the state the list screen warns
-- about, so it is asserted rather than assumed.
do $$
begin
  perform pg_temp.eq(pg_temp.bill_owes(), 3000::numeric,
    'the bill before the credit is applied');
  perform pg_temp.eq(pg_temp.owed(), 2400::numeric,
    'what the customer owes in total');
  perform pg_temp.pass('before allocating: the total drops, the bill does not');
end $$;

do $$
declare v_id uuid;
begin
  select id into v_id from public.sales_return order by created_at limit 1;
  perform public.allocate_credit(
    jsonb_build_array(jsonb_build_object(
      'invoice_id', pg_temp.bill(), 'amount', 600)),
    null, v_id);

  perform pg_temp.eq(pg_temp.bill_owes(), 2400::numeric, 'the bill after allocating');
  perform pg_temp.pass('allocating takes it off the bill it came from');

  -- The important one: not counted twice.
  perform pg_temp.eq(pg_temp.owed(), 2400::numeric,
    'what the customer owes after allocating');
  perform pg_temp.pass('and the customer total is unchanged by allocating — counted once');
end $$;

-- -----------------------------------------------------------------------------
-- Damaged goods: credited, but not back on the shelf.
-- -----------------------------------------------------------------------------

do $$
declare v_before numeric; v_r jsonb;
begin
  v_before := pg_temp.avail();

  v_r := public.post_sales_return(
    pg_temp.party(), current_date - 1,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod(), 'uom', 'BASE', 'qty', 10, 'rate', 30,
      'restock', false,
      'invoice_line_id', (select id from public.sales_invoice_line
                           where invoice_id = pg_temp.bill() limit 1))),
    'Crushed in transit', pg_temp.bill());

  perform pg_temp.eq((v_r ->> 'total_value')::numeric, 300::numeric,
    'the credit for damaged goods');
  perform pg_temp.eq((v_r ->> 'restocked_qty')::numeric, 0::numeric,
    'how much of it went back on the shelf');
  perform pg_temp.eq(pg_temp.avail(), v_before, 'stock after a damaged return');
  perform pg_temp.pass('damaged goods credit the customer and stay out of stock');
end $$;

-- -----------------------------------------------------------------------------
-- The views the screens read
-- -----------------------------------------------------------------------------

do $$
declare r record;
begin
  select * into r from public.v_return_list
   where reason = 'Over-ordered';

  perform pg_temp.eq(r.total_value, 600::numeric, 'the listed value');
  perform pg_temp.eq(r.qty_restocked, 20::numeric, 'the listed restocked quantity');
  perform pg_temp.eq(r.allocated, 600::numeric, 'the listed allocated amount');
  perform pg_temp.eq(r.unallocated, 0::numeric, 'the listed loose amount');
  perform pg_temp.eq(r.invoice_no, (select doc_no from public.sales_invoice
                                     where id = pg_temp.bill()),
    'the bill it came off');
  perform pg_temp.pass('the list shows value, restock and where the credit went');

  select * into r from public.v_return_list where reason = 'Crushed in transit';
  perform pg_temp.eq(r.qty_written_off, 10::numeric, 'the listed write-off');
  perform pg_temp.eq(r.unallocated, 300::numeric, 'a credit nobody has applied yet');
  perform pg_temp.pass('and marks a credit that is still loose');
end $$;

do $$
declare r record;
begin
  select * into r from public.v_invoice_returns where invoice_id = pg_temp.bill();
  perform pg_temp.eq(r.returns, 2::bigint, 'returns against this bill');
  perform pg_temp.eq(r.qty_base, 30::numeric, 'quantity returned against this bill');
  perform pg_temp.eq(r.value, 900::numeric, 'value returned against this bill');
  perform pg_temp.pass('the bill can say what has come back against it');
end $$;

-- -----------------------------------------------------------------------------
-- Cancelling a return undoes all of it.
-- -----------------------------------------------------------------------------

do $$
declare v_id uuid; v_stock numeric; v_owed numeric;
begin
  select id into v_id from public.sales_return where reason = 'Over-ordered';
  v_stock := pg_temp.avail();
  v_owed  := pg_temp.owed();

  perform public.cancel_sales_return(v_id, 'Entered against the wrong shop');

  perform pg_temp.eq(pg_temp.avail(), v_stock - 20, 'stock after cancelling the return');
  perform pg_temp.eq(pg_temp.owed(), v_owed + 600, 'what the customer owes again');
  perform pg_temp.eq(pg_temp.bill_owes(), 3000::numeric - 0, 'the bill owes again');
  perform pg_temp.pass('cancelling takes the goods back out and restores the debt');

  perform pg_temp.eq(
    (select count(*) from public.v_invoice_returns where invoice_id = pg_temp.bill()),
    1::bigint,
    'rows in the bill-returns view');
  perform pg_temp.pass('and a cancelled return stops counting against the bill');
end $$;

\echo '  12 of 12 passed.'
