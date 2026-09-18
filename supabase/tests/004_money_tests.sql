-- =============================================================================
-- 004_money_tests.sql
-- Returns, receipts, allocation, cheque handling, and the reporting views.
--
-- The centrepiece is test 14: the same party balance computed three
-- independent ways must agree to the paisa. If those ever diverge, money has
-- gone missing somewhere between the documents and the reports.
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
insert into public.product_group (id, code, name)
  values ('bbbbbbbb-0000-0000-0000-000000000001', 'G1', 'Group One');

-- Party A carries an opening balance; Party B starts at zero.
insert into public.party (id, code, name, route_id, opening_balance, opening_balance_date)
values
  ('dddddddd-0000-0000-0000-000000000001', 'P1', 'Party One',
   'aaaaaaaa-0000-0000-0000-000000000001', 5000.00, date '2026-04-01'),
  ('dddddddd-0000-0000-0000-000000000002', 'P2', 'Party Two',
   'aaaaaaaa-0000-0000-0000-000000000001', 0, null);

insert into public.product
  (id, code, name, group_id, base_uom, sale_rate, purchase_rate,
   opening_qty, opening_rate, opening_date)
values
  ('eeeeeeee-0000-0000-0000-000000000001', 'PR1', 'Product One',
   'bbbbbbbb-0000-0000-0000-000000000001', 'PCS', 100, 70,
   10000, 70, date '2026-04-01');

set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select public.post_opening_stock();

create temp table _ctx (k text primary key, v uuid);

-- =============================================================================
-- 1. A restockable return puts goods back; a written-off one does not
-- =============================================================================
do $$
declare r jsonb; v_before numeric; v_after numeric;
begin
  set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';

  select on_hand into v_before from public.product_stock
   where product_id = 'eeeeeeee-0000-0000-0000-000000000001';

  -- 10 good units back, 5 damaged written off. Customer credited for all 15.
  r := public.post_sales_return(
    p_party_id    => 'dddddddd-0000-0000-0000-000000000001',
    p_return_date => current_date,
    p_reason      => 'Short shipment dispute',
    p_lines       => '[
      {"product_id":"eeeeeeee-0000-0000-0000-000000000001","qty":10,"rate":100,"restock":true},
      {"product_id":"eeeeeeee-0000-0000-0000-000000000001","qty":5,"rate":100,"restock":false}
    ]'::jsonb);

  insert into _ctx values ('return1', (r ->> 'return_id')::uuid);

  select on_hand into v_after from public.product_stock
   where product_id = 'eeeeeeee-0000-0000-0000-000000000001';

  perform pg_temp.eq(v_after - v_before, 10, 'only restockable units returned to stock');
  perform pg_temp.eq((r ->> 'total_value')::numeric, 1500.00,
                     'customer credited for all 15 units');
  perform pg_temp.eq((r ->> 'restocked_qty')::numeric, 10, 'restocked quantity');

  perform pg_temp.pass('return credits all units but only restocks the good ones');
end $$;

-- =============================================================================
-- 2. A return is not applied to anything until it is allocated
-- =============================================================================
do $$
declare v_ret uuid;
begin
  select v into v_ret from _ctx where k = 'return1';

  if exists (select 1 from public.credit_allocation where sales_return_id = v_ret) then
    perform pg_temp.fail('a return allocated itself without being told to');
  end if;

  perform pg_temp.eq(
    (select unallocated from public.v_unallocated_credit where credit_id = v_ret),
    1500.00, 'whole return sitting unallocated');

  perform pg_temp.pass('credits stay unallocated until someone applies them');
end $$;

-- =============================================================================
-- 3. Invoices for the ageing boundary test
-- =============================================================================
do $$
declare d integer; r jsonb;
begin
  set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';

  -- One invoice of 100.00 at each boundary day.
  foreach d in array array[0, 15, 16, 30, 31, 45, 46, 90] loop
    r := public.create_sales_invoice(
      p_invoice_date => current_date - d,
      p_party_id     => 'dddddddd-0000-0000-0000-000000000002',
      p_lines        => '[{"product_id":"eeeeeeee-0000-0000-0000-000000000001",
                           "uom":"BASE","qty":1,"rate":100}]'::jsonb);
  end loop;

  perform pg_temp.pass('ageing fixtures created');
