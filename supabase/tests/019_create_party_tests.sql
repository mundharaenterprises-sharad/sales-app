-- =============================================================================
-- 019_create_party_tests.sql
-- Adding a customer, the codes that get generated, and the stock ledger
-- (migration 035).
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
  ('22222222-2222-2222-2222-222222222222', 'ram@test.local');
insert into public.app_user (id, full_name, role) values
  ('11111111-1111-1111-1111-111111111111', 'Office', 'ADMIN'),
  ('22222222-2222-2222-2222-222222222222', 'Ram Bahadur', 'REP');

create or replace function pg_temp.be(p_user uuid) returns void
language plpgsql as $$
begin execute format('set request.jwt.claim.sub = %L', p_user); end; $$;

select pg_temp.be('11111111-1111-1111-1111-111111111111');

do $$
begin
  perform public.import_masters('route', '[{"code":"R1","name":"Town"}]'::jsonb, false);
  perform public.import_masters('product_group',
    '[{"code":"GB","name":"Biscuits","master_code":"PARLE"}]'::jsonb, false);
  -- Codes as Sharad actually uses them: letters then a number, no padding,
  -- and deliberately not in order so "the highest" is not "the last".
  perform public.import_masters('party',
    '[{"code":"AA1","name":"Ram Store","route_code":"R1"},
      {"code":"AA340","name":"Shyam Store","route_code":"R1"},
      {"code":"AA7","name":"Gita Store","route_code":"R1"}]'::jsonb, false);
  perform public.import_masters('product',
    '[{"code":"PP82","name":"Parle G","group_code":"GB","base_uom":"PCS",
       "sale_price":"10","opening_qty":"100","opening_price":"8",
       "opening_date":"2026-04-01"}]'::jsonb, false);
  perform public.post_opening_stock();
end $$;

create or replace function pg_temp.route() returns uuid
language sql stable as $$ select id from public.route where code = 'R1'; $$;


-- =============================================================================
-- 1. The suggested code continues the sequence in use
-- =============================================================================
do $$
begin
  perform pg_temp.eq(public.suggest_master_code('party'), 'AA341',
    'the next party code follows the highest in use, not the last created');
  perform pg_temp.eq(public.suggest_master_code('product'), 'PP83',
    'and products have their own sequence');
  perform pg_temp.pass('the next code continues the sequence already in use');
end $$;


-- =============================================================================
-- 2. A rep can add a customer, and it gets the next code
-- =============================================================================
do $$
declare r jsonb; p record;
begin
  perform pg_temp.be('22222222-2222-2222-2222-222222222222');
  r := public.create_party('Hari Kirana Pasal', pg_temp.route(), '9800000000', 'Lahan');

  perform pg_temp.eq(r ->> 'code', 'AA341', 'the new customer takes the next code');

  select * into p from public.party where id = (r ->> 'party_id')::uuid;
  perform pg_temp.eq(p.name, 'Hari Kirana Pasal', 'with the name as given');
  perform pg_temp.eq(p.phone, '9800000000', 'and the phone');
  perform pg_temp.eq(p.is_active, true, 'and is active straight away');
  -- The two things a rep must not be setting from a shop doorway.
  perform pg_temp.eq(p.opening_balance, 0::numeric, 'with no opening balance');
  perform pg_temp.eq(p.credit_limit, 0::numeric, 'and no credit limit');

  perform pg_temp.pass('a rep can add a customer and it takes the next code');
end $$;


-- =============================================================================
-- 3. And the one after that is the one after that
-- =============================================================================
do $$
declare r jsonb;
begin
  perform pg_temp.be('22222222-2222-2222-2222-222222222222');
  r := public.create_party('Bina Stores', pg_temp.route());
  perform pg_temp.eq(r ->> 'code', 'AA342', 'the sequence moves on');
  perform pg_temp.eq(public.suggest_master_code('party'), 'AA343',
    'and the suggestion keeps up');
  perform pg_temp.pass('codes keep going up');
end $$;


-- =============================================================================
-- 4. A rep still cannot change one
-- =============================================================================
--
-- Checked structurally rather than by trying it, and the reason matters: this
-- suite runs as a superuser, and a superuser bypasses row-level security
-- altogether. An UPDATE here would succeed no matter what the policies say,
-- so a test that ran one would pass whether reps were locked out or not —
-- worse than no test. What can be checked truthfully is that the only write
-- policies on party still require an admin, and that adding a customer goes
-- through the function rather than around it.
do $$
declare v_insert text; v_update text; n integer;
begin
  select qual, with_check into v_update, v_insert
    from pg_policies
   where schemaname = 'public' and tablename = 'party' and cmd = 'UPDATE';

  if v_update is null or v_update not like '%is_admin%' then
    raise exception 'FAIL  a party update should still require an admin, policy reads: %',
      coalesce(v_update, '(none)');
  end if;

  select with_check into v_insert
    from pg_policies
   where schemaname = 'public' and tablename = 'party' and cmd = 'INSERT';

  if v_insert is null or v_insert not like '%is_admin%' then
    raise exception 'FAIL  the insert policy should still be admin-only — the rep''s way in is create_party, not a wider gate. Policy reads: %',
      coalesce(v_insert, '(none)');
  end if;

  -- And no policy has quietly appeared that lets anyone else write.
  select count(*) into n
    from pg_policies
   where schemaname = 'public' and tablename = 'party'
     and cmd in ('UPDATE', 'INSERT', 'ALL', 'DELETE')
     and coalesce(qual, '') || coalesce(with_check, '') not like '%is_admin%';
  perform pg_temp.eq(n, 0, 'no write policy on party skips the admin check');

  perform pg_temp.pass('editing a party is still admin-only; create_party is the only other door');
