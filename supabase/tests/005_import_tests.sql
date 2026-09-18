-- =============================================================================
-- 005_import_tests.sql
-- The master data importer, tested against the kind of data a real
-- spreadsheet produces: duplicates, typos, "12,500", missing dates.
--
-- The rule being proved throughout: a batch with any error imports NOTHING.
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

-- Does the report contain an error on this row and field?
create or replace function pg_temp.has_err(rep jsonb, r int, f text)
returns boolean language sql as $$
  select exists (
    select 1 from jsonb_array_elements(rep -> 'error_detail') e
     where (e ->> 'row')::int = r and e ->> 'field' = f);
$$;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'admin@test.local'),
  ('33333333-3333-3333-3333-333333333333', 'rep@test.local');

insert into public.app_user (id, full_name, role) values
  ('11111111-1111-1111-1111-111111111111', 'Admin User', 'ADMIN'),
  ('33333333-3333-3333-3333-333333333333', 'Rep User',   'REP');

set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

-- =============================================================================
-- 1. Only Admin may import
-- =============================================================================
do $$
begin
  set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
  begin
    perform public.import_masters('route',
      '[{"code":"R1","name":"Route One"}]'::jsonb, false);
    perform pg_temp.fail('a REP imported master data');
  exception when sqlstate 'SA003' then
    perform pg_temp.pass('REP blocked from importing');
  end;
end $$;

-- =============================================================================
-- 2. A clean import works, and the dry run predicts it
-- =============================================================================
do $$
declare r jsonb;
begin
  set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

  r := public.import_masters('route',
    '[{"code":"R1","name":"Biratnagar Town"},
      {"code":"R2","name":"Itahari"},
      {"code":"R3","name":"Dharan"}]'::jsonb, true);

  perform pg_temp.eq((r ->> 'errors')::numeric, 0, 'dry run finds no errors');
  perform pg_temp.eq((r ->> 'would_import')::numeric, 3, 'dry run row count');
  perform pg_temp.eq((select count(*) from public.route), 0,
                     'dry run wrote nothing');

  r := public.import_masters('route',
    '[{"code":"R1","name":"Biratnagar Town"},
      {"code":"R2","name":"Itahari"},
      {"code":"R3","name":"Dharan"}]'::jsonb, false);

  perform pg_temp.eq((r ->> 'imported')::numeric, 3, 'imported count');
  perform pg_temp.eq((select count(*) from public.route), 3, 'routes in the table');

  perform pg_temp.pass('dry run predicts, real run imports');
end $$;

-- =============================================================================
-- 3. Duplicates inside the sheet are caught, and nothing is written
-- =============================================================================
do $$
declare r jsonb;
begin
  r := public.import_masters('product_group',
    '[{"code":"G1","name":"Biscuits"},
      {"code":"G2","name":"Noodles"},
      {"code":"G1","name":"Biscuits again"}]'::jsonb, true);

  perform pg_temp.eq((r ->> 'errors')::numeric, 2,
                     'both duplicate rows flagged');

  if not pg_temp.has_err(r, 2, 'code') or not pg_temp.has_err(r, 4, 'code') then
    perform pg_temp.fail('duplicate rows not identified by row number');
  end if;

  -- A real run must refuse outright.
  begin
    perform public.import_masters('product_group',
      '[{"code":"G1","name":"Biscuits"},
        {"code":"G1","name":"Biscuits again"}]'::jsonb, false);
    perform pg_temp.fail('a sheet with duplicates was imported');
  exception when sqlstate 'SA004' then
    null;
  end;

  perform pg_temp.eq((select count(*) from public.product_group), 0,
                     'nothing written by the refused batch');

  perform pg_temp.pass('duplicate codes refused, nothing written');
end $$;

