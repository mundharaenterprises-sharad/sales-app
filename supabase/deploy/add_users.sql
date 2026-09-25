-- =============================================================================
-- add_users.sql
-- Giving your reps and office staff a login.
--
-- A login is TWO things and needs both:
--
--   1. A Supabase Auth user — the email and password they actually sign in
--      with. Made in the dashboard, not here, because only you should ever
--      type a password.
--
--   2. A row in public.app_user giving that login a name and a role. That is
--      what this file does.
--
-- Without the second, the person signs in and the app says "Not set up yet"
-- and shows them nothing. That is on purpose: a stray signup can never see
-- your data.
--
-- Run the steps below in order, in the Supabase SQL Editor. Safe to run more
-- than once — running it again just updates the names and roles.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- STEP 1 — create the Auth users first, in the dashboard
--
-- Authentication -> Users -> Add user -> Create new user
-- Enter the email and a password, and TICK "Auto Confirm User".
--
-- The email is only an identifier. It does not have to be a real mailbox:
-- ramesh@mundhara.local is fine for a rep whose password you set yourself.
-- The cost of a made-up address is that they cannot reset their own password —
-- you do it for them from the same screen. Office staff are better off with a
-- real address so they can reset it themselves.
--
-- Do that for everybody, then come back here.
-- -----------------------------------------------------------------------------


-- -----------------------------------------------------------------------------
-- STEP 2 — say who they are and what they may do
--
-- Edit the list below: one line per person, exactly the email you typed in the
-- dashboard, their name as it should appear, and one role.
--
--   REP       takes orders. Sees customers, products, stock and their orders.
--             Cannot bill, cannot take payments, cannot see purchase costs.
--   ACCOUNTS  the office. Bills, payments, purchases, stock, reports, day book.
--   ADMIN     all of that, plus customers, products, imports and users.
--
-- Give people the least that lets them do their job. A rep with ACCOUNTS can
-- quietly write off what a shop owes.
-- -----------------------------------------------------------------------------

with people (email, full_name, role) as (
  values
    -- >>> EDIT FROM HERE <<<
    ('agarwalaashi6555@gmail.com',   'Aashi Mundhara',   'ACCOUNTS'),
    ('gayatritradingcenter@gmail.com',   'Dipendra Mandal',     'ACCOUNTS'),
    ('ramsevak@gmail.com', 'Ramsevak Yadav', 'REP')
    -- >>> TO HERE. Keep the commas between lines, none after the last. <<<
)
insert into public.app_user (id, full_name, role, is_active)
select u.id, p.full_name, p.role::app.user_role, true
  from people p
  join auth.users u on lower(u.email) = lower(btrim(p.email))
on conflict (id) do update
  set full_name = excluded.full_name,
      role      = excluded.role,
      is_active = true;


-- -----------------------------------------------------------------------------
-- STEP 3 — check
--
-- This lists every Auth user, so it is the whole picture.
--
--   * Somebody you listed who does NOT appear at all was never created in
--     step 1, or the email here does not match what you typed there. Fix the
--     typo and run step 2 again.
--   * Somebody showing "NO APP_USER ROW" has a login but no role, so the app
--     will tell them they are not set up. Add them to the list in step 2.
--   * Anyone left over from testing should be switched off — see below.
-- -----------------------------------------------------------------------------

select
  coalesce(au.full_name, '(not set up)')        as name,
  u.email,
  coalesce(au.role::text, 'NO APP_USER ROW')    as role,
  case when au.is_active then 'active' else 'SWITCHED OFF' end as state,
  u.created_at::date                            as created
from auth.users u
left join public.app_user au on au.id = u.id
order by au.role nulls first, au.full_name;


-- =============================================================================
-- AFTERWARDS — the two things you will actually need
-- =============================================================================

-- SWITCHING SOMEBODY OFF
--
-- A rep leaves, or loses their phone. They get "Account disabled" the moment
-- they next try anything, and the app shows them nothing.
--
--   update public.app_user set is_active = false
--    where id = (select id from auth.users where email = 'ramesh@mundhara.local');
--
-- And back on again:
--
--   update public.app_user set is_active = true
--    where id = (select id from auth.users where email = 'ramesh@mundhara.local');
--
-- DO NOT DELETE PEOPLE. Every order, bill and receipt records who created it
-- and who collected the cash. The database will refuse to delete somebody who
-- has touched anything, and deleting the rest loses the trail of who did what.
-- Switching off is the correct move in every case.

-- CHANGING SOMEBODY'S ROLE
--
--   update public.app_user set role = 'ACCOUNTS'
--    where id = (select id from auth.users where email = 'suresh@mundhara.local');

-- RESETTING A PASSWORD
--
-- Not here — the dashboard. Authentication -> Users, find them, and use the
-- menu at the end of their row. Never put a password in a SQL file.
-- =============================================================================
