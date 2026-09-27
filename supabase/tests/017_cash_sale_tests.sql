-- =============================================================================
-- 017_cash_sale_tests.sql
-- Cash bills pay for themselves, and orders round like bills (migration 032).
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
    '[{"code":"GC","name":"Candy","master_code":"CURRENT"}]'::jsonb, false);
  perform public.import_masters('party',
    '[{"code":"C1","name":"Ram Store","route_code":"R1"}]'::jsonb, false);
  -- 3.33 a piece: any odd number of them lands off a whole rupee, which is
  -- the only way to test rounding honestly.
  perform public.import_masters('product',
    '[{"code":"P1","name":"Toffee","group_code":"GC","base_uom":"PCS",
       "sale_price":"3.33","opening_qty":"5000","opening_price":"2",
       "opening_date":"2026-04-01"}]'::jsonb, false);
  perform public.post_opening_stock();
end $$;

create or replace function pg_temp.pid(p_code text) returns uuid
language sql stable as $$ select id from public.product where code = p_code; $$;

create or replace function pg_temp.party() returns uuid
language sql stable as $$ select id from public.party where code = 'C1'; $$;

create or replace function pg_temp.lines(p_qty numeric, p_rate numeric default 3.33)
returns jsonb language sql stable as $$
  select jsonb_build_array(jsonb_build_object(
    'product_id', pg_temp.pid('P1'), 'uom', 'BASE', 'qty', p_qty, 'rate', p_rate));
$$;


-- =============================================================================
-- 1. An order rounds to the nearest rupee, and says by how much
-- =============================================================================
do $$
declare r jsonb; v_order uuid; v_value numeric; v_round numeric;
begin
  -- 7 x 3.33 = 23.31, which should become 23.00 (down by 0.31).
  r := public.create_sales_order(pg_temp.party(), current_date, pg_temp.lines(7));
  v_order := (r ->> 'order_id')::uuid;

  perform pg_temp.eq((r ->> 'round_off')::numeric, -0.31::numeric,
                     'the order reports what it rounded');

  select order_value, round_off into v_value, v_round
    from public.v_sales_order_summary where order_id = v_order;

  perform pg_temp.eq(v_value, 23.00::numeric, 'the order is worth a whole rupee');
  perform pg_temp.eq(v_round, -0.31::numeric, 'and keeps the rounding beside it');
  perform pg_temp.pass('an order rounds to the nearest rupee');
end $$;


-- =============================================================================
-- 2. The rounding survives a change to the order
-- =============================================================================
do $$
declare r jsonb; v_order uuid; v_value numeric;
begin
  r := public.create_sales_order(pg_temp.party(), current_date, pg_temp.lines(7));
  v_order := (r ->> 'order_id')::uuid;

  -- 8 x 3.33 = 26.64 -> 27.00 (up by 0.36).
  r := public.modify_sales_order(v_order, pg_temp.lines(8));
  perform pg_temp.eq((r ->> 'round_off')::numeric, 0.36::numeric,
                     'the change reports its own rounding');

  select order_value into v_value
    from public.v_sales_order_summary where order_id = v_order;
  perform pg_temp.eq(v_value, 27.00::numeric, 'and the order is worth the new whole rupee');

  select order_value into v_value
    from public.v_pending_orders where order_id = v_order;
  perform pg_temp.eq(v_value, 27.00::numeric, 'the Orders list agrees');

  perform pg_temp.pass('changing an order re-rounds it');
end $$;


-- =============================================================================
-- 3. A credit bill is unchanged — nothing is paid
-- =============================================================================
do $$
declare r jsonb; v_inv uuid; v_paid numeric; v_cash boolean;
begin
  r := public.create_sales_invoice(current_date, pg_temp.lines(10), null, pg_temp.party());
  v_inv := (r ->> 'invoice_id')::uuid;

  select is_cash into v_cash from public.sales_invoice where id = v_inv;
  perform pg_temp.eq(v_cash, false, 'a bill is credit unless it is told otherwise');

  select coalesce(sum(amount), 0) into v_paid
    from public.credit_allocation where invoice_id = v_inv;
  perform pg_temp.eq(v_paid, 0::numeric, 'and nothing has been applied to it');

  perform pg_temp.pass('a bill is still credit by default');
