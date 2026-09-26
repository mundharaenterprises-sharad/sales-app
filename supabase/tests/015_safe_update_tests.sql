-- =============================================================================
-- 015_safe_update_tests.sql
-- Every UPDATE and DELETE we ship says which rows it means.
--
-- Why this suite exists: migration 029 shipped three UPDATE statements with no
-- WHERE clause. They were correct — every row of a temporary staging table was
-- meant to be updated — and a plain local Postgres ran them without complaint,
-- so the whole test suite passed. Supabase refused them at the first order a
-- rep tried to take, because it runs with a safety net that rejects a
-- WHERE-less UPDATE or DELETE outright, whatever the table.
--
-- The lesson is not "029 had a typo". It is that the local database is more
-- permissive than the real one, so "the tests pass" did not mean "this works".
-- This suite closes that particular gap: it reads the source of every function
-- we install and fails on any UPDATE or DELETE without a WHERE, including the
-- ones hidden inside dynamic SQL, which is where the three were.
--
-- If a statement really does mean every row, write `where true`. That is the
-- point: it makes "all of them" something you said rather than something you
-- left out.
-- =============================================================================

\set QUIET on
set client_min_messages = notice;

create or replace function pg_temp.pass(msg text) returns void
language plpgsql as $$ begin raise notice 'PASS  %', msg; end; $$;


-- -----------------------------------------------------------------------------
-- Split a function body into statements and look at each one.
--
-- Crude on purpose. A real parser is not worth building here, and the failure
-- this guards against is not subtle: the word UPDATE or DELETE FROM starting a
-- statement, with no WHERE before the semicolon that ends it.
--
-- Comments are stripped first, so a `-- update everything` note in the prose
-- above a function does not read as code.
-- -----------------------------------------------------------------------------

create or replace function pg_temp.unsafe_statements(src text)
returns setof text
language plpgsql as $$
declare
  body text;
  stmt text;
begin
  -- Drop line comments and block comments.
  body := regexp_replace(src, '--[^\n]*', ' ', 'g');
  body := regexp_replace(body, '/\*.*?\*/', ' ', 'gs');

  foreach stmt in array string_to_array(body, ';') loop
    stmt := btrim(regexp_replace(stmt, '\s+', ' ', 'g'));
    continue when stmt = '';

    -- A statement is an UPDATE if it names a table and then SET. Anchoring to
    -- the start of the chunk would miss the common case, because the chunk
    -- before the first semicolon of a function body begins "begin update ...".
    -- Requiring SET after the table name is what keeps "for update", "on
    -- conflict do update set" and a GRANT ... UPDATE out of the results.
    if (stmt ~* '\mupdate\s+[a-z_0-9."]+\s+set\M'
        or stmt ~* '\mdelete\s+from\s+[a-z_0-9."]+')
       and stmt !~* '\mwhere\M'
    then
      return next left(stmt, 90);
    end if;
  end loop;
end $$;


-- =============================================================================
-- 1. No function we install has a WHERE-less UPDATE or DELETE
-- =============================================================================
do $$
declare
  r record;
  v_found text := '';
  v_count integer := 0;
begin
  for r in
    select n.nspname as schema_name, p.proname as fn, p.prosrc as src
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'app')
       and p.prokind = 'f'
     order by n.nspname, p.proname
  loop
    declare s text;
    begin
      for s in select * from pg_temp.unsafe_statements(r.src) loop
        v_count := v_count + 1;
        v_found := v_found || format(E'\n    %s.%s: %s', r.schema_name, r.fn, s);
      end loop;
    end;
  end loop;

  if v_count > 0 then
    raise exception
      'FAIL  % UPDATE/DELETE statement(s) with no WHERE clause. Supabase will refuse these at run time. Add `where true` if every row is meant:%',
      v_count, v_found;
  end if;

  perform pg_temp.pass('no function has a WHERE-less UPDATE or DELETE');
end $$;


-- =============================================================================
-- 2. The detector actually detects — a guard that cannot fail is not a guard
-- =============================================================================
do $$
declare n integer;
begin
  select count(*) into n from pg_temp.unsafe_statements(
    'begin update public.party set is_active = false; end');
  if n <> 1 then
    raise exception 'FAIL  detector missed a bare UPDATE (found %)', n;
  end if;

  select count(*) into n from pg_temp.unsafe_statements(
    'begin delete from public.party; end');
  if n <> 1 then
    raise exception 'FAIL  detector missed a bare DELETE (found %)', n;
  end if;

  -- The exact shape that got through: a WHERE-less UPDATE inside dynamic SQL,
  -- which is the half of the codebase a reader's eye slides over.
  select count(*) into n from pg_temp.unsafe_statements(
    $src$begin execute $q$
      update pg_temp._ord_stage set gross = round(qty * rate, 2);
      update pg_temp._ord_stage set line_discount_amount = 0;
    $q$; end$src$);
  if n <> 2 then
    raise exception 'FAIL  detector missed WHERE-less updates in dynamic SQL (found %)', n;
  end if;

  perform pg_temp.pass('the detector catches a bare UPDATE, a bare DELETE and both inside dynamic SQL');
end $$;


-- =============================================================================
-- 3. And does not cry wolf
-- =============================================================================
do $$
declare n integer;
begin
  select count(*) into n from pg_temp.unsafe_statements(
    'begin update public.party set is_active = false where id = v_id; end');
  if n <> 0 then
    raise exception 'FAIL  a WHERE-d UPDATE was reported (found %)', n;
  end if;

  select count(*) into n from pg_temp.unsafe_statements(
    'begin update pg_temp._ord_stage set gross = 1 where true; end');
  if n <> 0 then
    raise exception 'FAIL  `where true` was reported (found %)', n;
  end if;

  select count(*) into n from pg_temp.unsafe_statements(
    'begin -- update everything
     select 1 from public.party for update; end');
  if n <> 0 then
    raise exception 'FAIL  a comment or FOR UPDATE was reported (found %)', n;
  end if;

  perform pg_temp.pass('a WHERE, a `where true`, a comment and FOR UPDATE all pass');
end $$;


-- =============================================================================
-- 4. The statements that started this: taking an order still works
-- =============================================================================
do $$
declare v_src text;
begin
  select prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'order_line_discounts';

  if v_src is null then
    raise exception 'FAIL  app.order_line_discounts() is missing';
  end if;

  if (select count(*) from regexp_matches(v_src, 'where true', 'gi')) < 3 then
    raise exception
      'FAIL  app.order_line_discounts() should say `where true` on all three staging updates';
  end if;

  perform pg_temp.pass('the discount staging updates say which rows they mean');
end $$;

\echo '  4 of 4 passed.'
