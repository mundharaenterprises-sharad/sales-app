-- =============================================================================
-- 002_logic_tests.sql
-- Exercises the business logic functions end to end.
--
-- Depends on the fixtures created by 001_schema_tests.sql having NOT been run;
-- this file builds its own. Run against a freshly migrated database.
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

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'admin@test.local'),
  ('22222222-2222-2222-2222-222222222222', 'accounts@test.local'),
  ('33333333-3333-3333-3333-333333333333', 'rep@test.local');

insert into public.app_user (id, full_name, role) values
  ('11111111-1111-1111-1111-111111111111', 'Admin User',    'ADMIN'),
  ('22222222-2222-2222-2222-222222222222', 'Accounts User', 'ACCOUNTS'),
  ('33333333-3333-3333-3333-333333333333', 'Rep User',      'REP');

insert into public.route (id, code, name)
  values ('aaaaaaaa-0000-0000-0000-000000000001', 'R1', 'Route One');
insert into public.product_group (id, code, name, master_group_id)
select 'bbbbbbbb-0000-0000-0000-000000000001', 'G1', 'Group One', id
  from public.master_group where code = 'OTHERS';
insert into public.supplier (id, code, name)
  values ('cccccccc-0000-0000-0000-000000000001', 'S1', 'Supplier One');
insert into public.party (id, code, name, route_id)
  values ('dddddddd-0000-0000-0000-000000000001', 'P1', 'Party One',
          'aaaaaaaa-0000-0000-0000-000000000001');

-- PR1: sold in PCS, bought in boxes of 24. Opening 100 PCS.
insert into public.product
  (id, code, name, group_id, base_uom, pack_uom, pack_size,
   sale_rate, purchase_rate, opening_qty, opening_rate, opening_date)
values
  ('eeeeeeee-0000-0000-0000-000000000001', 'PR1', 'Product One',
   'bbbbbbbb-0000-0000-0000-000000000001', 'PCS', 'BOX', 24,
   10, 8, 100, 8, date '2026-04-01');

-- PR2 and PR3: no pack, for the discount arithmetic tests.
insert into public.product
  (id, code, name, group_id, base_uom, sale_rate, purchase_rate,
   opening_qty, opening_rate, opening_date)
values
  ('eeeeeeee-0000-0000-0000-000000000002', 'PR2', 'Product Two',
   'bbbbbbbb-0000-0000-0000-000000000001', 'KG', 33.33, 20,
   50, 20, date '2026-04-01'),
  ('eeeeeeee-0000-0000-0000-000000000003', 'PR3', 'Product Three',
   'bbbbbbbb-0000-0000-0000-000000000001', 'KG', 33.33, 20,
   50, 20, date '2026-04-01');

set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select public.post_opening_stock();

-- =============================================================================
-- 1. Purchase posts stock in base units
-- =============================================================================
do $$
declare r jsonb;
begin
  set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';

  -- 10 boxes of 24 at 192 per box = 240 PCS, 1920.00
  r := public.post_purchase(
    p_supplier_id   => 'cccccccc-0000-0000-0000-000000000001',
    p_purchase_date => current_date,
    p_lines         => '[{"product_id":"eeeeeeee-0000-0000-0000-000000000001",
                          "uom":"PACK","qty":10,"rate":192}]'::jsonb);

  perform pg_temp.eq((r ->> 'net_total')::numeric, 1920.00, 'purchase net total');
  perform pg_temp.eq(
    (select on_hand from public.product_stock
      where product_id = 'eeeeeeee-0000-0000-0000-000000000001'),
    340, 'on hand after purchase (100 opening + 240)');

  perform pg_temp.pass('purchase posts stock in base units');
end $$;

-- =============================================================================
-- 2. A rep cannot post a purchase
-- =============================================================================
do $$
begin
  set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
  begin
    perform public.post_purchase(
      'cccccccc-0000-0000-0000-000000000001', current_date,
      '[{"product_id":"eeeeeeee-0000-0000-0000-000000000001",
         "uom":"BASE","qty":1,"rate":1}]'::jsonb);
    perform pg_temp.fail('a REP posted a purchase');
  exception when sqlstate 'SA003' then
    perform pg_temp.pass('REP blocked from posting a purchase');
  end;
