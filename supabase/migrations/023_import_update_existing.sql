-- =============================================================================
-- 023_import_update_existing.sql
-- An import can now update rows that are already there.
--
-- Until now a code that already existed was either an error or something to
-- skip. Both are right when you are adding to a list. Neither is right when
-- the spreadsheet IS the list — when the parties are already in the database
-- and the numbers beside them, the opening balances above all, are what needs
-- to change.
--
-- So the import gains a third answer to "this code is already there":
--
--   stop    (default)  an error, nothing is written          p_skip_existing = false
--   skip               leave the existing row alone          p_skip_existing = true
--   update             overwrite it from the sheet           p_update_existing = true
--
-- Codes are still never changed: the code is what matches a sheet row to a
-- database row, so by definition it is the one thing that stays.
--
-- Update mode respects the rules in 019. A party whose opening balance is
-- frozen because it already has documents, or a product whose opening stock
-- has been posted, is reported as a row problem with its name in it — before
-- anything is written — rather than failing halfway through on a trigger.
--
-- Everything else is unchanged: the whole sheet is still checked before any of
-- it is written, and a sheet with one bad row writes nothing at all.
--
-- Run this file once in the Supabase SQL Editor. Safe to run more than once.
-- =============================================================================

-- Replaced rather than overloaded: two functions of the same name differing
-- only by a defaulted argument makes every call ambiguous.
drop function if exists public.import_masters(text, jsonb, boolean, boolean);

