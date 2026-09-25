-- =============================================================================
-- 011_master_group_tests.sql
-- Parle / Current / Others, and what a party owes against each
-- (migrations 024 and 025).
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

-- One route, two master groups in play, one product group under each.
do $$
begin
  perform public.import_masters('route', '[{"code":"R1","name":"Town"}]'::jsonb, false);
  perform public.import_masters('product_group',
    '[{"code":"GP","name":"Parle Biscuits","master_code":"parle"},
      {"code":"GC","name":"Current Candy","master_code":"CURRENT"}]'::jsonb, false);
  perform public.import_masters('party',
    '[{"code":"C1","name":"Ram Store","route_code":"R1",
       "opening_balance":"5000","opening_balance_date":"2026-04-01"},
      {"code":"C2","name":"Sita Traders","route_code":"R1"}]'::jsonb, false);
  perform public.import_masters('product',
    '[{"code":"PP","name":"Parle-G","group_code":"GP","base_uom":"PCS","sale_price":"10",
       "opening_qty":"1000","opening_price":"8","opening_date":"2026-04-01"},
      {"code":"PC","name":"Banana Candy","group_code":"GC","base_uom":"PCS","sale_price":"20",
       "opening_qty":"1000","opening_price":"16","opening_date":"2026-04-01"}]'::jsonb, false);
  perform public.post_opening_stock();
end $$;

create or replace function pg_temp.bill(p_party text, p_product text, p_qty numeric,
                                        p_rate numeric)
returns uuid language plpgsql as $$
declare v_party uuid; v_prod uuid; r jsonb;
begin
  select id into v_party from public.party   where code = p_party;
  select id into v_prod  from public.product where code = p_product;
  r := public.create_sales_invoice(current_date,
        jsonb_build_array(jsonb_build_object(
          'product_id', v_prod, 'uom', 'BASE', 'qty', p_qty, 'rate', p_rate)),
        null, v_party);
  return (r ->> 'invoice_id')::uuid;
end; $$;


-- =============================================================================
-- 1. A product group must say which master group it belongs to
-- =============================================================================
do $$
declare r jsonb;
begin
  r := public.import_masters('product_group',
    '[{"code":"GX","name":"No Master"}]'::jsonb, true);
  perform pg_temp.eq((r ->> 'errors')::int, 1, 'one problem');
  perform pg_temp.eq(r -> 'error_detail' -> 0 ->> 'field', 'master_code',
                     'the problem is the missing master code');

  r := public.import_masters('product_group',
    '[{"code":"GX","name":"Bad Master","master_code":"NOPE"}]'::jsonb, true);
  perform pg_temp.eq((r ->> 'errors')::int, 1, 'one problem');
  if (r -> 'error_detail' -> 0 ->> 'message') not like 'No master group exists%' then
    raise exception 'FAIL  unhelpful message: %', r -> 'error_detail' -> 0 ->> 'message';
  end if;

  perform pg_temp.pass('a product group without a valid master group is refused');
end $$;


-- =============================================================================
-- 2. A bill takes the master group of its lines, without being told
-- =============================================================================
do $$
declare v_inv uuid;
begin
  v_inv := pg_temp.bill('C1', 'PP', 100, 10);     -- 1,000 of Parle

  perform pg_temp.eq((select master_code from public.v_invoice_list where invoice_id = v_inv),
                     'PARLE', 'the bill is Parle');
  perform pg_temp.eq((select master_name from public.v_invoice_outstanding
                       where invoice_id = v_inv),
                     'Parle', 'and says so in words');
  perform pg_temp.pass('a bill takes the master group of its lines');
end $$;