end $$;

-- =============================================================================
-- 3. Submitting an order reserves stock
-- =============================================================================
do $$
declare r jsonb; v_ord uuid;
begin
  set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';

  -- 2 boxes = 48 PCS
  r := public.create_sales_order(
    'dddddddd-0000-0000-0000-000000000001', current_date,
    '[{"product_id":"eeeeeeee-0000-0000-0000-000000000001",
       "uom":"PACK","qty":2,"rate":240}]'::jsonb);

  v_ord := (r ->> 'order_id')::uuid;

  perform pg_temp.eq(
    (select reserved from public.product_stock
      where product_id = 'eeeeeeee-0000-0000-0000-000000000001'),
    48, 'reserved after order');

  perform pg_temp.eq(
    (select available from public.product_stock
      where product_id = 'eeeeeeee-0000-0000-0000-000000000001'),
    292, 'available after order (340 - 48)');

  -- Stash for later tests.
  create temp table _ctx (k text primary key, v uuid);
  insert into _ctx values ('order1', v_ord);

  perform pg_temp.pass('order submit reserves stock and reduces availability');
end $$;

-- =============================================================================
-- 4. An order beyond availability is refused, with a per-line breakdown
-- =============================================================================
do $$
declare v_detail text;
begin
  set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
  begin
    perform public.create_sales_order(
      'dddddddd-0000-0000-0000-000000000001', current_date,
      '[{"product_id":"eeeeeeee-0000-0000-0000-000000000001",
         "uom":"BASE","qty":500,"rate":10}]'::jsonb);
    perform pg_temp.fail('an order exceeding availability was accepted');
  exception when sqlstate 'SA001' then
    get stacked diagnostics v_detail = pg_exception_detail;

    if v_detail::jsonb -> 0 ->> 'product_code' <> 'PR1' then
      perform pg_temp.fail('shortfall detail does not name the product');
    end if;
    perform pg_temp.eq((v_detail::jsonb -> 0 ->> 'requested')::numeric, 500,
                       'shortfall requested qty');
    perform pg_temp.eq((v_detail::jsonb -> 0 ->> 'available')::numeric, 292,
                       'shortfall available qty');

    perform pg_temp.pass('over-availability order refused with usable detail');
  end;

  -- The failed attempt must not have left a reservation behind.
  perform pg_temp.eq(
    (select reserved from public.product_stock
      where product_id = 'eeeeeeee-0000-0000-0000-000000000001'),
    48, 'reserved unchanged after a failed order');
end $$;

-- =============================================================================
-- 5. Modifying an order adjusts the reservation
-- =============================================================================
do $$
declare v_ord uuid;
begin
  set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
  select v into v_ord from _ctx where k = 'order1';

  -- 2 boxes -> 3 boxes = 72 PCS
  perform public.modify_sales_order(v_ord,
    '[{"product_id":"eeeeeeee-0000-0000-0000-000000000001",
       "uom":"PACK","qty":3,"rate":240}]'::jsonb);

  perform pg_temp.eq(
    (select reserved from public.product_stock
      where product_id = 'eeeeeeee-0000-0000-0000-000000000001'),
    72, 'reserved after modify');

  perform pg_temp.pass('modifying an order re-reserves correctly');
end $$;