end $$;

-- =============================================================================
-- 4. Ageing buckets land on the right side of every boundary
-- =============================================================================
do $$
declare v_b text; d integer; expected text;
begin
  foreach d in array array[0, 15, 16, 30, 31, 45, 46, 90] loop
    expected := case
                  when d <= 15 then '0-15'
                  when d <= 30 then '16-30'
                  when d <= 45 then '31-45'
                  else '46+'
                end;

    select bucket into v_b from public.v_ageing
     where party_id = 'dddddddd-0000-0000-0000-000000000002'
       and days_outstanding = d;

    if v_b is distinct from expected then
      perform pg_temp.fail(format('day %s should be bucket %s, got %s', d, expected, v_b));
    end if;
  end loop;

  -- Two invoices in each of the first three buckets, two in the last.
  perform pg_temp.eq(
    (select b_0_15 from public.v_ageing_by_party
      where party_id = 'dddddddd-0000-0000-0000-000000000002'),
    200.00, '0-15 bucket total');
  perform pg_temp.eq(
    (select b_46_plus from public.v_ageing_by_party
      where party_id = 'dddddddd-0000-0000-0000-000000000002'),
    200.00, '46+ bucket total');

  perform pg_temp.pass('ageing buckets correct at every boundary');
end $$;

-- =============================================================================
-- 5. A receipt settles nothing until allocated
-- =============================================================================
do $$
declare r jsonb; v_rct uuid;
begin
  set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';

  r := public.create_receipt(
    p_party_id     => 'dddddddd-0000-0000-0000-000000000002',
    p_receipt_date => current_date - 3,
    p_mode         => 'CASH',
    p_amount       => 250.00,
    p_collected_by => '33333333-3333-3333-3333-333333333333');

  v_rct := (r ->> 'receipt_id')::uuid;
  insert into _ctx values ('receipt1', v_rct);

  perform pg_temp.eq((r ->> 'unallocated')::numeric, 250.00, 'nothing applied yet');

  if exists (select 1 from public.credit_allocation where receipt_id = v_rct) then
    perform pg_temp.fail('a receipt allocated itself');
  end if;

  perform pg_temp.pass('receipt created unallocated, as configured');
end $$;

-- =============================================================================
-- 6. Manual allocation across several invoices
-- =============================================================================
do $$
declare v_rct uuid; r jsonb; v_invs jsonb;
begin
  set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
  select v into v_rct from _ctx where k = 'receipt1';

  -- Settle the two oldest invoices fully (100 each) and half of a third.
  select jsonb_agg(jsonb_build_object('invoice_id', invoice_id, 'amount', amt))
    into v_invs
    from (
      select invoice_id,
             case when row_number() over (order by days_outstanding desc) <= 2
                  then 100.00 else 50.00 end as amt
        from public.v_invoice_outstanding
       where party_id = 'dddddddd-0000-0000-0000-000000000002'
       order by days_outstanding desc
       limit 3
    ) t;

  r := public.allocate_credit(v_invs, p_receipt_id => v_rct);

  perform pg_temp.eq((r ->> 'allocated')::numeric, 250.00, 'allocated total');
  perform pg_temp.eq((r ->> 'unallocated')::numeric, 0, 'nothing left over');
  perform pg_temp.eq((r ->> 'invoices')::numeric, 3, 'invoices touched');

  -- The part-paid invoice now shows 50 outstanding.
  if not exists (select 1 from public.v_invoice_outstanding
                  where party_id = 'dddddddd-0000-0000-0000-000000000002'
                    and outstanding = 50.00) then
    perform pg_temp.fail('part payment did not leave 50 outstanding');
  end if;

  perform pg_temp.pass('one receipt settles several invoices, partially');
end $$;

