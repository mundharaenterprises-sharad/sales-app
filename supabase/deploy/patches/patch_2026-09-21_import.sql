-- =============================================================================
-- patch_2026-09-21_import.sql
--
-- Brings a database deployed before 18 September up to date for the import
-- screen. Run the whole file once in the Supabase SQL Editor.
--
-- It contains migration 016 followed by migration 017, and the order matters:
-- 016 creates the helper functions and an older three-argument import
-- function; 017 then removes that older version and installs the current one.
-- Run 016 alone and two versions exist side by side, which makes every call
-- ambiguous. This file runs them in the right order in one go.
--
-- Safe to run more than once.
-- =============================================================================


-- >>>>>>>>>>>>>>>>>>>>  016_import.sql  <<<<<<<<<<<<<<<<<<<<

-- =============================================================================
-- 016_import.sql
-- Bulk import of master data from a spreadsheet.
--
-- Design: validate everything first, then write, and write nothing at all if
-- any row is bad. A half-imported party list is worse than no import, because
-- nobody can tell which half is missing.
--
-- Every field arrives as TEXT and is checked before being cast. A cell reading
-- "12,500" then reports "not a number" against that row and column, instead of
-- the whole batch dying with "invalid input syntax for numeric".
--
-- Foreign keys are given as human-readable CODES, not ids — a spreadsheet says
-- route "R1", never a UUID.
--
-- Import order matters: routes and product groups first, since parties and
-- products point at them.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Small helpers used by every validator
-- -----------------------------------------------------------------------------

-- Trimmed, with blank treated as absent.
create or replace function app.imp_text(p text)
returns text
language sql
immutable
as $$ select nullif(btrim(coalesce(p, '')), ''); $$;

-- Is this text a number we can trust? Rejects "12,500", "1.2.3", "abc", "".
create or replace function app.imp_is_number(p text)
returns boolean
language sql
immutable
as $$ select btrim(coalesce(p, '')) ~ '^-?[0-9]+(\.[0-9]+)?$'; $$;

-- Accepts YYYY-MM-DD and DD/MM/YYYY, which is what spreadsheets in this part
-- of the world actually produce.
create or replace function app.imp_to_date(p text)
returns date
language plpgsql
immutable
as $$
declare t text := btrim(coalesce(p, ''));
begin
  if t = '' then return null; end if;
  if t ~ '^\d{4}-\d{2}-\d{2}$'        then return to_date(t, 'YYYY-MM-DD'); end if;
  if t ~ '^\d{1,2}/\d{1,2}/\d{4}$'    then return to_date(t, 'DD/MM/YYYY'); end if;
  if t ~ '^\d{1,2}-\d{1,2}-\d{4}$'    then return to_date(t, 'DD-MM-YYYY'); end if;
  return null;
exception when others then
  return null;
end;
$$;

create or replace function app.imp_is_date(p text)
returns boolean
language sql
immutable
as $$
  select btrim(coalesce(p, '')) = '' or app.imp_to_date(p) is not null;
$$;

-- One error, in the shape the client renders.
create or replace function app.imp_err(
  p_row integer, p_field text, p_value text, p_message text)
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'row', p_row, 'field', p_field,
    'value', left(coalesce(p_value, ''), 80), 'message', p_message);
$$;

-- =============================================================================
-- The importer
--
--   select public.import_masters('party', '<rows>'::jsonb, true);   -- check
--   select public.import_masters('party', '<rows>'::jsonb, false);  -- import
--
-- Returns a report. On a real run with any error it raises SA004 and puts the
-- same report in the error DETAIL, so the transaction aborts and nothing is
-- written.
-- =============================================================================

