-- =============================================================================
-- health_check.sql
-- Safe to run any time. Reads only — changes nothing.
--
-- Every line should begin with OK. Anything else needs looking at before the
-- database is trusted with real data.
--
-- Run the whole file at once.
-- =============================================================================

drop table if exists _health;
create temp table _health (
  ord int, item text, found text, expected text, ok boolean
);

-- -----------------------------------------------------------------------------
-- Which migrations are in this database?
--
-- Each migration leaves a signature object behind. Looking for those tells us
-- which ones were run, without depending on anyone having recorded it. Every
-- lookup uses to_regclass / to_regprocedure, which return null for something
-- missing rather than failing the whole check.
--
-- When a new migration is added, add its signature here too.
-- -----------------------------------------------------------------------------

drop table if exists _mig;
create temp table _mig as
select * from (values
  ('001', 'foundation',          to_regclass('app.doc_sequence') is not null),
  ('002', 'users',               to_regclass('public.app_user') is not null),
  ('003', 'masters',             to_regclass('public.party') is not null),
  ('004', 'stock',               to_regclass('public.stock_ledger') is not null),
  ('005', 'purchase',            to_regclass('public.purchase') is not null),
  ('006', 'sales orders',        to_regclass('public.sales_order') is not null),
  ('007', 'sales invoices',      to_regclass('public.sales_invoice') is not null),
  ('008', 'sales returns',       to_regclass('public.sales_return') is not null),
  ('009', 'stock adjustments',   to_regclass('public.stock_adjustment') is not null),
  ('010', 'receipts',            to_regclass('public.receipt') is not null),
  ('011', 'audit log',           to_regclass('public.audit_log') is not null),
  ('012', 'row-level security',  exists (select 1 from pg_policies
                                          where schemaname = 'public'
                                            and tablename = 'party'
                                            and policyname = 'party_read')),
  ('022', 'one-step payment',
                                 to_regprocedure('public.receive_payment(uuid,date,numeric,jsonb,uuid,text)') is not null),
  ('021', 'full bill list',      to_regclass('public.v_invoice_list') is not null
                             and exists (select 1 from information_schema.columns
                                          where table_schema = 'public'
                                            and table_name = 'sales_invoice'
                                            and column_name = 'replaces_invoice_id')),
  ('020', 'same-day bill correction',
                                 to_regprocedure('public.revise_sales_invoice(uuid,jsonb,numeric,numeric,text)') is not null),
  ('013', 'order and invoice functions',
                                 to_regprocedure('public.create_sales_order(uuid,date,jsonb,text)') is not null),
  ('014', 'return and receipt functions',
                                 to_regprocedure('public.allocate_credit(jsonb,uuid,uuid)') is not null),
  ('015', 'reports',             to_regclass('public.v_party_ledger') is not null),
  ('016', 'import helpers',      to_regprocedure('app.imp_text(text)') is not null),
  -- 017 replaces 016's three-argument import function, and 023 replaces 017's
  -- four-argument one. Any two of them being present is as wrong as none:
  -- every call becomes ambiguous.
  ('017', 'import skip-existing',
                                 to_regprocedure('public.import_masters(text,jsonb,boolean)') is null
                             and exists (select 1 from pg_proc
                                          where proname = 'import_masters'
                                            and prosrc like '%p_skip_existing%')),
  ('018', 'pack prices',         exists (select 1 from information_schema.columns
                                          where table_schema = 'public'
                                            and table_name = 'product'
                                            and column_name = 'pack_sale_rate')
                             and exists (select 1 from pg_trigger
                                          where tgname = 'product_derive_rates'
                                            and not tgisinternal)
                             and exists (select 1 from pg_proc
                                          where proname = 'import_masters'
                                            and prosrc like '%sale_price%')),
  ('019', 'master editing rules',
                                 to_regclass('public.v_party_master') is not null
                             and to_regclass('public.v_product_master') is not null
                             and exists (select 1 from pg_trigger
                                          where tgname = 'party_guard'
                                            and not tgisinternal)),
  ('023', 'import update-existing',
                                 to_regprocedure('public.import_masters(text,jsonb,boolean,boolean,boolean)') is not null
                             and to_regprocedure('public.import_masters(text,jsonb,boolean,boolean)') is null),
  ('024', 'master groups',       to_regclass('public.master_group') is not null
                             and to_regclass('public.v_party_dues_by_master') is not null
                             and exists (select 1 from information_schema.columns
                                          where table_schema = 'public'
                                            and table_name = 'sales_invoice'
                                            and column_name = 'master_group_id')
                             and exists (select 1 from pg_trigger
                                          where tgname = 'sales_invoice_line_master'
                                            and not tgisinternal)),
  ('025', 'import master groups',
                                 exists (select 1 from pg_proc
                                          where proname = 'import_masters'
                                            and prosrc like '%master_code%'))
) as m(version, what, present);

