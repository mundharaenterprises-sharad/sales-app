-- =============================================================================
-- 025_no_future_date_tests.sql
-- Nothing can be dated later than today (migration 042).
--
-- Two halves, and the second matters as much as the first. Refusing tomorrow
-- is the easy part. Not refusing YESTERDAY is what keeps the app usable: a day
-- of collections keyed in the next morning, a purchase entered when the
-- paperwork turns up, a cancellation of a bill raised last year. A guard that
-- blocked those would be a worse bug than the one it fixed, so every document
-- type is asserted in both directions.
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
    '[{"code":"GS","name":"Snacks","master_code":"PARLE"}]'::jsonb, false);
  perform public.import_masters('supplier',
    '[{"code":"S1","name":"Parle Depot"}]'::jsonb, false);
  perform public.import_masters('party',
    '[{"code":"C1","name":"Ram Store","route_code":"R1"}]'::jsonb, false);
  perform public.import_masters('product',
    ('[{"code":"P1","name":"Chips","group_code":"GS","base_uom":"PCS",
        "pack_uom":"CTN","pack_size":60,"sale_price":2600,"purchase_price":2000,
        "opening_qty":3000,"opening_date":"' || (current_date - 40)::text || '"}]')::jsonb,
    false);
  perform public.post_opening_stock();
end $$;

create or replace function pg_temp.party() returns uuid
language sql as $$ select id from public.party where code = 'C1' $$;
create or replace function pg_temp.sup() returns uuid
language sql as $$ select id from public.supplier where code = 'S1' $$;
create or replace function pg_temp.prod() returns uuid
language sql as $$ select id from public.product where code = 'P1' $$;

create or replace function pg_temp.sale_lines(p_qty numeric) returns jsonb
language sql as $$
  select jsonb_build_array(jsonb_build_object(
    'product_id', pg_temp.prod(), 'uom', 'BASE', 'qty', p_qty, 'rate', 40));
$$;

-- -----------------------------------------------------------------------------
-- Tomorrow is refused, on every kind of document
-- -----------------------------------------------------------------------------
-- Each one checks the error code as well as the refusal, because SA004 is what
-- carries the message through to the screen. A bare check_violation would
-- reach the person as "One of the values is not allowed", which is the error
-- that cost a day in October.

do $$
declare v_msg text;
begin
  begin
    perform public.create_sales_invoice(
      current_date + 1, pg_temp.sale_lines(10), null, pg_temp.party());
    raise exception 'FAIL  a bill dated tomorrow was accepted';
  exception when sqlstate 'SA004' then
    get stacked diagnostics v_msg = MESSAGE_TEXT;
    if v_msg not like 'A bill cannot be dated in the future%' then
      raise exception 'FAIL  wrong message for a future bill: %', v_msg;
    end if;
    perform pg_temp.pass('a bill dated tomorrow is refused, and says so plainly');
  end;

  begin
    perform public.create_sales_order(
      pg_temp.party(), current_date + 1, pg_temp.sale_lines(10));
    raise exception 'FAIL  an order dated tomorrow was accepted';
  exception when sqlstate 'SA004' then
    perform pg_temp.pass('an order dated tomorrow is refused');
  end;

  begin
    perform public.post_purchase(
      p_supplier_id   => pg_temp.sup(),
      p_purchase_date => current_date + 1,
      p_lines         => jsonb_build_array(jsonb_build_object(
        'product_id', pg_temp.prod(), 'uom', 'BASE', 'qty', 10, 'rate', 30)));
    raise exception 'FAIL  a purchase dated tomorrow was accepted';
  exception when sqlstate 'SA004' then
    perform pg_temp.pass('a purchase dated tomorrow is refused');
  end;

  -- His answer when asked: block this one too.
  begin
    perform public.post_purchase(
      p_supplier_id        => pg_temp.sup(),
      p_purchase_date      => current_date,
      p_lines              => jsonb_build_array(jsonb_build_object(
        'product_id', pg_temp.prod(), 'uom', 'BASE', 'qty', 10, 'rate', 30)),
      p_supplier_bill_date => current_date + 30);
    raise exception 'FAIL  a supplier bill dated next month was accepted';
  exception when sqlstate 'SA004' then
    perform pg_temp.pass('and so is a supplier''s bill date in the future');
  end;

  begin
    perform public.receive_payment(pg_temp.party(), current_date + 1, 500);
    raise exception 'FAIL  a payment dated tomorrow was accepted';
  exception when sqlstate 'SA004' then
    perform pg_temp.pass('a payment dated tomorrow is refused');
  end;

  begin
    perform public.post_sales_return(
      pg_temp.party(), current_date + 1,
      jsonb_build_array(jsonb_build_object(
        'product_id', pg_temp.prod(), 'uom', 'BASE', 'qty', 1, 'rate', 40)),
      'Dated ahead');
    raise exception 'FAIL  a return dated tomorrow was accepted';
  exception when sqlstate 'SA004' then
    perform pg_temp.pass('a return dated tomorrow is refused');
  end;