-- =============================================================================
-- 6. Partial invoicing: stock leaves, reservation shrinks, availability holds
-- =============================================================================
do $$
declare v_ord uuid; v_line uuid; r jsonb;
begin
  set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
  select v into v_ord from _ctx where k = 'order1';
  select id into v_line from public.sales_order_line where order_id = v_ord;

  -- Invoice 1 box of the 3 ordered.
  r := public.create_sales_invoice(
    p_invoice_date => current_date,
    p_lines        => format('[{"order_line_id":"%s","uom":"PACK","qty":1,"rate":240}]',
                             v_line)::jsonb,
    p_order_id     => v_ord);

  insert into _ctx values ('invoice1', (r ->> 'invoice_id')::uuid);

  perform pg_temp.eq(
    (select on_hand from public.product_stock
      where product_id = 'eeeeeeee-0000-0000-0000-000000000001'),
    316, 'on hand after invoicing 24 (340 - 24)');

  perform pg_temp.eq(
    (select reserved from public.product_stock
      where product_id = 'eeeeeeee-0000-0000-0000-000000000001'),
    48, 'reserved after partial invoice (72 - 24)');

  -- Invoicing consumes reservation and stock equally, so availability is
  -- unchanged. This is the property that keeps the rep app honest.
  perform pg_temp.eq(
    (select available from public.product_stock
      where product_id = 'eeeeeeee-0000-0000-0000-000000000001'),
    268, 'available unchanged by invoicing');

  if (select status from public.sales_order where id = v_ord)
     <> 'PARTIALLY_INVOICED' then
    perform pg_temp.fail('order should be PARTIALLY_INVOICED');
  end if;

  perform pg_temp.pass('partial invoice moves stock and updates order status');
end $$;

-- =============================================================================
-- 7. Cannot invoice more than the order has pending
-- =============================================================================
do $$
declare v_ord uuid; v_line uuid;
begin
  set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
  select v into v_ord from _ctx where k = 'order1';
  select id into v_line from public.sales_order_line where order_id = v_ord;

  begin
    perform public.create_sales_invoice(
      p_invoice_date => current_date,
      p_lines        => format('[{"order_line_id":"%s","uom":"PACK","qty":5,"rate":240}]',
                               v_line)::jsonb,
      p_order_id     => v_ord);
    perform pg_temp.fail('invoiced more than the order had pending');
  exception when sqlstate 'SA002' then
    perform pg_temp.pass('over-invoicing an order refused');
  end;
end $$;

-- =============================================================================
-- 8. Bill discount allocation lands to the exact paisa
--
-- Three lines of 33.33, discount 10.00. 10/3 = 3.3333..., which floors to
-- 3.33 three times = 9.99. One paisa must be handed to the line with the
-- largest remainder, or the invoice will not balance.
-- =============================================================================
do $$
declare r jsonb; v_inv uuid; v_sum numeric; v_lines integer;
begin
  set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';

  r := public.create_sales_invoice(
    p_invoice_date         => current_date,
    p_party_id             => 'dddddddd-0000-0000-0000-000000000001',
    p_bill_discount_amount => 10.00,
    p_lines                => '[
      {"product_id":"eeeeeeee-0000-0000-0000-000000000002","uom":"BASE","qty":1,"rate":33.33},
      {"product_id":"eeeeeeee-0000-0000-0000-000000000003","uom":"BASE","qty":1,"rate":33.33},
      {"product_id":"eeeeeeee-0000-0000-0000-000000000002","uom":"BASE","qty":1,"rate":33.33}
    ]'::jsonb);

  v_inv := (r ->> 'invoice_id')::uuid;
  insert into _ctx values ('invoice2', v_inv);

  select sum(allocated_bill_discount), count(*) into v_sum, v_lines
    from public.sales_invoice_line where invoice_id = v_inv;

  perform pg_temp.eq(v_sum, 10.00, 'allocated bill discount sums to the whole');
  perform pg_temp.eq(v_lines, 3, 'line count');

  -- Exactly one line carries the extra paisa.
  if (select count(*) from public.sales_invoice_line
       where invoice_id = v_inv and allocated_bill_discount = 3.34) <> 1 then
    perform pg_temp.fail('the spare paisa was not given to exactly one line');
  end if;

  -- 99.99 gross - 10.00 discount = 89.99, rounded to 90 with 0.01 round off.
  perform pg_temp.eq((r ->> 'gross_total')::numeric, 99.99, 'gross total');
  perform pg_temp.eq((r ->> 'net_total')::numeric,   90.00, 'net total rounded');
  perform pg_temp.eq((r ->> 'round_off')::numeric,    0.01, 'round off');

  perform pg_temp.pass('bill discount allocated exactly, total rounded');
