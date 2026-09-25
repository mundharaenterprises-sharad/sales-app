-- =============================================================================
-- 001_schema_tests.sql
-- Verifies that the schema's safety rules actually fire.
--
-- Run against a freshly migrated database:
--   psql -v ON_ERROR_STOP=1 -d salesapp -f tests/001_schema_tests.sql
--
-- Any failure aborts with an exception. Silence plus the final summary
-- means everything passed.
-- =============================================================================

\set QUIET on
set client_min_messages = notice;

create or replace function pg_temp.pass(msg text) returns void
language plpgsql as $$
begin raise notice 'PASS  %', msg; end; $$;

create or replace function pg_temp.fail(msg text) returns void
language plpgsql as $$
begin raise exception 'FAIL  %', msg; end; $$;

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

insert into public.route (id, code, name) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'R1', 'Route One');

insert into public.product_group (id, code, name, master_group_id)
select 'bbbbbbbb-0000-0000-0000-000000000001', 'G1', 'Group One', id
  from public.master_group where code = 'OTHERS';

insert into public.supplier (id, code, name) values
  ('cccccccc-0000-0000-0000-000000000001', 'S1', 'Supplier One');

insert into public.party (id, code, name, route_id) values
  ('dddddddd-0000-0000-0000-000000000001', 'P1', 'Party One',
   'aaaaaaaa-0000-0000-0000-000000000001');

-- A product sold loose (PCS) and bought in boxes of 24.
insert into public.product
  (id, code, name, group_id, base_uom, pack_uom, pack_size,
   sale_rate, purchase_rate, opening_qty, opening_rate, opening_date)
values
  ('eeeeeeee-0000-0000-0000-000000000001', 'PR1', 'Product One',
   'bbbbbbbb-0000-0000-0000-000000000001', 'PCS', 'BOX', 24,
   10, 8, 100, 8, date '2026-04-01');

-- A product with no pack at all.
insert into public.product
  (id, code, name, group_id, base_uom, sale_rate, purchase_rate)
values
  ('eeeeeeee-0000-0000-0000-000000000002', 'PR2', 'Product Two',
   'bbbbbbbb-0000-0000-0000-000000000001', 'KG', 50, 40);

-- =============================================================================
-- 1. Product creation seeds a stock row
-- =============================================================================
do $$
begin
  if (select count(*) from public.product_stock) <> 2 then
    perform pg_temp.fail('every product should get a product_stock row');
  end if;
  perform pg_temp.pass('product insert seeds product_stock');
end $$;

-- =============================================================================
-- 2. Opening stock posts once and only once
-- =============================================================================
do $$
declare n integer;
begin
  set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

  n := public.post_opening_stock();
  if n <> 1 then
    perform pg_temp.fail(format('expected 1 opening row, posted %s', n));
  end if;

  -- Second run must be a no-op.
  n := public.post_opening_stock();
  if n <> 0 then
    perform pg_temp.fail('post_opening_stock is not idempotent');
  end if;

  if (select on_hand from public.product_stock
       where product_id = 'eeeeeeee-0000-0000-0000-000000000001') <> 100 then
    perform pg_temp.fail('opening stock did not reach product_stock');
  end if;

  perform pg_temp.pass('opening stock posts once and updates the cache');
end $$;

-- =============================================================================
-- 3. Non-admin cannot post opening stock
-- =============================================================================
do $$
begin
  set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
  begin
    perform public.post_opening_stock();
    perform pg_temp.fail('a REP was allowed to post opening stock');
  exception when insufficient_privilege then
    perform pg_temp.pass('REP blocked from posting opening stock');
  end;
end $$;