-- =============================================================================
-- 4. Row numbers match the spreadsheet, header included
-- =============================================================================
do $$
declare r jsonb;
begin
  -- The bad row is the third data row, which is row 4 in the spreadsheet.
  r := public.import_masters('route',
    '[{"code":"R10","name":"Ten"},
      {"code":"R11","name":"Eleven"},
      {"code":"R12","name":""}]'::jsonb, true);

  if not pg_temp.has_err(r, 4, 'name') then
    perform pg_temp.fail('blank name should be reported on spreadsheet row 4');
  end if;

  perform pg_temp.pass('errors report the spreadsheet row number, not the index');
end $$;

-- =============================================================================
-- 5. Codes that already exist are refused rather than overwritten
-- =============================================================================
do $$
declare r jsonb; v_name text;
begin
  r := public.import_masters('route',
    '[{"code":"R1","name":"Something Else Entirely"}]'::jsonb, true);

  perform pg_temp.eq((r ->> 'errors')::numeric, 1, 'existing code flagged');

  select name into v_name from public.route where code = 'R1';
  perform pg_temp.eq(
    case when v_name = 'Biratnagar Town' then 1 else 0 end, 1,
    'the existing route was left alone');

  perform pg_temp.pass('existing codes refused, never silently overwritten');
end $$;

-- =============================================================================
-- 6. Product groups, then products referencing them
-- =============================================================================
do $$
declare r jsonb;
begin
  perform public.import_masters('product_group',
    '[{"code":"G1","name":"Biscuits"},{"code":"G2","name":"Noodles"}]'::jsonb, false);

  r := public.import_masters('product',
    '[{"code":"P1","name":"Marie 100g","group_code":"G1","base_uom":"PCS",
       "pack_uom":"BOX","pack_size":"24","sale_rate":"25","purchase_rate":"20",
       "opening_qty":"480","opening_rate":"20","opening_date":"2026-04-01"},
      {"code":"P2","name":"Instant Noodles","group_code":"G2","base_uom":"PCS",
       "sale_rate":"20","purchase_rate":"16"}]'::jsonb, false);

  perform pg_temp.eq((r ->> 'imported')::numeric, 2, 'products imported');

  perform pg_temp.eq(
    (select pack_size from public.product where code = 'P1'), 24, 'pack size');
  perform pg_temp.eq(
    (select pack_size from public.product where code = 'P2'), 1,
    'no pack means pack size 1');

  perform pg_temp.pass('products import with pack conversion intact');
end $$;

-- =============================================================================
-- 7. A product pointing at a group that does not exist
-- =============================================================================
do $$
declare r jsonb;
begin
  r := public.import_masters('product',
    '[{"code":"P9","name":"Orphan","group_code":"NOPE","base_uom":"PCS"}]'::jsonb,
    true);

  if not pg_temp.has_err(r, 2, 'group_code') then
    perform pg_temp.fail('unknown group code not flagged');
  end if;

  if (r -> 'error_detail' -> 0 ->> 'message') not like '%Product Groups sheet%' then
    perform pg_temp.fail('the message should say how to fix it');
  end if;

  perform pg_temp.pass('unknown group reported with a fix, not a constraint error');
end $$;

-- =============================================================================
-- 8. Spreadsheet numbers: "12,500" and friends
-- =============================================================================
do $$
declare r jsonb;
begin
  r := public.import_masters('product',
    '[{"code":"P20","name":"Bad number","group_code":"G1","base_uom":"PCS",
       "sale_rate":"12,500"},
      {"code":"P21","name":"Negative","group_code":"G1","base_uom":"PCS",
       "sale_rate":"-5"},
      {"code":"P22","name":"Fine","group_code":"G1","base_uom":"PCS",
       "sale_rate":"12500"}]'::jsonb, true);

  if not pg_temp.has_err(r, 2, 'sale_rate') then
    perform pg_temp.fail('"12,500" should be reported as not a number');
  end if;

  if not pg_temp.has_err(r, 3, 'sale_rate') then
    perform pg_temp.fail('a negative rate should be reported');
  end if;

  if pg_temp.has_err(r, 4, 'sale_rate') then
    perform pg_temp.fail('a plain number was wrongly rejected');
  end if;

  perform pg_temp.pass('bad numbers named by row and column, not a cast failure');
