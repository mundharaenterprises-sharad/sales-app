-- =============================================================================
-- 035_create_party_and_ledger.sql
--
-- Run this in the Supabase SQL Editor. Committing it to git does nothing to
-- the database.
--
-- Two unrelated things that both needed the database.
--
-- 1. A REP CAN ADD A CUSTOMER, BUT NOT CHANGE ONE
--
-- A rep standing in a shop that is not on the list cannot take the order. So
-- they can create the customer — but only create. Editing stays with the
-- office, because a rep correcting a name in the field is how "Ram Store"
-- quietly becomes "Ram Stores" on one phone and stays "Ram Store" on another.
--
-- The insert policy is NOT loosened. It still says admin only, and this
-- function is security definer, so the only way a rep can create a party is
-- through this door — which generates the code, requires a route, and refuses
-- a blank name. A door is easier to reason about than a wider gate.
--
-- 2. CODES CONTINUE THE SEQUENCE ALREADY IN USE
--
-- Parties run AA1 … AA340, products PP1 … PP82: letters then a number, no
-- padding. Rather than store a counter that could drift from reality, the next
-- code is read from the data — the highest number actually in use, plus one.
-- That cannot disagree with what is there, survives an import that jumps the
-- sequence, and needs nothing kept in step.
--
-- Two people creating a customer at the same second would compute the same
-- number, so the insert retries on a collision rather than failing. Retrying a
-- generated code is right; retrying a typed one would not be.
--
-- 3. A STOCK LEDGER TO READ
--
-- Every movement has been recorded since the beginning and there has never
-- been a screen for it. The view adds what a ledger needs and a table of rows
-- does not have: a running balance, and the name of the document each movement
-- came from.
--
-- Safe to run twice.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. The next code in a sequence
-- -----------------------------------------------------------------------------

create or replace function app.next_master_code(p_table text, p_prefix text)
returns text
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_max bigint;
begin
  if p_table not in ('party', 'product') then
    raise exception 'Unknown master table %', p_table using errcode = 'SA004';
  end if;

  -- Only codes that are exactly this prefix followed by digits. A code someone
  -- typed by hand — "AA340-B", "OLD1" — is left out of the reckoning rather
  -- than crashing the cast or, worse, being treated as a number it is not.
  execute format(
    'select coalesce(max(substring(code from %L)::bigint), 0)
       from public.%I
      where code ~ %L',
    '^' || p_prefix || '([0-9]+)$',
    p_table,
    '^' || p_prefix || '[0-9]+$')
  into v_max;

  return p_prefix || (v_max + 1)::text;
end;
$$;

comment on function app.next_master_code(text, text) is
  'The next code in a prefix + number sequence, read from the codes actually in
   use rather than from a counter that could drift from them.';

revoke all on function app.next_master_code(text, text) from public, anon;


/** What the next code would be, for showing on a form before it is saved. */
create or replace function public.suggest_master_code(p_table text)
returns text
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
  perform app.require_signed_in();
  return app.next_master_code(
    p_table,
    case p_table when 'party' then 'AA' when 'product' then 'PP' end);
end;
$$;

revoke all on function public.suggest_master_code(text) from public, anon;
grant execute on function public.suggest_master_code(text) to authenticated;

comment on function public.suggest_master_code(text) is
  'A preview of the next code. Only a preview: the code is settled when the
   record is actually created, because somebody else may create one first.';


-- -----------------------------------------------------------------------------
-- 2. Creating a customer
-- -----------------------------------------------------------------------------

