-- =============================================================================
-- 016_own_order_tests.sql
-- A rep works their own orders; the office works everyone's (migration 031).
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

-- Three people: the office, and two reps who share a route.
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'admin@test.local'),
  ('22222222-2222-2222-2222-222222222222', 'ram@test.local'),
  ('33333333-3333-3333-3333-333333333333', 'shyam@test.local');
insert into public.app_user (id, full_name, role) values
  ('11111111-1111-1111-1111-111111111111', 'Office',      'ADMIN'),
  ('22222222-2222-2222-2222-222222222222', 'Ram Bahadur', 'REP'),
  ('33333333-3333-3333-3333-333333333333', 'Shyam Lal',   'REP');

create or replace function pg_temp.be(p_user uuid) returns void
language plpgsql as $$
begin
  execute format('set request.jwt.claim.sub = %L', p_user);
end; $$;

select pg_temp.be('11111111-1111-1111-1111-111111111111');

do $$
begin
  perform public.import_masters('route', '[{"code":"R1","name":"Town"}]'::jsonb, false);
  perform public.import_masters('product_group',
    '[{"code":"GC","name":"Candy","master_code":"CURRENT"}]'::jsonb, false);
  perform public.import_masters('party',
    '[{"code":"C1","name":"Ram Store","route_code":"R1"}]'::jsonb, false);
  perform public.import_masters('product',
    '[{"code":"P1","name":"Banana Candy","group_code":"GC","base_uom":"PCS",
       "sale_price":"20","opening_qty":"1000","opening_price":"16",
       "opening_date":"2026-04-01"}]'::jsonb, false);
  perform public.post_opening_stock();
end $$;

create or replace function pg_temp.pid(p_code text) returns uuid
language sql stable as $$ select id from public.product where code = p_code; $$;

create or replace function pg_temp.party() returns uuid
language sql stable as $$ select id from public.party where code = 'C1'; $$;

create or replace function pg_temp.an_order(p_qty numeric) returns uuid
language plpgsql as $$
declare r jsonb;
begin
  r := public.create_sales_order(pg_temp.party(), current_date,
         jsonb_build_array(jsonb_build_object(
           'product_id', pg_temp.pid('P1'), 'uom', 'BASE',
           'qty', p_qty, 'rate', 20)));
  return (r ->> 'order_id')::uuid;
end; $$;

create or replace function pg_temp.lines_of(p_qty numeric) returns jsonb
language sql stable as $$
  select jsonb_build_array(jsonb_build_object(
    'product_id', pg_temp.pid('P1'), 'uom', 'BASE', 'qty', p_qty, 'rate', 20));
$$;


-- =============================================================================
-- 1. A rep may change the order they took
-- =============================================================================
do $$
declare v_order uuid; v_qty numeric;
begin
  perform pg_temp.be('22222222-2222-2222-2222-222222222222');
  v_order := pg_temp.an_order(10);

  perform public.modify_sales_order(v_order, pg_temp.lines_of(25));

  select qty into v_qty from public.sales_order_line where order_id = v_order;
  perform pg_temp.eq(v_qty, 25::numeric, 'the rep''s own order took the change');
  perform pg_temp.pass('a rep may change the order they took');
end $$;


-- =============================================================================
-- 2. A rep may not change another rep's order, and is told whose it is
-- =============================================================================
do $$
declare v_order uuid; v_msg text; v_code text;
begin
  perform pg_temp.be('22222222-2222-2222-2222-222222222222');
  v_order := pg_temp.an_order(10);

  perform pg_temp.be('33333333-3333-3333-3333-333333333333');
  begin
    perform public.modify_sales_order(v_order, pg_temp.lines_of(99));
    raise exception 'FAIL  a rep changed another rep''s order';
  exception when others then
    get stacked diagnostics v_msg = message_text, v_code = returned_sqlstate;
    if v_msg like 'FAIL%' then raise; end if;
    perform pg_temp.eq(v_code, 'SA003', 'refusing another rep''s order is a permission error');
    if v_msg not like '%Ram Bahadur%' then
      raise exception 'FAIL  the refusal should name whose order it is, got: %', v_msg;
    end if;
  end;

  perform pg_temp.pass('a rep may not change another rep''s order, and is told whose it is');