create or replace function public.import_masters(
  p_entity          text,
  p_rows            jsonb,
  p_dry_run         boolean default true,
  p_skip_existing   boolean default false,
  p_update_existing boolean default false
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
  v_updated  integer := 0;
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

  -- Skipping and updating are two different answers to the same question.
  if p_skip_existing and p_update_existing then
    raise exception 'Rows that already exist can be skipped or updated, not both'
      using errcode = 'SA004';
  end if;

  drop table if exists _imp;
  create temp table _imp on commit drop as
  select
    (ordinality + 1)::integer as row_no,   -- +1 because row 1 is the header
    e.value                   as r,
    false                     as is_existing
  from jsonb_array_elements(p_rows) with ordinality as e(value, ordinality);

  v_count := (select count(*) from pg_temp._imp);

  -- ---------------------------------------------------------------------------
  -- Which rows are already in the database
  --
  -- Marked on the row itself rather than kept in a list on the side, because
  -- the write needs to know, row by row, which is an insert and which is an
  -- update.
  -- ---------------------------------------------------------------------------
  execute format($q$
    update pg_temp._imp i
       set is_existing = true
      from public.%1$I x
     where x.code = app.imp_text(i.r ->> 'code')
  $q$, p_entity);

  select coalesce(jsonb_agg(jsonb_build_object(
           'row', i.row_no, 'code', app.imp_text(i.r ->> 'code')) order by i.row_no),
         '[]'::jsonb)
    into v_existing
    from pg_temp._imp i
   where i.is_existing;

  v_skipped := jsonb_array_length(v_existing);

  -- When skipping, take them out before anything else is checked: a row that
  -- is not being imported should not produce errors about its other columns.
  if p_skip_existing and v_skipped > 0 then
    delete from pg_temp._imp i where i.is_existing;

    if not exists (select 1 from pg_temp._imp) then
      return jsonb_build_object(
        'entity', p_entity, 'rows', v_count, 'errors', 0,
        'error_detail', '[]'::jsonb, 'dry_run', p_dry_run,
        'imported', 0, 'updated', 0, 'skipped', v_skipped,
        'skipped_detail', v_existing,
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

  -- Already in the database, and neither skipping nor updating.
  if not p_skip_existing and not p_update_existing then
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
                     ('opening_rate'), ('sale_price'), ('purchase_price'),
                     ('opening_price')) as f(field)
       where app.imp_text(r ->> f.field) is not null
         and not app.imp_is_number(r ->> f.field)
      union all
      select app.imp_err(row_no, f.field, r ->> f.field, 'Cannot be negative')
        from pg_temp._imp,
             (values ('sale_rate'), ('purchase_rate'), ('opening_qty'),
                     ('opening_rate'), ('sale_price'), ('purchase_price'),
                     ('opening_price')) as f(field)
       where app.imp_is_number(r ->> f.field)
         and (r ->> f.field)::numeric < 0
      union all
      -- Two prices for the same thing, in two different units, would be a
      -- guess either way. Ask instead.
      select app.imp_err(row_no, f.new_field, r ->> f.new_field,
               'Fill in ' || f.new_field || ' or ' || f.old_field || ', not both. '
               || f.new_field || ' is per pack when there is a pack unit; '
               || f.old_field || ' is always per base unit.')
        from pg_temp._imp,
             (values ('sale_price', 'sale_rate'),
                     ('purchase_price', 'purchase_rate'),
                     ('opening_price', 'opening_rate')) as f(new_field, old_field)
       where app.imp_text(r ->> f.new_field) is not null
         and app.imp_text(r ->> f.old_field) is not null
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
  -- What update mode is not allowed to change
  --
  -- 019 freezes a party's opening balance once it has documents, and a
  -- product's opening stock once it has been posted. Those triggers would stop
  -- the import anyway — but on the first offending row, with no list of the
  -- others. Checking here turns that into the same row-by-row report as every
  -- other problem, and only complains when the sheet actually differs from
  -- what is stored.
  -- ---------------------------------------------------------------------------
  if p_update_existing then

    if p_entity = 'party' then
      select v_errors || coalesce(jsonb_agg(err), '[]'::jsonb) into v_errors
      from (
        select app.imp_err(i.row_no, 'opening_balance', i.r ->> 'opening_balance',
                 format('%s already has orders, bills or payments, so its opening balance can no longer change',
                        p.name)) as err
          from pg_temp._imp i
          join public.party p on p.code = app.imp_text(i.r ->> 'code')
         where i.is_existing
           and public.party_has_documents(p.id)
           and (coalesce(nullif(i.r ->> 'opening_balance', '')::numeric, 0)
                  is distinct from p.opening_balance
                or app.imp_to_date(i.r ->> 'opening_balance_date')
                  is distinct from p.opening_balance_date)
      ) t;
    end if;

    if p_entity = 'product' then
      select v_errors || coalesce(jsonb_agg(err), '[]'::jsonb) into v_errors
      from (
        select app.imp_err(i.row_no, 'opening_qty', i.r ->> 'opening_qty',
                 format('The opening stock of %s has already been posted and can no longer change',
                        p.name)) as err
          from pg_temp._imp i
          join public.product p on p.code = app.imp_text(i.r ->> 'code')
         where i.is_existing
           and public.product_opening_posted(p.id)
           and (coalesce(app.imp_text(i.r ->> 'opening_qty')::numeric, 0)
                  is distinct from p.opening_qty
                or app.imp_to_date(i.r ->> 'opening_date')
                  is distinct from p.opening_date)
      ) t;
    end if;

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
    'updated',        0,
    'skipped',        case when p_skip_existing then v_skipped else 0 end,
    'skipped_detail', case when p_skip_existing then v_existing else '[]'::jsonb end,
    'updated_detail', case when p_update_existing then v_existing else '[]'::jsonb end,
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
      'would_import', (select count(*) from pg_temp._imp where not is_existing),
      'would_update', (select count(*) from pg_temp._imp where is_existing));
  end if;

  -- ---------------------------------------------------------------------------
  -- Write
  --
  -- New rows are inserted; existing ones are updated only in update mode. In
  -- the other two modes nothing is marked existing by the time we get here —
  -- skip deleted them, stop refused the whole sheet — so the insert is the
  -- only statement that does anything.
  -- ---------------------------------------------------------------------------

  if p_entity = 'route' then
    insert into public.route (code, name)
    select app.imp_text(r ->> 'code'), app.imp_text(r ->> 'name')
      from pg_temp._imp where not is_existing;
    get diagnostics v_imported = row_count;

    if p_update_existing then
      update public.route t
         set name = app.imp_text(i.r ->> 'name')
        from pg_temp._imp i
       where i.is_existing and t.code = app.imp_text(i.r ->> 'code');
      get diagnostics v_updated = row_count;
    end if;

  elsif p_entity = 'product_group' then
    insert into public.product_group (code, name)
    select app.imp_text(r ->> 'code'), app.imp_text(r ->> 'name')
      from pg_temp._imp where not is_existing;
    get diagnostics v_imported = row_count;

    if p_update_existing then
      update public.product_group t
         set name = app.imp_text(i.r ->> 'name')
        from pg_temp._imp i
       where i.is_existing and t.code = app.imp_text(i.r ->> 'code');
      get diagnostics v_updated = row_count;
    end if;

  elsif p_entity = 'supplier' then
    insert into public.supplier (code, name, contact_person, phone, address, city)
    select app.imp_text(r ->> 'code'), app.imp_text(r ->> 'name'),
           app.imp_text(r ->> 'contact_person'), app.imp_text(r ->> 'phone'),
           app.imp_text(r ->> 'address'), app.imp_text(r ->> 'city')
      from pg_temp._imp where not is_existing;
    get diagnostics v_imported = row_count;

    if p_update_existing then
      update public.supplier t
         set name           = app.imp_text(i.r ->> 'name'),
             contact_person = app.imp_text(i.r ->> 'contact_person'),
             phone          = app.imp_text(i.r ->> 'phone'),
             address        = app.imp_text(i.r ->> 'address'),
             city           = app.imp_text(i.r ->> 'city')
        from pg_temp._imp i
       where i.is_existing and t.code = app.imp_text(i.r ->> 'code');
      get diagnostics v_updated = row_count;
    end if;

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
    join public.route rt on rt.code = app.imp_text(i.r ->> 'route_code')
   where not i.is_existing;
    get diagnostics v_imported = row_count;

    if p_update_existing then
      update public.party t
         set name                 = app.imp_text(i.r ->> 'name'),
             route_id             = rt.id,
             contact_person       = app.imp_text(i.r ->> 'contact_person'),
             phone                = app.imp_text(i.r ->> 'phone'),
             whatsapp_phone       = coalesce(app.imp_text(i.r ->> 'whatsapp_phone'),
                                             app.imp_text(i.r ->> 'phone')),
             address              = app.imp_text(i.r ->> 'address'),
             city                 = app.imp_text(i.r ->> 'city'),
             credit_limit         = coalesce(nullif(i.r ->> 'credit_limit', '')::numeric, 0),
             credit_days          = coalesce(nullif(i.r ->> 'credit_days', '')::smallint, 0),
             opening_balance      = coalesce(nullif(i.r ->> 'opening_balance', '')::numeric, 0),
             opening_balance_date = app.imp_to_date(i.r ->> 'opening_balance_date')
        from pg_temp._imp i
        join public.route rt on rt.code = app.imp_text(i.r ->> 'route_code')
       where i.is_existing and t.code = app.imp_text(i.r ->> 'code');
      get diagnostics v_updated = row_count;
    end if;

  elsif p_entity = 'product' then
    -- A *_price column is per pack when the row has a pack unit, and per base
    -- unit otherwise. A *_rate column is always per base unit. Validation has
    -- already made sure at most one of each pair is filled in.
    --
    -- The pack price is stored as typed; the trigger derives the unit rate.
    insert into public.product
      (code, name, group_id, base_uom, pack_uom, pack_size,
       sale_rate, purchase_rate, pack_sale_rate, pack_purchase_rate,
       opening_qty, opening_rate, opening_date)
    select
      x.code, x.name, x.group_id, x.base_uom, x.pack_uom, x.pack_size,
      coalesce(case when x.pack_uom is null then x.sale_price end, x.sale_rate, 0),
      coalesce(case when x.pack_uom is null then x.purchase_price end, x.purchase_rate, 0),
      case when x.pack_uom is not null then x.sale_price end,
      case when x.pack_uom is not null then x.purchase_price end,
      x.opening_qty,
      coalesce(case when x.pack_uom is null then x.opening_price
                    else round(x.opening_price / x.pack_size, 4) end,
               x.opening_rate, 0),
      x.opening_date
    from (
      select
        app.imp_text(i.r ->> 'code')                              as code,
        app.imp_text(i.r ->> 'name')                              as name,
        g.id                                                      as group_id,
        upper(app.imp_text(i.r ->> 'base_uom'))                   as base_uom,
        upper(app.imp_text(i.r ->> 'pack_uom'))                   as pack_uom,
        coalesce(app.imp_text(i.r ->> 'pack_size')::numeric, 1)   as pack_size,
        app.imp_text(i.r ->> 'sale_price')::numeric               as sale_price,
        app.imp_text(i.r ->> 'purchase_price')::numeric           as purchase_price,
        app.imp_text(i.r ->> 'opening_price')::numeric            as opening_price,
        app.imp_text(i.r ->> 'sale_rate')::numeric                as sale_rate,
        app.imp_text(i.r ->> 'purchase_rate')::numeric            as purchase_rate,
        app.imp_text(i.r ->> 'opening_rate')::numeric             as opening_rate,
        coalesce(app.imp_text(i.r ->> 'opening_qty')::numeric, 0) as opening_qty,
        app.imp_to_date(i.r ->> 'opening_date')                   as opening_date
      from pg_temp._imp i
      join public.product_group g on g.code = app.imp_text(i.r ->> 'group_code')
     where not i.is_existing
    ) x;
    get diagnostics v_imported = row_count;

    if p_update_existing then
      -- Note the derived unit rate below, where the insert above leaves it at
      -- zero and lets the trigger fill it in. On an update the trigger reads a
      -- changed sale_rate with an unchanged pack price as "somebody edited the
      -- unit rate by hand" and clears the pack price. Writing the rate the
      -- pack price implies means there is nothing for it to disagree with.
      update public.product t
         set name               = x.name,
             group_id           = x.group_id,
             base_uom           = x.base_uom,
             pack_uom           = x.pack_uom,
             pack_size          = x.pack_size,
             sale_rate          = coalesce(case when x.pack_uom is null then x.sale_price
                                                else round(x.sale_price / x.pack_size, 4) end,
                                           x.sale_rate, 0),
             purchase_rate      = coalesce(case when x.pack_uom is null then x.purchase_price
                                                else round(x.purchase_price / x.pack_size, 4) end,
                                           x.purchase_rate, 0),
             pack_sale_rate     = case when x.pack_uom is not null then x.sale_price end,
             pack_purchase_rate = case when x.pack_uom is not null then x.purchase_price end,
             opening_qty        = x.opening_qty,
             opening_rate       = coalesce(case when x.pack_uom is null then x.opening_price
                                                else round(x.opening_price / x.pack_size, 4) end,
                                           x.opening_rate, 0),
             opening_date       = x.opening_date
        from (
          select
            app.imp_text(i.r ->> 'code')                              as code,
            app.imp_text(i.r ->> 'name')                              as name,
            g.id                                                      as group_id,
            upper(app.imp_text(i.r ->> 'base_uom'))                   as base_uom,
            upper(app.imp_text(i.r ->> 'pack_uom'))                   as pack_uom,
            coalesce(app.imp_text(i.r ->> 'pack_size')::numeric, 1)   as pack_size,
            app.imp_text(i.r ->> 'sale_price')::numeric               as sale_price,
            app.imp_text(i.r ->> 'purchase_price')::numeric           as purchase_price,
            app.imp_text(i.r ->> 'opening_price')::numeric            as opening_price,
            app.imp_text(i.r ->> 'sale_rate')::numeric                as sale_rate,
            app.imp_text(i.r ->> 'purchase_rate')::numeric            as purchase_rate,
            app.imp_text(i.r ->> 'opening_rate')::numeric             as opening_rate,
            coalesce(app.imp_text(i.r ->> 'opening_qty')::numeric, 0) as opening_qty,
            app.imp_to_date(i.r ->> 'opening_date')                   as opening_date
          from pg_temp._imp i
          join public.product_group g on g.code = app.imp_text(i.r ->> 'group_code')
         where i.is_existing
        ) x
       where t.code = x.code;
      get diagnostics v_updated = row_count;
    end if;
  end if;

  return v_report || jsonb_build_object(
    'imported', v_imported,
    'updated',  v_updated);
end;
$$;

revoke all on function
  public.import_masters(text, jsonb, boolean, boolean, boolean) from public, anon;

grant execute on function
  public.import_masters(text, jsonb, boolean, boolean, boolean) to authenticated;

comment on function public.import_masters(text, jsonb, boolean, boolean, boolean) is
  'Bulk import of master data from a spreadsheet. A code that already exists is
   an error by default, skipped with p_skip_existing, or overwritten from the
   sheet with p_update_existing. Nothing is written unless every row is good.';
