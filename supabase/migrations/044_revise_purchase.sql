-- =============================================================================
-- 044_revise_purchase.sql
-- Correcting a purchase that was entered wrong.
--
-- Run this in the Supabase SQL Editor. Committing it to git does nothing to
-- the database.
--
-- A posted purchase has never been editable: the rule since 005 is that
-- correction is cancellation plus re-entry. That rule is right and is not
-- changing. What changes is that the two halves now happen in one step, with
-- the old entry kept and linked, instead of being a job somebody does by hand
-- and may do only half of.
--
-- HOW LONG IT STAYS POSSIBLE, which he chose: any time, as long as the goods
-- are still in stock.
--
-- A sales bill can only be corrected on the day it was raised, because the
-- customer has a copy of it. A purchase is internal — nobody outside has seen
-- it — and the mistake usually turns up when the paperwork is reconciled days
-- later. So the window is not a clock, it is the stock itself: the moment any
-- of what the purchase brought in has been sold, it cannot be taken back out,
-- and `cancel_purchase` already refuses exactly that. The correction inherits
-- the refusal rather than inventing a second rule, so there is one answer to
-- "can this be undone" and one place it is decided.
--
-- WHAT IT DOES TO FIGURES ALREADY REPORTED. Changing a purchase's rate changes
-- the weighted average cost from that purchase's date onward, and so the
-- margin on every sale after it (043). That is correct — if the cost was keyed
-- wrong then the margin was wrong — but it is worth knowing before wondering
-- why last week's profitability moved. The screen says so too.
--
-- TWO WAYS TO CORRECT ONE, because they are not the same job:
--
--   revise_purchase         everything: supplier, date, lines, rates,
--                           discounts, charges. Cancels and re-enters, so it
--                           needs the goods to still be there.
--   update_purchase_details supplier bill number, its date, remarks. Touches
--                           no stock and no money, so it is allowed whenever,
--                           including after the goods have gone out. A typo in
--                           a supplier's bill number should not need the whole
--                           document rebuilt, and after a month that is the
--                           only correction still available.
--
-- Safe to run twice. Nothing already stored changes.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. The trail
-- -----------------------------------------------------------------------------
-- Same shape as `sales_invoice.replaces_invoice_id` (021), so a cancelled
-- purchase can be read alongside the one that took its place rather than
-- looking like a purchase somebody simply abandoned.

alter table public.purchase
  add column if not exists replaces_purchase_id uuid
    references public.purchase (id) on delete restrict;

comment on column public.purchase.replaces_purchase_id is
  'The purchase this one was entered to correct. The old one stays, cancelled,
   so the pair can be read together.';

create index if not exists purchase_replaces_idx
  on public.purchase (replaces_purchase_id)
  where replaces_purchase_id is not null;


-- -----------------------------------------------------------------------------
-- 2. The details that touch nothing
-- -----------------------------------------------------------------------------

