-- =============================================================================
-- 011_audit.sql
-- Append-only audit log covering every master and transactional table.
--
-- Nobody, including Admin, can update or delete a row here. Admin can read it.
-- =============================================================================

create table public.audit_log (
  id          bigserial primary key,
  table_name  text        not null,
  row_id      text        not null,
  action      text        not null check (action in ('INSERT', 'UPDATE', 'DELETE')),
  old_values  jsonb,
  new_values  jsonb,
  -- Only the fields that actually changed, for a readable history view.
  changed     jsonb,
  changed_by  uuid,
  changed_at  timestamptz not null default now()
);

create trigger audit_log_no_change
  before update or delete on public.audit_log
  for each row execute function app.forbid_change();

create index audit_log_row_idx  on public.audit_log (table_name, row_id, changed_at desc);
create index audit_log_user_idx on public.audit_log (changed_by, changed_at desc);
create index audit_log_time_idx on public.audit_log (changed_at desc);

-- -----------------------------------------------------------------------------
-- Generic audit trigger.
-- -----------------------------------------------------------------------------

create or replace function app.audit_row()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_old     jsonb;
  v_new     jsonb;
  v_changed jsonb;
  v_row_id  text;
  v_actor   uuid;
begin
  -- auth.uid() is absent when a migration or a cron job is the actor.
  begin
    v_actor := auth.uid();
  exception when others then
    v_actor := null;
  end;

  if tg_op = 'DELETE' then
    v_old    := to_jsonb(old);
    v_row_id := v_old ->> 'id';
  elsif tg_op = 'INSERT' then
    v_new    := to_jsonb(new);
    v_row_id := v_new ->> 'id';
  else
    v_old    := to_jsonb(old);
    v_new    := to_jsonb(new);
    v_row_id := v_new ->> 'id';

    select jsonb_object_agg(key, value) into v_changed
      from jsonb_each(v_new)
     where key not in ('updated_at')
       and (v_old -> key) is distinct from value;

    -- Nothing of substance changed; do not write a noise row.
    if v_changed is null then
      return null;
    end if;
  end if;

  insert into public.audit_log
    (table_name, row_id, action, old_values, new_values, changed, changed_by)
  values
    (tg_table_name, coalesce(v_row_id, '?'), tg_op, v_old, v_new, v_changed, v_actor);

  return null;
end;
$$;

-- -----------------------------------------------------------------------------
-- Attach to every table worth auditing.
-- -----------------------------------------------------------------------------

do $$
declare
  t text;
  audited text[] := array[
    'app_user', 'app_setting',
    'route', 'product_group', 'supplier', 'party', 'product',
    'purchase', 'purchase_line',
    'sales_order', 'sales_order_line',
    'sales_invoice', 'sales_invoice_line',
    'invoice_cancellation', 'invoice_cancellation_line',
    'sales_return', 'sales_return_line',
    'stock_adjustment', 'stock_adjustment_line',
    'receipt', 'credit_allocation'
  ];
begin
  foreach t in array audited loop
    execute format(
      'create trigger %I after insert or update or delete on public.%I
         for each row execute function app.audit_row()',
      t || '_audit', t
    );
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- Readable per-document history, for the "who changed what" panel.
-- -----------------------------------------------------------------------------

create or replace view public.v_document_history as
select
  al.id,
  al.table_name,
  al.row_id,
  al.action,
  al.changed,
  al.changed_at,
  al.changed_by,
  u.full_name as changed_by_name,
  u.role      as changed_by_role
from public.audit_log al
left join public.app_user u on u.id = al.changed_by;
