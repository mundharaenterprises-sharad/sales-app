-- =============================================================================
-- 021_order_remarks_tests.sql
-- A remark survives an order being edited (migration 037).
--
-- The bug was silent: modify_sales_order simply had nowhere to put a remark,
-- so changing one succeeded, reported success, and changed nothing. Nobody
-- finds that by looking at a screen — the box still shows what you typed. It
-- only shows up on the printed bill, days later.
--
-- So the assertions are about what is IN the row after a modify, not about
-- whether the call succeeded.
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
        "purchase_price":1000,"opening_qty":4000,
        "opening_date":"' || (current_date - 30)::text || '"}]')::jsonb, false);
  perform public.post_opening_stock();
end $$;

create or replace function pg_temp.lines(p_qty numeric, p_disc numeric default null)
returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object(
    'product_id', (select id from public.product where code = 'P1'),
    'uom', 'BASE', 'qty', p_qty, 'rate', 30,
    'line_discount_pct', p_disc));
$$;

create or replace function pg_temp.order_id() returns uuid
language sql as $$ select id from public.sales_order order by created_at limit 1 $$;

create or replace function pg_temp.remark() returns text
language sql as $$ select remarks from public.sales_order where id = pg_temp.order_id() $$;

-- -----------------------------------------------------------------------------

do $$
declare r jsonb;
begin
  r := public.create_sales_order(
    (select id from public.party where code = 'C1'),
    current_date, pg_temp.lines(10), 'Deliver after 4pm');
  perform pg_temp.eq(pg_temp.remark(), 'Deliver after 4pm',
    'the remark a new order was written with');
  perform pg_temp.pass('a new order keeps its remark');
end $$;

do $$
begin
  perform public.modify_sales_order(pg_temp.order_id(), pg_temp.lines(12));
  perform pg_temp.eq(pg_temp.remark(), 'Deliver after 4pm',
    'the remark after an edit that did not mention it');
  perform pg_temp.pass('an edit that says nothing about the remark leaves it alone');
end $$;

do $$
begin
  perform public.modify_sales_order(pg_temp.order_id(), pg_temp.lines(12),
                                    null, null, 'Deliver before noon instead');
  perform pg_temp.eq(pg_temp.remark(), 'Deliver before noon instead',
    'the remark after it was changed');
  perform pg_temp.pass('and an edit CAN change it — which it could not before 037');
end $$;

do $$
begin
  perform public.modify_sales_order(pg_temp.order_id(), pg_temp.lines(12),
                                    null, null, '   ');
  perform pg_temp.eq(pg_temp.remark(), null::text, 'the remark after clearing the box');
  perform pg_temp.pass('an emptied box clears it, and clears it to null not ""');
end $$;

-- The whole point: what the bill ends up printing.
do $$
declare v_remark text;
begin
  perform public.modify_sales_order(pg_temp.order_id(), pg_temp.lines(12),
                                    null, null, 'Short credit, 7 days');

  perform public.create_sales_invoice(
    current_date,
    -- An order-based bill names the order line each bill line came from.
    (select jsonb_agg(jsonb_build_object(
              'order_line_id', sol.id, 'product_id', sol.product_id,
              'uom', sol.uom, 'qty', sol.qty, 'rate', sol.rate,
              'line_discount_pct', sol.line_discount_pct))
       from public.sales_order_line sol where sol.order_id = pg_temp.order_id()),
    pg_temp.order_id(),
    (select id from public.party where code = 'C1'),
    0, null,
    -- The billing screen sends the order's remark on, which is what it does
    -- in the app: it loads the order's remark into its own box.
    (select remarks from public.sales_order where id = pg_temp.order_id()));

  select remarks into v_remark from public.sales_invoice
   where order_id = pg_temp.order_id();
  perform pg_temp.eq(v_remark, 'Short credit, 7 days', 'the remark on the bill');
  perform pg_temp.pass('and it reaches the bill, which is where it was missed');
end $$;

-- Four arguments must no longer resolve, or every call is ambiguous.
do $$
begin
  if to_regprocedure('public.modify_sales_order(uuid,jsonb,numeric,numeric)') is not null then
    raise exception 'FAIL  the four-argument modify_sales_order is still there';
  end if;
  perform pg_temp.pass('the old four-argument version is gone');
end $$;

\echo '  6 of 6 passed.'
