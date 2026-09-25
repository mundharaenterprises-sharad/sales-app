-- =============================================================================
-- reset_for_go_live.sql
-- Empties the app so the real data can go in.
--
-- Everything entered while trying the app out is thrown away — customers,
-- products, orders, bills, payments, the lot. What is left is a working,
-- empty app: your logins still work and your business details are still on
-- the invoice.
--
-- WHAT STAYS
--   app_user      logins and roles
--   app_setting   your business name, address, phone and rules
--   master_group  Parle, Current and Others — these are configuration, not
--                 data, and the product groups you import point straight at
--                 them
--
-- WHAT GOES
--   every customer and route
--   every product, product group and supplier
--   every order, bill, cancellation, return and payment
--   every stock movement and stock balance
--   every purchase
--   the audit history
--   document numbering, back to 1 — the next bill is INV-000001
--
-- Codes come back with it. A party or product code can never be changed once
-- the record exists, so clearing the list is what makes every code yours to
-- choose again. That is the point of doing this before the first real bill.
--
-- THIS CANNOT BE UNDONE. There is no trash and no snapshot. If you would
-- rather have a copy first, take one in the dashboard — Database -> Backups —
-- before running anything here.
--
-- Run the three steps below in order, in the Supabase SQL Editor.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- STEP 1 — see what is about to go
--
-- Select these lines and run them on their own. Nothing is changed. Read the
-- numbers and make sure they are what you expect to lose.
-- -----------------------------------------------------------------------------

select 'logins             (kept)'   as what, count(*) from public.app_user
union all select 'business settings  (kept)', count(*) from public.app_setting
union all select 'master groups      (kept)', count(*) from public.master_group
union all select '---',                       null
union all select 'customers          (goes)', count(*) from public.party
union all select 'routes             (goes)', count(*) from public.route
union all select 'products           (goes)', count(*) from public.product
union all select 'product groups     (goes)', count(*) from public.product_group
union all select 'suppliers          (goes)', count(*) from public.supplier
union all select 'sales orders       (goes)', count(*) from public.sales_order
union all select 'bills              (goes)', count(*) from public.sales_invoice
union all select 'cancellations      (goes)', count(*) from public.invoice_cancellation
union all select 'returns            (goes)', count(*) from public.sales_return
union all select 'payments           (goes)', count(*) from public.receipt
union all select 'purchases          (goes)', count(*) from public.purchase
union all select 'stock adjustments  (goes)', count(*) from public.stock_adjustment
union all select 'stock movements    (goes)', count(*) from public.stock_ledger
union all select 'audit entries      (goes)', count(*) from public.audit_log;


-- -----------------------------------------------------------------------------
-- STEP 2 — the erase
--
-- It will not run as it stands. Change the word NO on the line marked below to
-- ERASE, then select this whole block and run it.
--
-- One statement, one transaction: it either all happens or none of it does.
-- -----------------------------------------------------------------------------

do $$
declare
  v_confirm text := 'NO';        -- <<< change NO to ERASE
  v_users   integer;
begin
  if v_confirm <> 'ERASE' then
    raise exception
      'Nothing was changed. To go ahead, change NO to ERASE on the marked line.';
  end if;

  -- TRUNCATE rather than DELETE. It is faster, and — the real reason — the
  -- stock ledger and the audit log carry triggers that forbid deleting a row,
  -- because they are append-only by design. TRUNCATE is the one door left open
  -- for exactly this situation.
  --
  -- Every table is named rather than using CASCADE. If some table we have
  -- forgotten still points at one of these, Postgres stops with a complaint
  -- instead of quietly emptying something that was meant to survive.
  truncate table
    public.credit_allocation,
    public.receipt,
    public.invoice_cancellation_line,
    public.invoice_cancellation,
    public.sales_invoice_line,
    public.sales_invoice,
    public.sales_return_line,
    public.sales_return,
    public.sales_order_line,
    public.sales_order,
    public.purchase_line,
    public.purchase,
    public.stock_adjustment_line,
    public.stock_adjustment,
    public.stock_ledger,
    public.product_stock,
    public.product,
    public.product_group,
    public.supplier,
    public.party,
    public.route;

  -- Numbering starts again. The first bill after this is INV-000001.
  update app.doc_sequence set next_number = 1, updated_at = now();

  -- Last, on its own: the audit trigger records changes made above, and a
  -- fresh history whose only entry is the clearing itself is worse than an
  -- empty one.
  truncate table public.audit_log;

  select count(*) into v_users from public.app_user;

  raise notice ' ';
  raise notice 'Done. The app is empty.';
  raise notice '  % login(s) kept', v_users;
  raise notice '  document numbering reset to 1';
  raise notice '  import Routes, Product Groups, Suppliers, Parties, Products next';
  raise notice ' ';
