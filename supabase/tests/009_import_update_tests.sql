-- =============================================================================
-- 009_import_update_tests.sql
-- Re-importing a sheet over rows that are already there (migration 023).
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
  perform public.import_masters('route',
    '[{"code":"R1","name":"Town"},{"code":"R2","name":"Highway"}]'::jsonb, false);
  perform public.import_masters('product_group',
    '[{"code":"G1","name":"Biscuits","master_code":"OTHERS"}]'::jsonb, false);
  perform public.import_masters('party',
    '[{"code":"C1","name":"Ram Store","route_code":"R1","phone":"9800000001"},
      {"code":"C2","name":"Sita Traders","route_code":"R1"}]'::jsonb, false);
end $$;


-- =============================================================================
-- 1. Update mode changes what is there and adds what is not
-- =============================================================================
do $$
declare r jsonb;
begin
  r := public.import_masters('party',
    '[{"code":"C1","name":"Ram Kirana Store","route_code":"R2","phone":"9811111111",
       "opening_balance":"12500","opening_balance_date":"2026-04-01"},
      {"code":"C3","name":"Hari Stores","route_code":"R1",
       "opening_balance":"4000","opening_balance_date":"2026-04-01"}]'::jsonb,
    false, false, true);

  perform pg_temp.eq((r ->> 'imported')::int, 1, 'one new party inserted');
  perform pg_temp.eq((r ->> 'updated')::int,  1, 'one existing party updated');

  perform pg_temp.eq((select name from public.party where code = 'C1'),
                     'Ram Kirana Store', 'name overwritten');
  perform pg_temp.eq((select r2.code from public.party p
                        join public.route r2 on r2.id = p.route_id
                       where p.code = 'C1'),
                     'R2', 'route moved');
  perform pg_temp.eq((select phone from public.party where code = 'C1'),
                     '9811111111', 'phone overwritten');
  perform pg_temp.eq((select opening_balance from public.party where code = 'C1'),
                     12500::numeric, 'opening balance set');
  perform pg_temp.eq((select opening_balance_date from public.party where code = 'C1'),
                     '2026-04-01'::date, 'opening balance date set');
  perform pg_temp.eq((select opening_balance from public.party where code = 'C3'),
                     4000::numeric, 'new party carries its opening balance');

  -- The party not mentioned in the sheet is left exactly as it was.
  perform pg_temp.eq((select name from public.party where code = 'C2'),
                     'Sita Traders', 'a party missing from the sheet is untouched');

  perform pg_temp.pass('update mode overwrites existing rows and inserts new ones');
end $$;


-- =============================================================================
-- 2. Without update or skip, an existing code is still an error
-- =============================================================================
do $$
declare r jsonb;
begin
  r := public.import_masters('party',
    '[{"code":"C1","name":"Ram Kirana Store","route_code":"R1"}]'::jsonb, true);

  perform pg_temp.eq((r ->> 'errors')::int, 1, 'one problem reported');
  perform pg_temp.eq(r -> 'error_detail' -> 0 ->> 'message',
                     'A party with this code already exists', 'the old message is unchanged');
  perform pg_temp.pass('the default is still to refuse a code that already exists');
end $$;


-- =============================================================================
-- 3. Skipping and updating cannot both be asked for
-- =============================================================================
do $$
declare v_msg text;
begin
  begin
    perform public.import_masters('party',
      '[{"code":"C1","name":"X","route_code":"R1"}]'::jsonb, true, true, true);
    raise exception 'FAIL  both flags together should be refused';
  exception when sqlstate 'SA004' then
    get stacked diagnostics v_msg = message_text;
  end;

  if v_msg not like '%skipped or updated, not both%' then
    raise exception 'FAIL  unexpected message: %', v_msg;
  end if;
  perform pg_temp.pass('skip and update together is refused');
end $$;


-- =============================================================================
-- 4. An opening balance that is already fixed is reported, and nothing writes
--
-- This is the rule that matters after go-live: once a party has a bill, its
-- opening balance is history. A sheet that tries to move it is refused — and
-- the perfectly good new row beside it does not sneak in either.
-- =============================================================================
do $$
declare v_party uuid; v_prod uuid; v_detail text; r jsonb;
begin
  perform public.import_masters('product',
    '[{"code":"P1","name":"Marie","group_code":"G1","base_uom":"PCS","sale_price":"20",
       "opening_qty":"1000","opening_price":"16","opening_date":"2026-04-01"}]'::jsonb, false);
  perform public.post_opening_stock();

  select id into v_party from public.party where code = 'C1';
  select id into v_prod  from public.product where code = 'P1';

  perform public.create_sales_invoice(current_date,
    jsonb_build_array(jsonb_build_object(
      'product_id', v_prod, 'uom', 'BASE', 'qty', 10, 'rate', 20)),
    null, v_party);

  -- Dry run first: the problem is named, with the party in it.
  r := public.import_masters('party',
    '[{"code":"C1","name":"Ram Kirana Store","route_code":"R2",
       "opening_balance":"9999","opening_balance_date":"2026-04-01"},
      {"code":"C9","name":"New Shop","route_code":"R1"}]'::jsonb,
    true, false, true);

  perform pg_temp.eq((r ->> 'errors')::int, 1, 'one problem reported');
  perform pg_temp.eq(r -> 'error_detail' -> 0 ->> 'field', 'opening_balance',
                     'the problem is on the opening balance');
  if (r -> 'error_detail' -> 0 ->> 'message') not like 'Ram Kirana Store already has%' then
    raise exception 'FAIL  the message should name the party, got: %',
      r -> 'error_detail' -> 0 ->> 'message';
  end if;

  -- A real run refuses outright and writes nothing at all.
  begin
    perform public.import_masters('party',
      '[{"code":"C1","name":"Ram Kirana Store","route_code":"R2",
         "opening_balance":"9999","opening_balance_date":"2026-04-01"},
        {"code":"C9","name":"New Shop","route_code":"R1"}]'::jsonb,
      false, false, true);
    raise exception 'FAIL  the import should have been refused';
  exception when sqlstate 'SA004' then
    null;
  end;

  perform pg_temp.eq((select opening_balance from public.party where code = 'C1'),
                     12500::numeric, 'the fixed opening balance is unchanged');
  perform pg_temp.eq((select count(*)::int from public.party where code = 'C9'),
                     0, 'the good row beside it was not written either');

  perform pg_temp.pass('a frozen opening balance is reported by name and nothing is written');
