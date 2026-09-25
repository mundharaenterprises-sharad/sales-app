-- =============================================================================
-- 024_master_groups.sql
-- Parle, Current and Others — one level above product groups.
--
-- The business is really two businesses sharing a customer list. A shop owes
-- money "on Parle" and separately "on Current", and that is how collections
-- are chased, so the app has to be able to say which is which.
--
-- The shape:
--
--   master_group      Parle · Current · Others
--     product_group     Chocolate, Biscuits, ...   (each belongs to one master)
--       product         each belongs to one group
--
-- A product's master group is therefore derived, never typed twice.
--
-- ONE MASTER GROUP PER DOCUMENT. An order, a bill and a return each carry the
-- master group of their lines, and the database refuses to let a second one in.
-- That is what makes "what does this shop owe on Parle" an exact figure rather
-- than an apportionment: a payment settles a bill, not a line, so a bill that
-- mixed the two could never be split honestly once it was part paid.
--
-- Billing a shop for both means two bills. In this trade that is what happens
-- anyway — the two principals are billed separately.
--
-- Opening balances predate the app and cannot be split, so they are all
-- attributed to one master group, named in step 3 below.
--
-- BEFORE RUNNING: read step 3 and set the master group your opening balances
-- belong to. Everything else runs as it stands.
--
-- Run this file once in the Supabase SQL Editor. Safe to run more than once.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. The master group itself
-- -----------------------------------------------------------------------------