-- =============================================================================
-- 3. A bill cannot mix, and the refusal says what and why
-- =============================================================================
do $$
declare v_party uuid; v_p uuid; v_c uuid; v_msg text;
begin
  select id into v_party from public.party   where code = 'C1';
  select id into v_p     from public.product where code = 'PP';
  select id into v_c     from public.product where code = 'PC';

  begin
    perform public.create_sales_invoice(current_date,
      jsonb_build_array(
        jsonb_build_object('product_id', v_p, 'uom', 'BASE', 'qty', 10, 'rate', 10),
        jsonb_build_object('product_id', v_c, 'uom', 'BASE', 'qty', 10, 'rate', 20)),
      null, v_party);
    raise exception 'FAIL  a mixed bill should have been refused';
  exception when sqlstate 'SA004' then
    get stacked diagnostics v_msg = message_text;
  end;

  -- Which of the two lines lands first is not fixed, so the test checks that
  -- the message names a product and both groups, not which way round.
  if v_msg not like 'A bill cannot mix master groups%'
     or not (v_msg like '%Parle-G%' or v_msg like '%Banana Candy%')
     or v_msg not like '%Parle%'
     or v_msg not like '%Current%' then
    raise exception 'FAIL  the refusal should name the product and both groups, got: %', v_msg;
  end if;

  -- And nothing was left behind.
  perform pg_temp.eq((select count(*)::int from public.sales_invoice
                       where party_id = v_party and invoice_date = current_date
                         and master_group_id is null),
                     0, 'no half-built bill left behind');

  perform pg_temp.pass('a bill mixing Parle and Current is refused, by name');
end $$;


-- =============================================================================
-- 4. The same rule on orders — otherwise a mixed order could never be billed
-- =============================================================================
do $$
declare v_party uuid; v_p uuid; v_c uuid; v_msg text;
begin
  select id into v_party from public.party   where code = 'C2';
  select id into v_p     from public.product where code = 'PP';
  select id into v_c     from public.product where code = 'PC';

  begin
    perform public.create_sales_order(v_party, current_date,
      jsonb_build_array(
        jsonb_build_object('product_id', v_p, 'uom', 'BASE', 'qty', 5, 'rate', 10),
        jsonb_build_object('product_id', v_c, 'uom', 'BASE', 'qty', 5, 'rate', 20)));
    raise exception 'FAIL  a mixed order should have been refused';
  exception when sqlstate 'SA004' then
    get stacked diagnostics v_msg = message_text;
  end;

  if v_msg not like 'An order cannot mix%' then
    raise exception 'FAIL  the message should be about an order, got: %', v_msg;
  end if;
  perform pg_temp.pass('an order mixing master groups is refused too');
end $$;


-- =============================================================================
-- 5. What the party owes, split by master group
--
-- Ram Store: 5,000 opening (Current, per the setting) + 1,000 Parle from test 2
-- + a 2,000 Current bill here.
-- =============================================================================
do $$
declare v_party uuid; v_inv uuid;
begin
  select id into v_party from public.party where code = 'C1';
  v_inv := pg_temp.bill('C1', 'PC', 100, 20);       -- 2,000 of Current

  perform pg_temp.eq((select due from public.v_party_dues_by_master
                       where party_id = v_party and master_code = 'PARLE'),
                     1000::numeric, 'Parle dues');
  perform pg_temp.eq((select due from public.v_party_dues_by_master
                       where party_id = v_party and master_code = 'CURRENT'),
                     7000::numeric, 'Current dues: 5,000 opening plus a 2,000 bill');
  perform pg_temp.eq((select opening_balance from public.v_party_dues_by_master
                       where party_id = v_party and master_code = 'CURRENT'),
                     5000::numeric, 'the opening sits under the configured group');
  perform pg_temp.eq((select count(*)::int from public.v_party_dues_by_master
                       where party_id = v_party),
                     2, 'two groups, no empty third');

  -- The split has to add up to the balance computed the old way.
  perform pg_temp.eq((select sum(due) from public.v_party_dues_by_master
                       where party_id = v_party),
                     (select balance from public.v_party_balance where party_id = v_party),
                     'the split adds up to the party balance');

  perform pg_temp.pass('dues split by master group, and they reconcile');
end $$;


-- =============================================================================
-- 6. Paying one group off does not touch the other
-- =============================================================================
do $$
declare v_party uuid; v_inv uuid;
begin
  select id into v_party from public.party where code = 'C1';
  select invoice_id into v_inv from public.v_invoice_list
   where party_id = v_party and master_code = 'PARLE' and outstanding > 0
   limit 1;

  perform public.receive_payment(v_party, current_date, 1000,
    jsonb_build_array(jsonb_build_object('invoice_id', v_inv, 'amount', 1000)));

  perform pg_temp.eq((select count(*)::int from public.v_party_dues_by_master
                       where party_id = v_party and master_code = 'PARLE'),
                     0, 'Parle is settled and drops off the list');
  perform pg_temp.eq((select due from public.v_party_dues_by_master
                       where party_id = v_party and master_code = 'CURRENT'),
                     7000::numeric, 'Current is untouched');
  perform pg_temp.pass('settling one master group leaves the other alone');
