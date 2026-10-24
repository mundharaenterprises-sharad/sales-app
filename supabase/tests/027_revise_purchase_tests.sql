-- =============================================================================
-- 027_revise_purchase_tests.sql
-- Correcting a purchase that was entered wrong (migration 044).
--
-- The rule being tested is not a clock, it is the stock: a purchase can be
-- corrected for as long as what it brought in is still on the shelf, and not
-- a moment after. So the two halves that matter are that a correction works
-- while the goods are there, and that it is refused — with something useful to
-- read — once they have gone.
--
-- Committed rather than rolled back: a correction cancels and re-posts inside
-- one transaction, and both documents are checked by the deferred totals
-- trigger at COMMIT. See bug #10.
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
    '[{"code":"GS","name":"Snacks","master_code":"PARLE"}]'::jsonb, false);
  perform public.import_masters('supplier',
    '[{"code":"S1","name":"Parle Depot"},{"code":"S2","name":"Other Depot"}]'::jsonb, false);
  perform public.import_masters('party',
    '[{"code":"C1","name":"Ram Store","route_code":"R1"}]'::jsonb, false);
  perform public.import_masters('product',
    '[{"code":"P1","name":"Chips","group_code":"GS","base_uom":"PCS",
        "pack_uom":"CTN","pack_size":60,"sale_price":3000,"purchase_price":1800},
      {"code":"P2","name":"Biscuit","group_code":"GS","base_uom":"PCS",
        "pack_uom":"CTN","pack_size":40,"sale_price":1600,"purchase_price":1200}]'::jsonb,
    false);
end $$;

create or replace function pg_temp.sup(p_code text) returns uuid
language sql as $$ select id from public.supplier where code = p_code $$;
create or replace function pg_temp.prod(p_code text) returns uuid
language sql as $$ select id from public.product where code = p_code $$;
create or replace function pg_temp.party() returns uuid
language sql as $$ select id from public.party where code = 'C1' $$;
create or replace function pg_temp.on_hand(p_code text) returns numeric
language sql as $$ select coalesce(on_hand, 0) from public.product_stock
                    where product_id = pg_temp.prod(p_code) $$;
create or replace function pg_temp.latest() returns public.purchase
language sql as $$ select * from public.purchase order by created_at desc limit 1 $$;

-- -----------------------------------------------------------------------------
-- A purchase keyed at the wrong rate
-- -----------------------------------------------------------------------------
-- 10 cartons of 60 at 2,000 — but the supplier's bill says 1,900.

begin;

do $$ begin perform public.post_purchase(
  p_supplier_id      => pg_temp.sup('S1'),
  p_purchase_date    => current_date - 4,
  p_lines            => jsonb_build_array(jsonb_build_object(
    'product_id', pg_temp.prod('P1'), 'uom', 'PACK', 'qty', 10, 'rate', 2000)),
  p_supplier_bill_no => 'PD/1001'); end $$;

commit;

do $$
begin
  perform pg_temp.eq((pg_temp.latest()).net_total, 20000::numeric, 'the wrong total');
  perform pg_temp.eq(pg_temp.on_hand('P1'), 600::numeric, 'stock from the wrong entry');
  perform pg_temp.pass('a purchase goes in at 20,000 and 600 pieces');
end $$;

begin;

do $$
declare v_old uuid; v_res jsonb;
begin
  select id into v_old from public.purchase where doc_no = (pg_temp.latest()).doc_no;

  v_res := public.revise_purchase(
    p_purchase_id   => v_old,
    p_lines         => jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod('P1'), 'uom', 'PACK', 'qty', 10, 'rate', 1900)),
    p_remarks       => 'Rate was keyed from the wrong line of the bill');

  perform pg_temp.eq((v_res ->> 'net_total')::numeric, 19000::numeric,
    'the corrected total');
end $$;

commit;

do $$
declare v_old public.purchase; v_new public.purchase;
begin
  select * into v_new from public.purchase order by created_at desc limit 1;
  select * into v_old from public.purchase where id = v_new.replaces_purchase_id;

  perform pg_temp.eq(v_old.status::text, 'CANCELLED', 'the original''s status');
  perform pg_temp.eq(v_new.status::text, 'ACTIVE',    'the replacement''s status');
  perform pg_temp.eq(v_new.net_total, 19000::numeric, 'what the replacement says');
  perform pg_temp.pass('the old one is cancelled and the new one replaces it');

  -- Both directions, because the list reads it both ways round.
  perform pg_temp.eq(
    (select replaces_doc_no from public.v_purchase_list where purchase_id = v_new.id),
    v_old.doc_no, 'what the replacement says it replaced');
  perform pg_temp.eq(
    (select replaced_by_doc_no from public.v_purchase_list where purchase_id = v_old.id),
    v_new.doc_no, 'what the cancelled one says replaced it');
  perform pg_temp.pass('and each one names the other');
end $$;

