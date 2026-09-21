-- =============================================================================
-- 019_master_editing.sql
-- Rules for editing parties and products by hand, now that the app has
-- screens for it.
--
-- Admin could always update these tables directly. RLS allowed it. What was
-- missing were the rules about WHICH fields may change, and when:
--
--   * Codes never change. Spreadsheets, imports and people refer to things by
--     code. Renaming one quietly breaks every list that uses the old code.
--
--   * A party's opening balance is frozen once the party has any document:
--     an order, invoice, return or receipt. After that, ageing and the party
--     ledger are built on top of it, and changing it would rewrite history.
--
--   * A product's opening stock is frozen once it has been posted to the stock
--     ledger. The ledger is append-only, so editing opening_qty afterwards
--     would change nothing except make the product record lie about it.
--
-- These rules live in the database, not the screens, so a change from any
-- route (app, SQL Editor, a future bulk update) meets the same rules.
--
-- Run this file once in the Supabase SQL Editor. Safe to run more than once.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Questions the screens need to ask. SECURITY DEFINER so the answer is the
-- same whoever asks, even if they cannot read the documents themselves. They
-- return only yes/no, never the documents.
-- -----------------------------------------------------------------------------

create or replace function public.party_has_documents(p_party_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
  select exists (select 1 from public.sales_order   where party_id = p_party_id)
      or exists (select 1 from public.sales_invoice where party_id = p_party_id)
      or exists (select 1 from public.sales_return  where party_id = p_party_id)
      or exists (select 1 from public.receipt       where party_id = p_party_id);
$$;

create or replace function public.product_opening_posted(p_product_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
  select exists (select 1 from public.stock_ledger
                  where product_id = p_product_id and doc_type = 'OPENING');
$$;

revoke all on function public.party_has_documents(uuid)    from public, anon;
revoke all on function public.product_opening_posted(uuid) from public, anon;
grant execute on function public.party_has_documents(uuid)    to authenticated;
grant execute on function public.product_opening_posted(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- Guards
-- -----------------------------------------------------------------------------

create or replace function app.party_guard()
returns trigger
language plpgsql
as $$
begin
  if new.code is distinct from old.code then
    raise exception 'A party code cannot be changed (% stays %).', old.name, old.code
      using errcode = 'SA004';
  end if;

  if (new.opening_balance is distinct from old.opening_balance
      or new.opening_balance_date is distinct from old.opening_balance_date)
     and public.party_has_documents(old.id) then
    raise exception 'The opening balance of % is fixed: the party already has orders, bills or payments.',
      old.name using errcode = 'SA002';
  end if;

  return new;
end;
$$;

drop trigger if exists party_guard on public.party;
create trigger party_guard
  before update on public.party
  for each row execute function app.party_guard();

create or replace function app.product_guard()
returns trigger
language plpgsql
as $$
begin
  if new.code is distinct from old.code then
    raise exception 'A product code cannot be changed (% stays %).', old.name, old.code
      using errcode = 'SA004';
  end if;

  if (new.opening_qty  is distinct from old.opening_qty
      or new.opening_rate is distinct from old.opening_rate
      or new.opening_date is distinct from old.opening_date)
     and public.product_opening_posted(old.id) then
    raise exception 'The opening stock of % has already been posted and cannot be changed here.',
      old.name using errcode = 'SA002';
  end if;

  return new;
end;
$$;

drop trigger if exists product_guard on public.product;
create trigger product_guard
  before update on public.product
  for each row execute function app.product_guard();

-- -----------------------------------------------------------------------------
-- What the Parties and Products screens read. One row per master, with the
-- names of what it points at and whether its opening figures are still open.
-- -----------------------------------------------------------------------------

create or replace view public.v_party_master as
select
  p.*,
  r.code  as route_code,
  r.name  as route_name,
  public.party_has_documents(p.id) as opening_locked
from public.party p
join public.route r on r.id = p.route_id;

create or replace view public.v_product_master as
select
  p.*,
  g.code  as group_code,
  g.name  as group_name,
  public.product_opening_posted(p.id) as opening_locked
from public.product p
join public.product_group g on g.id = p.group_id;

alter view public.v_party_master   set (security_invoker = true);
alter view public.v_product_master set (security_invoker = true);
grant select on public.v_party_master, public.v_product_master to authenticated;
