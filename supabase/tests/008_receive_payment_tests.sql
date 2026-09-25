-- =============================================================================
-- 008_receive_payment_tests.sql
-- Taking a payment and settling bills in one call (migration 022).
-- =============================================================================

\set QUIET on
set client_min_messages = notice;

create or replace function pg_temp.pass(msg text) returns void
language plpgsql as $$ begin raise notice 'PASS  %', msg; end; $$;

create or replace function pg_temp.fail(msg text) returns void
language plpgsql as $$ begin raise exception 'FAIL  %', msg; end; $$;

create or replace function pg_temp.eq(got numeric, want numeric, what text)
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
  perform public.import_masters('product_group', '[{"code":"G1","name":"Biscuits","master_code":"OTHERS"}]'::jsonb, false);
  perform public.import_masters('party',
    '[{"code":"C1","name":"Ram Store","route_code":"R1"},
      {"code":"C2","name":"Sita Traders","route_code":"R1"}]'::jsonb, false);
  perform public.import_masters('product',
    '[{"code":"P1","name":"Marie","group_code":"G1","base_uom":"PCS","sale_price":"20",
       "opening_qty":"1000","opening_price":"16","opening_date":"2026-04-01"}]'::jsonb, false);
  perform public.post_opening_stock();
end $$;

-- Two bills for Ram Store: 2,000 and 1,000.
create or replace function pg_temp.bill(p_party text, p_qty numeric) returns uuid
language plpgsql as $$
declare v_party uuid; v_prod uuid; r jsonb;
begin
  select id into v_party from public.party where code = p_party;
  select id into v_prod  from public.product where code = 'P1';
  r := public.create_sales_invoice(current_date,
        jsonb_build_array(jsonb_build_object(
          'product_id', v_prod, 'uom', 'BASE', 'qty', p_qty, 'rate', 20)),
        null, v_party);
  return (r ->> 'invoice_id')::uuid;
end; $$;

-- =============================================================================
-- 1. One call takes the money and settles the bills ticked
-- =============================================================================
do $$
declare v_party uuid; v_a uuid; v_b uuid; r jsonb; v_rec uuid;
begin
  select id into v_party from public.party where code = 'C1';
  v_a := pg_temp.bill('C1', 100);   -- 2,000
  v_b := pg_temp.bill('C1', 50);    -- 1,000

  r := public.receive_payment(v_party, current_date, 3000,
        jsonb_build_array(
          jsonb_build_object('invoice_id', v_a, 'amount', 2000),
          jsonb_build_object('invoice_id', v_b, 'amount', 1000)));
  v_rec := (r ->> 'receipt_id')::uuid;

  perform pg_temp.eq((r ->> 'allocated')::numeric, 3000, 'allocated');
  perform pg_temp.eq((r ->> 'unallocated')::numeric, 0, 'nothing left over');
  perform pg_temp.eq((select outstanding from public.v_invoice_list where invoice_id = v_a),
                     0, 'first bill settled');
  perform pg_temp.eq((select outstanding from public.v_invoice_list where invoice_id = v_b),
                     0, 'second bill settled');
  perform pg_temp.eq((select balance from public.v_party_balance where party_id = v_party),
                     0, 'party owes nothing');

  perform pg_temp.pass('payment recorded and applied in one step');
end $$;

-- =============================================================================
-- 2. Paying a round figure leaves the extra on account
-- =============================================================================
do $$
declare v_party uuid; v_inv uuid; r jsonb;
begin
  select id into v_party from public.party where code = 'C2';
  v_inv := pg_temp.bill('C2', 90);  -- 1,800

  r := public.receive_payment(v_party, current_date, 2000,
        jsonb_build_array(jsonb_build_object('invoice_id', v_inv, 'amount', 1800)));

  perform pg_temp.eq((r ->> 'unallocated')::numeric, 200, 'change stays on the payment');
  perform pg_temp.eq((select unallocated from public.v_unallocated_credit
                       where credit_id = (r ->> 'receipt_id')::uuid),
                     200, 'and shows as unapplied credit');
  perform pg_temp.eq((select balance from public.v_party_balance where party_id = v_party),
                     -200, 'party is 200 in credit');

  perform pg_temp.pass('money over the bills stays on account');
end $$;

-- =============================================================================
-- 3. Ticking more than the payment is refused, and nothing is written
-- =============================================================================
do $$
declare v_party uuid; v_inv uuid; v_before integer;
begin
  select id into v_party from public.party where code = 'C1';
  v_inv := pg_temp.bill('C1', 100);  -- 2,000
  select count(*) into v_before from public.receipt;

  begin
    perform public.receive_payment(v_party, current_date, 500,
      jsonb_build_array(jsonb_build_object('invoice_id', v_inv, 'amount', 2000)));
    perform pg_temp.fail('bills over the payment were accepted');
  exception when sqlstate 'SA004' then null;
  end;

  perform pg_temp.eq((select count(*) from public.receipt), v_before,
                     'no receipt was left behind');
  perform pg_temp.eq((select outstanding from public.v_invoice_list where invoice_id = v_inv),
                     2000, 'the bill is untouched');

  perform pg_temp.pass('a refused payment writes nothing at all');
end $$;

-- =============================================================================
-- 4. A bill belonging to someone else takes the whole thing down with it
-- =============================================================================
do $$
declare v_c1 uuid; v_c2 uuid; v_other uuid; v_before integer;
begin
  select id into v_c1 from public.party where code = 'C1';
  select id into v_c2 from public.party where code = 'C2';
  v_other := pg_temp.bill('C2', 10);   -- Sita's bill
  select count(*) into v_before from public.receipt;

  begin
    perform public.receive_payment(v_c1, current_date, 500,
      jsonb_build_array(jsonb_build_object('invoice_id', v_other, 'amount', 200)));
    perform pg_temp.fail('money from one customer settled another customer''s bill');
  exception when sqlstate 'SA004' then null;
           when sqlstate 'SA002' then null;
  end;

  perform pg_temp.eq((select count(*) from public.receipt), v_before,
                     'no receipt was left behind');
  perform pg_temp.pass('a bill from another customer is refused, receipt and all');
end $$;

-- =============================================================================
-- 5. With no amount given, the payment is what the bills come to
-- =============================================================================
do $$
declare v_party uuid; v_inv uuid; r jsonb;
begin
  select id into v_party from public.party where code = 'C1';
  v_inv := pg_temp.bill('C1', 25);  -- 500

  r := public.receive_payment(v_party, current_date, null,
        jsonb_build_array(jsonb_build_object('invoice_id', v_inv, 'amount', 500)));

  perform pg_temp.eq((select amount from public.receipt where id = (r ->> 'receipt_id')::uuid),
                     500, 'amount taken from the bills ticked');
  perform pg_temp.eq((r ->> 'unallocated')::numeric, 0, 'nothing left over');
  perform pg_temp.pass('the amount can be left to the bills themselves');
end $$;

do $$
begin
  raise notice '';
  raise notice '=====================================';
  raise notice ' All receive-payment tests passed.';
  raise notice '=====================================';
end $$;