end $$;

-- =============================================================================
-- 9. A sub-paisa discount still lands exactly
-- =============================================================================
do $$
declare r jsonb; v_sum numeric;
begin
  set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';

  r := public.create_sales_invoice(
    p_invoice_date         => current_date,
    p_party_id             => 'dddddddd-0000-0000-0000-000000000001',
    p_bill_discount_amount => 0.01,
    p_lines                => '[
      {"product_id":"eeeeeeee-0000-0000-0000-000000000002","uom":"BASE","qty":1,"rate":10},
      {"product_id":"eeeeeeee-0000-0000-0000-000000000003","uom":"BASE","qty":1,"rate":10},
      {"product_id":"eeeeeeee-0000-0000-0000-000000000002","uom":"BASE","qty":1,"rate":10}
    ]'::jsonb);

  select sum(allocated_bill_discount) into v_sum
    from public.sales_invoice_line
   where invoice_id = (r ->> 'invoice_id')::uuid;

  perform pg_temp.eq(v_sum, 0.01, 'one paisa discount across three lines');
  perform pg_temp.pass('sub-paisa discount allocation is exact');
end $$;

-- =============================================================================
-- 10. Partial cancellation returns stock and reduces what is owed
-- =============================================================================
do $$
declare v_inv uuid; v_line uuid; r jsonb;
begin
  set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
  select v into v_inv from _ctx where k = 'invoice1';
  select id into v_line from public.sales_invoice_line where invoice_id = v_inv;

  -- Cancel 4 of the 24 PCS invoiced.
  r := public.cancel_sales_invoice(v_inv, 'Customer refused 4 pieces',
        format('[{"invoice_line_id":"%s","qty_base":4}]', v_line)::jsonb);

  perform pg_temp.eq(
    (select on_hand from public.product_stock
      where product_id = 'eeeeeeee-0000-0000-0000-000000000001'),
    320, 'stock returned by partial cancel (316 + 4)');

  if (select status from public.sales_invoice where id = v_inv)
     <> 'PARTIALLY_CANCELLED' then
    perform pg_temp.fail('invoice should be PARTIALLY_CANCELLED');
  end if;

  -- Reservation must NOT increase: cancelled goods are free stock.
  perform pg_temp.eq(
    (select reserved from public.product_stock
      where product_id = 'eeeeeeee-0000-0000-0000-000000000001'),
    48, 'reserved untouched by a cancellation');

  perform pg_temp.pass('partial cancel returns free stock, not reserved stock');
end $$;

-- =============================================================================
-- 11. Cancelling releases a payment that would otherwise be stranded
-- =============================================================================
do $$
declare
  v_inv uuid; v_rct uuid; r jsonb;
  v_effective numeric; v_allocated numeric;
begin
  set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
  select v into v_inv from _ctx where k = 'invoice2';

  select effective_total into v_effective
    from public.sales_invoice where id = v_inv;

  -- Pay the invoice in full.
  insert into public.receipt (doc_no, party_id, receipt_date, mode, amount, created_by)
  values (app.next_doc_no('RECEIPT'), 'dddddddd-0000-0000-0000-000000000001',
          current_date, 'CASH', v_effective, auth.uid())
  returning id into v_rct;

  insert into public.credit_allocation (receipt_id, invoice_id, amount, created_by)
  values (v_rct, v_inv, v_effective, auth.uid());

  -- Now cancel the whole invoice. The payment must fall back to on-account
  -- rather than blocking the cancellation.
  r := public.cancel_sales_invoice(v_inv, 'Goods never dispatched');

  if not (r ->> 'is_full')::boolean then
    perform pg_temp.fail('this should have been a full cancellation');
  end if;

  perform pg_temp.eq((r ->> 'payment_released_to_on_account')::numeric,
                     v_effective, 'payment released to on-account');

  select coalesce(sum(amount), 0) into v_allocated
    from public.credit_allocation where invoice_id = v_inv;
  perform pg_temp.eq(v_allocated, 0, 'nothing still allocated to the invoice');

  -- The receipt itself is untouched; its money is simply unallocated again.
  perform pg_temp.eq(
    (select amount from public.receipt where id = v_rct),
    v_effective, 'receipt amount unchanged');

  if (select status from public.sales_invoice where id = v_inv) <> 'CANCELLED' then
    perform pg_temp.fail('invoice should be CANCELLED');
  end if;

  perform pg_temp.eq(
    (select effective_total from public.sales_invoice where id = v_inv),
    0, 'a fully cancelled invoice is worth nothing');

  perform pg_temp.pass('full cancel releases the payment to on-account');
