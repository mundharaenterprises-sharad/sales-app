-- =============================================================================
-- 024_purchase_discount_tests.sql
-- Discounts on a purchase, per line and on the whole bill (migration 041).
--
-- The figure that matters most here is not on the purchase at all. He decided
-- that a purchase discount lowers the recorded COST OF THE STOCK, so what
-- lands in stock_ledger.rate is the net figure per base unit, and that is what
-- every margin and every stock valuation afterwards leans on. Most of these
-- assertions are really about that one number.
--
-- Posted inside explicit transactions that are COMMITTED, because the
-- header-against-lines guard is a deferred constraint trigger: it fires at
-- commit and not on the insert. A suite that rolled back would pass against a
-- purchase whose header and lines disagreed — see bug #10, which cost a day in
-- October.
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
    '[{"code":"S1","name":"Parle Depot"}]'::jsonb, false);
  perform public.import_masters('product',
    '[{"code":"P1","name":"Chips","group_code":"GS","base_uom":"PCS",
        "pack_uom":"CTN","pack_size":60,"sale_price":2600,"purchase_price":2000},
      {"code":"P2","name":"Biscuit","group_code":"GS","base_uom":"PCS",
        "pack_uom":"CTN","pack_size":40,"sale_price":1500,"purchase_price":1200}]'::jsonb,
    false);
end $$;

create or replace function pg_temp.sup() returns uuid
language sql as $$ select id from public.supplier where code = 'S1' $$;
create or replace function pg_temp.prod(p_code text) returns uuid
language sql as $$ select id from public.product where code = p_code $$;
create or replace function pg_temp.pur(p_no text) returns uuid
language sql as $$ select id from public.purchase where doc_no = p_no $$;
create or replace function pg_temp.on_hand(p_code text) returns numeric
language sql as $$ select coalesce(on_hand, 0) from public.product_stock
                    where product_id = pg_temp.prod(p_code) $$;

-- -----------------------------------------------------------------------------
-- Spreading an amount so the parts sum to the whole
-- -----------------------------------------------------------------------------
-- Checked on its own before anything leans on it, because every later
-- assertion about per-line cost depends on it being exact.

do $$
declare v numeric;
begin
  select sum(alloc) into v from app.spread_amount(10,
    '[{"line_no":1,"net":100},{"line_no":2,"net":100},{"line_no":3,"net":100}]'::jsonb);
  perform pg_temp.eq(v, 10::numeric, '10 split three ways');

  select sum(alloc) into v from app.spread_amount(33.33,
    '[{"line_no":1,"net":1},{"line_no":2,"net":1},{"line_no":3,"net":1},
      {"line_no":4,"net":1},{"line_no":5,"net":1},{"line_no":6,"net":1},
      {"line_no":7,"net":1}]'::jsonb);
  perform pg_temp.eq(v, 33.33::numeric, '33.33 split seven ways');

  select coalesce(sum(alloc), 0) into v from app.spread_amount(500,
    '[{"line_no":1,"net":0},{"line_no":2,"net":0}]'::jsonb);
  perform pg_temp.eq(v, 0::numeric, 'nothing to weigh it against');
  perform pg_temp.pass('a discount splits across lines without losing a paisa');
end $$;

-- The sales engine has had this inline since 029. Same inputs, same answer, or
-- a purchase and a bill would round a shared discount differently.
do $$
declare v_mine numeric[]; v_sales numeric[]; v_amt numeric := 1234.57;
begin
  select array_agg(alloc order by line_no) into v_mine
    from app.spread_amount(v_amt,
      '[{"line_no":1,"net":4000},{"line_no":2,"net":2500},{"line_no":3,"net":937}]'::jsonb);

  select array_agg(alloc order by line_no) into v_sales from (
    with base as (
      select * from (values (1, 4000::numeric), (2, 2500), (3, 937)) as t(line_no, net)
    ),
    tot as (select coalesce(sum(net), 0) as s from base),
    exact as (
      select b.line_no, b.net,
             case when t.s = 0 then 0 else v_amt * b.net / t.s end as ex
        from base b cross join tot t
    ),
    floored as (
      select e.*, trunc(e.ex * 100) / 100 as flo, e.ex - trunc(e.ex * 100) / 100 as rem
        from exact e
    ),
    ranked as (
      select f.*,
             row_number() over (order by f.rem desc, f.net desc, f.line_no) as rk,
             round((v_amt - sum(f.flo) over ()) * 100)::int                 as spare
        from floored f
    )
    select line_no,
           (flo + case when rk <= spare then 0.01 else 0 end)::numeric(14,2) as alloc
      from ranked
  ) x;

  perform pg_temp.eq(v_mine, v_sales, 'the purchase allocator against the sales one');
  perform pg_temp.pass('and splits it the same way the billing engine does');
end $$;

-- -----------------------------------------------------------------------------
-- A purchase with both kinds of discount
-- -----------------------------------------------------------------------------
-- 5 cartons of Chips at 2,000 = 10,000, less 5% on the line = 9,500.
-- 10 cartons of Biscuit at 1,200 = 12,000, no line discount.
-- Then 1,000 off the whole bill, and 300 of freight.
--
--   goods            22,000
--   line discount       500
--   bill discount     1,000
--   other charges       300
--   total            20,800   (goods − discounts, then charges on top)

