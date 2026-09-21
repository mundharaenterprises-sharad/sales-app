-- =============================================================================
-- 018_pack_prices.sql
-- Prices can be entered per pack. The per-unit rate is worked out from it.
--
-- People price by the box: "a box of 24 is 500". Typing 20.8333 per piece is
-- slower and error-prone, and it also loses money. 20.8333 x 24 is 499.9992,
-- so a bill for 100 boxes would come to 49,999.92 instead of 50,000.00.
--
-- The fix is to keep the pack price as it was typed:
--
--   pack_sale_rate      500      (what was entered, used when billing by BOX)
--   sale_rate           20.8333  (derived, used when billing loose by PCS)
--
-- A trigger keeps the two in step. Whenever a pack price is set, the per-unit
-- rate is recalculated from it. That includes a later change of pack size.
-- If someone later edits the per-unit rate on its own, the pack price no longer
-- applies and is cleared. After that, the pack rate falls back to rate x size,
-- so the two can never quietly disagree.
--
-- The Products sheet gains sale_price, purchase_price and opening_price. Each
-- one is a price per PACK when the row has a pack unit, and per base unit
-- otherwise. The older sale_rate / purchase_rate / opening_rate columns still
-- work exactly as before (always per base unit), so an old workbook imports
-- unchanged. A row that fills in both styles for the same price is refused
-- rather than guessed at.
--
-- Run this file once in the Supabase SQL Editor. Safe to run more than once.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Columns
-- -----------------------------------------------------------------------------

alter table public.product
  add column if not exists pack_sale_rate     numeric(14,4),
  add column if not exists pack_purchase_rate numeric(14,4);

alter table public.product drop constraint if exists product_pack_rates_valid;
alter table public.product add constraint product_pack_rates_valid
  check (
    coalesce(pack_sale_rate, 0) >= 0
    and coalesce(pack_purchase_rate, 0) >= 0
    and (pack_uom is not null or (pack_sale_rate is null and pack_purchase_rate is null))
  ) not valid;
alter table public.product validate constraint product_pack_rates_valid;

comment on column public.product.pack_sale_rate is
  'Selling price of one pack, as entered. When set, sale_rate is derived from it.';
comment on column public.product.pack_purchase_rate is
  'Cost of one pack, as entered. When set, purchase_rate is derived from it.';
comment on column public.product.sale_rate is
  'Selling price per BASE unit. Derived from pack_sale_rate when that is set.';

-- -----------------------------------------------------------------------------
-- Keep pack and unit rates in step
-- -----------------------------------------------------------------------------

create or replace function app.product_derive_rates()
returns trigger
language plpgsql
as $$
begin
  -- A product with no pack cannot have a pack price.
  if new.pack_uom is null then
    new.pack_sale_rate     := null;
    new.pack_purchase_rate := null;
  end if;

  -- A per-unit rate edited on its own replaces the pack price. It does not get
  -- overwritten by it.
  if tg_op = 'UPDATE' then
    if new.sale_rate is distinct from old.sale_rate
       and new.pack_sale_rate is not distinct from old.pack_sale_rate then
      new.pack_sale_rate := null;
    end if;
    if new.purchase_rate is distinct from old.purchase_rate
       and new.pack_purchase_rate is not distinct from old.pack_purchase_rate then
      new.pack_purchase_rate := null;
    end if;
  end if;

  if new.pack_sale_rate is not null then
    new.sale_rate := round(new.pack_sale_rate / new.pack_size, 4);
  end if;
  if new.pack_purchase_rate is not null then
    new.purchase_rate := round(new.pack_purchase_rate / new.pack_size, 4);
  end if;

  return new;
end;
$$;

drop trigger if exists product_derive_rates on public.product;
create trigger product_derive_rates
  before insert or update on public.product
  for each row execute function app.product_derive_rates();

-- -----------------------------------------------------------------------------
-- Stock report carries the pack price, so screens need not recompute it.
-- New columns go on the end: CREATE OR REPLACE VIEW can only append.
-- -----------------------------------------------------------------------------

create or replace view public.v_stock_report as
select
  pr.id        as product_id,
  pr.code      as product_code,
  pr.name      as product_name,
  pg.name      as group_name,
  pr.base_uom,
  pr.pack_uom,
  pr.pack_size,
  ps.on_hand,
  ps.reserved,
  ps.available,
  case when pr.pack_size > 1
       then floor(ps.available / pr.pack_size) else null end as available_packs,
  pr.sale_rate,
  pr.purchase_rate,
  ps.on_hand * pr.purchase_rate as stock_value_at_cost,
  ps.updated_at,
  pr.is_active,
  -- The price of one pack: as entered if it was, otherwise rate x size.
  case when pr.pack_uom is not null
       then coalesce(pr.pack_sale_rate, round(pr.sale_rate * pr.pack_size, 2))
  end as pack_sale_rate,
  case when pr.pack_uom is not null
       then coalesce(pr.pack_purchase_rate, round(pr.purchase_rate * pr.pack_size, 2))
  end as pack_purchase_rate
from public.product pr
join public.product_group pg on pg.id = pr.group_id
join public.product_stock ps on ps.product_id = pr.id;

-- Replacing a view can reset its options. Reps must still only see what RLS
-- allows, so set this again explicitly.
alter view public.v_stock_report set (security_invoker = true);
grant select on public.v_stock_report to authenticated;

-- -----------------------------------------------------------------------------
-- Import: same function and signature as 017, with the product sheet
-- understanding the new price columns.
-- -----------------------------------------------------------------------------

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
    ) x;
  end if;

  get diagnostics v_imported = row_count;

  return v_report || jsonb_build_object('imported', v_imported);
end;
$$;

grant execute on function public.import_masters(text, jsonb, boolean, boolean)
  to authenticated;