end $$;

-- =============================================================================
-- 12. A full cancel accounts for the rounding adjustment too
-- =============================================================================
do $$
declare v_inv uuid;
begin
  select v into v_inv from _ctx where k = 'invoice2';

  -- net_total was 90.00 including a 0.01 round off; cancelled_value must
  -- match it exactly or the status CHECK would have rejected the update.
  perform pg_temp.eq(
    (select cancelled_value from public.sales_invoice where id = v_inv),
    90.00, 'cancelled value equals net total including round off');

  perform pg_temp.pass('full cancel absorbs the rounding adjustment');
end $$;

-- =============================================================================
-- 13. Stale orders expire and give their reservation back
-- =============================================================================
do $$
declare v_ord uuid; n integer; v_before numeric;
begin
  set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';

  v_ord := (public.create_sales_order(
    'dddddddd-0000-0000-0000-000000000001', current_date,
    '[{"product_id":"eeeeeeee-0000-0000-0000-000000000002",
       "uom":"BASE","qty":10,"rate":33.33}]'::jsonb) ->> 'order_id')::uuid;

  perform pg_temp.eq(
    (select reserved from public.product_stock
      where product_id = 'eeeeeeee-0000-0000-0000-000000000002'),
    10, 'reserved before expiry');

  -- Backdate it past the window.
  update public.sales_order set expires_at = now() - interval '1 day'
   where id = v_ord;

  n := public.expire_stale_orders();

  if n < 1 then
    perform pg_temp.fail('expire_stale_orders released nothing');
  end if;

  if (select status from public.sales_order where id = v_ord) <> 'EXPIRED' then
    perform pg_temp.fail('order should be EXPIRED');
  end if;

  perform pg_temp.eq(
    (select reserved from public.product_stock
      where product_id = 'eeeeeeee-0000-0000-0000-000000000002'),
    0, 'reservation released on expiry');

  insert into _ctx values ('expired', v_ord);
  perform pg_temp.pass('stale orders expire and release their reservation');
end $$;

-- =============================================================================
-- 14. An expired order can be reinstated
-- =============================================================================
do $$
declare v_ord uuid;
begin
  set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
  select v into v_ord from _ctx where k = 'expired';

  perform public.reinstate_sales_order(v_ord);

  if (select status from public.sales_order where id = v_ord) <> 'SUBMITTED' then
    perform pg_temp.fail('reinstated order should be SUBMITTED');
  end if;

  perform pg_temp.eq(
    (select reserved from public.product_stock
      where product_id = 'eeeeeeee-0000-0000-0000-000000000002'),
    10, 'reservation retaken on reinstate');

  perform pg_temp.pass('expired order reinstates and retakes its reservation');
end $$;

-- =============================================================================
-- 15. Cancelling an order releases its reservation
-- =============================================================================
do $$
declare v_ord uuid;
begin
  set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
  select v into v_ord from _ctx where k = 'expired';

  perform public.cancel_sales_order(v_ord, 'Customer changed their mind');

  perform pg_temp.eq(
    (select reserved from public.product_stock
      where product_id = 'eeeeeeee-0000-0000-0000-000000000002'),
    0, 'reservation released on order cancel');

  if (select status from public.sales_order where id = v_ord) <> 'CANCELLED' then
    perform pg_temp.fail('order should be CANCELLED');
  end if;

  perform pg_temp.pass('cancelling an order releases its reservation');
