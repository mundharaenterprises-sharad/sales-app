-- =============================================================================
-- 013_purchase_daybook_tests.sql
-- Cancelling a purchase, and the day book (migration 027).
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
  ('33333333-3333-3333-3333-333333333333', 'rep@test.local');
insert into public.app_user (id, full_name, role) values
  ('11111111-1111-1111-1111-111111111111', 'Admin User', 'ADMIN'),
  ('33333333-3333-3333-3333-333333333333', 'Rep User', 'REP');
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

do $$
begin
  perform public.import_masters('route', '[{"code":"R1","name":"Town"}]'::jsonb, false);
  perform public.import_masters('supplier', '[{"code":"S1","name":"Parle Depot"}]'::jsonb, false);
  perform public.import_masters('product_group',
    '[{"code":"GP","name":"Biscuits","master_code":"PARLE"},
      {"code":"GC","name":"Candy","master_code":"CURRENT"}]'::jsonb, false);
  perform public.import_masters('party',
    '[{"code":"C1","name":"Ram Store","route_code":"R1"}]'::jsonb, false);
  perform public.import_masters('product',
    '[{"code":"PP","name":"Parle-G","group_code":"GP","base_uom":"PCS","sale_price":"10",
       "purchase_price":"8"},
      {"code":"PC","name":"Banana Candy","group_code":"GC","base_uom":"PCS",
       "sale_price":"20","purchase_price":"16"}]'::jsonb, false);
end $$;

create or replace function pg_temp.buy(p_code text, p_qty numeric, p_rate numeric)
returns uuid language plpgsql as $$
declare v_sup uuid; v_prod uuid; r jsonb;
begin
  select id into v_sup  from public.supplier where code = 'S1';
  select id into v_prod from public.product  where code = p_code;
  r := public.post_purchase(v_sup, current_date,
        jsonb_build_array(jsonb_build_object(
          'product_id', v_prod, 'uom', 'BASE', 'qty', p_qty, 'rate', p_rate)),
        0, 'SB-001', current_date, null);
  return (r ->> 'purchase_id')::uuid;
end; $$;


-- =============================================================================
-- 1. A purchase carries the master group of what was bought
-- =============================================================================
do $$
declare v_pur uuid;
begin
  v_pur := pg_temp.buy('PP', 100, 8);     -- 800 of Parle

  perform pg_temp.eq((select master_code from public.v_purchase_list
                       where purchase_id = v_pur),
                     'PARLE', 'the purchase is Parle');
  perform pg_temp.eq((select net_total from public.v_purchase_list
                       where purchase_id = v_pur),
                     800::numeric, 'and worth 800');
  perform pg_temp.eq((select on_hand from public.product_stock ps
                        join public.product p on p.id = ps.product_id
                       where p.code = 'PP'),
                     100::numeric, 'the stock arrived');
  perform pg_temp.pass('a purchase takes the master group of its lines');
end $$;


-- =============================================================================
-- 2. And cannot mix, same as a bill
-- =============================================================================
do $$
declare v_sup uuid; v_p uuid; v_c uuid; v_msg text;
begin
  select id into v_sup from public.supplier where code = 'S1';
  select id into v_p   from public.product  where code = 'PP';
  select id into v_c   from public.product  where code = 'PC';

  begin
    perform public.post_purchase(v_sup, current_date,
      jsonb_build_array(
        jsonb_build_object('product_id', v_p, 'uom', 'BASE', 'qty', 5, 'rate', 8),
        jsonb_build_object('product_id', v_c, 'uom', 'BASE', 'qty', 5, 'rate', 16)),
      0, null, null, null);
    raise exception 'FAIL  a mixed purchase should have been refused';
  exception when sqlstate 'SA004' then
    get stacked diagnostics v_msg = message_text;
  end;

  if v_msg not like 'A purchase cannot mix%' then
    raise exception 'FAIL  unexpected message: %', v_msg;
  end if;
  perform pg_temp.pass('a purchase mixing master groups is refused');
end $$;