end $$;


-- =============================================================================
-- 4. A cash bill pays for itself, in full, at once
-- =============================================================================
do $$
declare
  r jsonb; v_inv uuid; v_net numeric; v_paid numeric;
  v_receipt uuid; v_amount numeric; v_mode app.payment_mode;
begin
  r := public.create_sales_invoice(current_date, pg_temp.lines(10), null, pg_temp.party(),
                                   0, null, null, true);
  v_inv := (r ->> 'invoice_id')::uuid;

  select net_total, cash_receipt_id into v_net, v_receipt
    from public.sales_invoice where id = v_inv and is_cash;
  if v_receipt is null then
    raise exception 'FAIL  a cash bill did not record which receipt paid it';
  end if;

  select coalesce(sum(amount), 0) into v_paid
    from public.credit_allocation where invoice_id = v_inv;
  perform pg_temp.eq(v_paid, v_net, 'the bill is settled in full');

  select amount, mode into v_amount, v_mode from public.receipt where id = v_receipt;
  perform pg_temp.eq(v_amount, v_net, 'the receipt is for the bill''s amount');
  perform pg_temp.eq(v_mode::text, 'CASH', 'and it is cash');

  perform pg_temp.eq((r ->> 'is_cash')::boolean, true, 'the caller is told it was cash');
  if (r ->> 'receipt_doc_no') is null then
    raise exception 'FAIL  the caller should get the receipt number back';
  end if;

  perform pg_temp.pass('a cash bill books its own receipt in full');
end $$;


-- =============================================================================
-- 5. So the customer owes nothing for it, and the day shows the money
-- =============================================================================
do $$
declare v_before numeric; v_after numeric; v_received numeric; v_sales numeric;
begin
  select coalesce(balance, 0) into v_before
    from public.v_party_balance where party_id = pg_temp.party();
  select coalesce(receipts, 0), coalesce(sales, 0) into v_received, v_sales
    from public.v_day_summary where entry_date = current_date;

  perform public.create_sales_invoice(current_date, pg_temp.lines(10), null,
                                      pg_temp.party(), 0, null, null, true);

  select coalesce(balance, 0) into v_after
    from public.v_party_balance where party_id = pg_temp.party();
  perform pg_temp.eq(v_after, v_before, 'a cash sale adds nothing to what they owe');

  -- The day book must show both halves: a cash sale is a sale and a receipt,
  -- and netting them would hide a day's trading.
  declare v_r2 numeric; v_s2 numeric;
  begin
    select coalesce(receipts, 0), coalesce(sales, 0) into v_r2, v_s2
      from public.v_day_summary where entry_date = current_date;
    if v_r2 <= v_received then
      raise exception 'FAIL  the day book did not count the cash taken';
    end if;
    if v_s2 <= v_sales then
      raise exception 'FAIL  the day book did not count the sale';
    end if;
  end;

  perform pg_temp.pass('a cash sale leaves nothing owing and shows in the day''s takings');
end $$;


-- =============================================================================
-- 6. A cash bill can still be corrected on the same day
--
-- Before 032 this was impossible: revise refuses a bill with money on it, and
-- a cash bill always has money on it — its own.
-- =============================================================================
do $$
declare
  r jsonb; v_inv uuid; v_new uuid; v_old_receipt uuid; v_new_receipt uuid;
  v_paid numeric; v_net numeric; v_status text;
begin
  r := public.create_sales_invoice(current_date, pg_temp.lines(10), null, pg_temp.party(),
                                   0, null, null, true);
  v_inv := (r ->> 'invoice_id')::uuid;
  select cash_receipt_id into v_old_receipt from public.sales_invoice where id = v_inv;

  -- The rep said 10, it was really 12.
  r := public.revise_sales_invoice(v_inv, pg_temp.lines(12));
  v_new := (r ->> 'invoice_id')::uuid;

  select status into v_status from public.receipt where id = v_old_receipt;
  perform pg_temp.eq(v_status, 'CANCELLED', 'the original cash receipt was cancelled');

  select net_total, cash_receipt_id, is_cash into v_net, v_new_receipt, v_status
    from public.sales_invoice where id = v_new;
  if v_new_receipt is null or v_new_receipt = v_old_receipt then
    raise exception 'FAIL  the corrected bill should have a fresh receipt of its own';
  end if;

  select coalesce(sum(amount), 0) into v_paid
    from public.credit_allocation where invoice_id = v_new;
  perform pg_temp.eq(v_paid, v_net, 'and the corrected bill is settled in full');

  perform pg_temp.pass('a cash bill can be corrected on the same day');