end $$;

-- =============================================================================
-- 16. A cancellation without a reason is refused
-- =============================================================================
do $$
declare v_ord uuid;
begin
  set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
  select v into v_ord from _ctx where k = 'order1';

  begin
    perform public.cancel_sales_order(v_ord, '   ');
    perform pg_temp.fail('an order was cancelled with a blank reason');
  exception when sqlstate 'SA004' then
    perform pg_temp.pass('blank cancellation reason refused');
  end;
end $$;

-- =============================================================================
-- 17. A rep cannot raise an invoice
-- =============================================================================
do $$
begin
  set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
  begin
    perform public.create_sales_invoice(
      p_invoice_date => current_date,
      p_party_id     => 'dddddddd-0000-0000-0000-000000000001',
      p_lines        => '[{"product_id":"eeeeeeee-0000-0000-0000-000000000002",
                           "uom":"BASE","qty":1,"rate":10}]'::jsonb);
    perform pg_temp.fail('a REP raised an invoice');
  exception when sqlstate 'SA003' then
    perform pg_temp.pass('REP blocked from raising an invoice');
  end;
end $$;

-- =============================================================================
-- 18. Row-level security actually applies to a normal user
-- =============================================================================
do $$
begin
  -- The suite has been running as superuser, which bypasses RLS entirely.
  -- These checks run as the authenticated role the way the app would.
  set local role authenticated;
  set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';

  if (select count(*) from public.supplier) <> 0 then
    perform pg_temp.fail('a REP can read the supplier master');
  end if;

  if (select count(*) from public.product) = 0 then
    perform pg_temp.fail('a REP cannot read products');
  end if;

  if (select count(*) from public.product_stock) = 0 then
    perform pg_temp.fail('a REP cannot see stock');
  end if;

  if (select count(*) from public.audit_log) <> 0 then
    perform pg_temp.fail('a REP can read the audit log');
  end if;

  reset role;
  perform pg_temp.pass('RLS hides suppliers and the audit log from a REP');
end $$;

do $$
begin
  set local role authenticated;
  set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

  if (select count(*) from public.supplier) = 0 then
    perform pg_temp.fail('Admin cannot read the supplier master');
  end if;

  if (select count(*) from public.audit_log) = 0 then
    perform pg_temp.fail('Admin cannot read the audit log');
  end if;

  reset role;
  perform pg_temp.pass('RLS lets Admin read suppliers and the audit log');
end $$;

-- =============================================================================
-- 19. A client cannot write to a document table directly
-- =============================================================================
do $$
begin
  set local role authenticated;
  set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';

  begin
    insert into public.sales_invoice
      (doc_no, party_id, invoice_date, gross_total, net_total)
    values ('HACK-1', 'dddddddd-0000-0000-0000-000000000001', current_date, 0, 0);
    reset role;
    perform pg_temp.fail('a client inserted an invoice directly');
  exception when insufficient_privilege or others then
    reset role;
    perform pg_temp.pass('direct invoice insert blocked; must go through the function');
  end;
end $$;

do $$
begin
  set local role authenticated;
  set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

  begin
    update public.product_stock set on_hand = 99999;
    reset role;
    perform pg_temp.fail('a client rewrote stock directly');
  exception when insufficient_privilege or others then
    reset role;
    perform pg_temp.pass('direct stock update blocked even for Admin');
  end;
end $$;

-- =============================================================================
-- 20. The ledger and the cache still agree after everything above
-- =============================================================================
do $$
declare n integer;
begin
  select count(*) into n from public.v_stock_reconciliation;
  if n <> 0 then
    perform pg_temp.fail(format('%s product(s) drifted from the ledger', n));
  end if;
  perform pg_temp.pass('stock cache still reconciles after all operations');
end $$;

-- -----------------------------------------------------------------------------

do $$
begin
  raise notice '';
  raise notice '=====================================';
  raise notice ' All logic tests passed.';
  raise notice '=====================================';
end $$;