-- =============================================================================
-- 3. Cancelling one puts the goods back out
-- =============================================================================
do $$
declare v_pur uuid; r jsonb;
begin
  v_pur := pg_temp.buy('PC', 50, 16);
  perform pg_temp.eq((select on_hand from public.product_stock ps
                        join public.product p on p.id = ps.product_id
                       where p.code = 'PC'),
                     50::numeric, 'fifty in');

  r := public.cancel_purchase(v_pur, 'Wrong supplier bill');
  perform pg_temp.eq(r ->> 'doc_no',
                     (select doc_no from public.purchase where id = v_pur),
                     'the document named');

  perform pg_temp.eq((select on_hand from public.product_stock ps
                        join public.product p on p.id = ps.product_id
                       where p.code = 'PC'),
                     0::numeric, 'and fifty back out');
  perform pg_temp.eq((select status::text from public.v_purchase_list
                       where purchase_id = v_pur),
                     'CANCELLED', 'marked cancelled');
  perform pg_temp.eq((select count(*)::int from public.stock_ledger
                       where doc_id = v_pur and doc_type = 'PURCHASE_CANCEL'),
                     1, 'one reversing ledger row, not an edited one');
  perform pg_temp.eq((select count(*)::int from public.v_stock_reconciliation),
                     0, 'the ledger and the cache still agree');
  perform pg_temp.pass('cancelling a purchase reverses the stock');
end $$;


-- =============================================================================
-- 4. Unless the goods have already gone
-- =============================================================================
do $$
declare v_pur uuid; v_party uuid; v_prod uuid; v_msg text; v_detail text;
begin
  v_pur := pg_temp.buy('PC', 30, 16);
  select id into v_party from public.party   where code = 'C1';
  select id into v_prod  from public.product where code = 'PC';

  -- Sell most of it.
  perform public.create_sales_invoice(current_date,
    jsonb_build_array(jsonb_build_object(
      'product_id', v_prod, 'uom', 'BASE', 'qty', 25, 'rate', 20)),
    null, v_party);

  begin
    perform public.cancel_purchase(v_pur, 'Changed my mind');
    raise exception 'FAIL  the cancellation should have been refused';
  exception when sqlstate 'SA001' then
    get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
  end;

  if v_msg not like '%already gone out%' then
    raise exception 'FAIL  unexpected message: %', v_msg;
  end if;
  if v_detail not like '%Banana Candy%' then
    raise exception 'FAIL  the detail should name the product, got: %', v_detail;
  end if;

  perform pg_temp.eq((select status::text from public.purchase where id = v_pur),
                     'ACTIVE', 'and the purchase is untouched');
  perform pg_temp.eq((select on_hand from public.product_stock ps
                        join public.product p on p.id = ps.product_id
                       where p.code = 'PC'),
                     5::numeric, 'as is the stock');
  perform pg_temp.pass('a purchase whose goods have been sold cannot be cancelled');
end $$;


-- =============================================================================
-- 5. A cancellation needs a reason, and a rep cannot buy
-- =============================================================================
do $$
declare v_pur uuid;
begin
  select purchase_id into v_pur from public.v_purchase_list
   where status = 'ACTIVE' order by created_at limit 1;

  begin
    perform public.cancel_purchase(v_pur, '   ');
    raise exception 'FAIL  a blank reason was accepted';
  exception when sqlstate 'SA004' then null;
  end;

  set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
  begin
    perform public.post_purchase(
      (select id from public.supplier where code = 'S1'), current_date,
      jsonb_build_array(jsonb_build_object(
        'product_id', (select id from public.product where code = 'PP'),
        'uom', 'BASE', 'qty', 1, 'rate', 8)), 0, null, null, null);
    raise exception 'FAIL  a rep posted a purchase';
  exception when sqlstate 'SA003' then null;
  end;
  set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

  perform pg_temp.pass('a reason is required, and reps cannot buy');
end $$;


-- =============================================================================
-- 6. The day book: every document of the day, in one place
-- =============================================================================
do $$
declare v_party uuid; v_prod uuid; v_inv uuid; r jsonb;
begin
  select id into v_party from public.party   where code = 'C1';
  select id into v_prod  from public.product where code = 'PP';

  -- A bill and a payment against it.
  r := public.create_sales_invoice(current_date,
        jsonb_build_array(jsonb_build_object(
          'product_id', v_prod, 'uom', 'BASE', 'qty', 10, 'rate', 10)),
        null, v_party);
  v_inv := (r ->> 'invoice_id')::uuid;

  perform public.receive_payment(v_party, current_date, 60,
    jsonb_build_array(jsonb_build_object('invoice_id', v_inv, 'amount', 60)));

  perform pg_temp.eq((select count(*)::int from public.v_day_book
                       where entry_date = current_date and doc_type = 'BILL'),
                     2, 'both bills of the day are listed');
  perform pg_temp.eq((select count(*)::int from public.v_day_book
                       where entry_date = current_date and doc_type = 'PAYMENT'),
                     1, 'and the payment');
  perform pg_temp.eq((select count(*)::int from public.v_day_book
                       where entry_date = current_date and doc_type = 'PURCHASE'),
                     3, 'and all three purchases, cancelled one included');

  perform pg_temp.eq((select who from public.v_day_book
                       where doc_type = 'PAYMENT' and entry_date = current_date),
                     'Ram Store', 'a payment says who paid');
  perform pg_temp.eq((select who from public.v_day_book
                       where doc_type = 'PURCHASE' and entry_date = current_date
                       limit 1),
                     'Parle Depot', 'a purchase says who was bought from');
  perform pg_temp.pass('the day book lists every kind of document');