-- =============================================================================
-- 4. Pack conversion: a PACK line converts to base units
-- =============================================================================
do $$
declare v_doc text; v_pur uuid; v_base numeric;
begin
  set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';

  v_doc := app.next_doc_no('PURCHASE');
  insert into public.purchase
    (doc_no, supplier_id, purchase_date, gross_total, net_total, created_by)
  values
    (v_doc, 'cccccccc-0000-0000-0000-000000000001', current_date,
     1920.00, 1920.00, auth.uid())
  returning id into v_pur;

  -- 10 boxes of 24 at 192 per box.
  insert into public.purchase_line
    (purchase_id, line_no, product_id, uom, qty, pack_size, rate)
  values
    (v_pur, 1, 'eeeeeeee-0000-0000-0000-000000000001', 'PACK', 10, 24, 192);

  select qty_base into v_base from public.purchase_line where purchase_id = v_pur;
  if v_base <> 240 then
    perform pg_temp.fail(format('10 boxes of 24 should be 240 base units, got %s', v_base));
  end if;

  perform pg_temp.pass('PACK quantity converts to base units');
end $$;

-- =============================================================================
-- 5. Purchase header totals must match its lines
-- =============================================================================
do $$
declare v_pur uuid;
begin
  begin
    insert into public.purchase
      (doc_no, supplier_id, purchase_date, gross_total, net_total)
    values
      (app.next_doc_no('PURCHASE'), 'cccccccc-0000-0000-0000-000000000001',
       current_date, 999.00, 999.00)
    returning id into v_pur;

    insert into public.purchase_line
      (purchase_id, line_no, product_id, uom, qty, pack_size, rate)
    values (v_pur, 1, 'eeeeeeee-0000-0000-0000-000000000002', 'BASE', 1, 1, 100);

    set constraints all immediate;
    perform pg_temp.fail('a purchase whose total disagrees with its lines was accepted');
  exception when check_violation then
    perform pg_temp.pass('purchase header/line total mismatch rejected');
  end;
end $$;

-- =============================================================================
-- 6. Stock can never go negative
-- =============================================================================
do $$
begin
  begin
    insert into public.stock_ledger
      (product_id, movement_date, qty_out, doc_type)
    values
      ('eeeeeeee-0000-0000-0000-000000000002', current_date, 1, 'SALE');
    perform pg_temp.fail('stock was driven negative');
  exception when check_violation then
    perform pg_temp.pass('negative stock rejected by CHECK constraint');
  end;
end $$;

-- =============================================================================
-- 7. The stock ledger is append-only
-- =============================================================================
do $$
begin
  begin
    update public.stock_ledger set qty_in = 999
     where doc_type = 'OPENING';
    perform pg_temp.fail('a stock ledger row was updated');
  exception when restrict_violation then
    perform pg_temp.pass('stock ledger UPDATE blocked');
  end;

  begin
    delete from public.stock_ledger where doc_type = 'OPENING';
    perform pg_temp.fail('a stock ledger row was deleted');
  exception when restrict_violation then
    perform pg_temp.pass('stock ledger DELETE blocked');
  end;
end $$;

-- =============================================================================
-- 8. The cached balance agrees with the ledger
-- =============================================================================
do $$
begin
  if exists (select 1 from public.v_stock_reconciliation) then
    perform pg_temp.fail('cached stock has drifted from the ledger');
  end if;
  perform pg_temp.pass('stock cache reconciles with the ledger');
end $$;

-- =============================================================================
-- 9. Invoice: bill discount must be allocated to lines exactly
-- =============================================================================
do $$
declare v_inv uuid;
begin
  -- 100 PCS at 10.00 = 1000.00, bill discount 10.00.
  -- Deliberately allocate only 9.99 to the line.
  begin
    insert into public.sales_invoice
      (doc_no, party_id, invoice_date, gross_total, line_discount_total,
       bill_discount_amount, round_off, net_total)
    values
      (app.next_doc_no('SALES_INVOICE'), 'dddddddd-0000-0000-0000-000000000001',
       current_date, 1000.00, 0, 10.00, 0, 990.00)
    returning id into v_inv;

    insert into public.sales_invoice_line
      (invoice_id, line_no, product_id, uom, qty, pack_size, rate,
       line_discount_amount, allocated_bill_discount)
    values
      (v_inv, 1, 'eeeeeeee-0000-0000-0000-000000000001', 'BASE', 100, 1, 10,
       0, 9.99);

    set constraints all immediate;
    perform pg_temp.fail('an under-allocated bill discount was accepted');
  exception when check_violation then
    perform pg_temp.pass('inexact bill discount allocation rejected');
  end;
end $$;