create or replace function public.create_party(
  p_name           text,
  p_route_id       uuid,
  p_phone          text default null,
  p_address        text default null,
  p_city           text default null,
  p_contact_person text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user uuid := app.require_signed_in();
  v_code text;
  v_id   uuid;
  v_try  int := 0;
begin
  if length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'A customer needs a name' using errcode = 'SA004';
  end if;

  if not exists (select 1 from public.route where id = p_route_id and is_active) then
    raise exception 'Choose a route for this customer' using errcode = 'SA004';
  end if;

  -- Name the customer that already exists, spelled and cased as IT is, not as
  -- the caller just typed it. "There is already a customer called ram store"
  -- sends somebody looking for a shop written that way; "called Ram Store
  -- (AA1)" is something they can go and find.
  declare v_clash text;
  begin
    select name || ' (' || code || ')' into v_clash
      from public.party
     where lower(btrim(name)) = lower(btrim(p_name))
     limit 1;

    if v_clash is not null then
      raise exception 'There is already a customer called %. Use that one, or give this a name that tells them apart.',
        v_clash using errcode = 'SA004';
    end if;
  end;

  -- Deliberately no opening balance and no credit limit. An opening balance is
  -- a go-live matter that is frozen once a party has documents, and a credit
  -- limit is the office's decision; a rep in a shop should be setting neither.
  loop
    v_try := v_try + 1;
    v_code := app.next_master_code('party', 'AA');
    begin
      insert into public.party (code, name, route_id, phone, address, city, contact_person)
      values (v_code, btrim(p_name), p_route_id,
              nullif(btrim(coalesce(p_phone, '')), ''),
              nullif(btrim(coalesce(p_address, '')), ''),
              nullif(btrim(coalesce(p_city, '')), ''),
              nullif(btrim(coalesce(p_contact_person, '')), ''))
      returning id into v_id;
      exit;
    exception when unique_violation then
      -- Somebody created a customer between reading the highest code and
      -- using it. Read it again. Five attempts is far more than a shop with
      -- three reps will ever need, and it will not spin forever if something
      -- is genuinely wrong.
      if v_try >= 5 then raise; end if;
    end;
  end loop;

  return jsonb_build_object('party_id', v_id, 'code', v_code, 'name', btrim(p_name));
end;
$$;

revoke all on function
  public.create_party(text, uuid, text, text, text, text) from public, anon;
grant execute on function
  public.create_party(text, uuid, text, text, text, text) to authenticated;

comment on function public.create_party(text, uuid, text, text, text, text) is
  'Adds a customer with the next code in the sequence. Callable by any signed-in
   user; editing a party remains admin-only, which is the point.';


-- -----------------------------------------------------------------------------
-- 3. The stock ledger
-- -----------------------------------------------------------------------------

drop view if exists public.v_stock_ledger;

create view public.v_stock_ledger as
select
  sl.id,
  sl.product_id,
  pr.code                     as product_code,
  pr.name                     as product_name,
  pr.base_uom,
  pg.name                     as group_name,
  mg.code                     as master_code,
  mg.name                     as master_name,
  sl.movement_date,
  sl.doc_type,
  sl.doc_id,
  sl.qty_in,
  sl.qty_out,
  sl.rate,
  sl.notes,
  u.full_name                 as entered_by,
  sl.created_at,

  -- The balance after this movement. Ordered by date and then by when the row
  -- was written, because several movements share a date and a running balance
  -- that jumps about is worse than none: the order it is summed in has to be
  -- the order it is shown in, so the arithmetic on screen can be checked by
  -- eye.
  sum(sl.qty_in - sl.qty_out) over (
    partition by sl.product_id
    order by sl.movement_date, sl.created_at, sl.id
    rows between unbounded preceding and current row
  )                           as balance_after
from public.stock_ledger sl
join public.product pr        on pr.id = sl.product_id
join public.product_group pg  on pg.id = pr.group_id
left join public.master_group mg on mg.id = pg.master_group_id
left join public.app_user u   on u.id = sl.created_by;

alter view public.v_stock_ledger set (security_invoker = true);
grant select on public.v_stock_ledger to authenticated;

comment on view public.v_stock_ledger is
  'Every stock movement with a running balance per product. The balance is
   computed in the same order the screen shows, so it can be checked by eye.';

notify pgrst, 'reload schema';
