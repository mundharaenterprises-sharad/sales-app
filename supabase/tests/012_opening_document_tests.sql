-- =============================================================================
-- 012_opening_document_tests.sql
-- Opening balances as documents you can age and settle (migration 026).
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
  ('11111111-1111-1111-1111-111111111111', 'Admin User', 'ADMIN');
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

-- Opening balances struck today, so the ageing arithmetic is not at the mercy
-- of when this suite happens to run.
do $$
begin
  perform public.import_masters('route', '[{"code":"R1","name":"Town"}]'::jsonb, false);
  perform public.import_masters('product_group',
    '[{"code":"GC","name":"Candy","master_code":"CURRENT"}]'::jsonb, false);
  perform public.import_masters('product',
    '[{"code":"P1","name":"Banana Candy","group_code":"GC","base_uom":"PCS",
       "sale_price":"20","opening_qty":"1000","opening_price":"16",
       "opening_date":"2026-04-01"}]'::jsonb, false);
  perform public.post_opening_stock();

  execute format($q$
    select public.import_masters('party',
      '[{"code":"C1","name":"Ram Store","route_code":"R1",
         "opening_balance":"5000","opening_balance_date":"%1$s"},
        {"code":"C2","name":"Sita Traders","route_code":"R1",
         "opening_balance":"3000","opening_balance_date":"%1$s"},
        {"code":"C3","name":"Hari Stores","route_code":"R1"}]'::jsonb, false)
  $q$, current_date);
end $$;


-- =============================================================================
-- 1. Before posting, the opening balance is a column and cannot be settled
-- =============================================================================
do $$
begin
  perform pg_temp.eq((select waiting::int from public.v_opening_balance_status),
                     2, 'two balances waiting');
  perform pg_temp.eq((select waiting_value from public.v_opening_balance_status),
                     8000::numeric, 'worth 8,000 between them');
  perform pg_temp.eq((select count(*)::int from public.v_ageing_by_party),
                     0, 'nothing ages, because nothing is a document yet');
  perform pg_temp.eq((select balance from public.v_party_balance
                       where party_code = 'C1'),
                     5000::numeric, 'but the balance still shows it');
  perform pg_temp.pass('an unposted opening balance shows but does not age');
end $$;


-- =============================================================================
-- 2. Posting makes a document, dated 16 days back, and nothing is counted twice
-- =============================================================================
do $$
declare v_n integer;
begin
  v_n := public.post_opening_balances(16);
  perform pg_temp.eq(v_n, 2, 'two documents made');

  perform pg_temp.eq((select doc_no from public.v_invoice_list
                       where party_code = 'C1' and is_opening),
                     'OPN-C1', 'numbered after the customer');
  perform pg_temp.eq((select outstanding from public.v_invoice_list
                       where doc_no = 'OPN-C1'),
                     5000::numeric, 'carrying the whole balance');
  perform pg_temp.eq((select days_outstanding::int from public.v_invoice_list
                       where doc_no = 'OPN-C1'),
                     16, 'sixteen days old');

  -- The balance must not move: column out, document in.
  perform pg_temp.eq((select balance from public.v_party_balance
                       where party_code = 'C1'),
                     5000::numeric, 'the balance is unchanged, not doubled');
  perform pg_temp.eq((select count(*)::int from public.v_party_ledger
                       where party_code = 'C1'),
                     1, 'one ledger line, not two');
  perform pg_temp.eq((select doc_type from public.v_party_ledger
                       where party_code = 'C1'),
                     'OPENING', 'and it still reads as an opening balance');

  -- The figure as imported is untouched, for the record.
  perform pg_temp.eq((select opening_balance from public.party where code = 'C1'),
                     5000::numeric, 'the imported figure is kept as it was');
  perform pg_temp.pass('posting makes a document without moving the balance');
end $$;


-- =============================================================================
-- 3. It ages — into the 16-30 bucket, as asked
-- =============================================================================
do $$
begin
  perform pg_temp.eq((select b_16_30 from public.v_ageing_by_party
                       where party_code = 'C1'),
                     5000::numeric, 'sits in the 16-30 bucket');
  perform pg_temp.eq((select coalesce(b_0_15, 0) from public.v_ageing_by_party
                       where party_code = 'C1'),
                     0::numeric, 'and not in the first one');
  perform pg_temp.eq((select total_outstanding from public.v_ageing_by_party_master
                       where party_code = 'C1' and master_code = 'CURRENT'),
                     5000::numeric, 'under the master group set for openings');
  perform pg_temp.pass('an opening balance ages, in the bucket asked for');
end $$;