-- =============================================================================
-- 10. A correctly totalled invoice is accepted
-- =============================================================================
do $$
declare v_inv uuid; v_eff numeric;
begin
  set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';

  insert into public.sales_invoice
    (id, doc_no, party_id, invoice_date, gross_total, line_discount_total,
     bill_discount_amount, round_off, net_total, created_by)
  values
    ('ffffffff-0000-0000-0000-000000000001', app.next_doc_no('SALES_INVOICE'),
     'dddddddd-0000-0000-0000-000000000001', current_date,
     1000.00, 50.00, 10.00, 0, 940.00, auth.uid())
  returning id into v_inv;

  insert into public.sales_invoice_line
    (invoice_id, line_no, product_id, uom, qty, pack_size, rate,
     line_discount_pct, line_discount_amount, allocated_bill_discount)
  values
    (v_inv, 1, 'eeeeeeee-0000-0000-0000-000000000001', 'BASE', 100, 1, 10,
     5, 50.00, 10.00);

  set constraints all immediate;

  select effective_amount into v_eff
    from public.sales_invoice_line where invoice_id = v_inv;

  if v_eff <> 940.00 then
    perform pg_temp.fail(format('effective_amount should be 940.00, got %s', v_eff));
  end if;

  if (select effective_total from public.sales_invoice where id = v_inv) <> 940.00 then
    perform pg_temp.fail('effective_total should equal net_total when nothing is cancelled');
  end if;

  perform pg_temp.pass('well-formed invoice accepted, line maths correct');
end $$;

-- =============================================================================
-- 11. Allocation cannot exceed the receipt that funds it
-- =============================================================================
do $$
declare v_rct uuid;
begin
  insert into public.receipt
    (id, doc_no, party_id, receipt_date, mode, amount, created_by)
  values
    ('ffffffff-0000-0000-0000-000000000010', app.next_doc_no('RECEIPT'),
     'dddddddd-0000-0000-0000-000000000001', current_date, 'CASH', 500.00,
     '22222222-2222-2222-2222-222222222222')
  returning id into v_rct;

  begin
    insert into public.credit_allocation (receipt_id, invoice_id, amount)
    values (v_rct, 'ffffffff-0000-0000-0000-000000000001', 600.00);

    set constraints all immediate;
    perform pg_temp.fail('allocated more than the receipt amount');
  exception when check_violation then
    perform pg_temp.pass('over-allocation of a receipt rejected');
  end;
end $$;

-- =============================================================================
-- 12. Allocation cannot exceed the invoice it settles
-- =============================================================================
do $$
declare v_rct uuid;
begin
  insert into public.receipt
    (id, doc_no, party_id, receipt_date, mode, amount, created_by)
  values
    ('ffffffff-0000-0000-0000-000000000011', app.next_doc_no('RECEIPT'),
     'dddddddd-0000-0000-0000-000000000001', current_date, 'CASH', 5000.00,
     '22222222-2222-2222-2222-222222222222')
  returning id into v_rct;

  begin
    insert into public.credit_allocation (receipt_id, invoice_id, amount)
    values (v_rct, 'ffffffff-0000-0000-0000-000000000001', 1000.00);

    set constraints all immediate;
    perform pg_temp.fail('allocated more than the invoice is worth');
  exception when check_violation then
    perform pg_temp.pass('over-allocation against an invoice rejected');
  end;
end $$;

-- =============================================================================
-- 13. A part payment allocates cleanly, leaving the rest on account
-- =============================================================================
do $$
declare v_alloc numeric; v_unalloc numeric;
begin
  insert into public.credit_allocation (receipt_id, invoice_id, amount)
  values ('ffffffff-0000-0000-0000-000000000011',
          'ffffffff-0000-0000-0000-000000000001', 400.00);

  set constraints all immediate;

  select coalesce(sum(amount), 0) into v_alloc
    from public.credit_allocation
   where receipt_id = 'ffffffff-0000-0000-0000-000000000011';

  select amount - v_alloc into v_unalloc
    from public.receipt where id = 'ffffffff-0000-0000-0000-000000000011';

  if v_alloc <> 400.00 or v_unalloc <> 4600.00 then
    perform pg_temp.fail(format('allocation maths wrong: allocated %s, on account %s',
                                v_alloc, v_unalloc));
  end if;

  perform pg_temp.pass('part payment allocates, remainder stays on account');