begin;

do $$ begin perform public.post_purchase(
  p_supplier_id        => pg_temp.sup(),
  p_purchase_date      => current_date - 3,
  p_lines              => jsonb_build_array(
    jsonb_build_object('product_id', pg_temp.prod('P1'), 'uom', 'PACK',
                       'qty', 5, 'rate', 2000, 'line_discount_pct', 5),
    jsonb_build_object('product_id', pg_temp.prod('P2'), 'uom', 'PACK',
                       'qty', 10, 'rate', 1200)),
  p_other_charges      => 300,
  p_supplier_bill_no   => 'PD/2211',
  p_bill_discount_amount => 1000); end $$;

commit;

do $$
declare h record;
begin
  select * into h from public.purchase order by created_at desc limit 1;

  perform pg_temp.eq(h.gross_total, 22000::numeric, 'goods on the purchase');
  perform pg_temp.eq(h.line_discount_total, 500::numeric, 'the line discount');
  perform pg_temp.eq(h.bill_discount_amount, 1000::numeric, 'the bill discount');
  perform pg_temp.eq(h.other_charges, 300::numeric, 'the freight');
  perform pg_temp.eq(h.net_total, 20800::numeric, 'what the supplier is owed');
  perform pg_temp.pass('goods less both discounts, then charges on top — 20,800');
end $$;

-- Freight is NOT discounted and NOT spread into cost. Stated as an assertion
-- because it is a decision, not arithmetic: 22,000 less 5% would be 20,900,
-- and discounting the transporter would make the total 20,785.
do $$
declare h record;
begin
  select * into h from public.purchase order by created_at desc limit 1;
  perform pg_temp.eq(h.net_total - h.other_charges, 20500::numeric,
    'the goods after discount, with freight set aside');
  perform pg_temp.pass('the discount came off the goods, not off the freight');
end $$;

do $$
declare v_alloc numeric; v_head numeric;
begin
  select coalesce(sum(allocated_bill_discount), 0) into v_alloc
    from public.purchase_line
   where purchase_id = (select id from public.purchase order by created_at desc limit 1);
  select bill_discount_amount into v_head
    from public.purchase order by created_at desc limit 1;

  perform pg_temp.eq(v_alloc, v_head, 'the bill discount spread over the lines');
  perform pg_temp.pass('every paisa of the bill discount sits on a line');
end $$;

-- -----------------------------------------------------------------------------
-- The number this was all for: what the stock cost
-- -----------------------------------------------------------------------------
-- Chips: 9,500 of goods, and 9,500/21,500 of the 1,000 bill discount = 441.86,
-- so 9,058.14 for 300 pieces — 30.1938 each, against a list rate of 33.3333.

do $$
declare l record; v_led numeric;
begin
  select pl.* into l
    from public.purchase_line pl
    join public.purchase pu on pu.id = pl.purchase_id
   where pl.product_id = pg_temp.prod('P1')
   order by pu.created_at desc limit 1;

  perform pg_temp.eq(l.amount, 10000::numeric, 'what the supplier billed for the chips');
  perform pg_temp.eq(l.line_discount_amount, 500::numeric, '5% off the line');
  perform pg_temp.eq(l.allocated_bill_discount, 441.86::numeric,
    'its share of the bill discount');
  perform pg_temp.eq(l.net_amount, 9058.14::numeric, 'what the chips actually cost');
  perform pg_temp.eq(l.qty_base, 300::numeric, 'pieces received');

  select rate into v_led from public.stock_ledger
   where doc_type = 'PURCHASE' and doc_line_id = l.id;

  perform pg_temp.eq(v_led, round(l.net_amount / l.qty_base, 4),
    'the cost stock went in at');
  perform pg_temp.eq(v_led, 30.1938::numeric, 'the cost per piece');
  perform pg_temp.pass('stock is costed net of discount — 30.1938, not 33.3333');
end $$;

-- The percentage is stored even when the rupees were typed, and the other way
-- round, so the paper can be reconciled either way.
do $$
declare l record;
begin
  select pl.* into l
    from public.purchase_line pl
    join public.purchase pu on pu.id = pl.purchase_id
   where pl.product_id = pg_temp.prod('P1')
   order by pu.created_at desc limit 1;
  perform pg_temp.eq(l.line_discount_pct, 5::numeric, 'the percentage as stored');
  perform pg_temp.pass('both halves of the discount pair are kept');
end $$;

do $$
begin
  perform pg_temp.eq(pg_temp.on_hand('P1'), 300::numeric, 'chips on hand');
  perform pg_temp.eq(pg_temp.on_hand('P2'), 400::numeric, 'biscuits on hand');
  perform pg_temp.pass('and the goods are in stock, discount or no discount');
end $$;

-- -----------------------------------------------------------------------------
-- Rupees off a line, rather than a percentage
-- -----------------------------------------------------------------------------

begin;

