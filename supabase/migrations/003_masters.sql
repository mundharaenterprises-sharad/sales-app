-- =============================================================================
-- 003_masters.sql
-- Route, product group, supplier, party, product.
--
-- Masters are never hard-deleted once transactions reference them; they are
-- deactivated with is_active = false.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Route
-- -----------------------------------------------------------------------------

create table public.route (
  id          uuid primary key default gen_random_uuid(),
  code        text        not null unique check (length(btrim(code)) > 0),
  name        text        not null check (length(btrim(name)) > 0),
  is_active   boolean     not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create trigger route_touch before update on public.route
  for each row execute function app.touch_updated_at();

-- -----------------------------------------------------------------------------
-- Product group
-- -----------------------------------------------------------------------------

create table public.product_group (
  id          uuid primary key default gen_random_uuid(),
  code        text        not null unique check (length(btrim(code)) > 0),
  name        text        not null check (length(btrim(name)) > 0),
  is_active   boolean     not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create trigger product_group_touch before update on public.product_group
  for each row execute function app.touch_updated_at();

-- -----------------------------------------------------------------------------
-- Supplier
-- -----------------------------------------------------------------------------

create table public.supplier (
  id             uuid primary key default gen_random_uuid(),
  code           text        not null unique check (length(btrim(code)) > 0),
  name           text        not null check (length(btrim(name)) > 0),
  contact_person text,
  phone          text,
  address        text,
  city           text,
  is_active      boolean     not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create trigger supplier_touch before update on public.supplier
  for each row execute function app.touch_updated_at();

create index supplier_name_idx on public.supplier using gin (to_tsvector('simple', name));

-- -----------------------------------------------------------------------------
-- Party (customer)
-- -----------------------------------------------------------------------------

create table public.party (
  id                   uuid primary key default gen_random_uuid(),
  code                 text        not null unique check (length(btrim(code)) > 0),
  name                 text        not null check (length(btrim(name)) > 0),
  route_id             uuid        not null references public.route (id) on delete restrict,
  contact_person       text,
  phone                text,
  whatsapp_phone       text,
  address              text,
  city                 text,

  -- 0 means "no limit". Enforcement behaviour is a setting, see app_setting.
  credit_limit         numeric(14,2) not null default 0 check (credit_limit >= 0),
  credit_days          smallint      not null default 0 check (credit_days >= 0),

  -- Receivable carried in at go-live. Positive = customer owes us.
  opening_balance      numeric(14,2) not null default 0,
  opening_balance_date date,

  is_active            boolean     not null default true,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),

  constraint party_opening_needs_date
    check (opening_balance = 0 or opening_balance_date is not null)
);

comment on column public.party.opening_balance is
  'Amount receivable as at opening_balance_date. Set once at go-live by Admin.';

create trigger party_touch before update on public.party
  for each row execute function app.touch_updated_at();

create index party_route_idx on public.party (route_id) where is_active;
create index party_name_idx  on public.party using gin (to_tsvector('simple', name));

-- -----------------------------------------------------------------------------
-- Product
--
-- Stock is always held in the BASE unit. pack_size is how many base units are
-- in one pack; it is snapshotted onto every document line so that changing it
-- later never rewrites history.
-- -----------------------------------------------------------------------------

create table public.product (
  id             uuid primary key default gen_random_uuid(),
  code           text        not null unique check (length(btrim(code)) > 0),
  name           text        not null check (length(btrim(name)) > 0),
  group_id       uuid        not null references public.product_group (id) on delete restrict,

  base_uom       text        not null check (length(btrim(base_uom)) > 0),
  pack_uom       text,
  pack_size      numeric(14,4) not null default 1 check (pack_size > 0),

  -- Both rates are per BASE unit.
  sale_rate      numeric(14,4) not null default 0 check (sale_rate >= 0),
  purchase_rate  numeric(14,4) not null default 0 check (purchase_rate >= 0),

  opening_qty    numeric(14,4) not null default 0 check (opening_qty >= 0),
  opening_rate   numeric(14,4) not null default 0 check (opening_rate >= 0),
  opening_date   date,

  is_active      boolean     not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),

  -- A pack unit only means something if it differs from the base unit.
  constraint product_pack_consistent
    check (
      (pack_uom is null and pack_size = 1)
      or (pack_uom is not null and length(btrim(pack_uom)) > 0)
    ),

  constraint product_opening_needs_date
    check (opening_qty = 0 or opening_date is not null)
);

comment on column public.product.pack_size is
  'Base units per pack. 1 box of 24 pieces => base_uom PCS, pack_uom BOX, pack_size 24.';

create trigger product_touch before update on public.product
  for each row execute function app.touch_updated_at();

create index product_group_idx on public.product (group_id) where is_active;
create index product_name_idx  on public.product using gin (to_tsvector('simple', name));

-- -----------------------------------------------------------------------------
-- Application settings
--
-- Single-row table. Business rules that may change without a code deploy.
-- -----------------------------------------------------------------------------

create table public.app_setting (
  id                        boolean primary key default true check (id),
  business_name             text          not null default 'My Business',
  business_address          text,
  business_phone            text,

  -- Sales orders with no invoice are released after this many days.
  reservation_expiry_days   smallint      not null default 2
                              check (reservation_expiry_days between 1 and 30),

  -- 'IGNORE' | 'WARN' | 'BLOCK'
  credit_limit_mode         text          not null default 'WARN'
                              check (credit_limit_mode in ('IGNORE', 'WARN', 'BLOCK')),

  -- Reps may see how much each party owes.
  reps_see_outstanding      boolean       not null default true,

  -- Round the invoice net total to the nearest whole currency unit.
  round_invoice_total       boolean       not null default true,

  updated_at                timestamptz   not null default now()
);

insert into public.app_setting (id) values (true);

create trigger app_setting_touch before update on public.app_setting
  for each row execute function app.touch_updated_at();

create or replace function app.settings()
returns public.app_setting
language sql
stable
security definer
set search_path = public, pg_catalog
as $$ select * from public.app_setting where id; $$;