end $$;


-- =============================================================================
-- 7. The day's figures — and cancelled work counts as zero, not as money
-- =============================================================================
do $$
declare v_sales numeric; v_purch numeric; v_recv numeric;
begin
  select sales, purchases, receipts into v_sales, v_purch, v_recv
    from public.v_day_summary where entry_date = current_date;

  -- Sold: 500 (25 x 20) + 100 (10 x 10).
  perform pg_temp.eq(v_sales, 600::numeric, 'sales for the day');
  -- Bought: 800 + 480 + 800 of which the 800 candy purchase was cancelled.
  perform pg_temp.eq(v_purch, 1280::numeric,
                     'purchases for the day, the cancelled one left out of the money');
  perform pg_temp.eq(v_recv, 60::numeric, 'cash received');

  perform pg_temp.eq((select purchase_count::int from public.v_day_summary
                       where entry_date = current_date),
                     3, 'but the cancelled purchase is still counted as raised');
  perform pg_temp.pass('the day totals sold, bought and collected separately');
end $$;


-- =============================================================================
-- 8. An opening balance is not a day's sale
-- =============================================================================
do $$
declare v_before numeric;
begin
  select sales into v_before from public.v_day_summary where entry_date = current_date;

  update public.party
     set opening_balance = 9999, opening_balance_date = current_date
   where code = 'C1' and false;   -- guarded: C1 already has documents

  -- Make one on a party that has none, dated today.
  perform public.import_masters('party',
    '[{"code":"C9","name":"Fresh Shop","route_code":"R1"}]'::jsonb, false);
  update public.party
     set opening_balance = 9999, opening_balance_date = current_date
   where code = 'C9';
  perform public.post_opening_balances(0);

  perform pg_temp.eq((select sales from public.v_day_summary where entry_date = current_date),
                     v_before, 'the day''s sales did not move');
  perform pg_temp.eq((select count(*)::int from public.v_day_book
                       where entry_date = current_date and doc_no like 'OPN-%'),
                     0, 'and no opening document is in the day book');
  perform pg_temp.pass('a balance brought forward is never a day''s sale');
end $$;



-- =============================================================================
-- 9. Suppliers are a master like any other: Admin edits, codes stay
-- =============================================================================
do $$
declare v_id uuid; v_msg text;
begin
  insert into public.supplier (code, name, city)
  values ('S2', 'Current Agency', 'Biratnagar')
  returning id into v_id;

  -- Editable, as long as it is not the code.
  update public.supplier set name = 'Current Agency Pvt Ltd', phone = '9800000009'
   where id = v_id;
  perform pg_temp.eq((select name from public.supplier where id = v_id),
                     'Current Agency Pvt Ltd', 'a supplier can be edited');

  begin
    update public.supplier set code = 'S9' where id = v_id;
    raise exception 'FAIL  a supplier code was changed';
  exception when sqlstate 'SA004' then
    get stacked diagnostics v_msg = message_text;
  end;
  if v_msg not like '%code cannot be changed%' then
    raise exception 'FAIL  unexpected message: %', v_msg;
  end if;

  -- The list carries what was bought, so switching one off is informed.
  perform pg_temp.eq((select purchase_count::int from public.v_supplier_list
                       where code = 'S1'),
                     3, 'the supplier list counts purchases');
  perform pg_temp.eq((select bought_value from public.v_supplier_list where code = 'S1'),
                     1280::numeric, 'and what was bought, cancellations left out');
  perform pg_temp.eq((select purchase_count::int from public.v_supplier_list
                       where code = 'S2'),
                     0, 'a new supplier starts at nothing');

  -- Switched off, never deleted.
  update public.supplier set is_active = false where id = v_id;
  perform pg_temp.eq((select is_active from public.v_supplier_list where code = 'S2'),
                     false, 'and can be switched off');

  perform pg_temp.pass('suppliers edit like a master, and codes stay put');
end $$;

\echo 'All purchase and day book tests passed.'