do $$ begin perform public.post_purchase(
  p_supplier_id   => pg_temp.sup(),
  p_purchase_date => current_date,
  p_lines         => jsonb_build_array(
    jsonb_build_object('product_id', pg_temp.prod('P2'), 'uom', 'PACK',
                       'qty', 3, 'rate', 1200, 'line_discount_amount', 180)),
  p_remarks       => 'rupees not per cent'); end $$;

commit;

do $$
declare l record; h record;
begin
  select * into h from public.purchase order by created_at desc limit 1;
  select * into l from public.purchase_line where purchase_id = h.id;

  perform pg_temp.eq(l.line_discount_amount, 180::numeric, 'the rupees taken off');
  perform pg_temp.eq(l.line_discount_pct, 5::numeric, 'the percentage worked out from them');
  perform pg_temp.eq(h.net_total, 3420::numeric, 'the total');
  perform pg_temp.pass('rupees off a line fill in their own percentage');
end $$;

-- An amount beats a percentage when both arrive, the same way round as a bill.
begin;

do $$ begin perform public.post_purchase(
  p_supplier_id          => pg_temp.sup(),
  p_purchase_date        => current_date,
  p_lines                => jsonb_build_array(
    jsonb_build_object('product_id', pg_temp.prod('P2'), 'uom', 'PACK',
                       'qty', 1, 'rate', 1200)),
  p_bill_discount_amount => 100,
  p_bill_discount_pct    => 50); end $$;

commit;

do $$
declare h record;
begin
  select * into h from public.purchase order by created_at desc limit 1;
  perform pg_temp.eq(h.bill_discount_amount, 100::numeric,
    'the discount when both an amount and a percentage are sent');
  perform pg_temp.pass('an amount wins over a percentage, as on a sales bill');
end $$;

-- -----------------------------------------------------------------------------
-- What it refuses
-- -----------------------------------------------------------------------------

do $$
declare v_state text;
begin
  begin
    perform public.post_purchase(
      p_supplier_id          => pg_temp.sup(),
      p_purchase_date        => current_date,
      p_lines                => jsonb_build_array(
        jsonb_build_object('product_id', pg_temp.prod('P2'), 'uom', 'BASE',
                           'qty', 10, 'rate', 30)),
      p_bill_discount_amount => 5000);
    raise exception 'FAIL  a discount larger than the goods was accepted';
  exception when sqlstate 'SA004' then
    perform pg_temp.pass('a discount larger than the goods is refused');
  end;

  begin
    perform public.post_purchase(
      p_supplier_id   => pg_temp.sup(),
      p_purchase_date => current_date,
      p_lines         => jsonb_build_array(
        jsonb_build_object('product_id', pg_temp.prod('P2'), 'uom', 'BASE',
                           'qty', 10, 'rate', 30, 'line_discount_pct', 120)));
    raise exception 'FAIL  a 120%% line discount was accepted';
  exception when sqlstate 'SA004' then
    perform pg_temp.pass('and a line discount over 100 per cent');
  end;
end $$;

-- -----------------------------------------------------------------------------
-- Cancelling takes the stock out at what it came in at
-- -----------------------------------------------------------------------------
-- The asymmetry worth guarding: taking it back out at the gross rate would
-- leave value behind in a store with nothing in it.

do $$
declare h record; v_in numeric; v_out numeric;
begin
  select * into h from public.purchase
   where remarks = 'rupees not per cent' limit 1;

  perform public.cancel_purchase(h.id, 'Wrong supplier');

  select sl.rate into v_in from public.stock_ledger sl
   where sl.doc_type = 'PURCHASE' and sl.doc_id = h.id limit 1;
  select sl.rate into v_out from public.stock_ledger sl
   where sl.doc_type = 'PURCHASE_CANCEL' and sl.doc_id = h.id limit 1;

  perform pg_temp.eq(v_out, v_in, 'the cost it went out at against the cost it came in at');
  perform pg_temp.pass('cancelling reverses it at the discounted cost, not the list rate');
end $$;

-- -----------------------------------------------------------------------------
-- A purchase with no discount is exactly what it was before 041
-- -----------------------------------------------------------------------------

begin;

do $$ begin perform public.post_purchase(
  p_supplier_id   => pg_temp.sup(),
  p_purchase_date => current_date,
  p_lines         => jsonb_build_array(
    jsonb_build_object('product_id', pg_temp.prod('P1'), 'uom', 'BASE',
                       'qty', 20, 'rate', 35)),
  p_other_charges => 50,
  p_remarks       => 'plain'); end $$;

commit;

do $$
declare h record; l record;
begin
  select * into h from public.purchase where remarks = 'plain';
  select * into l from public.purchase_line where purchase_id = h.id;

  perform pg_temp.eq(h.line_discount_total, 0::numeric, 'no line discount');
  perform pg_temp.eq(h.bill_discount_amount, 0::numeric, 'no bill discount');
  perform pg_temp.eq(h.net_total, 750::numeric, '700 of goods plus 50 of freight');
  perform pg_temp.eq(l.net_amount, l.amount, 'cost equals what was billed');
  perform pg_temp.pass('an undiscounted purchase behaves exactly as it always did');
end $$;

\echo '  14 of 14 passed.'