-- =============================================================================
-- 7. Re-allocating replaces the previous picture wholesale
-- =============================================================================
do $$
declare v_rct uuid; r jsonb; v_inv uuid;
begin
  set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
  select v into v_rct from _ctx where k = 'receipt1';

  select invoice_id into v_inv from public.v_invoice_outstanding
   where party_id = 'dddddddd-0000-0000-0000-000000000002'
   order by days_outstanding desc limit 1;

  -- Move the whole 250 onto a single invoice instead.
  r := public.allocate_credit(
    jsonb_build_array(jsonb_build_object('invoice_id', v_inv, 'amount', 100.00)),
    p_receipt_id => v_rct);

  perform pg_temp.eq((r ->> 'allocated')::numeric, 100.00, 'reallocated amount');
  perform pg_temp.eq((r ->> 'unallocated')::numeric, 150.00, 'released back to on-account');

  perform pg_temp.eq(
    (select count(*) from public.credit_allocation where receipt_id = v_rct),
    1, 'previous allocations cleared');

  perform pg_temp.pass('re-allocation replaces rather than accumulates');
end $$;

-- =============================================================================
-- 8. Cannot allocate more than the credit is worth
-- =============================================================================
do $$
declare v_rct uuid; v_inv uuid;
begin
  set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
  select v into v_rct from _ctx where k = 'receipt1';
  select invoice_id into v_inv from public.v_invoice_outstanding
   where party_id = 'dddddddd-0000-0000-0000-000000000002' limit 1;

  begin
    perform public.allocate_credit(
      jsonb_build_array(jsonb_build_object('invoice_id', v_inv, 'amount', 9999.00)),
      p_receipt_id => v_rct);
    perform pg_temp.fail('allocated more than the receipt held');
  exception when sqlstate 'SA004' then
    perform pg_temp.pass('over-allocating a receipt refused');
  end;
end $$;