end $$;


-- =============================================================================
-- 5. Two customers of the same name are refused
--
-- The whole reason this is a function and not a looser policy.
-- =============================================================================
do $$
declare v_code text; v_msg text;
begin
  perform pg_temp.be('22222222-2222-2222-2222-222222222222');
  begin
    perform public.create_party('  ram store  ', pg_temp.route());
    raise exception 'FAIL  a duplicate name was accepted';
  exception when others then
    get stacked diagnostics v_msg = message_text, v_code = returned_sqlstate;
    if v_msg like 'FAIL%' then raise; end if;
    perform pg_temp.eq(v_code, 'SA004', 'a duplicate name is refused as bad input');
    -- Named as the existing customer is written, with its code, so somebody
    -- can go and find it — not echoed back as the caller typed it.
    if v_msg not like '%Ram Store (AA1)%' then
      raise exception 'FAIL  the refusal should name the customer it clashes with, got: %', v_msg;
    end if;
  end;

  perform pg_temp.pass('the same name, however spaced or cased, is refused');
end $$;


-- =============================================================================
-- 6. A name or a route that makes no sense is refused
-- =============================================================================
do $$
declare v_code text; v_msg text;
begin
  perform pg_temp.be('22222222-2222-2222-2222-222222222222');

  begin
    perform public.create_party('   ', pg_temp.route());
    raise exception 'FAIL  a blank name was accepted';
  exception when others then
    get stacked diagnostics v_msg = message_text, v_code = returned_sqlstate;
    if v_msg like 'FAIL%' then raise; end if;
    perform pg_temp.eq(v_code, 'SA004', 'a blank name is refused');
  end;

  begin
    perform public.create_party('Somebody', '00000000-0000-0000-0000-000000000000');
    raise exception 'FAIL  an unknown route was accepted';
  exception when others then
    get stacked diagnostics v_msg = message_text, v_code = returned_sqlstate;
    if v_msg like 'FAIL%' then raise; end if;
    perform pg_temp.eq(v_code, 'SA004', 'an unknown route is refused');
  end;

  perform pg_temp.pass('a blank name or an unknown route is refused');
end $$;


-- =============================================================================
-- 7. A code with letters after the number does not break the reckoning
-- =============================================================================
do $$
declare r jsonb;
begin
  perform pg_temp.be('11111111-1111-1111-1111-111111111111');
  perform public.import_masters('party',
    '[{"code":"AA400-B","name":"Hand Coded Shop","route_code":"R1"}]'::jsonb, false);

  -- AA400-B is not AA-then-digits, so it is not in the sequence and must not
  -- drag the next code to AA401.
  perform pg_temp.eq(public.suggest_master_code('party'), 'AA343',
    'a hand-typed code is left out of the reckoning');

  perform pg_temp.be('22222222-2222-2222-2222-222222222222');
  r := public.create_party('Another Shop', pg_temp.route());
  perform pg_temp.eq(r ->> 'code', 'AA343', 'and the next real code is unaffected');

  perform pg_temp.pass('an odd code neither breaks nor skews the sequence');
end $$;


-- =============================================================================
-- 8. The stock ledger runs a balance that matches what is on hand
-- =============================================================================
do $$
declare
  v_pid uuid; v_last numeric; v_hand numeric; n integer;
begin
  perform pg_temp.be('11111111-1111-1111-1111-111111111111');
  select id into v_pid from public.product where code = 'PP82';

  -- Sell some, so the ledger has more than its opening row.
  perform public.create_sales_invoice(current_date,
    jsonb_build_array(jsonb_build_object(
      'product_id', v_pid, 'uom', 'BASE', 'qty', 30, 'rate', 10)),
    null, (select id from public.party where code = 'AA1'));

  select count(*) into n from public.v_stock_ledger where product_id = v_pid;
  if n < 2 then
    raise exception 'FAIL  the ledger should have an opening and a sale, has %', n;
  end if;

  select balance_after into v_last
    from public.v_stock_ledger
   where product_id = v_pid
   order by movement_date desc, created_at desc, id desc
   limit 1;

  select on_hand into v_hand from public.product_stock where product_id = v_pid;

  -- The point of the whole screen: the last line of the ledger is the stock.
  perform pg_temp.eq(v_last, v_hand, 'the ledger ends at what is on hand');
  perform pg_temp.eq(v_hand, 70::numeric, 'which is the opening less what was sold');

  perform pg_temp.pass('the running balance ends at what is actually on hand');
end $$;


-- =============================================================================
-- 9. The ledger says where each movement came from
-- =============================================================================
do $$
declare r record;
begin
  select * into r from public.v_stock_ledger
   where doc_type = 'SALE' order by created_at desc limit 1;

  perform pg_temp.eq(r.product_code, 'PP82', 'the movement names the product');
  perform pg_temp.eq(r.qty_out, 30::numeric, 'and how much went out');
  perform pg_temp.eq(r.entered_by, 'Office', 'and who entered it');
  if r.doc_id is null then
    raise exception 'FAIL  a movement should point at the document that caused it';
  end if;

  perform pg_temp.pass('every movement points at the document behind it');
end $$;

\echo '  9 of 9 passed.'
