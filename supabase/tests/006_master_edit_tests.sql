-- =============================================================================
-- 006_master_edit_tests.sql
-- Editing parties and products by hand (migration 019): who may, which fields
-- are fixed, and when opening figures freeze.
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

-- Fixtures: one route, one group, a party and two products.
do $$
begin
  perform public.import_masters('route', '[{"code":"R1","name":"Town"}]'::jsonb, false);
  perform public.import_masters('product_group', '[{"code":"G1","name":"Biscuits","master_code":"OTHERS"}]'::jsonb, false);
  perform public.import_masters('party',
    '[{"code":"C1","name":"Ram Store","route_code":"R1"},
      {"code":"C2","name":"Sita Traders","route_code":"R1"}]'::jsonb, false);
  perform public.import_masters('product',
    '[{"code":"P1","name":"Marie","group_code":"G1","base_uom":"PCS","pack_uom":"BOX",
       "pack_size":"24","sale_price":"480","opening_qty":"240","opening_price":"384",
       "opening_date":"2026-04-01"},
      {"code":"P2","name":"Noodles","group_code":"G1","base_uom":"PCS",
       "sale_price":"20"}]'::jsonb, false);
end $$;

-- =============================================================================
-- 1. Admin edits and adds through the tables, as the screens do, under RLS
-- =============================================================================
do $$
begin
  set local role authenticated;
  set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

  update public.party set phone = '9800000000', credit_limit = 50000,
                          opening_balance = 1500, opening_balance_date = '2026-04-01'
   where code = 'C1';

  insert into public.party (code, name, route_id)
  select 'C3', 'New Shop', id from public.route where code = 'R1';

  update public.product set pack_sale_rate = 504 where code = 'P1';

  insert into public.product (code, name, group_id, base_uom, pack_uom, pack_size, pack_sale_rate)
  select 'P3', 'Wafers', id, 'PCS', 'BOX', 12, 300 from public.product_group where code = 'G1';

  reset role;

  perform pg_temp.eq((select credit_limit from public.party where code = 'C1'), 50000, 'party edited');
  perform pg_temp.eq((select count(*) from public.party), 3, 'party added');
  perform pg_temp.eq((select sale_rate from public.product where code = 'P1'), 21, 'box price edit re-derives');
  perform pg_temp.eq((select sale_rate from public.product where code = 'P3'), 25, 'new product derived');
  perform pg_temp.eq((select count(*) from public.product_stock ps
                        join public.product p on p.id = ps.product_id where p.code = 'P3'),
                     1, 'new product gets a stock row');
  perform pg_temp.pass('Admin can edit and add parties and products');
end $$;

-- =============================================================================
-- 2. Nobody else can
-- =============================================================================
do $$
declare n integer;
begin
  set local role authenticated;
  set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';

  update public.party set phone = 'hacked' where code = 'C1';
  get diagnostics n = row_count;
  reset role;
  if n <> 0 then perform pg_temp.fail('a REP edited a party'); end if;
  perform pg_temp.pass('a REP cannot edit masters');
end $$;

-- =============================================================================
-- 3. Codes never change
-- =============================================================================
do $$
begin
  begin
    update public.party set code = 'C9' where code = 'C1';
    perform pg_temp.fail('a party code changed');
  exception when sqlstate 'SA004' then null;
  end;
  begin
    update public.product set code = 'P9' where code = 'P1';
    perform pg_temp.fail('a product code changed');
  exception when sqlstate 'SA004' then null;
  end;
  perform pg_temp.pass('codes cannot be changed');
end $$;

-- =============================================================================
-- 4. Opening stock is open until posted, then frozen
-- =============================================================================
do $$
begin
  update public.product set opening_qty = 480 where code = 'P1';
  perform pg_temp.eq((select opening_qty from public.product where code = 'P1'), 480,
                     'opening qty editable before posting');

  perform public.post_opening_stock();

  if not (select opening_locked from public.v_product_master where code = 'P1') then
    perform pg_temp.fail('v_product_master should show P1 locked');
  end if;
  if (select opening_locked from public.v_product_master where code = 'P2') then
    perform pg_temp.fail('P2 has no opening stock posted and should be open');
  end if;

  begin
    update public.product set opening_qty = 1 where code = 'P1';
    perform pg_temp.fail('posted opening stock was edited');
  exception when sqlstate 'SA002' then null;
  end;

  -- Other fields stay editable.
  update public.product set name = 'Marie Gold' where code = 'P1';
  perform pg_temp.pass('opening stock frozen once posted; the rest stays editable');
end $$;

-- =============================================================================
-- 5. Opening balance is open until the party's first document, then frozen
-- =============================================================================
do $$
declare v_party uuid; v_prod uuid;
begin
  select id into v_party from public.party where code = 'C2';
  select id into v_prod  from public.product where code = 'P1';

  update public.party set opening_balance = 2000, opening_balance_date = '2026-04-01'
   where id = v_party;

  perform public.create_sales_order(v_party, current_date,
    jsonb_build_array(jsonb_build_object('product_id', v_prod, 'uom', 'PACK',
                                         'qty', 1, 'rate', 504)));

  if not (select opening_locked from public.v_party_master where code = 'C2') then
    perform pg_temp.fail('v_party_master should show C2 locked');
  end if;

  begin
    update public.party set opening_balance = 0 where id = v_party;
    perform pg_temp.fail('opening balance changed after an order');
  exception when sqlstate 'SA002' then null;
  end;

  update public.party set phone = '9811111111' where id = v_party;
  perform pg_temp.pass('opening balance frozen after the first document');
end $$;

do $$
begin
  raise notice '';
  raise notice '=====================================';
  raise notice ' All master editing tests passed.';
  raise notice '=====================================';
end $$;