end $$;

-- =============================================================================
-- 14. A receipt may settle several invoices
-- =============================================================================
do $$
declare v_inv2 uuid; v_count integer;
begin
  insert into public.sales_invoice
    (id, doc_no, party_id, invoice_date, gross_total, line_discount_total,
     bill_discount_amount, round_off, net_total, created_by)
  values
    ('ffffffff-0000-0000-0000-000000000002', app.next_doc_no('SALES_INVOICE'),
     'dddddddd-0000-0000-0000-000000000001', current_date,
     500.00, 0, 0, 0, 500.00, '22222222-2222-2222-2222-222222222222')
  returning id into v_inv2;

  insert into public.sales_invoice_line
    (invoice_id, line_no, product_id, uom, qty, pack_size, rate)
  values
    (v_inv2, 1, 'eeeeeeee-0000-0000-0000-000000000002', 'BASE', 10, 1, 50);

  insert into public.credit_allocation (receipt_id, invoice_id, amount)
  values ('ffffffff-0000-0000-0000-000000000011', v_inv2, 500.00);

  set constraints all immediate;

  select count(*) into v_count from public.credit_allocation
   where receipt_id = 'ffffffff-0000-0000-0000-000000000011';

  if v_count <> 2 then
    perform pg_temp.fail('one receipt should be able to settle two invoices');
  end if;

  perform pg_temp.pass('one receipt settles multiple invoices');
end $$;

-- =============================================================================
-- 15. Order line arithmetic and the over-consumption guard
-- =============================================================================
do $$
declare v_ord uuid; v_pending numeric;
begin
  set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';

  insert into public.sales_order
    (id, doc_no, party_id, order_date, status, submitted_at, expires_at, created_by)
  values
    ('ffffffff-0000-0000-0000-000000000020', app.next_doc_no('SALES_ORDER'),
     'dddddddd-0000-0000-0000-000000000001', current_date,
     'SUBMITTED', now(), now() + interval '2 days', auth.uid())
  returning id into v_ord;

  -- 2 boxes of 24 = 48 base units.
  insert into public.sales_order_line
    (order_id, line_no, product_id, uom, qty, pack_size, rate)
  values
    (v_ord, 1, 'eeeeeeee-0000-0000-0000-000000000001', 'PACK', 2, 24, 240);

  select qty_pending_base into v_pending
    from public.sales_order_line where order_id = v_ord;

  if v_pending <> 48 then
    perform pg_temp.fail(format('pending should be 48 base units, got %s', v_pending));
  end if;

  begin
    update public.sales_order_line
       set qty_invoiced_base = 50
     where order_id = v_ord;
    perform pg_temp.fail('an order line was invoiced beyond its quantity');
  exception when check_violation then
    perform pg_temp.pass('order line over-consumption rejected');
  end;

  perform pg_temp.pass('order line pending quantity computed correctly');
end $$;

-- =============================================================================
-- 16. One product may appear only once on an order
-- =============================================================================
do $$
begin
  begin
    insert into public.sales_order_line
      (order_id, line_no, product_id, uom, qty, pack_size, rate)
    values
      ('ffffffff-0000-0000-0000-000000000020', 2,
       'eeeeeeee-0000-0000-0000-000000000001', 'BASE', 5, 1, 10);
    perform pg_temp.fail('the same product was added twice to one order');
  exception when unique_violation then
    perform pg_temp.pass('duplicate product on an order rejected');
  end;
end $$;

-- =============================================================================
-- 17. Invoice status must agree with the cancelled value
-- =============================================================================
do $$
begin
  begin
    update public.sales_invoice
       set cancelled_value = 100.00
     where id = 'ffffffff-0000-0000-0000-000000000001';
    perform pg_temp.fail('cancelled value was set without changing status');
  exception when check_violation then
    perform pg_temp.pass('invoice status/cancelled value kept consistent');
  end;
end $$;

