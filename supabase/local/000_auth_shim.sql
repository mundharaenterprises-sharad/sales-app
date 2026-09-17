-- =============================================================================
-- 000_auth_shim.sql   —   LOCAL TESTING ONLY. Never run this on Supabase.
--
-- Supabase provides the auth schema, the auth.users table and auth.uid().
-- This recreates just enough of them to run the migrations and the test suite
-- against a plain PostgreSQL instance.
-- =============================================================================

create schema if not exists auth;

create table if not exists auth.users (
  id         uuid primary key default gen_random_uuid(),
  email      text unique,
  created_at timestamptz not null default now()
);

-- Mirrors Supabase: reads the subject claim of the request's JWT.
-- Locally, tests set it with:  set local request.jwt.claim.sub = '<uuid>';
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

-- Supabase defines these roles. RLS policies reference them by name.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end;
$$;