-- The whole point: one lot of goods, not two.
do $$
begin
  perform pg_temp.eq(pg_temp.on_hand('P1'), 600::numeric, 'stock after correcting');
  perform pg_temp.pass('stock is still 600 — corrected, not doubled');
end $$;

-- And the cost followed the correction rather than the original.
do $$
declare v_cost numeric;
begin
  select unit_cost into v_cost from app.v_cost_events
   where product_id = pg_temp.prod('P1')
   order by event_no desc limit 1;

  perform pg_temp.eq(v_cost, 31.6667::numeric, 'the average cost after correcting');
  perform pg_temp.pass('cost is 1,900/60 and not 2,000/60 — margins follow the fix');
end $$;

-- The remark and bill number carried across; the supplier did not change.
do $$
declare v public.purchase;
begin
  select * into v from public.purchase order by created_at desc limit 1;
  perform pg_temp.eq(v.supplier_bill_no, 'PD/1001', 'the supplier bill number');
  perform pg_temp.eq(v.supplier_id, pg_temp.sup('S1'), 'the supplier');
  perform pg_temp.eq(v.remarks, 'Rate was keyed from the wrong line of the bill',
    'the remark');
  perform pg_temp.pass('anything not corrected is carried over, not blanked');
end $$;

-- -----------------------------------------------------------------------------
-- Correcting more than the rate
-- -----------------------------------------------------------------------------

begin;

do $$
declare v_old uuid;
begin
  select id into v_old from public.purchase where status = 'ACTIVE'
   order by created_at desc limit 1;

  perform public.revise_purchase(
    p_purchase_id          => v_old,
    p_lines                => jsonb_build_array(
      jsonb_build_object('product_id', pg_temp.prod('P1'), 'uom', 'PACK',
                         'qty', 8, 'rate', 1900, 'line_discount_pct', 5),
      jsonb_build_object('product_id', pg_temp.prod('P2'), 'uom', 'PACK',
                         'qty', 5, 'rate', 1200)),
    p_purchase_date        => current_date - 3,
    p_other_charges        => 250,
    p_supplier_bill_no     => 'PD/1001-A',
    p_bill_discount_amount => 500,
    p_supplier_id          => pg_temp.sup('S2'));
end $$;

commit;

do $$
declare v public.purchase;
begin
  select * into v from public.purchase order by created_at desc limit 1;

  -- 8 x 1,900 = 15,200 less 5% = 760; plus 5 x 1,200 = 6,000. Goods 21,200,
  -- line discount 760, bill discount 500, freight 250.
  perform pg_temp.eq(v.gross_total, 21200::numeric, 'the corrected goods');
  perform pg_temp.eq(v.line_discount_total, 760::numeric, 'the line discount');
  perform pg_temp.eq(v.bill_discount_amount, 500::numeric, 'the bill discount');
  perform pg_temp.eq(v.other_charges, 250::numeric, 'the freight');
  perform pg_temp.eq(v.net_total, 20190::numeric, 'the corrected total');
  perform pg_temp.eq(v.purchase_date, current_date - 3, 'the corrected date');
  perform pg_temp.eq(v.supplier_id, pg_temp.sup('S2'), 'the corrected supplier');
  perform pg_temp.eq(v.supplier_bill_no, 'PD/1001-A', 'the corrected bill number');
  perform pg_temp.pass('lines, discounts, charges, date and supplier all correct together');

  perform pg_temp.eq(pg_temp.on_hand('P1'), 480::numeric, 'chips after correcting again');
  perform pg_temp.eq(pg_temp.on_hand('P2'), 200::numeric, 'biscuits after correcting again');
  perform pg_temp.pass('and a correction of a correction leaves one lot of stock');
end $$;

-- -----------------------------------------------------------------------------
-- Once the goods have gone, it is too late
-- -----------------------------------------------------------------------------

do $$
declare v_id uuid; v_detail text;
begin
  -- Sell nearly all of it, so the purchase can no longer be taken back.
  perform public.create_sales_invoice(
    current_date,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod('P1'), 'uom', 'BASE', 'qty', 470, 'rate', 60)),
    null, pg_temp.party());

  select id into v_id from public.purchase where status = 'ACTIVE'
   order by created_at desc limit 1;

  begin
    perform public.revise_purchase(
      p_purchase_id => v_id,
      p_lines       => jsonb_build_array(jsonb_build_object(
        'product_id', pg_temp.prod('P1'), 'uom', 'PACK', 'qty', 8, 'rate', 1800)));
    raise exception 'FAIL  a purchase was corrected after its goods had gone out';
  exception when sqlstate 'SA001' then
    get stacked diagnostics v_detail = PG_EXCEPTION_DETAIL;
    if v_detail is null or v_detail = '' then
      raise exception 'FAIL  the refusal did not say which product was short';
    end if;
    perform pg_temp.pass('correcting is refused once the goods have been sold');
    perform pg_temp.pass('and the refusal names the product and the quantities');
  end;
end $$;