-- =============================================================================
-- 9. Cannot pay one party's invoice with another party's money
-- =============================================================================
do $$
declare v_rct uuid; v_inv uuid;
begin
  set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
  select v into v_rct from _ctx where k = 'receipt1';   -- belongs to Party Two

  -- An invoice belonging to Party One.
  insert into _ctx values ('inv_p1', (public.create_sales_invoice(
    p_invoice_date => current_date,
    p_party_id     => 'dddddddd-0000-0000-0000-000000000001',
    p_lines        => '[{"product_id":"eeeeeeee-0000-0000-0000-000000000001",
                         "uom":"BASE","qty":20,"rate":100}]'::jsonb) ->> 'invoice_id')::uuid);

  select v into v_inv from _ctx where k = 'inv_p1';

  begin
    perform public.allocate_credit(
      jsonb_build_array(jsonb_build_object('invoice_id', v_inv, 'amount', 100.00)),
      p_receipt_id => v_rct);
    perform pg_temp.fail('money moved between parties');
  exception when sqlstate 'SA004' then
    perform pg_temp.pass('cross-party allocation refused');
  end;
end $$;

-- =============================================================================
-- 10. A bounced cheque un-pays its invoices
-- =============================================================================
do $$
declare r jsonb; v_rct uuid; v_inv uuid; v_before numeric; v_after numeric;
begin
  set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
  select v into v_inv from _ctx where k = 'inv_p1';

  v_rct := (public.create_receipt(
    p_party_id        => 'dddddddd-0000-0000-0000-000000000001',
    p_receipt_date    => current_date,
    p_mode            => 'CHEQUE',
    p_amount          => 2000.00,
    p_reference_no    => '123456',
    p_instrument_date => current_date,
    p_bank_name       => 'Test Bank') ->> 'receipt_id')::uuid;

  insert into _ctx values ('cheque1', v_rct);

  perform public.allocate_credit(
    jsonb_build_array(jsonb_build_object('invoice_id', v_inv, 'amount', 2000.00)),
    p_receipt_id => v_rct);

  select outstanding into v_before from public.v_invoice_outstanding where invoice_id = v_inv;

  -- It bounces.
  r := public.set_cheque_status(v_rct, 'BOUNCED', 'Insufficient funds');

  perform pg_temp.eq((r ->> 'allocations_reversed')::numeric, 2000.00,
                     'allocations reversed on bounce');

  select outstanding into v_after from public.v_invoice_outstanding where invoice_id = v_inv;
  perform pg_temp.eq(v_after - v_before, 2000.00, 'invoice back into outstanding');

  -- A bounced cheque must not count as money anywhere.
  if exists (select 1 from public.v_credit where credit_id = v_rct) then
    perform pg_temp.fail('a bounced cheque still counts as a credit');
  end if;

  perform pg_temp.pass('bounced cheque reverses allocations and stops being money');
end $$;

-- =============================================================================
-- 11. A bounced cheque cannot be re-allocated
-- =============================================================================
do $$
declare v_rct uuid; v_inv uuid;
begin
  set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
  select v into v_rct from _ctx where k = 'cheque1';
  select v into v_inv from _ctx where k = 'inv_p1';

  begin
    perform public.allocate_credit(
      jsonb_build_array(jsonb_build_object('invoice_id', v_inv, 'amount', 100.00)),
      p_receipt_id => v_rct);
    perform pg_temp.fail('a bounced cheque settled an invoice');
  exception when sqlstate 'SA002' then
    perform pg_temp.pass('bounced cheque refused for allocation');
  end;
end $$;

-- =============================================================================
-- 12. Cancelling a receipt releases what it was paying
-- =============================================================================
do $$
declare v_rct uuid; v_inv uuid; v_before numeric; v_after numeric;
begin
  set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
  select v into v_inv from _ctx where k = 'inv_p1';

  v_rct := (public.create_receipt(
    'dddddddd-0000-0000-0000-000000000001', current_date, 'BANK', 500.00)
    ->> 'receipt_id')::uuid;

  perform public.allocate_credit(
    jsonb_build_array(jsonb_build_object('invoice_id', v_inv, 'amount', 500.00)),
    p_receipt_id => v_rct);

  select outstanding into v_before from public.v_invoice_outstanding where invoice_id = v_inv;

  perform public.cancel_receipt(v_rct, 'Entered against the wrong party');

  select outstanding into v_after from public.v_invoice_outstanding where invoice_id = v_inv;
  perform pg_temp.eq(v_after - v_before, 500.00, 'invoice back into outstanding');

  perform pg_temp.pass('cancelling a receipt releases its allocations');
end $$;

-- =============================================================================
-- 13. A return cannot be cancelled once the goods are resold
-- =============================================================================
do $$
declare v_ret uuid; v_avail numeric;
begin
  set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
  select v into v_ret from _ctx where k = 'return1';

  -- Sell everything so the returned units cannot be taken back out.
  select on_hand into v_avail from public.product_stock
   where product_id = 'eeeeeeee-0000-0000-0000-000000000001';

  perform public.create_sales_invoice(
    p_invoice_date => current_date,
    p_party_id     => 'dddddddd-0000-0000-0000-000000000001',
    p_lines        => format('[{"product_id":"eeeeeeee-0000-0000-0000-000000000001",
                                "uom":"BASE","qty":%s,"rate":100}]', v_avail)::jsonb);

  begin
    perform public.cancel_sales_return(v_ret, 'Entered by mistake');
    perform pg_temp.fail('a return was cancelled although its goods were resold');
  exception when sqlstate 'SA001' then
    perform pg_temp.pass('return cancel refused when the goods have been resold');
  end;
end $$;

-- =============================================================================
-- 14. THE RECONCILIATION
--
-- The same party balance, computed three independent ways. If these disagree
-- the reports are lying about money.
-- =============================================================================
do $$
declare
  p           uuid;
  v_view      numeric(14,2);
  v_direct    numeric(14,2);
  v_ledger    numeric(14,2);
begin
  foreach p in array array[
    'dddddddd-0000-0000-0000-000000000001'::uuid,
    'dddddddd-0000-0000-0000-000000000002'::uuid
  ] loop

    -- (a) what the balance view reports
    select balance into v_view from public.v_party_balance where party_id = p;

    -- (b) straight from the documents
    select
      (select opening_balance from public.party where id = p)
      + coalesce((select sum(effective_total) from public.sales_invoice
                   where party_id = p and status <> 'CANCELLED'), 0)
      - coalesce((select sum(amount) from public.receipt
                   where party_id = p and status = 'ACTIVE'
                     and coalesce(clearing_status, 'CLEARED') <> 'BOUNCED'), 0)
      - coalesce((select sum(total_value) from public.sales_return
                   where party_id = p and status = 'ACTIVE'), 0)
    into v_direct;

    -- (c) the last running balance in the ledger
    select running_balance into v_ledger
      from public.v_party_ledger
     where party_id = p
     order by entry_date desc, doc_type desc, doc_no desc
     limit 1;

    if v_view is distinct from v_direct then
      raise exception
        'FAIL  party %: balance view says %, documents say %', p, v_view, v_direct;
    end if;

    if v_ledger is distinct from v_direct then
      raise exception
        'FAIL  party %: ledger ends at %, documents say %', p, v_ledger, v_direct;
    end if;

  end loop;

  perform pg_temp.pass('party balance agrees three independent ways, both parties');
end $$;

-- =============================================================================
-- 15. Outstanding plus on-account reconciles to the balance
-- =============================================================================
do $$
declare r record;
begin
  for r in select * from public.v_party_balance loop
    if r.balance is distinct from
       (r.opening_balance + r.invoice_outstanding - r.on_account) then
      perform pg_temp.fail(format(
        'party %s: %s + %s - %s does not equal %s',
        r.party_code, r.opening_balance, r.invoice_outstanding,
        r.on_account, r.balance));
    end if;
  end loop;

  perform pg_temp.pass('opening + outstanding - on-account equals the balance');
end $$;

-- =============================================================================
-- 16. Collections attribute to the rep and show how long cash was in transit
-- =============================================================================
do $$
declare v_rows integer; v_days integer;
begin
  select count(*), max(days_in_transit) into v_rows, v_days
    from public.v_collection_report
   where collected_by_name = 'Rep User';

  if v_rows = 0 then
    perform pg_temp.fail('the rep collection is not attributed');
  end if;

  -- Receipt dated 3 days before it was entered.
  perform pg_temp.eq(v_days, 3, 'days the cash sat with the rep');

  perform pg_temp.pass('collections attribute to the collector with transit days');
end $$;

-- =============================================================================
-- 17. Pending cheques surface; the bounced one does not
-- =============================================================================
do $$
declare v_bounced uuid;
begin
  select v into v_bounced from _ctx where k = 'cheque1';

  if exists (select 1 from public.v_pending_cheques where receipt_id = v_bounced) then
    perform pg_temp.fail('a bounced cheque is listed as pending');
  end if;

  perform pg_temp.pass('bounced cheque excluded from pending cheques');
end $$;

-- =============================================================================
-- 18. Reports respect RLS
-- =============================================================================
do $$
begin
  set local role authenticated;
  set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';

  -- reps_see_outstanding defaults to true, so a rep may see ageing.
  if (select count(*) from public.v_ageing) = 0 then
    perform pg_temp.fail('a REP cannot see ageing although the setting allows it');
  end if;

  -- But never the purchase register.
  if (select count(*) from public.v_purchase_register) <> 0 then
    perform pg_temp.fail('a REP can read the purchase register');
  end if;

  reset role;
  perform pg_temp.pass('report views honour RLS for a REP');
end $$;

do $$
begin
  -- Turn the setting off and the rep should lose sight of the money.
  update public.app_setting set reps_see_outstanding = false;

  set local role authenticated;
  set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';

  if (select count(*) from public.v_ageing) <> 0 then
    perform pg_temp.fail('a REP still sees ageing after the setting was turned off');
  end if;

  reset role;
  update public.app_setting set reps_see_outstanding = true;

  perform pg_temp.pass('turning off reps_see_outstanding actually hides the money');
end $$;

-- =============================================================================
-- 19. Stock still reconciles after all the returns and cancellations
-- =============================================================================
do $$
begin
  if exists (select 1 from public.v_stock_reconciliation) then
    perform pg_temp.fail('stock cache drifted from the ledger');
  end if;
  perform pg_temp.pass('stock cache reconciles after returns and cancellations');
end $$;

-- -----------------------------------------------------------------------------

do $$
begin
  raise notice '';
  raise notice '=====================================';
  raise notice ' All money tests passed.';
  raise notice '=====================================';
end $$;
