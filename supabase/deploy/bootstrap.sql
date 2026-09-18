-- =============================================================================
-- bootstrap.sql
-- Run ONCE, after deploy_all.sql, on a new Supabase project.
--
-- Three things the schema cannot do for itself:
--   1. schedule the reservation-release job
--   2. create the first Admin (there is no Admin yet to create one)
--   3. record your business details for invoice printing
--
-- Read the comments and edit the marked values before running.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. The reservation release job
--
-- Sales orders that are submitted and never invoiced hold stock hostage. This
-- releases them after the window in app_setting.reservation_expiry_days
-- (default 2). Without this job, reservations never expire.
--
-- FIRST enable pg_cron in the dashboard:
--   Database -> Extensions -> search "pg_cron" -> toggle on
-- then run this.
-- -----------------------------------------------------------------------------

select cron.schedule(
  'expire-stale-orders',
  '0 1 * * *',                       -- 01:00 UTC daily = 06:45 Nepal time
  $$select public.expire_stale_orders()$$
);

-- Check it registered:
--   select jobid, jobname, schedule, active from cron.job;
-- Check it has been running, after a day or two:
--   select * from cron.job_run_details order by start_time desc limit 10;


-- -----------------------------------------------------------------------------
-- 2. The first Admin
--
-- Chicken and egg: app_user can only be written by an Admin, and there is no
-- Admin yet. The SQL Editor runs with privileges that bypass row-level
-- security, so this is the one moment it can be done. Every later user is
-- created through the app.
--
-- BEFORE running this:
--   Authentication -> Users -> Add user -> Create new user
--   Enter your email and a password, and tick "Auto Confirm User".
--
-- Then set the email below to the one you just created.
-- -----------------------------------------------------------------------------

insert into public.app_user (id, full_name, role)
select u.id,
       'Sharad',                     -- <<< your name as it should appear
       'ADMIN'
  from auth.users u
 where u.email = 'you@example.com'   -- <<< the email you just created
on conflict (id) do update
  set role = 'ADMIN', is_active = true;

-- Confirm exactly one Admin exists:
--   select full_name, role, is_active from public.app_user;


-- -----------------------------------------------------------------------------
-- 3. Business details, printed on every invoice
-- -----------------------------------------------------------------------------

update public.app_setting
   set business_name    = 'Mundhara Enterprises',   -- <<< as it should print
       business_address = null,                     -- <<< street, city
       business_phone   = null                      -- <<< phone for the invoice
 where id;


-- -----------------------------------------------------------------------------
-- 4. Sanity check
--
-- Every line should report OK. Anything else means deploy_all.sql did not
-- finish cleanly and should be investigated before loading real data.
-- -----------------------------------------------------------------------------

select
  case when count(*) = 24 then 'OK   ' else 'WRONG' end || '  tables: ' || count(*)
    || ' (expected 24)' as check
  from pg_tables where schemaname = 'public'

union all
select
  case when count(*) >= 19 then 'OK   ' else 'WRONG' end || '  views: ' || count(*)
    || ' (expected 19)'
  from pg_views where schemaname = 'public'

union all
select
  case when count(*) = 1 then 'OK   ' else 'WRONG' end || '  admin users: ' || count(*)
    || ' (expected 1)'
  from public.app_user where role = 'ADMIN' and is_active

union all
select
  case when bool_and(rowsecurity) then 'OK   ' else 'WRONG' end
    || '  row-level security enabled on every table'
  from pg_tables where schemaname = 'public'

union all
select
  case when count(*) = 7 then 'OK   ' else 'WRONG' end || '  document series: ' || count(*)
    || ' (expected 7)'
  from app.doc_sequence

union all
select
  case when count(*) = 1 then 'OK   ' else 'WRONG' end || '  settings row: ' || count(*)
    || ' (expected 1)'
  from public.app_setting;
