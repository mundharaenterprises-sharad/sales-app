-- =============================================================================
-- 002_users.sql
-- Application users. One row per auth.users row, carrying the role.
-- =============================================================================

create table public.app_user (
  id          uuid primary key references auth.users (id) on delete restrict,
  full_name   text           not null check (length(btrim(full_name)) > 0),
  role        app.user_role  not null default 'REP',
  phone       text,
  is_active   boolean        not null default true,
  created_at  timestamptz    not null default now(),
  updated_at  timestamptz    not null default now()
);

comment on table public.app_user is
  'Profile and role for each login. Deactivate rather than delete: users are
   referenced by every document they created.';

create trigger app_user_touch
  before update on public.app_user
  for each row execute function app.touch_updated_at();

create index app_user_role_idx on public.app_user (role) where is_active;

-- -----------------------------------------------------------------------------
-- Role helpers used by every RLS policy.
--
-- SECURITY DEFINER so that reading app_user does not itself require a policy
-- that reads app_user (which would recurse). STABLE so the planner calls them
-- once per statement rather than once per row.
-- -----------------------------------------------------------------------------

create or replace function app.current_role()
returns app.user_role
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
  select u.role
    from public.app_user u
   where u.id = auth.uid()
     and u.is_active;
$$;

create or replace function app.is_admin()
returns boolean
language sql
stable
as $$ select app.current_role() = 'ADMIN'; $$;

-- Accounts and Admin both post financial documents.
create or replace function app.is_back_office()
returns boolean
language sql
stable
as $$ select app.current_role() in ('ACCOUNTS', 'ADMIN'); $$;

create or replace function app.is_signed_in()
returns boolean
language sql
stable
as $$ select app.current_role() is not null; $$;