end $$;

-- =============================================================================
-- 9. Pack unit and pack size must agree
-- =============================================================================
do $$
declare r jsonb;
begin
  r := public.import_masters('product',
    '[{"code":"P30","name":"Pack unit no size","group_code":"G1",
       "base_uom":"PCS","pack_uom":"BOX"},
      {"code":"P31","name":"Size no unit","group_code":"G1",
       "base_uom":"PCS","pack_size":"12"}]'::jsonb, true);

  if not pg_temp.has_err(r, 2, 'pack_size') then
    perform pg_temp.fail('pack unit without a size not flagged');
  end if;

  if not pg_temp.has_err(r, 3, 'pack_uom') then
    perform pg_temp.fail('pack size without a unit not flagged');
  end if;

  perform pg_temp.pass('half-specified pack conversion caught');
end $$;

-- =============================================================================
-- 10. Parties: route lookup by code, dates in either format
-- =============================================================================
do $$
declare r jsonb;
begin
  r := public.import_masters('party',
    '[{"code":"C1","name":"Ram Store","route_code":"R1","phone":"9800000001",
       "credit_limit":"50000","credit_days":"30",
       "opening_balance":"12500","opening_balance_date":"01/04/2026"},
      {"code":"C2","name":"Shyam Traders","route_code":"R2"}]'::jsonb, false);

  perform pg_temp.eq((r ->> 'imported')::numeric, 2, 'parties imported');

  perform pg_temp.eq(
    (select opening_balance from public.party where code = 'C1'),
    12500, 'opening balance');

  if (select opening_balance_date from public.party where code = 'C1')
     <> date '2026-04-01' then
    perform pg_temp.fail('DD/MM/YYYY date not parsed correctly');
  end if;

  -- Route resolved by code, not by guesswork.
  if (select rt.code from public.party p join public.route rt on rt.id = p.route_id
       where p.code = 'C1') <> 'R1' then
    perform pg_temp.fail('party attached to the wrong route');
  end if;

  -- WhatsApp defaults to the phone number when not given separately.
  perform pg_temp.eq(
    case when (select whatsapp_phone from public.party where code = 'C1')
              = '9800000001' then 1 else 0 end, 1,
    'whatsapp defaults to phone');

  perform pg_temp.pass('parties import with route lookup and DD/MM/YYYY dates');
end $$;

-- =============================================================================
-- 11. An opening balance with no date cannot be aged, so it is refused
-- =============================================================================
do $$
declare r jsonb;
begin
  r := public.import_masters('party',
    '[{"code":"C9","name":"No date","route_code":"R1",
       "opening_balance":"5000"}]'::jsonb, true);

  if not pg_temp.has_err(r, 2, 'opening_balance_date') then
    perform pg_temp.fail('opening balance without a date not flagged');
  end if;

  perform pg_temp.pass('opening balance without a date refused');
end $$;

-- =============================================================================
-- 12. A bad row in the middle of a good batch writes nothing
-- =============================================================================
do $$
declare v_before integer; v_after integer;
begin
  select count(*) into v_before from public.party;

  begin
    perform public.import_masters('party',
      '[{"code":"D1","name":"Good One","route_code":"R1"},
        {"code":"D2","name":"Good Two","route_code":"R2"},
        {"code":"D3","name":"Bad One","route_code":"DOES_NOT_EXIST"},
        {"code":"D4","name":"Good Three","route_code":"R3"}]'::jsonb, false);
    perform pg_temp.fail('a batch with one bad row was imported');
  exception when sqlstate 'SA004' then
    null;
  end;

  select count(*) into v_after from public.party;
  perform pg_temp.eq(v_after - v_before, 0,
                     'not one row of the failed batch was written');

  perform pg_temp.pass('one bad row in four means nothing is imported');