end $$;


-- =============================================================================
-- 5. The same sheet re-imported with the same opening balance is fine
--
-- Fixing a phone number months later should not be blocked just because the
-- sheet still carries the opening balance it always had.
-- =============================================================================
do $$
declare r jsonb;
begin
  r := public.import_masters('party',
    '[{"code":"C1","name":"Ram Kirana Store","route_code":"R2","phone":"9822222222",
       "opening_balance":"12500","opening_balance_date":"2026-04-01"}]'::jsonb,
    false, false, true);

  perform pg_temp.eq((r ->> 'updated')::int, 1, 'the row updated');
  perform pg_temp.eq((select phone from public.party where code = 'C1'),
                     '9822222222', 'phone changed');
  perform pg_temp.pass('an unchanged opening balance does not block a later correction');
end $$;


-- =============================================================================
-- 6. A re-priced product keeps its box price, and the piece rate follows
--
-- The trap: on an update, the rate trigger reads "unit rate changed, pack price
-- did not" as somebody editing the unit rate by hand, and clears the pack
-- price. The import must not trip it.
-- =============================================================================
do $$
declare r jsonb;
begin
  perform public.import_masters('product',
    '[{"code":"P2","name":"Glucose","group_code":"G1","base_uom":"PCS",
       "pack_uom":"BOX","pack_size":"24","sale_price":"480"}]'::jsonb, false);

  perform pg_temp.eq((select pack_sale_rate from public.product where code = 'P2'),
                     480::numeric, 'box price stored as typed');
  perform pg_temp.eq((select sale_rate from public.product where code = 'P2'),
                     20::numeric, 'piece rate derived');

  r := public.import_masters('product',
    '[{"code":"P2","name":"Glucose Biscuit","group_code":"G1","base_uom":"PCS",
       "pack_uom":"BOX","pack_size":"24","sale_price":"500"}]'::jsonb,
    false, false, true);

  perform pg_temp.eq((r ->> 'updated')::int, 1, 'the product updated');
  perform pg_temp.eq((select name from public.product where code = 'P2'),
                     'Glucose Biscuit', 'name changed');
  perform pg_temp.eq((select pack_sale_rate from public.product where code = 'P2'),
                     500::numeric, 'new box price kept, not cleared');
  perform pg_temp.eq((select sale_rate from public.product where code = 'P2'),
                     round(500::numeric / 24, 4), 'piece rate re-derived from the box price');

  perform pg_temp.pass('a re-priced box keeps its box price and re-derives the piece rate');
end $$;


-- =============================================================================
-- 7. Posted opening stock cannot be moved by a re-import
-- =============================================================================
do $$
declare r jsonb;
begin
  r := public.import_masters('product',
    '[{"code":"P1","name":"Marie","group_code":"G1","base_uom":"PCS","sale_price":"22",
       "opening_qty":"5000","opening_price":"16","opening_date":"2026-04-01"}]'::jsonb,
    true, false, true);

  perform pg_temp.eq((r ->> 'errors')::int, 1, 'one problem reported');
  perform pg_temp.eq(r -> 'error_detail' -> 0 ->> 'field', 'opening_qty',
                     'the problem is on the opening quantity');
  perform pg_temp.pass('posted opening stock cannot be moved by a re-import');
end $$;


-- =============================================================================
-- 8. Skip mode still behaves exactly as it did
-- =============================================================================
do $$
declare r jsonb;
begin
  r := public.import_masters('party',
    '[{"code":"C1","name":"Something Else","route_code":"R1"},
      {"code":"C7","name":"Gita Stores","route_code":"R1"}]'::jsonb,
    false, true, false);

  perform pg_temp.eq((r ->> 'imported')::int, 1, 'only the new one imported');
  perform pg_temp.eq((r ->> 'skipped')::int, 1, 'the existing one skipped');
  perform pg_temp.eq((select name from public.party where code = 'C1'),
                     'Ram Kirana Store', 'the skipped row is untouched');
  perform pg_temp.pass('skip mode is unchanged');
end $$;


\echo 'All import update tests passed.'