end;
$$;


-- -----------------------------------------------------------------------------
-- STEP 3 — check
--
-- Every line should say OK. Run it on its own.
-- -----------------------------------------------------------------------------

select
  case when count(*) = 0 then 'OK   ' else 'WRONG' end
    || '  bills, orders, returns and payments: ' || count(*) || ' (expected 0)' as check
  from (
    select 1 from public.sales_invoice
    union all select 1 from public.sales_order
    union all select 1 from public.sales_return
    union all select 1 from public.receipt
  ) t

union all
select
  case when count(*) = 0 then 'OK   ' else 'WRONG' end
    || '  stock movements: ' || count(*) || ' (expected 0)'
  from public.stock_ledger

union all
select
  case when count(*) = 0 then 'OK   ' else 'WRONG' end
    || '  products, groups and suppliers: ' || count(*) || ' (expected 0)'
  from (
    select 1 from public.product
    union all select 1 from public.product_group
    union all select 1 from public.supplier
  ) t

union all
select
  case when count(*) = 0 then 'OK   ' else 'WRONG' end
    || '  customers and routes: ' || count(*) || ' (expected 0)'
  from (
    select 1 from public.party
    union all select 1 from public.route
  ) t

union all
select
  case when count(*) = 0 then 'OK   ' else 'WRONG' end
    || '  audit entries: ' || count(*) || ' (expected 0)'
  from public.audit_log

union all
select
  case when bool_and(next_number = 1) then 'OK   ' else 'WRONG' end
    || '  document numbering back to 1'
  from app.doc_sequence

union all
select
  case when count(*) > 0 then 'OK   ' else 'WRONG' end
    || '  logins still here: ' || count(*)
  from public.app_user

union all
select
  case when count(*) = 1 then 'OK   ' else 'WRONG' end
    || '  business settings still here: ' || count(*) || ' (expected 1)'
  from public.app_setting

union all
select
  case when count(*) >= 3 then 'OK   ' else 'WRONG' end
    || '  master groups still here: ' || count(*) || ' (expected 3 or more)'
  from public.master_group;


-- -----------------------------------------------------------------------------
-- AFTERWARDS
--
--   1. Import the whole workbook: Routes, Product Groups, Suppliers, Parties,
--      Products. The sheets are done in the right order for you. Leave the
--      choice on "Stop and tell me" — nothing exists, so nothing should clash.
--      Leave the Master Groups sheet empty: Parle, Current and Others are
--      already here and survive this script. It is only for adding a fourth.
--      Parties carry opening_balance and opening_balance_date; products carry
--      opening_qty, opening_price and opening_date.
--   2. On the Import screen, press "Post opening stock".
--   3. Check the Stock screen, a party ledger, and Reports -> Ageing.
--   4. Raise one test bill, confirm it is INV-000001, print it, then correct
--      it to see the cancelled one still listed. Then start billing.
--
-- Get the codes and the opening figures right in the workbook before you
-- import. Once a party has its first document its opening balance is fixed,
-- once opening stock is posted it is fixed too, and codes can never change —
-- all on purpose, and all unforgiving.
-- =============================================================================
