-- =============================================================================
-- 026_opening_documents.sql
-- An opening balance becomes a document you can age and settle.
--
-- Until now a party's opening balance was a number on the party record. It
-- showed in the ledger and in the total owed, but it could not be aged — it
-- carries no bill date — and it could not be paid off, because a payment is
-- allocated to a bill and it was not one.
--
-- So it becomes one: a bill with no lines, numbered OPN-<party code>, carrying
-- the amount brought forward. Everything else in the app then works on it for
-- free — ageing, the payment screen, the ledger, dues by master group.
--
-- THE DATE. An opening balance has no invoice date of its own, so one is
-- chosen: the opening balance date, less a number of days (16 by default).
-- That puts it in the 16-30 bucket on day one, and from then on it ages like
-- anything else — 31-45 next fortnight, then 46+. Money carried in should not
-- look fresher than money billed last week.
--
-- NOTHING IS DESTROYED. party.opening_balance stays exactly as imported; it is
-- the record of what was carried in. party.opening_posted_at marks that the
-- document has been made, and the views read the document from then on rather
-- than the column, so nothing is counted twice.
--
-- Run this file once in the Supabase SQL Editor. Safe to run more than once.
-- Posting the balances themselves is a button on the Import screen.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Columns
-- -----------------------------------------------------------------------------

alter table public.sales_invoice
  add column if not exists is_opening boolean not null default false;

comment on column public.sales_invoice.is_opening is
  'A balance brought forward at go-live rather than a bill raised by us. Has no
   lines, moves no stock, and cannot be printed as a bill.';

create index if not exists sales_invoice_opening_idx
  on public.sales_invoice (is_opening) where is_opening;

alter table public.party
  add column if not exists opening_posted_at timestamptz;

comment on column public.party.opening_posted_at is
  'When this party opening balance was turned into an opening document. While
   null, the views read the opening_balance column instead.';


-- -----------------------------------------------------------------------------
-- 2. An opening document has no lines, so the totals check must let it be
--
-- Every other invoice must agree with its lines to the paisa. This one has
-- none by design, so the check would fail it on gross_total. Instead it gets
-- its own rules: no discounts, no rounding, and an amount above zero.
-- -----------------------------------------------------------------------------

create or replace function app.check_invoice_totals(p_invoice_id uuid)
returns void
language plpgsql
as $$
declare
  v_head      public.sales_invoice%rowtype;
  v_gross     numeric(14,2);
  v_line_disc numeric(14,2);
  v_bill_disc numeric(14,2);
  v_effective numeric(14,2);
begin
  select * into v_head from public.sales_invoice where id = p_invoice_id;
  if not found then
    return;
  end if;

  if v_head.is_opening then
    if exists (select 1 from public.sales_invoice_line where invoice_id = p_invoice_id) then
      raise exception 'Opening document % cannot have lines', v_head.doc_no
        using errcode = 'check_violation';
    end if;
    if v_head.net_total <= 0
       or v_head.gross_total <> v_head.net_total
       or v_head.line_discount_total <> 0
       or v_head.bill_discount_amount <> 0
       or v_head.round_off <> 0 then
      raise exception
        'Opening document % must be a single positive amount with no discount or rounding',
        v_head.doc_no using errcode = 'check_violation';
    end if;
    return;
  end if;

  select coalesce(sum(gross_amount), 0),
         coalesce(sum(line_discount_amount), 0),
         coalesce(sum(allocated_bill_discount), 0),
         coalesce(sum(effective_amount), 0)
    into v_gross, v_line_disc, v_bill_disc, v_effective
    from public.sales_invoice_line
   where invoice_id = p_invoice_id;

  if v_head.gross_total <> v_gross then
    raise exception 'Invoice % gross_total % <> line sum %',
      v_head.doc_no, v_head.gross_total, v_gross using errcode = 'check_violation';
  end if;

  if v_head.line_discount_total <> v_line_disc then
    raise exception 'Invoice % line_discount_total % <> line sum %',
      v_head.doc_no, v_head.line_discount_total, v_line_disc using errcode = 'check_violation';
  end if;

  if v_head.bill_discount_amount <> v_bill_disc then
    raise exception
      'Invoice %: bill discount % was allocated to lines as % — allocation must be exact',
      v_head.doc_no, v_head.bill_discount_amount, v_bill_disc
      using errcode = 'check_violation';
  end if;

  if v_head.net_total <> v_effective + v_head.round_off then
    raise exception 'Invoice % net_total % <> effective line sum % plus round off %',
      v_head.doc_no, v_head.net_total, v_effective, v_head.round_off
      using errcode = 'check_violation';
  end if;