end $$;


-- =============================================================================
-- 7. Ageing, per party per master group
-- =============================================================================
do $$
declare v_party uuid;
begin
  select id into v_party from public.party where code = 'C1';

  perform pg_temp.eq((select total_outstanding from public.v_ageing_by_party_master
                       where party_id = v_party and master_code = 'CURRENT'),
                     2000::numeric, 'only the bill ages, not the opening balance');
  perform pg_temp.eq((select b_0_15 from public.v_ageing_by_party_master
                       where party_id = v_party and master_code = 'CURRENT'),
                     2000::numeric, 'a bill raised today is in the first bucket');
  perform pg_temp.eq((select count(*)::int from public.v_ageing_by_party_master
                       where party_id = v_party),
                     1, 'the settled Parle bill is gone from ageing');
  perform pg_temp.pass('ageing splits by master group');
end $$;


-- =============================================================================
-- 8. The ledger says which group every line belongs to
-- =============================================================================
do $$
declare v_party uuid;
begin
  select id into v_party from public.party where code = 'C1';

  perform pg_temp.eq((select master_code from public.v_party_ledger
                       where party_id = v_party and doc_type = 'OPENING'),
                     'CURRENT', 'the opening line carries the configured group');
  perform pg_temp.eq((select count(*)::int from public.v_party_ledger
                       where party_id = v_party and doc_type = 'INVOICE'
                         and master_code is null),
                     0, 'every bill line has a group');
  perform pg_temp.eq((select master_code from public.v_party_ledger
                       where party_id = v_party and doc_type = 'RECEIPT'),
                     null, 'a payment belongs to no group until it is applied');
  perform pg_temp.pass('the ledger carries the master group per line');
end $$;


-- =============================================================================
-- 9. Sales and product reports carry it too
-- =============================================================================
do $$
begin
  perform pg_temp.eq((select count(distinct master_code)::int
                        from public.v_sales_register where status <> 'CANCELLED'),
                     2, 'the sales register shows both groups');
  perform pg_temp.eq((select master_code from public.v_product_sales
                       where product_code = 'PC' limit 1),
                     'CURRENT', 'product sales carry the master group');
  perform pg_temp.eq((select master_code from public.v_product_master
                       where code = 'PP'),
                     'PARLE', 'the products list carries it');
  perform pg_temp.pass('the reports carry the master group');
end $$;


-- =============================================================================
-- 10. Master groups can be imported, and a group can be moved between them
-- =============================================================================
do $$
declare r jsonb;
begin
  r := public.import_masters('master_group',
    '[{"code":"HALDIRAM","name":"Haldiram"}]'::jsonb, false);
  perform pg_temp.eq((r ->> 'imported')::int, 1, 'a new master group imported');

  -- The three from 024 are already there; importing them again is a skip.
  r := public.import_masters('master_group',
    '[{"code":"PARLE","name":"Parle"},{"code":"CURRENT","name":"Current"}]'::jsonb,
    false, true, false);
  perform pg_temp.eq((r ->> 'skipped')::int, 2, 'the seeded ones are left alone');

  -- Move a product group to another master, by re-importing the sheet.
  r := public.import_masters('product_group',
    '[{"code":"GP","name":"Parle Biscuits","master_code":"HALDIRAM"}]'::jsonb,
    false, false, true);
  perform pg_temp.eq((r ->> 'updated')::int, 1, 'the group moved');
  perform pg_temp.eq((select master_code from public.v_product_master where code = 'PP'),
                     'HALDIRAM', 'and its products moved with it');

  -- Put it back, so anything after this reads as it did.
  perform public.import_masters('product_group',
    '[{"code":"GP","name":"Parle Biscuits","master_code":"PARLE"}]'::jsonb,
    false, false, true);

  perform pg_temp.pass('master groups import, and a product group can be moved');
end $$;


\echo 'All master group tests passed.'