create or replace function public.update_purchase_details(
  p_purchase_id        uuid,
  p_supplier_bill_no   text default null,
  p_supplier_bill_date date default null,
  p_remarks            text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user uuid := app.require_back_office();
  v_pur  public.purchase%rowtype;
begin
  select * into v_pur from public.purchase where id = p_purchase_id for update;

  if not found then
    raise exception 'That purchase does not exist' using errcode = 'SA005';
  end if;

  if v_pur.status <> 'ACTIVE' then
    raise exception '% is cancelled, so there is nothing to correct on it',
      v_pur.doc_no using errcode = 'SA002';
  end if;

  -- null leaves a field alone; an empty string clears it. The same convention
  -- as an order's remark (037), so the two screens can be written the same way.
  update public.purchase
     set supplier_bill_no   = case when p_supplier_bill_no is null
                                   then supplier_bill_no
                                   else nullif(btrim(p_supplier_bill_no), '') end,
         supplier_bill_date = coalesce(p_supplier_bill_date, supplier_bill_date),
         remarks            = case when p_remarks is null
                                   then remarks
                                   else nullif(btrim(p_remarks), '') end
   where id = p_purchase_id;

  return jsonb_build_object('purchase_id', p_purchase_id, 'doc_no', v_pur.doc_no);
end;
$$;

revoke all on function
  public.update_purchase_details(uuid, text, date, text) from public, anon;
grant execute on function
  public.update_purchase_details(uuid, text, date, text) to authenticated;

comment on function public.update_purchase_details(uuid, text, date, text) is
  'Corrects a supplier bill number, its date or the remarks. Moves no stock and
   no money, so it is allowed for as long as the purchase is active. null
   leaves a field alone; an empty string clears it.';


-- -----------------------------------------------------------------------------
-- 3. The real correction
-- -----------------------------------------------------------------------------

create or replace function public.revise_purchase(
  p_purchase_id          uuid,
  p_lines                jsonb,
  p_purchase_date        date    default null,
  p_other_charges        numeric default 0,
  p_supplier_bill_no     text    default null,
  p_supplier_bill_date   date    default null,
  p_remarks              text    default null,
  p_bill_discount_amount numeric default 0,
  p_bill_discount_pct    numeric default null,
  p_supplier_id          uuid    default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user uuid := app.require_back_office();
  v_pur  public.purchase%rowtype;
  v_new  jsonb;
begin
  select * into v_pur from public.purchase where id = p_purchase_id for update;

  if not found then
    raise exception 'That purchase does not exist' using errcode = 'SA005';
  end if;

  if v_pur.status <> 'ACTIVE' then
    raise exception '% has already been cancelled, so it cannot be corrected',
      v_pur.doc_no using errcode = 'SA002';
  end if;

  if v_pur.replaces_purchase_id is not null then
    -- Correcting a correction is fine; it is only worth saying that the chain
    -- is of documents, not of edits, so nothing is lost.
    null;
  end if;

  if jsonb_typeof(coalesce(p_lines, 'null'::jsonb)) <> 'array'
     or jsonb_array_length(p_lines) = 0 then
    raise exception 'A corrected purchase still needs at least one line'
      using errcode = 'SA004';
  end if;

  -- Takes the goods back out, and refuses with SA001 and a per-product
  -- breakdown if any of them have already gone. That refusal IS the window on
  -- this correction, and it is deliberately not duplicated here: one rule, one
  -- place, one message.
  perform public.cancel_purchase(
    p_purchase_id,
    'Corrected and re-entered as a new purchase');

  v_new := public.post_purchase(
    p_supplier_id          => coalesce(p_supplier_id, v_pur.supplier_id),
    p_purchase_date        => coalesce(p_purchase_date, v_pur.purchase_date),
    p_lines                => p_lines,
    p_other_charges        => coalesce(p_other_charges, 0),
    p_supplier_bill_no     => coalesce(p_supplier_bill_no, v_pur.supplier_bill_no),
    p_supplier_bill_date   => coalesce(p_supplier_bill_date, v_pur.supplier_bill_date),
    p_remarks              => coalesce(p_remarks, v_pur.remarks),
    p_bill_discount_amount => coalesce(p_bill_discount_amount, 0),
    p_bill_discount_pct    => p_bill_discount_pct);

  update public.purchase
     set replaces_purchase_id = p_purchase_id
   where id = (v_new ->> 'purchase_id')::uuid;

  return v_new || jsonb_build_object(
    'replaced_purchase_id', p_purchase_id,
    'replaced_doc_no',      v_pur.doc_no);
end;
$$;

revoke all on function
  public.revise_purchase(uuid,jsonb,date,numeric,text,date,text,numeric,numeric,uuid)
  from public, anon;
grant execute on function
  public.revise_purchase(uuid,jsonb,date,numeric,text,date,text,numeric,numeric,uuid)
  to authenticated;

comment on function
  public.revise_purchase(uuid,jsonb,date,numeric,text,date,text,numeric,numeric,uuid) is
  'Cancels a purchase and enters a corrected one in its place, linked. Refuses
   once any of the goods it brought in have gone out, because that stock cannot
   be taken back. Changing a rate changes the average cost from that date on,
   and so margins already reported.';


-- -----------------------------------------------------------------------------
-- 4. The list and the screen need to see the link
-- -----------------------------------------------------------------------------
-- Appended rather than inserted, because `create or replace view` cannot move
-- a column and these have dependants — bug #9.

create or replace view public.v_purchase_list as
select
  pu.id            as purchase_id,
  pu.doc_no,
  pu.purchase_date,
  pu.supplier_id,
  s.code           as supplier_code,
  s.name           as supplier_name,
  pu.supplier_bill_no,
  pu.supplier_bill_date,
  pu.master_group_id,
  mg.code          as master_code,
  mg.name          as master_name,
  pu.gross_total,
  pu.other_charges,
  pu.net_total,
  pu.status,
  pu.cancel_reason,
  pu.remarks,
  u.full_name      as created_by_name,
  pu.created_at,
  coalesce(l.lines, 0) as line_count,
  coalesce(l.qty_base, 0) as qty_base,
  pu.line_discount_total,
  pu.bill_discount_amount,
  (pu.line_discount_total + pu.bill_discount_amount) as discount_total,
  pu.replaces_purchase_id,
  old.doc_no       as replaces_doc_no,
  rep.id           as replaced_by_id,
  rep.doc_no       as replaced_by_doc_no
from public.purchase pu
join public.supplier s on s.id = pu.supplier_id
left join public.master_group mg on mg.id = pu.master_group_id
left join public.app_user u on u.id = pu.created_by
left join public.purchase old on old.id = pu.replaces_purchase_id
left join public.purchase rep on rep.replaces_purchase_id = pu.id
left join (
  select purchase_id, count(*) as lines, sum(qty_base) as qty_base
    from public.purchase_line
   group by purchase_id
) l on l.purchase_id = pu.id;

alter view public.v_purchase_list set (security_invoker = true);

notify pgrst, 'reload schema';