create or replace function public.import_masters(
  p_entity  text,
  p_rows    jsonb,
  p_dry_run boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user     uuid := app.require_signed_in();
  v_errors   jsonb := '[]'::jsonb;
  v_count    integer := 0;
  v_imported integer := 0;
  v_report   jsonb;
begin
  if not app.is_admin() then
    raise exception 'Only Admin may import master data' using errcode = 'SA003';
  end if;

  if p_entity not in ('route', 'product_group', 'supplier', 'party', 'product') then
    raise exception 'Unknown entity "%". Expected route, product_group, supplier, party or product.',
      p_entity using errcode = 'SA004';
  end if;

  if jsonb_typeof(coalesce(p_rows, 'null'::jsonb)) <> 'array' then
    raise exception 'Rows must be a JSON array' using errcode = 'SA004';
  end if;

  if jsonb_array_length(p_rows) = 0 then
    raise exception 'There are no rows to import' using errcode = 'SA004';
  end if;

  -- Everything as text, with the spreadsheet row number carried through so an
  -- error can say "row 47" and mean the row the person is looking at.
  drop table if exists _imp;
  create temp table _imp on commit drop as
  select
    (ordinality + 1)::integer as row_no,   -- +1 because row 1 is the header
    e.value                   as r
  from jsonb_array_elements(p_rows) with ordinality as e(value, ordinality);

  v_count := (select count(*) from pg_temp._imp);

  -- ---------------------------------------------------------------------------
  -- Shared checks: every entity has a code and a name.
  -- ---------------------------------------------------------------------------
  select v_errors || coalesce(jsonb_agg(err), '[]'::jsonb) into v_errors
  from (
    select app.imp_err(row_no, 'code', r ->> 'code', 'Code is required') as err
      from pg_temp._imp where app.imp_text(r ->> 'code') is null
    union all
    select app.imp_err(row_no, 'name', r ->> 'name', 'Name is required')
      from pg_temp._imp where app.imp_text(r ->> 'name') is null
    union all
    -- Duplicated inside the sheet itself.
    select app.imp_err(row_no, 'code', r ->> 'code',
             'This code appears more than once in the sheet')
      from pg_temp._imp
     where app.imp_text(r ->> 'code') is not null
       and app.imp_text(r ->> 'code') in (
             select app.imp_text(d.r ->> 'code') from pg_temp._imp d
              group by 1 having count(*) > 1)
    union all
    -- The template ships with a sample row. Forgetting to delete it would
    -- otherwise create a party called "Example Store" that nobody notices
    -- until it turns up on a report.
    select app.imp_err(row_no, 'code', r ->> 'code',
             'This is the example row from the template — delete it before importing')
      from pg_temp._imp
     where upper(coalesce(app.imp_text(r ->> 'code'), '')) like 'EXAMPLE%'
  ) t;

  -- Already in the database. Import adds; it never silently overwrites.
  execute format($q$
    select coalesce(jsonb_agg(app.imp_err(i.row_no, 'code', i.r ->> 'code',
             'A %1$s with this code already exists')), '[]'::jsonb)
      from pg_temp._imp i
      join public.%1$I x on x.code = app.imp_text(i.r ->> 'code')
  $q$, p_entity)
  into v_report;
  v_errors := v_errors || v_report;

  -- ---------------------------------------------------------------------------
  -- Per-entity checks
  -- ---------------------------------------------------------------------------

  if p_entity = 'party' then
    select v_errors || coalesce(jsonb_agg(err), '[]'::jsonb) into v_errors
    from (
      select app.imp_err(row_no, 'route_code', r ->> 'route_code',
               'Route code is required') as err
        from pg_temp._imp where app.imp_text(r ->> 'route_code') is null
      union all
      select app.imp_err(row_no, 'route_code', r ->> 'route_code',
               'No route exists with this code — add it to the Routes sheet first')
        from pg_temp._imp i
       where app.imp_text(i.r ->> 'route_code') is not null
         and not exists (select 1 from public.route rt
                          where rt.code = app.imp_text(i.r ->> 'route_code'))
      union all
      select app.imp_err(row_no, 'credit_limit', r ->> 'credit_limit', 'Not a number')
        from pg_temp._imp
       where app.imp_text(r ->> 'credit_limit') is not null
         and not app.imp_is_number(r ->> 'credit_limit')
      union all
      select app.imp_err(row_no, 'credit_days', r ->> 'credit_days', 'Not a whole number')
        from pg_temp._imp
       where app.imp_text(r ->> 'credit_days') is not null
         and (not app.imp_is_number(r ->> 'credit_days')
              or (r ->> 'credit_days') ~ '\.')
      union all
      select app.imp_err(row_no, 'opening_balance', r ->> 'opening_balance', 'Not a number')
        from pg_temp._imp
       where app.imp_text(r ->> 'opening_balance') is not null
         and not app.imp_is_number(r ->> 'opening_balance')
      union all
      select app.imp_err(row_no, 'opening_balance_date', r ->> 'opening_balance_date',
               'Not a date — use YYYY-MM-DD or DD/MM/YYYY')
        from pg_temp._imp where not app.imp_is_date(r ->> 'opening_balance_date')
      union all
      -- An opening balance with no date cannot be aged.
      select app.imp_err(row_no, 'opening_balance_date', r ->> 'opening_balance_date',
               'An opening balance needs a date')
        from pg_temp._imp
       where app.imp_is_number(r ->> 'opening_balance')
         and (r ->> 'opening_balance')::numeric <> 0
         and app.imp_text(r ->> 'opening_balance_date') is null
    ) t;
  end if;

  if p_entity = 'product' then
    select v_errors || coalesce(jsonb_agg(err), '[]'::jsonb) into v_errors
    from (
      select app.imp_err(row_no, 'group_code', r ->> 'group_code',
               'Group code is required') as err
        from pg_temp._imp where app.imp_text(r ->> 'group_code') is null
      union all
      select app.imp_err(row_no, 'group_code', r ->> 'group_code',
               'No product group exists with this code — add it to the Product Groups sheet first')
        from pg_temp._imp i
       where app.imp_text(i.r ->> 'group_code') is not null
         and not exists (select 1 from public.product_group g
                          where g.code = app.imp_text(i.r ->> 'group_code'))
      union all
      select app.imp_err(row_no, 'base_uom', r ->> 'base_uom',
               'Base unit is required, e.g. PCS or KG')
        from pg_temp._imp where app.imp_text(r ->> 'base_uom') is null
      union all
      select app.imp_err(row_no, 'pack_size', r ->> 'pack_size',
               'Not a number')
        from pg_temp._imp
       where app.imp_text(r ->> 'pack_size') is not null
         and not app.imp_is_number(r ->> 'pack_size')
      union all
      select app.imp_err(row_no, 'pack_size', r ->> 'pack_size',
               'Pack size must be above zero')
        from pg_temp._imp
       where app.imp_is_number(r ->> 'pack_size')
         and (r ->> 'pack_size')::numeric <= 0
      union all
      -- A pack unit without a size, or a size without a unit, is a typo.
      select app.imp_err(row_no, 'pack_size', r ->> 'pack_size',
               'A pack unit needs a pack size above 1')
        from pg_temp._imp
       where app.imp_text(r ->> 'pack_uom') is not null
         and (app.imp_text(r ->> 'pack_size') is null
              or (app.imp_is_number(r ->> 'pack_size')
                  and (r ->> 'pack_size')::numeric <= 1))
      union all
      select app.imp_err(row_no, 'pack_uom', r ->> 'pack_uom',
               'A pack size above 1 needs a pack unit, e.g. BOX')
        from pg_temp._imp
       where app.imp_is_number(r ->> 'pack_size')
         and (r ->> 'pack_size')::numeric > 1
         and app.imp_text(r ->> 'pack_uom') is null
      union all
      select app.imp_err(row_no, f.field, r ->> f.field, 'Not a number')
        from pg_temp._imp,
             (values ('sale_rate'), ('purchase_rate'), ('opening_qty'),
                     ('opening_rate')) as f(field)
       where app.imp_text(r ->> f.field) is not null
         and not app.imp_is_number(r ->> f.field)
      union all
      select app.imp_err(row_no, f.field, r ->> f.field, 'Cannot be negative')
        from pg_temp._imp,
             (values ('sale_rate'), ('purchase_rate'), ('opening_qty'),
                     ('opening_rate')) as f(field)
       where app.imp_is_number(r ->> f.field)
         and (r ->> f.field)::numeric < 0
      union all
      select app.imp_err(row_no, 'opening_date', r ->> 'opening_date',
               'Not a date — use YYYY-MM-DD or DD/MM/YYYY')
        from pg_temp._imp where not app.imp_is_date(r ->> 'opening_date')
      union all
      select app.imp_err(row_no, 'opening_date', r ->> 'opening_date',
               'Opening stock needs a date')
        from pg_temp._imp
       where app.imp_is_number(r ->> 'opening_qty')
         and (r ->> 'opening_qty')::numeric > 0
         and app.imp_text(r ->> 'opening_date') is null
    ) t;
  end if;

  -- ---------------------------------------------------------------------------
  -- Report, and stop here if anything is wrong
  -- ---------------------------------------------------------------------------

  v_report := jsonb_build_object(
    'entity',       p_entity,
    'rows',         v_count,
    'errors',       jsonb_array_length(v_errors),
    'error_detail', (select jsonb_agg(e order by (e ->> 'row')::int, e ->> 'field')
                       from jsonb_array_elements(v_errors) e),
    'dry_run',      p_dry_run,
    'imported',     0);

  if jsonb_array_length(v_errors) > 0 then
    if p_dry_run then
      return v_report;                     -- checking: hand back the problems
    end if;
    raise exception 'Import refused: % row problem(s). Nothing was imported.',
      jsonb_array_length(v_errors)
      using errcode = 'SA004', detail = v_report::text;
  end if;

  if p_dry_run then
    return v_report || jsonb_build_object('would_import', v_count);
  end if;

  -- ---------------------------------------------------------------------------
  -- Write
  -- ---------------------------------------------------------------------------

  if p_entity = 'route' then
    insert into public.route (code, name)
    select app.imp_text(r ->> 'code'), app.imp_text(r ->> 'name')
      from pg_temp._imp;

  elsif p_entity = 'product_group' then
    insert into public.product_group (code, name)
    select app.imp_text(r ->> 'code'), app.imp_text(r ->> 'name')
      from pg_temp._imp;

  elsif p_entity = 'supplier' then
    insert into public.supplier (code, name, contact_person, phone, address, city)
    select app.imp_text(r ->> 'code'), app.imp_text(r ->> 'name'),
           app.imp_text(r ->> 'contact_person'), app.imp_text(r ->> 'phone'),
           app.imp_text(r ->> 'address'), app.imp_text(r ->> 'city')
      from pg_temp._imp;

  elsif p_entity = 'party' then
    insert into public.party
      (code, name, route_id, contact_person, phone, whatsapp_phone,
       address, city, credit_limit, credit_days,
       opening_balance, opening_balance_date)
    select
      app.imp_text(i.r ->> 'code'),
      app.imp_text(i.r ->> 'name'),
      rt.id,
      app.imp_text(i.r ->> 'contact_person'),
      app.imp_text(i.r ->> 'phone'),
      coalesce(app.imp_text(i.r ->> 'whatsapp_phone'), app.imp_text(i.r ->> 'phone')),
      app.imp_text(i.r ->> 'address'),
      app.imp_text(i.r ->> 'city'),
      coalesce(nullif(i.r ->> 'credit_limit', '')::numeric, 0),
      coalesce(nullif(i.r ->> 'credit_days', '')::smallint, 0),
      coalesce(nullif(i.r ->> 'opening_balance', '')::numeric, 0),
      app.imp_to_date(i.r ->> 'opening_balance_date')
    from pg_temp._imp i
    join public.route rt on rt.code = app.imp_text(i.r ->> 'route_code');

  elsif p_entity = 'product' then
    insert into public.product
      (code, name, group_id, base_uom, pack_uom, pack_size,
       sale_rate, purchase_rate, opening_qty, opening_rate, opening_date)
    select
      app.imp_text(i.r ->> 'code'),
      app.imp_text(i.r ->> 'name'),
      g.id,
      upper(app.imp_text(i.r ->> 'base_uom')),
      upper(app.imp_text(i.r ->> 'pack_uom')),
      coalesce(nullif(i.r ->> 'pack_size', '')::numeric, 1),
      coalesce(nullif(i.r ->> 'sale_rate', '')::numeric, 0),
      coalesce(nullif(i.r ->> 'purchase_rate', '')::numeric, 0),
      coalesce(nullif(i.r ->> 'opening_qty', '')::numeric, 0),
      coalesce(nullif(i.r ->> 'opening_rate', '')::numeric, 0),
      app.imp_to_date(i.r ->> 'opening_date')
    from pg_temp._imp i
    join public.product_group g on g.code = app.imp_text(i.r ->> 'group_code');
  end if;

  get diagnostics v_imported = row_count;

  return v_report || jsonb_build_object('imported', v_imported);
end;
$$;

grant execute on function public.import_masters(text, jsonb, boolean) to authenticated;

-- >>>>>>>>>>>>>>>>>>>>  017_import_skip_existing.sql  <<<<<<<<<<<<<<<<<<<<

-- =============================================================================
-- 017_import_skip_existing.sql
-- Lets an import skip rows whose code is already in the database.
--
-- Why this exists: parties point at routes, so routes must be imported before
-- parties can even be checked. That means a workbook is loaded sheet by sheet,
-- and a failure on the Parties sheet leaves Routes already imported. Without a
-- skip, correcting the parties and re-uploading the same workbook would then
-- fail on Routes with "already exists" — and the person would be stuck.
--
-- Skipping is never silent. The report says how many rows were skipped and
-- lists their codes, so "import did nothing" always has a visible reason.
-- =============================================================================

-- The 3-argument version is replaced rather than overloaded: two functions of
-- the same name differing only by a defaulted argument makes every call
-- ambiguous.
drop function if exists public.import_masters(text, jsonb, boolean);

create or replace function public.import_masters(
  p_entity        text,
  p_rows          jsonb,
  p_dry_run       boolean default true,
  p_skip_existing boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user     uuid := app.require_signed_in();
  v_errors   jsonb := '[]'::jsonb;
  v_existing jsonb := '[]'::jsonb;
  v_count    integer := 0;
  v_skipped  integer := 0;
  v_imported integer := 0;
  v_report   jsonb;
  v_tmp      jsonb;
begin
  if not app.is_admin() then
    raise exception 'Only Admin may import master data' using errcode = 'SA003';
  end if;

  if p_entity not in ('route', 'product_group', 'supplier', 'party', 'product') then
    raise exception 'Unknown entity "%". Expected route, product_group, supplier, party or product.',
      p_entity using errcode = 'SA004';
  end if;

  if jsonb_typeof(coalesce(p_rows, 'null'::jsonb)) <> 'array' then
    raise exception 'Rows must be a JSON array' using errcode = 'SA004';
  end if;

  if jsonb_array_length(p_rows) = 0 then
    raise exception 'There are no rows to import' using errcode = 'SA004';
  end if;

  drop table if exists _imp;
  create temp table _imp on commit drop as
  select
    (ordinality + 1)::integer as row_no,   -- +1 because row 1 is the header
    e.value                   as r
  from jsonb_array_elements(p_rows) with ordinality as e(value, ordinality);

  v_count := (select count(*) from pg_temp._imp);

  -- ---------------------------------------------------------------------------
  -- Which rows are already in the database
  -- ---------------------------------------------------------------------------
  execute format($q$
    select coalesce(jsonb_agg(jsonb_build_object(
             'row', i.row_no, 'code', app.imp_text(i.r ->> 'code'))), '[]'::jsonb)
      from pg_temp._imp i
      join public.%1$I x on x.code = app.imp_text(i.r ->> 'code')
  $q$, p_entity)
  into v_existing;

  v_skipped := jsonb_array_length(v_existing);

  -- When skipping, take them out before anything else is checked: a row that
  -- is not being imported should not produce errors about its other columns.
  if p_skip_existing and v_skipped > 0 then
    delete from pg_temp._imp i
     where i.row_no in (
       select (e ->> 'row')::int from jsonb_array_elements(v_existing) e);

    if not exists (select 1 from pg_temp._imp) then
      return jsonb_build_object(
        'entity', p_entity, 'rows', v_count, 'errors', 0,
        'error_detail', '[]'::jsonb, 'dry_run', p_dry_run,
        'imported', 0, 'skipped', v_skipped, 'skipped_detail', v_existing,
        'note', 'Every row was already in the database. Nothing to import.');
    end if;
  end if;

  -- ---------------------------------------------------------------------------
  -- Shared checks
  -- ---------------------------------------------------------------------------
  select v_errors || coalesce(jsonb_agg(err), '[]'::jsonb) into v_errors
  from (
    select app.imp_err(row_no, 'code', r ->> 'code', 'Code is required') as err
      from pg_temp._imp where app.imp_text(r ->> 'code') is null
    union all
    select app.imp_err(row_no, 'name', r ->> 'name', 'Name is required')
      from pg_temp._imp where app.imp_text(r ->> 'name') is null
    union all
    select app.imp_err(row_no, 'code', r ->> 'code',
             'This code appears more than once in the sheet')
      from pg_temp._imp
     where app.imp_text(r ->> 'code') is not null
       and app.imp_text(r ->> 'code') in (
             select app.imp_text(d.r ->> 'code') from pg_temp._imp d
              group by 1 having count(*) > 1)
    union all
    select app.imp_err(row_no, 'code', r ->> 'code',
             'This is the example row from the template — delete it before importing')
      from pg_temp._imp
     where upper(coalesce(app.imp_text(r ->> 'code'), '')) like 'EXAMPLE%'
  ) t;

  -- Already in the database, and not skipping.
  if not p_skip_existing then
    select coalesce(jsonb_agg(app.imp_err(
             (e ->> 'row')::int, 'code', e ->> 'code',
             format('A %s with this code already exists', p_entity))), '[]'::jsonb)
      into v_tmp
      from jsonb_array_elements(v_existing) e;
    v_errors := v_errors || v_tmp;
  end if;

  -- ---------------------------------------------------------------------------
  -- Per-entity checks
  -- ---------------------------------------------------------------------------

  if p_entity = 'party' then
    select v_errors || coalesce(jsonb_agg(err), '[]'::jsonb) into v_errors
    from (
      select app.imp_err(row_no, 'route_code', r ->> 'route_code',
               'Route code is required') as err
        from pg_temp._imp where app.imp_text(r ->> 'route_code') is null
      union all
      select app.imp_err(row_no, 'route_code', r ->> 'route_code',
               'No route exists with this code — import the Routes sheet first')
        from pg_temp._imp i
       where app.imp_text(i.r ->> 'route_code') is not null
         and not exists (select 1 from public.route rt
                          where rt.code = app.imp_text(i.r ->> 'route_code'))
      union all
      select app.imp_err(row_no, 'credit_limit', r ->> 'credit_limit', 'Not a number')
        from pg_temp._imp
       where app.imp_text(r ->> 'credit_limit') is not null
         and not app.imp_is_number(r ->> 'credit_limit')
      union all
      select app.imp_err(row_no, 'credit_days', r ->> 'credit_days', 'Not a whole number')
        from pg_temp._imp
       where app.imp_text(r ->> 'credit_days') is not null
         and (not app.imp_is_number(r ->> 'credit_days')
              or (r ->> 'credit_days') ~ '\.')
      union all
      select app.imp_err(row_no, 'opening_balance', r ->> 'opening_balance', 'Not a number')
        from pg_temp._imp
       where app.imp_text(r ->> 'opening_balance') is not null
         and not app.imp_is_number(r ->> 'opening_balance')
      union all
      select app.imp_err(row_no, 'opening_balance_date', r ->> 'opening_balance_date',
               'Not a date — use YYYY-MM-DD or DD/MM/YYYY')
        from pg_temp._imp where not app.imp_is_date(r ->> 'opening_balance_date')
      union all
      select app.imp_err(row_no, 'opening_balance_date', r ->> 'opening_balance_date',
               'An opening balance needs a date')
        from pg_temp._imp
       where app.imp_is_number(r ->> 'opening_balance')
         and (r ->> 'opening_balance')::numeric <> 0
         and app.imp_text(r ->> 'opening_balance_date') is null
    ) t;
  end if;

  if p_entity = 'product' then
    select v_errors || coalesce(jsonb_agg(err), '[]'::jsonb) into v_errors
    from (
      select app.imp_err(row_no, 'group_code', r ->> 'group_code',
               'Group code is required') as err
        from pg_temp._imp where app.imp_text(r ->> 'group_code') is null
      union all
      select app.imp_err(row_no, 'group_code', r ->> 'group_code',
               'No product group exists with this code — import the Product Groups sheet first')
        from pg_temp._imp i
       where app.imp_text(i.r ->> 'group_code') is not null
         and not exists (select 1 from public.product_group g
                          where g.code = app.imp_text(i.r ->> 'group_code'))
      union all
      select app.imp_err(row_no, 'base_uom', r ->> 'base_uom',
               'Base unit is required, e.g. PCS or KG')
        from pg_temp._imp where app.imp_text(r ->> 'base_uom') is null
      union all
      select app.imp_err(row_no, 'pack_size', r ->> 'pack_size', 'Not a number')
        from pg_temp._imp
       where app.imp_text(r ->> 'pack_size') is not null
         and not app.imp_is_number(r ->> 'pack_size')
      union all
      select app.imp_err(row_no, 'pack_size', r ->> 'pack_size',
               'Pack size must be above zero')
        from pg_temp._imp
       where app.imp_is_number(r ->> 'pack_size')
         and (r ->> 'pack_size')::numeric <= 0
      union all
      select app.imp_err(row_no, 'pack_size', r ->> 'pack_size',
               'A pack unit needs a pack size above 1')
        from pg_temp._imp
       where app.imp_text(r ->> 'pack_uom') is not null
         and (app.imp_text(r ->> 'pack_size') is null
              or (app.imp_is_number(r ->> 'pack_size')
                  and (r ->> 'pack_size')::numeric <= 1))
      union all
      select app.imp_err(row_no, 'pack_uom', r ->> 'pack_uom',
               'A pack size above 1 needs a pack unit, e.g. BOX')
        from pg_temp._imp
       where app.imp_is_number(r ->> 'pack_size')
         and (r ->> 'pack_size')::numeric > 1
         and app.imp_text(r ->> 'pack_uom') is null
      union all
      select app.imp_err(row_no, f.field, r ->> f.field, 'Not a number')
        from pg_temp._imp,
             (values ('sale_rate'), ('purchase_rate'), ('opening_qty'),
                     ('opening_rate')) as f(field)
       where app.imp_text(r ->> f.field) is not null
         and not app.imp_is_number(r ->> f.field)
      union all
      select app.imp_err(row_no, f.field, r ->> f.field, 'Cannot be negative')
        from pg_temp._imp,
             (values ('sale_rate'), ('purchase_rate'), ('opening_qty'),
                     ('opening_rate')) as f(field)
       where app.imp_is_number(r ->> f.field)
         and (r ->> f.field)::numeric < 0
      union all
      select app.imp_err(row_no, 'opening_date', r ->> 'opening_date',
               'Not a date — use YYYY-MM-DD or DD/MM/YYYY')
        from pg_temp._imp where not app.imp_is_date(r ->> 'opening_date')
      union all
      select app.imp_err(row_no, 'opening_date', r ->> 'opening_date',
               'Opening stock needs a date')
        from pg_temp._imp
       where app.imp_is_number(r ->> 'opening_qty')
         and (r ->> 'opening_qty')::numeric > 0
         and app.imp_text(r ->> 'opening_date') is null
    ) t;
  end if;

  -- ---------------------------------------------------------------------------
  -- Report
  -- ---------------------------------------------------------------------------

  v_report := jsonb_build_object(
    'entity',         p_entity,
    'rows',           v_count,
    'errors',         jsonb_array_length(v_errors),
    'error_detail',   coalesce((select jsonb_agg(e order by (e ->> 'row')::int, e ->> 'field')
                                  from jsonb_array_elements(v_errors) e), '[]'::jsonb),
    'dry_run',        p_dry_run,
    'imported',       0,
    'skipped',        case when p_skip_existing then v_skipped else 0 end,
    'skipped_detail', case when p_skip_existing then v_existing else '[]'::jsonb end,
    'already_exists', v_skipped);

  if jsonb_array_length(v_errors) > 0 then
    if p_dry_run then
      return v_report;
    end if;
    raise exception 'Import refused: % row problem(s). Nothing was imported.',
      jsonb_array_length(v_errors)
      using errcode = 'SA004', detail = v_report::text;
  end if;

  if p_dry_run then
    return v_report || jsonb_build_object(
      'would_import', (select count(*) from pg_temp._imp));
  end if;

  -- ---------------------------------------------------------------------------
  -- Write
  -- ---------------------------------------------------------------------------

  if p_entity = 'route' then
    insert into public.route (code, name)
    select app.imp_text(r ->> 'code'), app.imp_text(r ->> 'name')
      from pg_temp._imp;

  elsif p_entity = 'product_group' then
    insert into public.product_group (code, name)
    select app.imp_text(r ->> 'code'), app.imp_text(r ->> 'name')
      from pg_temp._imp;

  elsif p_entity = 'supplier' then
    insert into public.supplier (code, name, contact_person, phone, address, city)
    select app.imp_text(r ->> 'code'), app.imp_text(r ->> 'name'),
           app.imp_text(r ->> 'contact_person'), app.imp_text(r ->> 'phone'),
           app.imp_text(r ->> 'address'), app.imp_text(r ->> 'city')
      from pg_temp._imp;

  elsif p_entity = 'party' then
    insert into public.party
      (code, name, route_id, contact_person, phone, whatsapp_phone,
       address, city, credit_limit, credit_days,
       opening_balance, opening_balance_date)
    select
      app.imp_text(i.r ->> 'code'),
      app.imp_text(i.r ->> 'name'),
      rt.id,
      app.imp_text(i.r ->> 'contact_person'),
      app.imp_text(i.r ->> 'phone'),
      coalesce(app.imp_text(i.r ->> 'whatsapp_phone'), app.imp_text(i.r ->> 'phone')),
      app.imp_text(i.r ->> 'address'),
      app.imp_text(i.r ->> 'city'),
      coalesce(nullif(i.r ->> 'credit_limit', '')::numeric, 0),
      coalesce(nullif(i.r ->> 'credit_days', '')::smallint, 0),
      coalesce(nullif(i.r ->> 'opening_balance', '')::numeric, 0),
      app.imp_to_date(i.r ->> 'opening_balance_date')
    from pg_temp._imp i
    join public.route rt on rt.code = app.imp_text(i.r ->> 'route_code');

  elsif p_entity = 'product' then
    insert into public.product
      (code, name, group_id, base_uom, pack_uom, pack_size,
       sale_rate, purchase_rate, opening_qty, opening_rate, opening_date)
    select
      app.imp_text(i.r ->> 'code'),
      app.imp_text(i.r ->> 'name'),
      g.id,
      upper(app.imp_text(i.r ->> 'base_uom')),
      upper(app.imp_text(i.r ->> 'pack_uom')),
      coalesce(nullif(i.r ->> 'pack_size', '')::numeric, 1),
      coalesce(nullif(i.r ->> 'sale_rate', '')::numeric, 0),
      coalesce(nullif(i.r ->> 'purchase_rate', '')::numeric, 0),
      coalesce(nullif(i.r ->> 'opening_qty', '')::numeric, 0),
      coalesce(nullif(i.r ->> 'opening_rate', '')::numeric, 0),
      app.imp_to_date(i.r ->> 'opening_date')
    from pg_temp._imp i
    join public.product_group g on g.code = app.imp_text(i.r ->> 'group_code');
  end if;

  get diagnostics v_imported = row_count;

  return v_report || jsonb_build_object('imported', v_imported);
end;
$$;

grant execute on function public.import_masters(text, jsonb, boolean, boolean)
  to authenticated;
