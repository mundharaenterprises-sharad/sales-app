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

insert into _health
select 1, 'tables', count(*)::text, '24', count(*) = 24
  from pg_tables where schemaname = 'public';

insert into _health
select 2, 'views', count(*)::text, '19 or more', count(*) >= 19
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
