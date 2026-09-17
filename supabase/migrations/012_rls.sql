-- =============================================================================
-- 012_rls.sql
-- Row-level security.
--
-- Posture: clients may READ what their role allows and WRITE almost nothing
-- directly. Every document is created through a SECURITY DEFINER function in
-- 013, which performs its own permission check. A compromised or buggy client
-- therefore cannot post a document, move stock, or settle an invoice by
-- talking to the tables.
--
-- The only direct writes permitted are master data by Admin, where there is
-- no stock or money arithmetic to get wrong.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Start from nothing. Supabase grants broadly by default; we grant back
-- deliberately, table by table.
-- -----------------------------------------------------------------------------

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated;
revoke all on schema app                    from anon, authenticated;

-- Signed-out users get nothing at all.
grant usage on schema public to authenticated;

do $$
declare t text;
begin
  foreach t in array array[
    'app_user', 'app_setting',
    'route', 'product_group', 'supplier', 'party', 'product',
    'product_stock', 'stock_ledger',
    'purchase', 'purchase_line',
    'sales_order', 'sales_order_line',
    'sales_invoice', 'sales_invoice_line',
    'invoice_cancellation', 'invoice_cancellation_line',
    'sales_return', 'sales_return_line',
    'stock_adjustment', 'stock_adjustment_line',
    'receipt', 'credit_allocation',
    'audit_log'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- Reference data every signed-in user needs
-- -----------------------------------------------------------------------------

grant select on
  public.app_user, public.app_setting,
  public.route, public.product_group, public.party, public.product,
  public.product_stock
to authenticated;

create policy app_user_read on public.app_user
  for select to authenticated using (app.is_signed_in());

create policy app_setting_read on public.app_setting
  for select to authenticated using (app.is_signed_in());

create policy route_read on public.route
  for select to authenticated using (app.is_signed_in());

create policy product_group_read on public.product_group
  for select to authenticated using (app.is_signed_in());

create policy party_read on public.party
  for select to authenticated using (app.is_signed_in());

create policy product_read on public.product
  for select to authenticated using (app.is_signed_in());

-- Reps need live availability; this is the whole point of the rep app.
create policy product_stock_read on public.product_stock
  for select to authenticated using (app.is_signed_in());

-- -----------------------------------------------------------------------------
-- Master maintenance — Admin only, direct writes allowed
-- -----------------------------------------------------------------------------

grant insert, update on
  public.route, public.product_group, public.supplier,
  public.party, public.product
to authenticated;

grant update on public.app_setting to authenticated;
grant insert, update on public.app_user to authenticated;

do $$
declare t text;
begin
  foreach t in array array[
    'route', 'product_group', 'supplier', 'party', 'product', 'app_user'
  ] loop
    execute format(
      'create policy %I on public.%I for insert to authenticated
         with check (app.is_admin())', t || '_admin_insert', t);
    execute format(
      'create policy %I on public.%I for update to authenticated
         using (app.is_admin()) with check (app.is_admin())',
      t || '_admin_update', t);
  end loop;
end;
$$;

create policy app_setting_admin_update on public.app_setting
  for update to authenticated
  using (app.is_admin()) with check (app.is_admin());

-- Deliberately no DELETE policy anywhere. Masters are deactivated, not deleted.

-- -----------------------------------------------------------------------------
-- Back-office-only reading
-- -----------------------------------------------------------------------------

grant select on
  public.supplier, public.stock_ledger,
  public.purchase, public.purchase_line,
  public.invoice_cancellation, public.invoice_cancellation_line,
  public.sales_return, public.sales_return_line,
  public.stock_adjustment, public.stock_adjustment_line
to authenticated;

do $$
declare t text;
begin
  foreach t in array array[
    'supplier', 'stock_ledger',
    'purchase', 'purchase_line',
    'invoice_cancellation', 'invoice_cancellation_line',
    'sales_return', 'sales_return_line',
    'stock_adjustment', 'stock_adjustment_line'
  ] loop
    execute format(
      'create policy %I on public.%I for select to authenticated
         using (app.is_back_office())', t || '_read', t);
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- Orders — visible to everyone signed in
--
-- All routes are open to all reps, so orders are not partitioned by rep. When
-- that changes, this is the single place it changes.
-- -----------------------------------------------------------------------------

grant select on public.sales_order, public.sales_order_line to authenticated;

create policy sales_order_read on public.sales_order
  for select to authenticated using (app.is_signed_in());

create policy sales_order_line_read on public.sales_order_line
  for select to authenticated using (app.is_signed_in());

-- -----------------------------------------------------------------------------
-- Money — invoices, receipts, allocations
--
-- Back office always. Reps only while app_setting.reps_see_outstanding is on,
-- because seeing invoices is seeing who owes what.
-- -----------------------------------------------------------------------------

create or replace function app.can_see_money()
returns boolean
language sql
stable
as $$
  select app.is_back_office()
      or (app.current_role() = 'REP' and (app.settings()).reps_see_outstanding);
$$;

grant select on
  public.sales_invoice, public.sales_invoice_line,
  public.receipt, public.credit_allocation
to authenticated;

create policy sales_invoice_read on public.sales_invoice
  for select to authenticated using (app.can_see_money());

create policy sales_invoice_line_read on public.sales_invoice_line
  for select to authenticated using (app.can_see_money());

create policy receipt_read on public.receipt
  for select to authenticated using (app.can_see_money());

create policy credit_allocation_read on public.credit_allocation
  for select to authenticated using (app.can_see_money());

-- -----------------------------------------------------------------------------
-- Audit log — Admin reads, nobody writes
-- -----------------------------------------------------------------------------

grant select on public.audit_log to authenticated;

create policy audit_log_read on public.audit_log
  for select to authenticated using (app.is_admin());

-- -----------------------------------------------------------------------------
-- Helper functions used by policies must be callable by clients.
-- -----------------------------------------------------------------------------

grant usage on schema app to authenticated;

grant execute on function
  app.current_role(), app.is_admin(), app.is_back_office(),
  app.is_signed_in(), app.can_see_money(), app.settings()
to authenticated;

-- -----------------------------------------------------------------------------
-- Views inherit the policies of their underlying tables only when created with
-- security_invoker. Without it a view silently becomes a hole in RLS.
-- -----------------------------------------------------------------------------

alter view public.v_stock_reconciliation set (security_invoker = true);
alter view public.v_sales_order_summary  set (security_invoker = true);
alter view public.v_document_history     set (security_invoker = true);

grant select on
  public.v_stock_reconciliation,
  public.v_sales_order_summary,
  public.v_document_history
to authenticated;