end $$;


-- =============================================================================
-- 3. Nor cancel it — cancelling cannot be looser than editing
-- =============================================================================
do $$
declare v_order uuid; v_code text; v_msg text; v_status app.order_status;
begin
  perform pg_temp.be('22222222-2222-2222-2222-222222222222');
  v_order := pg_temp.an_order(10);

  perform pg_temp.be('33333333-3333-3333-3333-333333333333');
  begin
    perform public.cancel_sales_order(v_order, 'not mine to scrap');
    raise exception 'FAIL  a rep cancelled another rep''s order';
  exception when others then
    get stacked diagnostics v_msg = message_text, v_code = returned_sqlstate;
    if v_msg like 'FAIL%' then raise; end if;
    perform pg_temp.eq(v_code, 'SA003', 'refusing to cancel is a permission error');
  end;

  select status into v_status from public.sales_order where id = v_order;
  perform pg_temp.eq(v_status::text, 'SUBMITTED', 'the order survived the attempt');
  perform pg_temp.pass('a rep may not cancel another rep''s order');
end $$;


-- =============================================================================
-- 4. The office may change and cancel anybody's
-- =============================================================================
do $$
declare v_order uuid; v_qty numeric; v_status app.order_status;
begin
  perform pg_temp.be('22222222-2222-2222-2222-222222222222');
  v_order := pg_temp.an_order(10);

  perform pg_temp.be('11111111-1111-1111-1111-111111111111');
  perform public.modify_sales_order(v_order, pg_temp.lines_of(7));
  select qty into v_qty from public.sales_order_line where order_id = v_order;
  perform pg_temp.eq(v_qty, 7::numeric, 'the office changed a rep''s order');

  perform public.cancel_sales_order(v_order, 'customer changed their mind');
  select status into v_status from public.sales_order where id = v_order;
  perform pg_temp.eq(v_status::text, 'CANCELLED', 'the office cancelled a rep''s order');

  perform pg_temp.pass('the office may change and cancel anybody''s order');
end $$;


-- =============================================================================
-- 5. A refused change leaves the order and its reservation exactly as they were
--
-- modify_sales_order releases the reservation before rebuilding the lines. If
-- the ownership check ran after that, a refused attempt would hand the stock
-- back while leaving the order claiming it.
-- =============================================================================
do $$
declare
  v_order uuid;
  v_before numeric;
  v_after numeric;
  v_qty numeric;
begin
  perform pg_temp.be('22222222-2222-2222-2222-222222222222');
  v_order := pg_temp.an_order(40);

  select available into v_before from public.v_stock_report where product_id = pg_temp.pid('P1');

  perform pg_temp.be('33333333-3333-3333-3333-333333333333');
  begin
    perform public.modify_sales_order(v_order, pg_temp.lines_of(1));
  exception when others then null;
  end;

  perform pg_temp.be('11111111-1111-1111-1111-111111111111');
  select available into v_after from public.v_stock_report where product_id = pg_temp.pid('P1');
  select qty into v_qty from public.sales_order_line where order_id = v_order;

  perform pg_temp.eq(v_after, v_before, 'the reservation was not released by the refusal');
  perform pg_temp.eq(v_qty, 40::numeric, 'the lines were not touched');
  perform pg_temp.pass('a refused change leaves the order and its stock alone');
end $$;


-- =============================================================================
-- 6. An order nobody is recorded as having raised is nobody's to protect
-- =============================================================================
do $$
declare v_order uuid; v_qty numeric;
begin
  perform pg_temp.be('11111111-1111-1111-1111-111111111111');
  v_order := pg_temp.an_order(5);
  update public.sales_order set created_by = null where id = v_order;

  perform pg_temp.be('33333333-3333-3333-3333-333333333333');
  perform public.modify_sales_order(v_order, pg_temp.lines_of(6));
  perform pg_temp.be('11111111-1111-1111-1111-111111111111');
  select qty into v_qty from public.sales_order_line where order_id = v_order;

  perform pg_temp.eq(v_qty, 6::numeric, 'an unowned order can still be corrected');
  perform pg_temp.pass('an order with no recorded author is nobody''s to protect');
