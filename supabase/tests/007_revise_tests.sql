-- =============================================================================
-- 007_revise_tests.sql
-- Same-day correction of a bill (migration 020).
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
  perform public.import_masters('product_group', '[{"code":"G1","name":"Biscuits"}]'::jsonb, false);
  perform public.import_masters('party',
    '[{"code":"C1","name":"Ram Store","route_code":"R1"}]'::jsonb, false);
  perform public.import_masters('product',
    '[{"code":"P1","name":"Marie","group_code":"G1","base_uom":"PCS","pack_uom":"BOX",
       "pack_size":"24","sale_price":"480","opening_qty":"240","opening_price":"384",
       "opening_date":"2026-04-01"}]'::jsonb, false);
  perform public.post_opening_stock();
end $$;

-- =============================================================================
-- 1. A bill typed wrongly today is corrected in one go
-- =============================================================================
do $$
declare v_party uuid; v_prod uuid; v_inv uuid; r jsonb;
begin
  select id into v_party from public.party where code = 'C1';
  select id into v_prod  from public.product where code = 'P1';

  r := public.create_sales_invoice(current_date,
        jsonb_build_array(jsonb_build_object(
          'product_id', v_prod, 'uom', 'PACK', 'qty', 5, 'rate', 480)),
        null, v_party);
  v_inv := (r ->> 'invoice_id')::uuid;

  perform pg_temp.eq((select on_hand from public.product_stock where product_id = v_prod),
                     120, 'stock after the first bill');

  -- Meant three boxes, not five.
  r := public.revise_sales_invoice(v_inv,
        jsonb_build_array(jsonb_build_object(
          'product_id', v_prod, 'uom', 'PACK', 'qty', 3, 'rate', 480)));

  perform pg_temp.eq((select on_hand from public.product_stock where product_id = v_prod),
                     168, 'stock reflects the corrected quantity only');
  perform pg_temp.eq((select net_total from public.sales_invoice
                       where id = (r ->> 'invoice_id')::uuid), 1440, 'new bill total');
  perform pg_temp.eq((select cancelled_value from public.sales_invoice where id = v_inv),
                     2400, 'the wrong bill is fully cancelled');

  if (select status from public.sales_invoice where id = v_inv) <> 'CANCELLED' then
    perform pg_temp.fail('the replaced bill should be marked cancelled');
  end if;

  -- The customer owes the corrected amount, not both.
  perform pg_temp.eq((select balance from public.v_party_balance where party_id = v_party),
                     1440, 'party owes only the corrected bill');

  perform pg_temp.pass('a same-day mistake is corrected in one transaction');
end $$;

-- =============================================================================
-- 2. Yesterday's bill cannot be corrected this way
-- =============================================================================
do $$
declare v_party uuid; v_prod uuid; v_inv uuid; r jsonb;
begin
  select id into v_party from public.party where code = 'C1';
  select id into v_prod  from public.product where code = 'P1';

  r := public.create_sales_invoice(current_date,
        jsonb_build_array(jsonb_build_object(
          'product_id', v_prod, 'uom', 'BASE', 'qty', 10, 'rate', 20)),
        null, v_party);
  v_inv := (r ->> 'invoice_id')::uuid;

  -- Age it by a day, as if this were tomorrow morning.
  update public.sales_invoice
     set invoice_date = current_date - 1, created_at = now() - interval '1 day'
   where id = v_inv;

  begin
    perform public.revise_sales_invoice(v_inv,
      jsonb_build_array(jsonb_build_object(
        'product_id', v_prod, 'uom', 'BASE', 'qty', 5, 'rate', 20)));
    perform pg_temp.fail('an old bill was corrected');
  exception when sqlstate 'SA002' then null;
  end;

  perform pg_temp.pass('only today''s bills can be corrected');
end $$;

-- =============================================================================
-- 3. A bill with money against it is refused
-- =============================================================================
do $$
declare v_party uuid; v_prod uuid; v_inv uuid; v_rec uuid; r jsonb;
begin
  select id into v_party from public.party where code = 'C1';
  select id into v_prod  from public.product where code = 'P1';

  r := public.create_sales_invoice(current_date,
        jsonb_build_array(jsonb_build_object(
          'product_id', v_prod, 'uom', 'BASE', 'qty', 10, 'rate', 20)),
        null, v_party);
  v_inv := (r ->> 'invoice_id')::uuid;

  r := public.create_receipt(v_party, current_date, 'CASH', 100);
  v_rec := (r ->> 'receipt_id')::uuid;

  perform public.allocate_credit(
    jsonb_build_array(jsonb_build_object('invoice_id', v_inv, 'amount', 100)),
    v_rec, null);

  begin
    perform public.revise_sales_invoice(v_inv,
      jsonb_build_array(jsonb_build_object(
        'product_id', v_prod, 'uom', 'BASE', 'qty', 5, 'rate', 20)));
    perform pg_temp.fail('a paid bill was corrected');
  exception when sqlstate 'SA002' then null;
  end;

  perform pg_temp.pass('a bill with a payment against it is not silently rewritten');
end $$;

-- =============================================================================
-- 4. Correcting an order-based bill hands the quantity back to the order
-- =============================================================================
do $$
declare v_party uuid; v_prod uuid; v_ord uuid; v_line uuid; v_inv uuid; r jsonb;
begin
  select id into v_party from public.party where code = 'C1';
  select id into v_prod  from public.product where code = 'P1';

  r := public.create_sales_order(v_party, current_date,
        jsonb_build_array(jsonb_build_object(
          'product_id', v_prod, 'uom', 'PACK', 'qty', 2, 'rate', 480)));
  v_ord := (r ->> 'order_id')::uuid;
  select id into v_line from public.sales_order_line where order_id = v_ord;

  r := public.create_sales_invoice(current_date,
        jsonb_build_array(jsonb_build_object(
          'order_line_id', v_line, 'uom', 'PACK', 'qty', 2, 'rate', 480)),
        v_ord);
  v_inv := (r ->> 'invoice_id')::uuid;

  perform pg_temp.eq((select qty_pending_base from public.sales_order_line where id = v_line),
                     0, 'order fully billed');

  r := public.revise_sales_invoice(v_inv,
        jsonb_build_array(jsonb_build_object(
          'order_line_id', v_line, 'uom', 'PACK', 'qty', 1, 'rate', 480)));

  perform pg_temp.eq((select qty_pending_base from public.sales_order_line where id = v_line),
                     24, 'the box taken off the bill is pending on the order again');
  if (select status from public.sales_order where id = v_ord) <> 'PARTIALLY_INVOICED' then
    perform pg_temp.fail('the order should be back to partly invoiced');
  end if;

  perform pg_temp.pass('correcting an order-based bill restores the order');
end $$;

do $$
begin
  raise notice '';
  raise notice '=====================================';
  raise notice ' All revise tests passed.';
  raise notice '=====================================';
end $$;
