-- =============================================================================
-- 028_restate_opening_cost_tests.sql
-- Correcting what opening stock cost (migration 047).
--
-- The scenario is the live one, scaled down. Opening stock booked at a cost
-- worked out from the selling price rather than taken from an invoice, sold
-- through for a month, and the margin reading far below what the business
-- actually earns.
--
--   opening   1,000 PCS at 98.31      <- the formula: list 107.50 less 8.5%
--   purchase  1,000 PCS at 93.39      <- what was really paid
--   sold      1,000 PCS at 97.08      <- after the usual discount off list
--
-- Costed at the blended 95.85 that gives a 1.3% margin. Restated to the real
-- 93.39 it gives 3.8%, which is the business. Every figure below is worked out
-- in the comments first, because somebody prices goods on this.
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
  ('22222222-2222-2222-2222-222222222222', 'office@test.local');
insert into public.app_user (id, full_name, role) values
  ('11111111-1111-1111-1111-111111111111', 'Owner',  'ADMIN'),
  ('22222222-2222-2222-2222-222222222222', 'Office', 'ACCOUNTS');

set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

do $$
begin
  perform public.import_masters('route', '[{"code":"R1","name":"Town"}]'::jsonb, false);
  perform public.import_masters('product_group',
    '[{"code":"GB","name":"Biscuits","master_code":"PARLE"}]'::jsonb, false);
  perform public.import_masters('supplier',
    '[{"code":"S1","name":"Parle Depot"}]'::jsonb, false);
  perform public.import_masters('party',
    '[{"code":"C1","name":"Ram Store","route_code":"R1"}]'::jsonb, false);
  perform public.import_masters('product',
    ('[{"code":"P1","name":"Parle G 42gm","group_code":"GB","base_uom":"PCS",
        "sale_price":107.50,"purchase_price":93.39,
        "opening_qty":1000,"opening_rate":98.31,
        "opening_date":"' || (current_date - 35)::text || '"}]')::jsonb, false);
  perform public.post_opening_stock();
end $$;

create or replace function pg_temp.prod() returns uuid
language sql as $$ select id from public.product where code = 'P1' $$;
create or replace function pg_temp.party() returns uuid
language sql as $$ select id from public.party where code = 'C1' $$;
create or replace function pg_temp.cost() returns numeric
language sql as $$ select unit_cost from app.v_cost_events
                    where product_id = pg_temp.prod() order by event_no desc limit 1 $$;
create or replace function pg_temp.margin() returns numeric
language sql as $$ select round(sum(margin), 2) from public.profit_lines() $$;

-- -----------------------------------------------------------------------------
-- The state it starts in: cost from a formula
-- -----------------------------------------------------------------------------

do $$
begin
  perform pg_temp.eq(pg_temp.cost(), 98.31::numeric, 'the opening cost as imported');
  perform pg_temp.pass('opening stock is costed at the figure the sheet carried');
end $$;

do $$
begin
  perform public.post_purchase(
    p_supplier_id   => (select id from public.supplier where code = 'S1'),
    p_purchase_date => current_date - 20,
    p_lines         => jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod(), 'uom', 'BASE', 'qty', 1000, 'rate', 93.39)));

  -- (1,000 x 98.31 + 1,000 x 93.39) / 2,000
  perform pg_temp.eq(pg_temp.cost(), 95.85::numeric, 'the blended cost');
  perform pg_temp.pass('a real purchase at 93.39 blends to 95.85 against it');
end $$;

do $$
begin
  perform public.create_sales_invoice(
    current_date - 10,
    jsonb_build_array(jsonb_build_object(
      'product_id', pg_temp.prod(), 'uom', 'BASE', 'qty', 1000, 'rate', 97.08)),
    null, pg_temp.party());

  -- Earned 97,080, cost 1,000 x 95.85 = 95,850.
  perform pg_temp.eq(pg_temp.margin(), 1230.00::numeric, 'the margin as it reads');
  perform pg_temp.pass('and the sale reports 1,230 — about 1.3%, not the 3.8% it is');
end $$;

-- -----------------------------------------------------------------------------
-- Restating it
-- -----------------------------------------------------------------------------

do $$
declare r jsonb;
begin
  r := public.restate_opening_cost(
    pg_temp.prod(), 93.39, 'Opening sheet was worked out from the selling price');

  perform pg_temp.eq((r ->> 'was')::numeric, 98.31::numeric, 'what it was');
  perform pg_temp.eq((r ->> 'now')::numeric, 93.39::numeric, 'what it is now');
  perform pg_temp.eq((r ->> 'cost_removed')::numeric, 4920.00::numeric,
    'the cost that was never spent');
  perform pg_temp.pass('restating reports the 4,920 of cost it took out');
end $$;

do $$
begin
  perform pg_temp.eq(pg_temp.cost(), 93.39::numeric, 'the cost after restating');
  perform pg_temp.pass('both lots are now costed at what was actually paid');

  -- Earned 97,080, cost 1,000 x 93.39 = 93,390.
  perform pg_temp.eq(pg_temp.margin(), 3690.00::numeric, 'the margin after restating');
  perform pg_temp.pass('and a sale made BEFORE the correction now reads 3,690 — 3.8%');
end $$;