insert into _health
select 0, 'migrations',
       case when count(*) filter (where not present) = 0
            then 'all ' || count(*) || ' present'
            else count(*) filter (where not present) || ' missing — see below'
       end,
       'all present',
       count(*) filter (where not present) = 0
  from _mig;

-- One row per missing migration, so the fix is named, not just the symptom.
insert into _health
select 0, '  missing ' || version || ' — ' || what,
       'not applied', 'applied', false
  from _mig
 where not present;

insert into _health
select 1, 'tables', count(*)::text, '25', count(*) = 25
  from pg_tables where schemaname = 'public';

insert into _health
select 2, 'views', count(*)::text, '22 or more', count(*) >= 22
  from pg_views where schemaname = 'public';

insert into _health
select 3, 'row-level security',
       count(*) filter (where not rowsecurity)::text || ' unprotected',
       '0 unprotected',
       bool_and(rowsecurity)
  from pg_tables where schemaname in ('public', 'app');

insert into _health
select 4, 'document series', count(*)::text, '7', count(*) = 7
  from app.doc_sequence;

insert into _health
select 5, 'settings row', count(*)::text, '1', count(*) = 1
  from public.app_setting;

insert into _health
select 6, 'business functions', count(*)::text, '15 or more', count(*) >= 15
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.prosecdef;

insert into _health
select 7, 'admin user',
       case when count(*) = 0 then 'none yet — run bootstrap.sql'
            else count(*)::text end,
       'exactly 1', count(*) = 1
  from public.app_user where role = 'ADMIN' and is_active;

insert into _health
select 8, 'pg_cron extension',
       case when exists (select 1 from pg_extension where extname = 'pg_cron')
            then 'installed' else 'not installed — enable it in Extensions' end,
       'installed',
       exists (select 1 from pg_extension where extname = 'pg_cron');

-- cron.job cannot be named directly: Postgres parses the whole statement
-- before running it, so a reference to a missing table fails even inside a
-- branch that would never execute. Hence dynamic SQL.
do $$
declare n integer := 0;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    execute 'select count(*) from cron.job where jobname = $1 and active'
      into n using 'expire-stale-orders';

    insert into _health values (9, 'reservation release job',
      case when n = 1 then 'scheduled and active' else 'NOT scheduled' end,
      'scheduled and active', n = 1);
  else
    insert into _health values (9, 'reservation release job',
      'cannot check — pg_cron not installed', 'scheduled and active', false);
  end if;
end $$;

insert into _health
select 10, 'stock reconciliation',
       count(*)::text || ' product(s) drifted', '0 drifted', count(*) = 0
  from public.v_stock_reconciliation;

insert into _health
select 11, 'business name',
       case when business_name = 'My Business' then 'still the default'
            else business_name end,
       'your business name',
       business_name <> 'My Business'
  from public.app_setting;

-- -----------------------------------------------------------------------------

select
  case when ok then 'OK' else '>>' end as status,
  item,
  found,
  expected
from _health
order by ord;