create table if not exists public.master_group (
  id          uuid primary key default gen_random_uuid(),
  code        text        not null unique check (length(btrim(code)) > 0),
  name        text        not null check (length(btrim(name)) > 0),
  sort_order  smallint    not null default 0,
  is_active   boolean     not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table public.master_group is
  'The top level of the product hierarchy — the principal whose goods these are.
   Every product group belongs to exactly one, and every order, bill and return
   carries the one its lines belong to.';

drop trigger if exists master_group_touch on public.master_group;
create trigger master_group_touch before update on public.master_group
  for each row execute function app.touch_updated_at();

insert into public.master_group (code, name, sort_order) values
  ('PARLE',   'Parle',   1),
  ('CURRENT', 'Current', 2),
  ('OTHERS',  'Others',  9)
on conflict (code) do nothing;

alter table public.master_group enable row level security;
alter table public.master_group force row level security;

grant select         on public.master_group to authenticated;
grant insert, update on public.master_group to authenticated;

drop policy if exists master_group_read         on public.master_group;
drop policy if exists master_group_admin_insert on public.master_group;
drop policy if exists master_group_admin_update on public.master_group;

create policy master_group_read on public.master_group
  for select to authenticated using (app.is_signed_in());
create policy master_group_admin_insert on public.master_group
  for insert to authenticated with check (app.is_admin());
create policy master_group_admin_update on public.master_group
  for update to authenticated using (app.is_admin()) with check (app.is_admin());


-- -----------------------------------------------------------------------------
-- 2. Every product group belongs to one
--
-- Existing groups land under Others rather than being guessed at. Move them
-- from the Products screen, or re-import the sheet with a master_code column.
-- -----------------------------------------------------------------------------

alter table public.product_group
  add column if not exists master_group_id uuid references public.master_group (id) on delete restrict;

update public.product_group
   set master_group_id = (select id from public.master_group where code = 'OTHERS')
 where master_group_id is null;

alter table public.product_group alter column master_group_id set not null;

create index if not exists product_group_master_idx
  on public.product_group (master_group_id);


-- -----------------------------------------------------------------------------
-- 3. Where the opening balances belong
--
-- A party's opening balance is one number carried in from before the app, so
-- it cannot be broken down by master group. It is attributed whole to the one
-- named here, and shows as a single "Opening balance" line in the ledger.
--
-- >>> CHANGE 'CURRENT' BELOW if your opening balances are Parle money. <<<
-- To change it later:
--   update public.app_setting
--      set opening_master_group_id = (select id from public.master_group
--                                      where code = 'PARLE');
-- -----------------------------------------------------------------------------

alter table public.app_setting
  add column if not exists opening_master_group_id uuid references public.master_group (id);

update public.app_setting
   set opening_master_group_id =
       (select id from public.master_group where code = 'CURRENT')   -- <<< here
 where opening_master_group_id is null;

alter table public.app_setting alter column opening_master_group_id set not null;

comment on column public.app_setting.opening_master_group_id is
  'The master group every party opening balance is treated as owing against.
   Opening balances predate the app, so they cannot be split.';


-- -----------------------------------------------------------------------------
-- 4. Documents carry their master group
--
-- Filled in by the trigger in step 5 as the first line arrives, so nothing
-- has to be typed and no existing function needs changing.
-- -----------------------------------------------------------------------------

alter table public.sales_order
  add column if not exists master_group_id uuid references public.master_group (id);
alter table public.sales_invoice
  add column if not exists master_group_id uuid references public.master_group (id);
alter table public.sales_return
  add column if not exists master_group_id uuid references public.master_group (id);

create index if not exists sales_order_master_idx   on public.sales_order (master_group_id);
create index if not exists sales_invoice_master_idx on public.sales_invoice (master_group_id);
create index if not exists sales_return_master_idx  on public.sales_return (master_group_id);

-- Anything raised before this migration: take the master group from its lines.
-- A document from before the rule existed could in principle mix, so the
-- earliest group wins and nothing is refused retrospectively.
update public.sales_order so
   set master_group_id = x.mg
  from (select sol.order_id, min(pg.master_group_id::text)::uuid as mg
          from public.sales_order_line sol
          join public.product pr       on pr.id = sol.product_id
          join public.product_group pg on pg.id = pr.group_id
         group by sol.order_id) x
 where so.id = x.order_id and so.master_group_id is null;

update public.sales_invoice si
   set master_group_id = x.mg
  from (select sil.invoice_id, min(pg.master_group_id::text)::uuid as mg
          from public.sales_invoice_line sil
          join public.product pr       on pr.id = sil.product_id
          join public.product_group pg on pg.id = pr.group_id
         group by sil.invoice_id) x
 where si.id = x.invoice_id and si.master_group_id is null;

update public.sales_return sr
   set master_group_id = x.mg
  from (select srl.return_id, min(pg.master_group_id::text)::uuid as mg
          from public.sales_return_line srl
          join public.product pr       on pr.id = srl.product_id
          join public.product_group pg on pg.id = pr.group_id
         group by srl.return_id) x
 where sr.id = x.return_id and sr.master_group_id is null;


-- -----------------------------------------------------------------------------
-- 5. The rule: one master group per document
--
-- A trigger on the LINE tables rather than a change to create_sales_invoice
-- and friends, so the rule holds whichever way a line arrives — the app, a
-- correction, a future bulk tool, or somebody at the SQL console.
--
-- The first line decides the document's master group. Every line after it must
-- agree, and the refusal names the product and both groups, because "cannot
-- mix master groups" on its own leaves somebody hunting through twenty lines.
-- -----------------------------------------------------------------------------

create or replace function app.product_master_group(p_product_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
  select pg.master_group_id
    from public.product p
    join public.product_group pg on pg.id = p.group_id
   where p.id = p_product_id;
$$;

revoke all on function app.product_master_group(uuid) from public, anon, authenticated;

create or replace function app.enforce_one_master_group()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_table text := tg_argv[0];   -- the header table
  v_fk    text := tg_argv[1];   -- the column on the line pointing at it
  v_word  text := tg_argv[2];   -- 'order', 'bill', 'return' — for the message
  v_head  uuid;
  v_line  uuid;
  v_have  uuid;
begin
  v_head := (to_jsonb(new) ->> v_fk)::uuid;
  v_line := app.product_master_group(new.product_id);

  if v_line is null then
    raise exception 'Product has no master group; its product group is not set up correctly'
      using errcode = 'SA005';
  end if;

  -- The row lock makes two lines arriving at once safe: the second waits and
  -- then sees what the first decided.
  execute format(
    'select master_group_id from public.%I where id = $1 for update', v_table)
    into v_have using v_head;

  if v_have is null then
    execute format(
      'update public.%I set master_group_id = $1 where id = $2', v_table)
      using v_line, v_head;
    return new;
  end if;

  if v_have <> v_line then
    raise exception
      '% cannot mix master groups. % is %, but this % is already %. Raise a separate %.',
      case when left(v_word, 1) in ('a','e','i','o','u') then 'An ' else 'A ' end || v_word,
      (select name from public.product where id = new.product_id),
      (select name from public.master_group where id = v_line),
      v_word,
      (select name from public.master_group where id = v_have),
      v_word
      using errcode = 'SA004';
  end if;

  return new;
end;
$$;

drop trigger if exists sales_order_line_master   on public.sales_order_line;
drop trigger if exists sales_invoice_line_master on public.sales_invoice_line;
drop trigger if exists sales_return_line_master  on public.sales_return_line;

create trigger sales_order_line_master
  after insert on public.sales_order_line
  for each row execute function app.enforce_one_master_group('sales_order', 'order_id', 'order');

create trigger sales_invoice_line_master
  after insert on public.sales_invoice_line
  for each row execute function app.enforce_one_master_group('sales_invoice', 'invoice_id', 'bill');

create trigger sales_return_line_master
  after insert on public.sales_return_line
  for each row execute function app.enforce_one_master_group('sales_return', 'return_id', 'return');


-- =============================================================================
-- 6. The views
--
-- Dropped and recreated rather than replaced, because the new columns go in
-- the middle and `create or replace view` cannot move a column. Order matters:
-- v_invoice_outstanding feeds v_ageing feeds v_ageing_by_party feeds
-- v_ageing_by_route, and v_party_balance reads the first.
-- =============================================================================

drop view if exists public.v_ageing_by_route;
drop view if exists public.v_ageing_by_party_master;
drop view if exists public.v_ageing_by_party;
drop view if exists public.v_ageing;
drop view if exists public.v_party_dues_by_master;
drop view if exists public.v_party_balance;
drop view if exists public.v_invoice_outstanding;
drop view if exists public.v_invoice_list;
drop view if exists public.v_party_ledger;
drop view if exists public.v_sales_register;
drop view if exists public.v_product_sales;

create view public.v_invoice_outstanding as
select
  si.id            as invoice_id,
  si.doc_no,
  si.party_id,
  p.code           as party_code,
  p.name           as party_name,
  p.route_id,
  rt.name          as route_name,
  si.master_group_id,
  mg.code          as master_code,
  mg.name          as master_name,
  si.invoice_date,
  si.net_total,
  si.cancelled_value,
  si.effective_total,
  coalesce(ca.allocated, 0)                      as settled,
  si.effective_total - coalesce(ca.allocated, 0) as outstanding,
  current_date - si.invoice_date                 as days_outstanding,
  si.status
from public.sales_invoice si
join public.party p  on p.id  = si.party_id
join public.route rt on rt.id = p.route_id
left join public.master_group mg on mg.id = si.master_group_id
left join (
  select invoice_id, sum(amount) as allocated
    from public.credit_allocation
   group by invoice_id
) ca on ca.invoice_id = si.id
where si.status <> 'CANCELLED';

create view public.v_ageing as
select
  io.*,
  case
    when io.days_outstanding <= 15 then '0-15'
    when io.days_outstanding <= 30 then '16-30'
    when io.days_outstanding <= 45 then '31-45'
    else '46+'
  end as bucket
from public.v_invoice_outstanding io
where io.outstanding > 0;

create view public.v_ageing_by_party as
select
  party_id, party_code, party_name, route_id, route_name,
  sum(outstanding)                                 as total_outstanding,
  sum(outstanding) filter (where bucket = '0-15')  as b_0_15,
  sum(outstanding) filter (where bucket = '16-30') as b_16_30,
  sum(outstanding) filter (where bucket = '31-45') as b_31_45,
  sum(outstanding) filter (where bucket = '46+')   as b_46_plus,
  max(days_outstanding)                            as oldest_days,
  count(*)                                         as open_invoices
from public.v_ageing
group by party_id, party_code, party_name, route_id, route_name;

create view public.v_ageing_by_route as
select
  route_id, route_name,
  sum(total_outstanding) as total_outstanding,
  sum(b_0_15)            as b_0_15,
  sum(b_16_30)           as b_16_30,
  sum(b_31_45)           as b_31_45,
  sum(b_46_plus)         as b_46_plus,
  count(*)               as parties_owing
from public.v_ageing_by_party
group by route_id, route_name;

-- Ageing one step finer: a party's buckets, per master group. This is the one
-- the collection list is built on.
create view public.v_ageing_by_party_master as
select
  party_id, party_code, party_name, route_id, route_name,
  master_group_id, master_code, master_name,
  sum(outstanding)                                 as total_outstanding,
  sum(outstanding) filter (where bucket = '0-15')  as b_0_15,
  sum(outstanding) filter (where bucket = '16-30') as b_16_30,
  sum(outstanding) filter (where bucket = '31-45') as b_31_45,
  sum(outstanding) filter (where bucket = '46+')   as b_46_plus,
  max(days_outstanding)                            as oldest_days,
  count(*)                                         as open_invoices
from public.v_ageing
group by party_id, party_code, party_name, route_id, route_name,
         master_group_id, master_code, master_name;

create view public.v_party_balance as
select
  p.id                as party_id,
  p.code              as party_code,
  p.name              as party_name,
  p.route_id,
  rt.name             as route_name,
  p.credit_limit,
  p.credit_days,
  p.opening_balance,
  coalesce(inv.owed, 0)                          as invoice_outstanding,
  coalesce(cr.unapplied, 0)                      as on_account,
  p.opening_balance + coalesce(inv.owed, 0) - coalesce(cr.unapplied, 0) as balance,
  case
    when p.credit_limit > 0
     and p.opening_balance + coalesce(inv.owed, 0) - coalesce(cr.unapplied, 0)
         > p.credit_limit
    then true else false
  end                 as over_credit_limit,
  p.is_active
from public.party p
join public.route rt on rt.id = p.route_id
left join (
  select party_id, sum(outstanding) as owed
    from public.v_invoice_outstanding
   group by party_id
) inv on inv.party_id = p.id
left join (
  select party_id, sum(unallocated) as unapplied
    from public.v_unallocated_credit
   group by party_id
) cr on cr.party_id = p.id;

-- -----------------------------------------------------------------------------
-- What a party owes, split by master group
--
-- The headline of this whole migration. Opening balance plus unsettled bills,
-- one row per party per master group, zero rows left out.
--
-- Money received but not yet applied to a bill is NOT here, because it belongs
-- to no master group until somebody allocates it. It stays on v_party_balance
-- as on_account, and the screens show it as its own line.
-- -----------------------------------------------------------------------------

create view public.v_party_dues_by_master as
select
  x.party_id,
  p.code            as party_code,
  p.name            as party_name,
  p.route_id,
  rt.name           as route_name,
  x.master_group_id,
  mg.code           as master_code,
  mg.name           as master_name,
  mg.sort_order,
  sum(x.opening)                as opening_balance,
  sum(x.outstanding)            as invoice_outstanding,
  sum(x.opening + x.outstanding) as due
from (
  select io.party_id, io.master_group_id,
         0::numeric as opening, io.outstanding
    from public.v_invoice_outstanding io
   where io.master_group_id is not null

  union all

  select pa.id, s.opening_master_group_id,
         pa.opening_balance, 0::numeric
    from public.party pa
   cross join public.app_setting s
   where pa.opening_balance <> 0
) x
join public.party p        on p.id  = x.party_id
join public.route rt       on rt.id = p.route_id
join public.master_group mg on mg.id = x.master_group_id
group by x.party_id, p.code, p.name, p.route_id, rt.name,
         x.master_group_id, mg.code, mg.name, mg.sort_order
having sum(x.opening + x.outstanding) <> 0;

create view public.v_party_ledger as
with entries as (
  select p.id as party_id, p.opening_balance_date as entry_date, 0 as sort_key,
         'OPENING'::text as doc_type, 'Opening balance'::text as doc_no,
         p.opening_balance as debit, 0::numeric as credit, null::uuid as doc_id,
         s.opening_master_group_id as master_group_id
    from public.party p
   cross join public.app_setting s
   where p.opening_balance <> 0

  union all

  select si.party_id, si.invoice_date, 1, 'INVOICE', si.doc_no,
         si.net_total, 0, si.id, si.master_group_id
    from public.sales_invoice si

  union all

  select si.party_id, ic.cancellation_date, 2, 'CANCELLATION', ic.doc_no,
         0, ic.cancelled_value, ic.id, si.master_group_id
    from public.invoice_cancellation ic
    join public.sales_invoice si on si.id = ic.invoice_id

  union all

  select sr.party_id, sr.return_date, 3, 'RETURN', sr.doc_no,
         0, sr.total_value, sr.id, sr.master_group_id
    from public.sales_return sr
   where sr.status = 'ACTIVE'

  union all

  -- A receipt belongs to no master group until it is applied to a bill.
  select r.party_id, r.receipt_date, 4, 'RECEIPT', r.doc_no,
         0, r.amount, r.id, null::uuid
    from public.receipt r
   where r.status = 'ACTIVE'
     and coalesce(r.clearing_status, 'CLEARED') <> 'BOUNCED'
)
select
  e.party_id,
  p.code as party_code,
  p.name as party_name,
  e.entry_date,
  e.doc_type,
  e.doc_no,
  e.doc_id,
  e.master_group_id,
  mg.code as master_code,
  mg.name as master_name,
  e.debit,
  e.credit,
  sum(e.debit - e.credit) over (
    partition by e.party_id
    order by e.entry_date, e.sort_key, e.doc_no
    rows between unbounded preceding and current row
  ) as running_balance
from entries e
join public.party p on p.id = e.party_id
left join public.master_group mg on mg.id = e.master_group_id;

create view public.v_invoice_list as
select
  si.id            as invoice_id,
  si.doc_no,
  si.party_id,
  p.code           as party_code,
  p.name           as party_name,
  p.route_id,
  rt.name          as route_name,
  si.master_group_id,
  mg.code          as master_code,
  mg.name          as master_name,
  si.invoice_date,
  si.net_total,
  si.cancelled_value,
  si.effective_total,
  coalesce(ca.allocated, 0)                      as settled,
  si.effective_total - coalesce(ca.allocated, 0) as outstanding,
  current_date - si.invoice_date                 as days_outstanding,
  si.status,
  so.doc_no        as order_no,
  old.doc_no       as replaces_doc_no,
  si.replaces_invoice_id,
  new_one.doc_no   as replaced_by_doc_no,
  new_one.id       as replaced_by_invoice_id
from public.sales_invoice si
join public.party p   on p.id  = si.party_id
join public.route rt  on rt.id = p.route_id
left join public.master_group mg on mg.id = si.master_group_id
left join public.sales_order so on so.id = si.order_id
left join public.sales_invoice old     on old.id = si.replaces_invoice_id
left join public.sales_invoice new_one on new_one.replaces_invoice_id = si.id
left join (
  select invoice_id, sum(amount) as allocated
    from public.credit_allocation
   group by invoice_id
) ca on ca.invoice_id = si.id;

create view public.v_sales_register as
select
  si.id           as invoice_id,
  si.doc_no,
  si.invoice_date,
  p.code          as party_code,
  p.name          as party_name,
  rt.name         as route_name,
  mg.code         as master_code,
  mg.name         as master_name,
  u.full_name     as created_by_name,
  so.doc_no       as order_no,
  rep.full_name   as rep_name,
  si.gross_total,
  si.line_discount_total,
  si.bill_discount_amount,
  si.round_off,
  si.net_total,
  si.cancelled_value,
  si.effective_total,
  si.status
from public.sales_invoice si
join public.party p       on p.id  = si.party_id
join public.route rt      on rt.id = p.route_id
left join public.master_group mg on mg.id = si.master_group_id
left join public.app_user u   on u.id = si.created_by
left join public.sales_order so on so.id = si.order_id
left join public.app_user rep on rep.id = so.created_by;

create view public.v_product_sales as
select
  pr.id            as product_id,
  pr.code          as product_code,
  pr.name          as product_name,
  pg.name          as group_name,
  mg.code          as master_code,
  mg.name          as master_name,
  pr.base_uom,
  si.invoice_date,
  sum(sil.qty_base - sil.qty_cancelled_base)     as qty_sold_base,
  sum(sil.effective_amount
      - round(sil.effective_amount * sil.qty_cancelled_base
              / nullif(sil.qty_base, 0), 2))     as net_sales,
  sum((sil.qty_base - sil.qty_cancelled_base) * pr.purchase_rate) as est_cost,
  sum(sil.effective_amount
      - round(sil.effective_amount * sil.qty_cancelled_base
              / nullif(sil.qty_base, 0), 2))
    - sum((sil.qty_base - sil.qty_cancelled_base) * pr.purchase_rate)
                                                  as est_margin
from public.sales_invoice_line sil
join public.sales_invoice si on si.id = sil.invoice_id
join public.product pr       on pr.id = sil.product_id
join public.product_group pg on pg.id = pr.group_id
join public.master_group mg  on mg.id = pg.master_group_id
where si.status <> 'CANCELLED'
group by pr.id, pr.code, pr.name, pg.name, mg.code, mg.name,
         pr.base_uom, si.invoice_date;

-- The Products screen reads this; it gains the master group so the list can
-- be filtered and the form can show where a product sits. Dropped rather than
-- replaced for the same reason as the others: the new columns land in front of
-- opening_locked.
drop view if exists public.v_product_master;

create view public.v_product_master as
select
  p.*,
  g.code  as group_code,
  g.name  as group_name,
  g.master_group_id,
  mg.code as master_code,
  mg.name as master_name,
  public.product_opening_posted(p.id) as opening_locked
from public.product p
join public.product_group g  on g.id  = p.group_id
join public.master_group mg  on mg.id = g.master_group_id;


-- -----------------------------------------------------------------------------
-- Security and grants
--
-- Every view runs as the caller, so RLS on the tables underneath still
-- applies. Forgetting this on one view would open a hole in all of them.
-- -----------------------------------------------------------------------------

do $$
declare v text;
begin
  foreach v in array array[
    'v_invoice_outstanding', 'v_ageing', 'v_ageing_by_party',
    'v_ageing_by_route', 'v_ageing_by_party_master', 'v_party_balance',
    'v_party_dues_by_master', 'v_party_ledger', 'v_invoice_list',
    'v_sales_register', 'v_product_sales', 'v_product_master'
  ] loop
    execute format('alter view public.%I set (security_invoker = true)', v);
    execute format('grant select on public.%I to authenticated', v);
  end loop;
end;
$$;