-- The ledger is a record of what happened and is not rewritten; what it shows
-- for the opening row is the corrected cost, so the screen and the costing
-- cannot disagree.
do $$
declare v_ledger numeric; v_raw numeric;
begin
  select rate into v_ledger from public.v_stock_ledger
   where product_id = pg_temp.prod() and doc_type = 'OPENING';
  select rate into v_raw from public.stock_ledger
   where product_id = pg_temp.prod() and doc_type = 'OPENING';

  perform pg_temp.eq(v_ledger, 93.39::numeric, 'what the ledger screen shows');
  perform pg_temp.eq(v_raw, 98.31::numeric, 'what the ledger row still holds');
  perform pg_temp.pass('the screen shows the corrected cost; the row itself is untouched');
end $$;

-- Nothing moved. This is the assertion that says a restatement is not a stock
-- adjustment wearing a different hat.
do $$
declare n int;
begin
  perform pg_temp.eq(
    (select on_hand from public.product_stock where product_id = pg_temp.prod()),
    1000::numeric, 'stock on hand after restating');

  select count(*) into n from public.stock_ledger where product_id = pg_temp.prod();
  perform pg_temp.eq(n, 3, 'ledger rows after restating');
  perform pg_temp.pass('no stock moved and no ledger row was written');
end $$;

-- Who did it, and why, is answerable afterwards.
do $$
declare a record;
begin
  select * into a from public.audit_log
   where table_name = 'product' and action = 'UPDATE'
   order by changed_at desc limit 1;

  perform pg_temp.eq((a.old_values ->> 'opening_rate')::numeric, 98.31::numeric,
    'the audited old cost');
  perform pg_temp.eq((a.new_values ->> 'opening_rate')::numeric, 93.39::numeric,
    'the audited new cost');
  perform pg_temp.eq(a.changed_by, '11111111-1111-1111-1111-111111111111'::uuid,
    'who is recorded as changing it');
  perform pg_temp.pass('and the audit log has the old figure, the new one and who');
end $$;

-- -----------------------------------------------------------------------------
-- What it refuses
-- -----------------------------------------------------------------------------

do $$
begin
  begin
    perform public.restate_opening_cost(pg_temp.prod(), 90, '');
    raise exception 'FAIL  a restatement with no reason was accepted';
  exception when sqlstate 'SA004' then
    perform pg_temp.pass('a restatement needs a reason');
  end;

  begin
    perform public.restate_opening_cost(pg_temp.prod(), -1, 'negative');
    raise exception 'FAIL  a negative opening cost was accepted';
  exception when sqlstate 'SA004' then
    perform pg_temp.pass('and cannot be negative');
  end;

  -- The check that would have caught this whole problem at go-live.
  begin
    perform public.restate_opening_cost(pg_temp.prod(), 110, 'typed in a hurry');
    raise exception 'FAIL  a cost above the selling price was accepted silently';
  exception when sqlstate 'SA004' then
    perform pg_temp.pass('a cost at or above the selling price is refused by default');
  end;

  -- But it is a guard, not a rule: a genuine loss-leader can be said out loud.
  perform public.restate_opening_cost(
    pg_temp.prod(), 110, 'Clearance line, sold at a loss on purpose');
  -- The product's own opening cost, not the running average, which also
  -- carries the purchase at 93.39 and is a different question.
  perform pg_temp.eq(
    (select opening_rate from public.product where id = pg_temp.prod()),
    110::numeric, 'the deliberately high opening cost');
  perform pg_temp.pass('and allowed when the reason says so');

  perform public.restate_opening_cost(pg_temp.prod(), 93.39, 'Back to the invoice figure');
end $$;

-- -----------------------------------------------------------------------------
-- Admin only, and the other guards still hold
-- -----------------------------------------------------------------------------

do $$
begin
  set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
  begin
    perform public.restate_opening_cost(pg_temp.prod(), 90, 'Accounts trying it on');
    raise exception 'FAIL  Accounts restated an opening cost';
  exception when sqlstate 'SA003' then
    perform pg_temp.pass('Accounts cannot restate a cost — it is Admin only');
  end;
  set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
end $$;

-- The quantity and the date are still locked, and so is the rate by any other
-- route. The door 047 opens is exactly one function wide.
do $$
begin
  begin
    update public.product set opening_qty = 2000 where id = pg_temp.prod();
    raise exception 'FAIL  the opening quantity was changed after posting';
  exception when sqlstate 'SA002' then
    perform pg_temp.pass('the opening quantity is still locked');
  end;

  begin
    update public.product set opening_date = current_date - 1 where id = pg_temp.prod();
    raise exception 'FAIL  the opening date was changed after posting';
  exception when sqlstate 'SA002' then
    perform pg_temp.pass('so is the opening date');
  end;

  begin
    update public.product set opening_rate = 50 where id = pg_temp.prod();
    raise exception 'FAIL  the opening cost was changed by a plain update';
  exception when sqlstate 'SA002' then
    perform pg_temp.pass('and the cost cannot be changed except through the function');
  end;
end $$;

-- The flag the function uses is transaction-local, so it cannot be left on.
do $$
begin
  perform pg_temp.eq(
    coalesce(nullif(current_setting('app.restating_opening_cost', true), ''), 'off'),
    'off', 'the restating flag afterwards');
  perform pg_temp.pass('the door closes behind it');
end $$;

\echo '  18 of 18 passed.'