-- =============================================================================
-- 18. A cancellation may not strand an allocated payment
-- =============================================================================
do $$
begin
  -- Invoice 1 is worth 940.00 and has 400.00 allocated to it.
  -- Cancelling it entirely without releasing that payment must fail.
  begin
    update public.sales_invoice
       set cancelled_value = 940.00, status = 'CANCELLED'
     where id = 'ffffffff-0000-0000-0000-000000000001';

    set constraints all immediate;
    perform pg_temp.fail('an invoice was cancelled leaving a payment stranded on it');
  exception when check_violation then
    perform pg_temp.pass('cancellation blocked while a payment is still allocated');
  end;
end $$;

-- =============================================================================
-- 19. A cheque must carry a clearing status; other modes must not
-- =============================================================================
do $$
begin
  begin
    insert into public.receipt (doc_no, party_id, receipt_date, mode, amount)
    values (app.next_doc_no('RECEIPT'), 'dddddddd-0000-0000-0000-000000000001',
            current_date, 'CHEQUE', 100);
    perform pg_temp.fail('a cheque receipt was saved without a clearing status');
  exception when check_violation then
    perform pg_temp.pass('cheque receipt requires a clearing status');
  end;

  begin
    insert into public.receipt
      (doc_no, party_id, receipt_date, mode, amount, clearing_status)
    values (app.next_doc_no('RECEIPT'), 'dddddddd-0000-0000-0000-000000000001',
            current_date, 'CASH', 100, 'PENDING');
    perform pg_temp.fail('a cash receipt was given a clearing status');
  exception when check_violation then
    perform pg_temp.pass('clearing status rejected on non-cheque modes');
  end;
end $$;

-- =============================================================================
-- 20. Document numbers are unique and sequential
-- =============================================================================
do $$
declare a text; b text;
begin
  a := app.next_doc_no('SALES_INVOICE');
  b := app.next_doc_no('SALES_INVOICE');
  if a = b then
    perform pg_temp.fail('document numbering handed out the same number twice');
  end if;
  if a !~ '^INV-[0-9]{6}$' then
    perform pg_temp.fail(format('unexpected document number format: %s', a));
  end if;
  perform pg_temp.pass('document numbering is unique and formatted');
end $$;

-- =============================================================================
-- 21. The audit log captured the activity above
-- =============================================================================
do $$
declare n integer;
begin
  select count(*) into n from public.audit_log where table_name = 'sales_invoice';
  if n = 0 then
    perform pg_temp.fail('no audit rows written for sales_invoice');
  end if;

  select count(*) into n from public.audit_log
   where table_name = 'party' and action = 'INSERT';
  if n <> 1 then
    perform pg_temp.fail('party insert was not audited exactly once');
  end if;

  perform pg_temp.pass('audit log is capturing changes');
end $$;

-- =============================================================================
-- 22. The audit log itself cannot be altered
-- =============================================================================
do $$
begin
  begin
    update public.audit_log set changed_by = null where id = (
      select min(id) from public.audit_log);
    perform pg_temp.fail('an audit row was updated');
  exception when restrict_violation then
    perform pg_temp.pass('audit log UPDATE blocked');
  end;

  begin
    delete from public.audit_log where id = (select min(id) from public.audit_log);
    perform pg_temp.fail('an audit row was deleted');
  exception when restrict_violation then
    perform pg_temp.pass('audit log DELETE blocked');
  end;
end $$;

-- =============================================================================
-- 23. A product with no pack cannot take a PACK line
-- =============================================================================
do $$
begin
  begin
    insert into public.purchase_line
      (purchase_id, line_no, product_id, uom, qty, pack_size, rate)
    select id, 99, 'eeeeeeee-0000-0000-0000-000000000002', 'PACK', 1, 1, 10
      from public.purchase limit 1;
    perform pg_temp.fail('a PACK line was allowed on a product with pack_size 1');
  exception when check_violation then
    perform pg_temp.pass('PACK line rejected where no pack is defined');
  end;
end $$;

-- -----------------------------------------------------------------------------

do $$
begin
  raise notice '';
  raise notice '=====================================';
  raise notice ' All schema tests passed.';
  raise notice '=====================================';
end $$;
