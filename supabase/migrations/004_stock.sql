-- =============================================================================
-- 004_stock.sql
-- The stock ledger (append-only, source of truth) and the cached balance.
--
-- Every movement of goods writes exactly one ledger row. product_stock is a
-- derived cache maintained by trigger; a reconciliation view compares the two.
-- =============================================================================

create table public.stock_ledger (
  id            uuid primary key default gen_random_uuid(),
  product_id    uuid          not null references public.product (id) on delete restrict,
  movement_date date          not null,

  qty_in        numeric(14,4) not null default 0 check (qty_in  >= 0),
  qty_out       numeric(14,4) not null default 0 check (qty_out >= 0),
  rate          numeric(14,4) not null default 0 check (rate    >= 0),

  doc_type      app.stock_doc_type not null,
  doc_id        uuid,
  doc_line_id   uuid,
  notes         text,

  created_at    timestamptz   not null default now(),
  created_by    uuid          references public.app_user (id),

  -- Exactly one direction per row. Keeps the ledger unambiguous to read.
  constraint stock_ledger_one_direction
    check ((qty_in > 0 and qty_out = 0) or (qty_out > 0 and qty_in = 0))
);

comment on table public.stock_ledger is
  'Append-only. Never updated, never deleted. Corrections are new reversing rows.';

create trigger stock_ledger_no_update
  before update or delete on public.stock_ledger
  for each row execute function app.forbid_change();

create index stock_ledger_product_idx on public.stock_ledger (product_id, movement_date);
create index stock_ledger_doc_idx     on public.stock_ledger (doc_type, doc_id);

-- -----------------------------------------------------------------------------
-- Cached balance
--
-- on_hand >= 0 is a hard CHECK. This is the last line of defence behind the
-- application logic: even a bug cannot drive stock negative, the transaction
-- simply fails.
-- -----------------------------------------------------------------------------

create table public.product_stock (
  product_id  uuid primary key references public.product (id) on delete restrict,
  on_hand     numeric(14,4) not null default 0 check (on_hand  >= 0),
  reserved    numeric(14,4) not null default 0 check (reserved >= 0),
  available   numeric(14,4) generated always as (on_hand - reserved) stored,
  updated_at  timestamptz   not null default now()
);

comment on column public.product_stock.reserved is
  'Committed to submitted sales orders not yet invoiced. Not a stock movement,
   so it is maintained by the order functions rather than by the ledger.';

create index product_stock_available_idx on public.product_stock (available);

-- Every product gets a stock row the moment it is created.
create or replace function app.create_stock_row()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
  insert into public.product_stock (product_id) values (new.id)
  on conflict (product_id) do nothing;
  return new;
end;
$$;

create trigger product_create_stock_row
  after insert on public.product
  for each row execute function app.create_stock_row();

-- Ledger row in, cached balance updated. The only writer of on_hand.
--
-- Deliberately UPDATE-then-INSERT rather than INSERT ... ON CONFLICT DO UPDATE.
-- An upsert evaluates CHECK constraints against the proposed insert row before
-- it detects the conflict, so a stock-out of 24 would be checked as -24 >= 0
-- and rejected before the update path was ever reached. Every product gets its
-- stock row when it is created, so the UPDATE is the normal path; the INSERT is
-- a fallback that should never fire.
create or replace function app.apply_ledger_to_stock()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
  update public.product_stock
     set on_hand    = on_hand + (new.qty_in - new.qty_out),
         updated_at = now()
   where product_id = new.product_id;

  if not found then
    insert into public.product_stock (product_id, on_hand)
    values (new.product_id, new.qty_in - new.qty_out);
  end if;

  return new;
end;
$$;

create trigger stock_ledger_apply
  after insert on public.stock_ledger
  for each row execute function app.apply_ledger_to_stock();

-- -----------------------------------------------------------------------------
-- Reconciliation: the cache must always agree with the ledger.
-- Run this as a scheduled check; any row returned is a bug worth investigating.
-- -----------------------------------------------------------------------------

create or replace view public.v_stock_reconciliation as
select
  p.id                                   as product_id,
  p.code,
  p.name,
  coalesce(ps.on_hand, 0)                as cached_on_hand,
  coalesce(sum(sl.qty_in - sl.qty_out), 0) as ledger_on_hand,
  coalesce(ps.on_hand, 0) - coalesce(sum(sl.qty_in - sl.qty_out), 0) as difference
from public.product p
left join public.product_stock ps on ps.product_id = p.id
left join public.stock_ledger  sl on sl.product_id = p.id
group by p.id, p.code, p.name, ps.on_hand
having coalesce(ps.on_hand, 0) <> coalesce(sum(sl.qty_in - sl.qty_out), 0);

comment on view public.v_stock_reconciliation is
  'Should always be empty. Any row means the cached balance drifted from the ledger.';

-- -----------------------------------------------------------------------------
-- Opening stock
--
-- Posts each product''s opening_qty as an OPENING ledger row. Idempotent:
-- a product that already has an OPENING row is skipped.
-- -----------------------------------------------------------------------------

create or replace function public.post_opening_stock()
returns integer
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_count integer := 0;
begin
  if not app.is_admin() then
    raise exception 'Only Admin may post opening stock'
      using errcode = 'insufficient_privilege';
  end if;

  insert into public.stock_ledger
    (product_id, movement_date, qty_in, rate, doc_type, notes, created_by)
  select p.id, p.opening_date, p.opening_qty, p.opening_rate, 'OPENING',
         'Opening stock at go-live', auth.uid()
    from public.product p
   where p.opening_qty > 0
     and p.opening_date is not null
     and not exists (
           select 1 from public.stock_ledger sl
            where sl.product_id = p.id and sl.doc_type = 'OPENING'
         );

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
