-- =============================================================================
-- 001_foundation.sql
-- Schemas, enums, shared helper functions, document numbering.
-- =============================================================================

create schema if not exists app;

comment on schema app is
  'Internal helpers. Not exposed through the API. Only the public schema is.';

-- -----------------------------------------------------------------------------
-- Enums
-- -----------------------------------------------------------------------------

create type app.user_role as enum ('REP', 'ACCOUNTS', 'ADMIN');

create type app.uom_type as enum ('BASE', 'PACK');

create type app.stock_doc_type as enum (
  'OPENING',
  'PURCHASE',
  'PURCHASE_CANCEL',
  'SALE',
  'SALE_CANCEL',
  'SALE_RETURN',
  'SALE_RETURN_CANCEL',
  'ADJUSTMENT'
);

create type app.order_status as enum (
  'DRAFT',
  'SUBMITTED',
  'PARTIALLY_INVOICED',
  'INVOICED',
  'CANCELLED',
  'EXPIRED'
);

create type app.invoice_status as enum (
  'ACTIVE',
  'PARTIALLY_CANCELLED',
  'CANCELLED'
);

create type app.doc_status as enum ('ACTIVE', 'CANCELLED');

create type app.payment_mode as enum ('CASH', 'BANK', 'CHEQUE', 'DIGITAL');

create type app.adjustment_reason as enum (
  'DAMAGE',
  'SAMPLE',
  'COUNT_CORRECTION',
  'EXPIRY',
  'OTHER'
);

create type app.doc_series as enum (
  'PURCHASE',
  'SALES_ORDER',
  'SALES_INVOICE',
  'SALES_RETURN',
  'STOCK_ADJUSTMENT',
  'RECEIPT',
  'INVOICE_CANCELLATION'
);

-- -----------------------------------------------------------------------------
-- Shared: updated_at maintenance
-- -----------------------------------------------------------------------------

create or replace function app.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- Shared: block UPDATE and DELETE on append-only tables
-- -----------------------------------------------------------------------------

create or replace function app.forbid_change()
returns trigger
language plpgsql
as $$
begin
  raise exception
    '% is append-only; % is not permitted', tg_table_name, tg_op
    using errcode = 'restrict_violation';
end;
$$;

-- -----------------------------------------------------------------------------
-- Document numbering
--
-- Format: <prefix><zero-padded number>, e.g. INV-000123.
-- Numbering format is configurable per series so it can be finalised later
-- without a schema change.
-- -----------------------------------------------------------------------------

create table app.doc_sequence (
  series        app.doc_series primary key,
  prefix        text        not null default '',
  next_number   bigint      not null default 1 check (next_number > 0),
  pad_width     smallint    not null default 6 check (pad_width between 1 and 12),
  updated_at    timestamptz not null default now()
);

insert into app.doc_sequence (series, prefix) values
  ('PURCHASE',             'PUR-'),
  ('SALES_ORDER',          'SO-'),
  ('SALES_INVOICE',        'INV-'),
  ('SALES_RETURN',         'SR-'),
  ('STOCK_ADJUSTMENT',     'ADJ-'),
  ('RECEIPT',              'RCT-'),
  ('INVOICE_CANCELLATION', 'CAN-');

-- Belt and braces. This table is already unreachable from a client: it lives
-- in the app schema, which PostgREST does not expose, and 012_rls.sql revokes
-- everything on that schema from anon and authenticated. RLS with no policy
-- denies by default, so this closes the door a third time. next_doc_no is
-- SECURITY DEFINER owned by this table's owner, which RLS does not restrain,
-- so numbering is unaffected.
alter table app.doc_sequence enable row level security;

-- Locks the sequence row for the duration of the caller's transaction, so two
-- concurrent documents can never take the same number.
create or replace function app.next_doc_no(p_series app.doc_series)
returns text
language plpgsql
security definer
set search_path = app, pg_catalog
as $$
declare
  v_prefix text;
  v_number bigint;
  v_width  smallint;
begin
  update app.doc_sequence
     set next_number = next_number + 1,
         updated_at  = now()
   where series = p_series
  returning prefix, next_number - 1, pad_width
    into v_prefix, v_number, v_width;

  if not found then
    raise exception 'Unknown document series: %', p_series;
  end if;

  return v_prefix || lpad(v_number::text, v_width, '0');
end;
$$;

-- -----------------------------------------------------------------------------
-- Money helpers
-- -----------------------------------------------------------------------------

-- Rounds half away from zero at 2 decimals. Postgres numeric rounding is
-- already half-up for positive values; this exists so every call site is
-- explicit and consistent.
create or replace function app.money(p numeric)
returns numeric
language sql
immutable
as $$ select round(coalesce(p, 0), 2); $$;