end $$;


-- =============================================================================
-- 7. v_order_for_edit says whose the order is and whether it can be changed
-- =============================================================================
do $$
declare
  v_order uuid;
  r record;
begin
  perform pg_temp.be('22222222-2222-2222-2222-222222222222');
  v_order := pg_temp.an_order(3);

  select * into r from public.v_order_for_edit where order_id = v_order;
  perform pg_temp.eq(r.rep_name, 'Ram Bahadur', 'the view names the rep');
  perform pg_temp.eq(r.party_name, 'Ram Store', 'the view names the customer');
  perform pg_temp.eq(r.is_editable, true, 'a submitted, unbilled order is editable');

  -- Bill it, and it stops being editable.
  perform pg_temp.be('11111111-1111-1111-1111-111111111111');
  declare v_line uuid;
  begin
    select id into v_line from public.sales_order_line where order_id = v_order;
    perform public.create_sales_invoice(
      current_date,
      jsonb_build_array(jsonb_build_object(
        'order_line_id', v_line,
        'product_id', pg_temp.pid('P1'), 'uom', 'BASE', 'qty', 3, 'rate', 20)),
      v_order, null, 0, null, null);
  end;

  select * into r from public.v_order_for_edit where order_id = v_order;
  perform pg_temp.eq(r.is_editable, false, 'a billed order is not editable');

  perform pg_temp.pass('v_order_for_edit reports ownership and editability');
end $$;


-- =============================================================================
-- 8. And the database says no even when the screen would not have asked
-- =============================================================================
do $$
declare v_order uuid; v_code text; v_msg text;
begin
  perform pg_temp.be('22222222-2222-2222-2222-222222222222');
  v_order := pg_temp.an_order(2);

  perform pg_temp.be('11111111-1111-1111-1111-111111111111');
  perform public.cancel_sales_order(v_order, 'office cleanup');

  -- Already cancelled: the ownership check must still come first for a rep,
  -- so the message is about whose order it is rather than about its state.
  perform pg_temp.be('33333333-3333-3333-3333-333333333333');
  begin
    perform public.cancel_sales_order(v_order, 'trying anyway');
    raise exception 'FAIL  a cancelled order was cancelled again';
  exception when others then
    get stacked diagnostics v_msg = message_text, v_code = returned_sqlstate;
    if v_msg like 'FAIL%' then raise; end if;
    perform pg_temp.eq(v_code, 'SA003', 'ownership is checked before state');
  end;

  perform pg_temp.pass('ownership is settled before anything else about the order');
end $$;



-- =============================================================================
-- 9. The Orders list shows what the customer was quoted, not the gross
--
-- 029 discounted orders and this view was missed, so the Orders screen and the
-- day book disagreed about what the same order was worth.
-- =============================================================================
do $$
declare v_order uuid; r record;
begin
  perform pg_temp.be('22222222-2222-2222-2222-222222222222');
  r := null;

  -- 100 pieces at 20 = 2,000, less 10% on the line = 1,800, less 100 on the
  -- order = 1,700.
  declare res jsonb;
  begin
    res := public.create_sales_order(pg_temp.party(), current_date,
      jsonb_build_array(jsonb_build_object(
        'product_id', pg_temp.pid('P1'), 'uom', 'BASE',
        'qty', 100, 'rate', 20, 'line_discount_pct', 10)),
      null, 100, null);
    v_order := (res ->> 'order_id')::uuid;
  end;

  select * into r from public.v_pending_orders where order_id = v_order;
  perform pg_temp.eq(r.order_value, 1700::numeric, 'the list shows the quoted value');
  perform pg_temp.eq(r.gross_value, 2000::numeric, 'the gross is there beside it');
  perform pg_temp.eq(r.rep_id, '22222222-2222-2222-2222-222222222222'::uuid,
                     'the list says whose order it is');

  perform pg_temp.pass('the Orders list agrees with the day book about an order''s value');
end $$;

\echo '  9 of 9 passed.'