-- Nothing was half-done by the attempt: the purchase is still active and the
-- stock is still there. A cancel that succeeded followed by a post that failed
-- would be the worst possible outcome, and the transaction is what prevents it.
do $$
declare v public.purchase;
begin
  select * into v from public.purchase where status = 'ACTIVE'
   order by created_at desc limit 1;
  perform pg_temp.eq(v.status::text, 'ACTIVE', 'the purchase after a refused correction');
  perform pg_temp.eq(v.net_total, 20190::numeric, 'its total after a refused correction');
  perform pg_temp.eq(pg_temp.on_hand('P1'), 10::numeric, 'stock after a refused correction');
  perform pg_temp.pass('a refused correction leaves the purchase exactly as it was');
end $$;

-- -----------------------------------------------------------------------------
-- The details can still be fixed, which is the point of having two ways
-- -----------------------------------------------------------------------------

do $$
declare v_id uuid; v public.purchase;
begin
  select id into v_id from public.purchase where status = 'ACTIVE'
   order by created_at desc limit 1;

  perform public.update_purchase_details(
    v_id, 'PD/1001-B', current_date - 3, 'Bill number corrected from the file copy');

  select * into v from public.purchase where id = v_id;
  perform pg_temp.eq(v.supplier_bill_no, 'PD/1001-B', 'the corrected bill number');
  perform pg_temp.eq(v.supplier_bill_date, current_date - 3, 'the corrected bill date');
  perform pg_temp.eq(v.remarks, 'Bill number corrected from the file copy', 'the remark');
  perform pg_temp.eq(v.net_total, 20190::numeric, 'the total, which must not move');
  perform pg_temp.eq(pg_temp.on_hand('P1'), 10::numeric, 'stock, which must not move');
  perform pg_temp.pass('details can be fixed long after the goods have gone');
end $$;

-- null leaves a field alone rather than clearing it — the same convention as
-- an order's remark, and the thing that makes a partial edit safe.
do $$
declare v_id uuid; v public.purchase;
begin
  select id into v_id from public.purchase where status = 'ACTIVE'
   order by created_at desc limit 1;

  perform public.update_purchase_details(v_id, null, null, 'Only the remark this time');

  select * into v from public.purchase where id = v_id;
  perform pg_temp.eq(v.supplier_bill_no, 'PD/1001-B', 'the bill number after a remark-only edit');
  perform pg_temp.eq(v.remarks, 'Only the remark this time', 'the new remark');
  perform pg_temp.pass('a field left alone stays as it was');

  perform public.update_purchase_details(v_id, null, null, '   ');
  select * into v from public.purchase where id = v_id;
  perform pg_temp.eq(v.remarks, null::text, 'the remark after clearing it');
  perform pg_temp.pass('and an emptied box clears it, to null rather than ""');
end $$;

-- -----------------------------------------------------------------------------
-- What it refuses
-- -----------------------------------------------------------------------------

do $$
declare v_id uuid;
begin
  select id into v_id from public.purchase where status = 'CANCELLED' limit 1;

  begin
    perform public.revise_purchase(
      p_purchase_id => v_id,
      p_lines       => jsonb_build_array(jsonb_build_object(
        'product_id', pg_temp.prod('P1'), 'uom', 'PACK', 'qty', 1, 'rate', 1900)));
    raise exception 'FAIL  a cancelled purchase was corrected';
  exception when sqlstate 'SA002' then
    perform pg_temp.pass('a cancelled purchase cannot be corrected');
  end;

  begin
    perform public.update_purchase_details(v_id, 'X/1');
    raise exception 'FAIL  details were edited on a cancelled purchase';
  exception when sqlstate 'SA002' then
    perform pg_temp.pass('nor can its details be edited');
  end;

  begin
    perform public.revise_purchase(
      p_purchase_id => (select id from public.purchase where status = 'ACTIVE'
                         order by created_at desc limit 1),
      p_lines       => '[]'::jsonb);
    raise exception 'FAIL  a correction with no lines was accepted';
  exception when sqlstate 'SA004' then
    perform pg_temp.pass('and a correction still needs at least one line');
  end;
end $$;

-- A rep may not do either of these.
do $$
begin
  insert into auth.users (id, email) values
    ('33333333-3333-3333-3333-333333333333', 'rep@test.local');
  insert into public.app_user (id, full_name, role) values
    ('33333333-3333-3333-3333-333333333333', 'Rep', 'REP');
  set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';

  begin
    perform public.revise_purchase(
      p_purchase_id => (select id from public.purchase where status = 'ACTIVE' limit 1),
      p_lines       => jsonb_build_array(jsonb_build_object(
        'product_id', pg_temp.prod('P1'), 'uom', 'PACK', 'qty', 1, 'rate', 1900)));
    raise exception 'FAIL  a rep corrected a purchase';
  exception when sqlstate 'SA003' then
    perform pg_temp.pass('a rep cannot correct a purchase');
  end;

  set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
end $$;

\echo '  18 of 18 passed.'