end $$;

-- A year ahead, which is the real-world case: 11/12 keyed instead of 11/02.
do $$
begin
  begin
    perform public.create_sales_invoice(
      current_date + 330, pg_temp.sale_lines(10), null, pg_temp.party());
    raise exception 'FAIL  a bill eleven months ahead was accepted';
  exception when sqlstate 'SA004' then
    perform pg_temp.pass('and a bill eleven months out, which is the typing slip');
  end;
end $$;

-- -----------------------------------------------------------------------------
-- Today and yesterday still work
-- -----------------------------------------------------------------------------

do $$
declare v_inv jsonb; v_pur jsonb; v_rec jsonb; v_ret jsonb;
begin
  v_inv := public.create_sales_invoice(
    current_date, pg_temp.sale_lines(10), null, pg_temp.party());
  perform pg_temp.eq((v_inv ->> 'net_total')::numeric, 400::numeric, 'a bill dated today');

  v_inv := public.create_sales_invoice(
    current_date - 9, pg_temp.sale_lines(5), null, pg_temp.party());
  perform pg_temp.eq((v_inv ->> 'net_total')::numeric, 200::numeric,
    'a bill dated nine days ago');
  perform pg_temp.pass('today and last week are both fine — back-dating is untouched');

  v_pur := public.post_purchase(
    p_supplier_id        => pg_temp.sup(),
    p_purchase_date      => current_date - 4,
    p_lines              => jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod(), 'uom', 'BASE', 'qty', 10, 'rate', 30)),
    p_supplier_bill_date => current_date - 6);
  perform pg_temp.eq((v_pur ->> 'net_total')::numeric, 300::numeric,
    'a purchase entered when the paperwork arrived');
  perform pg_temp.pass('a purchase and a supplier bill both dated in the past');

  v_rec := public.receive_payment(pg_temp.party(), current_date - 1, 100);
  perform pg_temp.eq((v_rec ->> 'amount')::numeric, 100::numeric,
    'yesterday''s collections keyed this morning');
  perform pg_temp.pass('yesterday''s collections go in today');

  v_ret := public.post_sales_return(
    pg_temp.party(), current_date - 2,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod(), 'uom', 'BASE', 'qty', 1, 'rate', 40)),
    'Came back on Tuesday');
  perform pg_temp.eq((v_ret ->> 'total_value')::numeric, 40::numeric,
    'a return dated when the goods came back');
  perform pg_temp.pass('and a return dated the day the goods actually arrived');
end $$;

-- -----------------------------------------------------------------------------
-- An old document can still be acted on
-- -----------------------------------------------------------------------------
-- The trap in a guard like this: a trigger that re-checked the date on every
-- UPDATE would refuse to cancel anything raised before today. The guard only
-- looks at a date that actually moved.

do $$
declare v_id uuid;
begin
  select id into v_id from public.sales_invoice
   where invoice_date = current_date - 9 limit 1;

  perform public.cancel_sales_invoice(v_id, 'Cancelled long after it was raised');
  perform pg_temp.eq(
    (select status::text from public.sales_invoice where id = v_id),
    'CANCELLED', 'the old bill''s status');
  perform pg_temp.pass('a bill from last week can still be cancelled today');
end $$;

-- -----------------------------------------------------------------------------
-- The stock ledger is guarded too
-- -----------------------------------------------------------------------------
-- It is where every quantity question is answered from, so a movement dated
-- ahead would make "what is on the shelf" and "what does the ledger say"
-- disagree until that date arrived.

do $$
begin
  begin
    insert into public.stock_ledger
      (product_id, movement_date, qty_in, rate, doc_type, created_by)
    values
      (pg_temp.prod(), current_date + 1, 10, 30, 'ADJUSTMENT',
       '11111111-1111-1111-1111-111111111111');
    raise exception 'FAIL  a stock movement dated tomorrow was accepted';
  exception when sqlstate 'SA004' then
    perform pg_temp.pass('a stock movement dated tomorrow is refused');
  end;
end $$;

-- -----------------------------------------------------------------------------
-- One date is deliberately left free
-- -----------------------------------------------------------------------------
-- A post-dated cheque is a real thing somebody is handed. receipt_date — the
-- date that decides which day's collections a payment counts in — is guarded;
-- the instrument's own date is not. Asserted so that nobody "tidies up" the
-- list of triggers later and quietly closes it.

do $$
begin
  perform pg_temp.eq(
    (select count(*) from pg_trigger
      where tgname = 'receipt_instrument_date_not_future'),
    0::bigint,
    'triggers on the instrument date');
  perform pg_temp.pass('a cheque''s own date is left free, on purpose');
end $$;

do $$
begin
  perform pg_temp.eq(
    (select count(*) from pg_trigger where tgname like '%\_not\_future'),
    11::bigint,
    'date columns guarded');
  perform pg_temp.pass('all eleven dated columns carry the guard');
end $$;

\echo '  15 of 15 passed.'