-- =============================================================================
-- 4. And it can be paid off, like any bill
-- =============================================================================
do $$
declare v_party uuid; v_inv uuid; r jsonb;
begin
  select id into v_party from public.party where code = 'C1';
  select invoice_id into v_inv from public.v_invoice_list where doc_no = 'OPN-C1';

  r := public.receive_payment(v_party, current_date, 2000,
        jsonb_build_array(jsonb_build_object('invoice_id', v_inv, 'amount', 2000)));

  perform pg_temp.eq((r ->> 'allocated')::numeric, 2000::numeric, 'two thousand applied');
  perform pg_temp.eq((select outstanding from public.v_invoice_list where doc_no = 'OPN-C1'),
                     3000::numeric, 'three thousand of it left');
  perform pg_temp.eq((select balance from public.v_party_balance where party_code = 'C1'),
                     3000::numeric, 'and that is what the customer owes');

  -- Settle the rest.
  perform public.receive_payment(v_party, current_date, 3000,
    jsonb_build_array(jsonb_build_object('invoice_id', v_inv, 'amount', 3000)));

  perform pg_temp.eq((select count(*)::int from public.v_ageing_by_party
                       where party_code = 'C1'),
                     0, 'settled, so it drops out of ageing');
  perform pg_temp.eq((select balance from public.v_party_balance where party_code = 'C1'),
                     0::numeric, 'the account is clear');
  perform pg_temp.pass('an opening balance can be settled by payment');
end $$;


-- =============================================================================
-- 5. Running it again does nothing, and a party with no balance gets nothing
-- =============================================================================
do $$
begin
  perform pg_temp.eq(public.post_opening_balances(16), 0, 'nothing left to post');
  perform pg_temp.eq((select count(*)::int from public.sales_invoice where is_opening),
                     2, 'still two documents');
  perform pg_temp.eq((select count(*)::int from public.v_invoice_list
                       where party_code = 'C3'),
                     0, 'a customer with no opening balance gets no document');
  perform pg_temp.pass('posting twice changes nothing');
end $$;


-- =============================================================================
-- 6. An opening document is not a bill and will not pretend to be one
-- =============================================================================
do $$
declare v_inv uuid; v_prod uuid; v_msg text;
begin
  select invoice_id into v_inv from public.v_invoice_list where doc_no = 'OPN-C2';
  select id into v_prod from public.product where code = 'P1';

  begin
    insert into public.sales_invoice_line
      (invoice_id, line_no, product_id, uom, pack_size, qty, rate)
    values (v_inv, 1, v_prod, 'BASE', 1, 1, 20);
    raise exception 'FAIL  a line was added to an opening document';
  exception when sqlstate 'SA002' then
    get stacked diagnostics v_msg = message_text;
  end;

  if v_msg not like '%no lines%' then
    raise exception 'FAIL  unexpected message: %', v_msg;
  end if;
  perform pg_temp.pass('an opening document cannot be given lines');
end $$;


-- =============================================================================
-- 7. A wrong opening balance can be undone, until money lands on it
-- =============================================================================
do $$
declare v_party uuid; v_inv uuid; r jsonb; v_msg text;
begin
  select id into v_party from public.party where code = 'C2';

  r := public.unpost_opening_balance(v_party);
  perform pg_temp.eq(r ->> 'doc_no', 'OPN-C2', 'the document named');
  perform pg_temp.eq((select count(*)::int from public.sales_invoice
                       where party_id = v_party),
                     0, 'and removed');
  perform pg_temp.eq((select opening_posted_at is null from public.party where id = v_party),
                     true, 'the party is back to waiting');

  -- Which means the balance can be corrected, because no document remains.
  update public.party set opening_balance = 3500 where id = v_party;
  perform pg_temp.eq(public.post_opening_balances(16), 1, 'and posted again');
  perform pg_temp.eq((select outstanding from public.v_invoice_list where doc_no = 'OPN-C2'),
                     3500::numeric, 'at the corrected figure');

  -- Once something is settled against it, that door closes.
  select invoice_id into v_inv from public.v_invoice_list where doc_no = 'OPN-C2';
  perform public.receive_payment(v_party, current_date, 500,
    jsonb_build_array(jsonb_build_object('invoice_id', v_inv, 'amount', 500)));

  begin
    perform public.unpost_opening_balance(v_party);
    raise exception 'FAIL  undo should have been refused';
  exception when sqlstate 'SA002' then
    get stacked diagnostics v_msg = message_text;
  end;
  if v_msg not like '%already been settled%' then
    raise exception 'FAIL  unexpected message: %', v_msg;
  end if;

  perform pg_temp.pass('an opening balance can be corrected until money lands on it');
end $$;


-- =============================================================================
-- 8. A real bill still has to agree with its lines
--
-- 026 loosened the totals check for opening documents. Make sure it did not
-- loosen it for anything else.
-- =============================================================================
do $$
declare v_party uuid; v_prod uuid;
begin
  select id into v_party from public.party where code = 'C3';
  select id into v_prod  from public.product where code = 'P1';

  perform public.create_sales_invoice(current_date,
    jsonb_build_array(jsonb_build_object(
      'product_id', v_prod, 'uom', 'BASE', 'qty', 10, 'rate', 20)),
    null, v_party);

  perform pg_temp.eq((select net_total from public.v_invoice_list
                       where party_code = 'C3' and not is_opening),
                     200::numeric, 'an ordinary bill still totals its lines');

  -- The totals check is a DEFERRED constraint trigger, so it does not fire on
  -- the statement itself. Forcing it to run is the only way to see it here.
  begin
    update public.sales_invoice set net_total = 999
     where party_id = v_party and not is_opening;
    set constraints all immediate;
    raise exception 'FAIL  a bill was allowed to disagree with its lines';
  exception when sqlstate '23514' then
    null;
  end;
  set constraints all deferred;

  perform pg_temp.pass('ordinary bills are still checked against their lines');
end $$;


\echo 'All opening document tests passed.'