end $$;

-- =============================================================================
-- 13. The refusal carries the full report so the client can show it
-- =============================================================================
do $$
declare v_detail text; v_rep jsonb;
begin
  begin
    perform public.import_masters('party',
      '[{"code":"E1","name":"Bad","route_code":"NOPE"}]'::jsonb, false);
    perform pg_temp.fail('should have been refused');
  exception when sqlstate 'SA004' then
    get stacked diagnostics v_detail = pg_exception_detail;
    v_rep := v_detail::jsonb;

    if (v_rep ->> 'entity') <> 'party' then
      perform pg_temp.fail('report does not name the entity');
    end if;
    if jsonb_array_length(v_rep -> 'error_detail') = 0 then
      perform pg_temp.fail('report carries no error detail');
    end if;

    perform pg_temp.pass('refusal carries the full error report');
  end;
end $$;

-- =============================================================================
-- 14. Imported opening stock reaches the ledger and reconciles
-- =============================================================================
do $$
begin
  perform public.post_opening_stock();

  perform pg_temp.eq(
    (select on_hand from public.product_stock ps
      join public.product p on p.id = ps.product_id where p.code = 'P1'),
    480, 'imported opening stock posted');

  if exists (select 1 from public.v_stock_reconciliation) then
    perform pg_temp.fail('imported stock does not reconcile');
  end if;

  perform pg_temp.pass('imported opening stock posts and reconciles');
end $$;

-- =============================================================================
-- 15b. The template's example row is caught if someone forgets to delete it
-- =============================================================================
do $$
declare r jsonb;
begin
  -- Exactly what the shipped template contains in row 2.
  r := public.import_masters('party',
    '[{"code":"EXAMPLE-C","name":"Example Store","route_code":"R1",
       "phone":"9800000001","credit_limit":"50000","credit_days":"30",
       "opening_balance":"12500","opening_balance_date":"2026-04-01"},
      {"code":"C50","name":"Real Customer","route_code":"R1"}]'::jsonb, true);

  if not pg_temp.has_err(r, 2, 'code') then
    perform pg_temp.fail('the example row was not caught');
  end if;

  if (select e ->> 'message' from jsonb_array_elements(r -> 'error_detail') e
       where (e ->> 'row')::int = 2 limit 1) not like '%example row%' then
    perform pg_temp.fail('the message should say it is the example row');
  end if;

  perform pg_temp.eq((r ->> 'errors')::numeric, 1,
                     'only the example row is a problem');

  -- And a real run refuses the whole batch rather than importing the good one.
  begin
    perform public.import_masters('party',
      '[{"code":"EXAMPLE-C","name":"Example Store","route_code":"R1"},
        {"code":"C51","name":"Real Customer","route_code":"R1"}]'::jsonb, false);
    perform pg_temp.fail('a batch containing the example row was imported');
  exception when sqlstate 'SA004' then
    null;
  end;

  if exists (select 1 from public.party where code in ('EXAMPLE-C', 'C51')) then
    perform pg_temp.fail('something from the refused batch was written');
  end if;

  perform pg_temp.pass('forgotten example row refuses the batch, nothing written');
end $$;

-- =============================================================================
-- 15. An unknown entity name is rejected clearly
-- =============================================================================
do $$
begin
  begin
    perform public.import_masters('customers', '[{"code":"X"}]'::jsonb, true);
    perform pg_temp.fail('an unknown entity was accepted');
  exception when sqlstate 'SA004' then
    perform pg_temp.pass('unknown entity name rejected with the valid list');
  end;
end $$;

-- -----------------------------------------------------------------------------

do $$
begin
  raise notice '';
  raise notice '=====================================';
  raise notice ' All import tests passed.';
  raise notice '=====================================';
end $$;