end;
$$;


-- -----------------------------------------------------------------------------
-- 3. Making the documents
--
-- Mirrors post_opening_stock: run it, it does whatever is still waiting, and
-- running it again does nothing. A party whose balance is already posted is
-- left alone, so it is safe after adding a few more customers.
-- -----------------------------------------------------------------------------

create or replace function public.post_opening_balances(p_days_old integer default 16)
returns integer
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user  uuid := app.require_signed_in();
  v_group uuid;
  v_count integer := 0;
begin
  if not app.is_admin() then
    raise exception 'Only Admin may post opening balances' using errcode = 'SA003';
  end if;

  if p_days_old < 0 or p_days_old > 3650 then
    raise exception 'Days must be between 0 and 3650' using errcode = 'SA004';
  end if;

  select opening_master_group_id into v_group from public.app_setting;

  insert into public.sales_invoice
    (doc_no, party_id, invoice_date, gross_total, net_total,
     master_group_id, is_opening, created_by, remarks)
  select
    'OPN-' || p.code,
    p.id,
    -- No bill date exists, so one is chosen: this many days before the date
    -- the balance was struck. It ages normally from there.
    p.opening_balance_date - p_days_old,
    p.opening_balance,
    p.opening_balance,
    v_group,
    true,
    v_user,
    'Balance brought forward as at ' || to_char(p.opening_balance_date, 'DD Mon YYYY')
  from public.party p
  where p.opening_balance > 0
    and p.opening_balance_date is not null
    and p.opening_posted_at is null;

  get diagnostics v_count = row_count;

  update public.party p
     set opening_posted_at = now()
   where p.opening_balance > 0
     and p.opening_balance_date is not null
     and p.opening_posted_at is null;

  return v_count;
end;
$$;

revoke all on function public.post_opening_balances(integer) from public, anon;
grant execute on function public.post_opening_balances(integer) to authenticated;

comment on function public.post_opening_balances(integer) is
  'Turns every unposted party opening balance into an opening document, dated
   p_days_old days before the opening balance date so it ages from there.';


-- -----------------------------------------------------------------------------
-- 4. Undoing one, while it is still safe to
--
-- Once the document exists the party has a document, which freezes its opening
-- balance — by design, but that would make a typed-wrong opening balance
-- permanent. So: as long as nothing has been allocated against it, the
-- document can be removed and the balance corrected and posted again.
--
-- This is the only place in the app that deletes a document, and deliberately
-- so: a balance brought forward is a figure being set up, not a trade that
-- happened.
-- -----------------------------------------------------------------------------