end $$;


-- =============================================================================
-- 7. Somebody else's money still stops a correction dead
-- =============================================================================
do $$
declare r jsonb; v_inv uuid; v_code text; v_msg text;
begin
  r := public.create_sales_invoice(current_date, pg_temp.lines(10), null, pg_temp.party());
  v_inv := (r ->> 'invoice_id')::uuid;

  perform public.receive_payment(
    pg_temp.party(), current_date, 10,
    jsonb_build_array(jsonb_build_object('invoice_id', v_inv, 'amount', 10)));

  begin
    perform public.revise_sales_invoice(v_inv, pg_temp.lines(12));
    raise exception 'FAIL  a bill with a payment on it was corrected anyway';
  exception when others then
    get stacked diagnostics v_msg = message_text, v_code = returned_sqlstate;
    if v_msg like 'FAIL%' then raise; end if;
    perform pg_temp.eq(v_code, 'SA002', 'a settled bill refuses correction');
  end;

  perform pg_temp.pass('a payment somebody else made still blocks a correction');
end $$;


-- =============================================================================
-- 8. Cancelling a cash bill leaves the money on the account, not lost
-- =============================================================================
do $$
declare
  r jsonb; v_inv uuid; v_receipt uuid; v_status text;
  v_before numeric; v_after numeric; v_net numeric;
begin
  select coalesce(balance, 0) into v_before
    from public.v_party_balance where party_id = pg_temp.party();

  r := public.create_sales_invoice(current_date, pg_temp.lines(10), null, pg_temp.party(),
                                   0, null, null, true);
  v_inv := (r ->> 'invoice_id')::uuid;
  select cash_receipt_id, net_total into v_receipt, v_net
    from public.sales_invoice where id = v_inv;

  perform public.cancel_sales_invoice(v_inv, 'Customer changed their mind');

  select status into v_status from public.receipt where id = v_receipt;
  perform pg_temp.eq(v_status, 'ACTIVE', 'the receipt survives the cancellation');

  select coalesce(balance, 0) into v_after
    from public.v_party_balance where party_id = pg_temp.party();
  perform pg_temp.eq(v_after, v_before - v_net,
                     'the money sits on the account as credit');

  perform pg_temp.pass('cancelling a cash bill keeps the money as credit, not a silent refund');
end $$;


-- =============================================================================
-- 9. An order billed as cash: the whole road, end to end
-- =============================================================================
do $$
declare
  r jsonb; v_order uuid; v_line uuid; v_inv uuid; v_paid numeric; v_net numeric;
begin
  r := public.create_sales_order(pg_temp.party(), current_date, pg_temp.lines(9));
  v_order := (r ->> 'order_id')::uuid;
  select id into v_line from public.sales_order_line where order_id = v_order;

  r := public.create_sales_invoice(
    current_date,
    jsonb_build_array(jsonb_build_object(
      'order_line_id', v_line, 'product_id', pg_temp.pid('P1'),
      'uom', 'BASE', 'qty', 9, 'rate', 3.33)),
    v_order, null, 0, null, null, true);
  v_inv := (r ->> 'invoice_id')::uuid;

  select net_total into v_net from public.sales_invoice where id = v_inv;
  select coalesce(sum(amount), 0) into v_paid
    from public.credit_allocation where invoice_id = v_inv;

  perform pg_temp.eq(v_paid, v_net, 'an order billed for cash is settled too');
  perform pg_temp.eq(v_net, 30.00::numeric, 'and rounded to the rupee');
  perform pg_temp.pass('an order can be billed as a cash sale');
end $$;

\echo '  9 of 9 passed.'
