-- =============================================================================
-- 020_register_opening_tests.sql
-- Opening balances stay out of the sales register (migration 036).
--
-- The failure this guards against is a quiet one. An opening document is a
-- real bill — it has a number, a party, a date and a value — so nothing about
-- it looks wrong in a list. It is only wrong when it is added up, and by then
-- the figure has already gone to the company.
--
-- So the tests check both directions: the register must not count it, and
-- every other place that shows a customer what they owe must still show it.
-- Removing it from the ageing would be a worse bug than the one being fixed.
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

-- Two customers, one of whom owed money at cutover, and one real sale.
do $$
begin
  perform public.import_masters('route', '[{"code":"R1","name":"Town"}]'::jsonb, false);
  perform public.import_masters('product_group',
    '[{"code":"GB","name":"Biscuits","master_code":"PARLE"}]'::jsonb, false);
  perform public.import_masters('party',
    ('[{"code":"C1","name":"Owed Us Money","route_code":"R1",
        "opening_balance":5000,"opening_balance_date":"' ||
        (current_date - 20)::text || '"},
       {"code":"C2","name":"New Shop","route_code":"R1"}]')::jsonb, false);
  perform public.import_masters('product',
    ('[{"code":"P1","name":"Biscuit","group_code":"GB","base_uom":"PCS",
        "pack_uom":"CTN","pack_size":40,"sale_price":1200,
        "purchase_price":1000,"opening_qty":400,
        "opening_date":"' || (current_date - 30)::text || '"}]')::jsonb, false);
  perform public.post_opening_stock();
  perform public.post_opening_balances(16);
end $$;

do $$
declare v_party uuid; v_prod uuid;
begin
  select id into v_party from public.party where code = 'C2';
  select id into v_prod  from public.product where code = 'P1';

  -- Ten pieces at 30 — a 300 rupee sale, against a 5,000 opening balance, so
  -- a register that counted both would be wrong by a factor anyone can see.
  perform public.create_sales_invoice(
    current_date,
    jsonb_build_array(jsonb_build_object(
      'product_id', v_prod, 'uom', 'BASE', 'qty', 10, 'rate', 30)),
    null, v_party);
end $$;

-- -----------------------------------------------------------------------------

do $$
declare n int;
begin
  select count(*) into n from public.sales_invoice where is_opening;
  perform pg_temp.eq(n, 1, 'one opening document was posted');
  perform pg_temp.pass('an opening balance becomes a document');
end $$;

do $$
declare n int;
begin
  select count(*) into n from public.v_sales_register where doc_no like 'OPN-%';
  perform pg_temp.eq(n, 0, 'opening documents in the register');
  perform pg_temp.pass('the register does not list an opening balance');
end $$;

do $$
declare n int; v numeric;
begin
  select count(*), coalesce(sum(net_total), 0) into n, v
    from public.v_sales_register;
  perform pg_temp.eq(n, 1, 'bills in the register');
  perform pg_temp.eq(v, 300::numeric, 'turnover in the register');
  perform pg_temp.pass('turnover is the real sale only, not 5,300');
end $$;

-- The half of the fix that is easy to get wrong: these must still show it.
do $$
declare n int;
begin
  select count(*) into n from public.v_invoice_list where doc_no like 'OPN-%';
  perform pg_temp.eq(n, 1, 'opening documents in the bill list');
  perform pg_temp.pass('the bill list still shows the opening balance');
end $$;

do $$
declare v numeric;
begin
  select outstanding into v from public.v_invoice_outstanding
   where doc_no like 'OPN-%';
  perform pg_temp.eq(v, 5000::numeric, 'what the shop still owes from before');
  perform pg_temp.pass('the opening balance is still owed, and still ages');
end $$;

-- An opening document has no lines, so it was never in the line-level view.
-- Asserted rather than assumed: it is the reason 036 leaves that view alone.
do $$
declare n int;
begin
  select count(*) into n from public.v_sales_register_lines where doc_no like 'OPN-%';
  perform pg_temp.eq(n, 0, 'opening documents among the register lines');
  perform pg_temp.pass('the product-wise sheet never saw one either');
end $$;

\echo '  6 of 6 passed.'