create or replace function public.unpost_opening_balance(p_party_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_inv public.sales_invoice%rowtype;
begin
  if not app.is_admin() then
    raise exception 'Only Admin may undo an opening balance' using errcode = 'SA003';
  end if;

  select * into v_inv
    from public.sales_invoice
   where party_id = p_party_id and is_opening
   limit 1;

  if not found then
    raise exception 'That customer has no opening document' using errcode = 'SA005';
  end if;

  if exists (select 1 from public.credit_allocation where invoice_id = v_inv.id) then
    raise exception
      'Money has already been settled against %, so it can no longer be undone. Raise a return or a fresh payment instead.',
      v_inv.doc_no using errcode = 'SA002';
  end if;

  if v_inv.status <> 'ACTIVE' then
    raise exception '% is already cancelled', v_inv.doc_no using errcode = 'SA002';
  end if;

  delete from public.sales_invoice where id = v_inv.id;

  update public.party set opening_posted_at = null where id = p_party_id;

  return jsonb_build_object('doc_no', v_inv.doc_no, 'amount', v_inv.net_total);
end;
$$;

revoke all on function public.unpost_opening_balance(uuid) from public, anon;
grant execute on function public.unpost_opening_balance(uuid) to authenticated;


-- -----------------------------------------------------------------------------
-- 5. An opening document is not a bill, and will not be treated as one
-- -----------------------------------------------------------------------------

create or replace function app.opening_not_a_bill()
returns trigger
language plpgsql
as $$
begin
  if exists (select 1 from public.sales_invoice
              where id = new.invoice_id and is_opening) then
    raise exception 'An opening document has no lines and none can be added'
      using errcode = 'SA002';
  end if;
  return new;
end;
$$;

drop trigger if exists sales_invoice_line_not_opening on public.sales_invoice_line;
create trigger sales_invoice_line_not_opening
  before insert on public.sales_invoice_line
  for each row execute function app.opening_not_a_bill();


-- =============================================================================
-- 6. The views stop double counting
--
-- While opening_posted_at is null the opening balance is a column; once it is
-- set the document carries it. Exactly one of the two is ever in play.
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
  si.is_opening,
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
  -- Counted here only while it is still a column rather than a document.
  case when p.opening_posted_at is null then p.opening_balance else 0 end as opening_unposted,
  coalesce(inv.owed, 0)                          as invoice_outstanding,
  coalesce(cr.unapplied, 0)                      as on_account,
  case when p.opening_posted_at is null then p.opening_balance else 0 end
    + coalesce(inv.owed, 0) - coalesce(cr.unapplied, 0) as balance,
  case
    when p.credit_limit > 0
     and case when p.opening_posted_at is null then p.opening_balance else 0 end
         + coalesce(inv.owed, 0) - coalesce(cr.unapplied, 0)
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
  sum(x.opening)                 as opening_balance,
  sum(x.outstanding)             as invoice_outstanding,
  sum(x.opening + x.outstanding) as due
from (
  select io.party_id, io.master_group_id,
         0::numeric as opening, io.outstanding
    from public.v_invoice_outstanding io
   where io.master_group_id is not null

  union all

  -- Only while it has not been turned into a document.
  select pa.id, s.opening_master_group_id,
         pa.opening_balance, 0::numeric
    from public.party pa
   cross join public.app_setting s
   where pa.opening_balance <> 0
     and pa.opening_posted_at is null
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
     and p.opening_posted_at is null

  union all

  select si.party_id, si.invoice_date, case when si.is_opening then 0 else 1 end,
         case when si.is_opening then 'OPENING' else 'INVOICE' end,
         si.doc_no, si.net_total, 0, si.id, si.master_group_id
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
  si.is_opening,
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

-- A count of what is still waiting, for the Import screen.
create or replace view public.v_opening_balance_status as
select
  count(*) filter (where opening_balance > 0 and opening_balance_date is not null
                     and opening_posted_at is null)                      as waiting,
  coalesce(sum(opening_balance) filter (where opening_balance > 0
                     and opening_balance_date is not null
                     and opening_posted_at is null), 0)                  as waiting_value,
  count(*) filter (where opening_posted_at is not null)                  as posted,
  count(*) filter (where opening_balance > 0 and opening_balance_date is null)
                                                                         as missing_date
from public.party;

do $$
declare v text;
begin
  foreach v in array array[
    'v_invoice_outstanding', 'v_ageing', 'v_ageing_by_party',
    'v_ageing_by_route', 'v_ageing_by_party_master', 'v_party_balance',
    'v_party_dues_by_master', 'v_party_ledger', 'v_invoice_list',
    'v_opening_balance_status'
  ] loop
    execute format('alter view public.%I set (security_invoker = true)', v);
    execute format('grant select on public.%I to authenticated', v);
  end loop;
end;
$$;
