-- =============================================================================
-- 021_invoice_list.sql
-- Every bill in the list, and a link from a corrected bill to the one it
-- replaced.
--
-- Two problems this fixes.
--
-- First, the Bills screen was reading v_invoice_outstanding, which exists to
-- answer "who owes what" and therefore leaves cancelled bills out. Correct a
-- bill and its old number simply vanished from the list, which looks exactly
-- like data going missing. v_invoice_list below shows every bill, cancelled
-- ones included, and stays separate from the outstanding view so that ageing
-- and the receivables reports are untouched.
--
-- Second, nothing recorded that INV-000031 was raised because INV-000030 was
-- wrong. The two documents existed side by side with no connection. A single
-- column now records it, so both bills can say what happened.
--
-- Run this file once in the Supabase SQL Editor. Safe to run more than once.
-- =============================================================================

alter table public.sales_invoice
  add column if not exists replaces_invoice_id uuid
    references public.sales_invoice (id) on delete restrict;

comment on column public.sales_invoice.replaces_invoice_id is
  'Set when this bill was raised to correct another one the same day. The
   replaced bill is cancelled; this is how they stay connected.';

create index if not exists sales_invoice_replaces_idx
  on public.sales_invoice (replaces_invoice_id)
  where replaces_invoice_id is not null;

-- -----------------------------------------------------------------------------
-- The Bills screen: every bill, newest first, with what is still due on it.
-- Cancelled bills carry zero effective value, so they show as settled rather
-- than owing anything, and their status says what happened.
-- -----------------------------------------------------------------------------

create or replace view public.v_invoice_list as
select
  si.id            as invoice_id,
  si.doc_no,
  si.party_id,
  p.code           as party_code,
  p.name           as party_name,
  p.route_id,
  rt.name          as route_name,
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
left join public.sales_order so on so.id = si.order_id
left join public.sales_invoice old     on old.id = si.replaces_invoice_id
left join public.sales_invoice new_one on new_one.replaces_invoice_id = si.id
left join (
  select invoice_id, sum(amount) as allocated
    from public.credit_allocation
   group by invoice_id
) ca on ca.invoice_id = si.id;

alter view public.v_invoice_list set (security_invoker = true);
grant select on public.v_invoice_list to authenticated;

-- -----------------------------------------------------------------------------
-- Record the link when a bill is corrected.
--
-- Same function as 020 with one statement added at the end. Everything else,
-- including the rules about when a correction is allowed, is unchanged.
-- -----------------------------------------------------------------------------

create or replace function public.revise_sales_invoice(
  p_invoice_id           uuid,
  p_lines                jsonb,
  p_bill_discount_amount numeric default 0,
  p_bill_discount_pct    numeric default null,
  p_remarks              text    default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user    uuid := app.require_back_office();
  v_inv     public.sales_invoice%rowtype;
  v_settled numeric(14,2);
  v_new     jsonb;
begin
  select * into v_inv from public.sales_invoice where id = p_invoice_id for update;

  if not found then
    raise exception 'Unknown bill' using errcode = 'SA005';
  end if;

  if v_inv.status <> 'ACTIVE' then
    raise exception 'Bill % has already been cancelled in part or in full, so it cannot be corrected.',
      v_inv.doc_no using errcode = 'SA002';
  end if;

  if v_inv.invoice_date <> current_date or v_inv.created_at::date <> current_date then
    raise exception 'Bill % was not raised today. Raise a sales return or a cancellation instead.',
      v_inv.doc_no using errcode = 'SA002';
  end if;

  select coalesce(sum(amount), 0) into v_settled
    from public.credit_allocation where invoice_id = p_invoice_id;

  if v_settled > 0 then
    raise exception 'Bill % already has % applied to it. Undo the allocation first.',
      v_inv.doc_no, v_settled using errcode = 'SA002';
  end if;

  if jsonb_typeof(coalesce(p_lines, 'null'::jsonb)) <> 'array'
     or jsonb_array_length(p_lines) = 0 then
    raise exception 'A corrected bill still needs at least one line' using errcode = 'SA004';
  end if;

  perform public.cancel_sales_invoice(
    p_invoice_id,
    'Corrected on the same day, replaced by a new bill');

  -- Cancelling a bill deliberately does NOT hand quantities back to its order:
  -- normally a cancellation ends the matter and the goods become free stock.
  -- A correction is the one case where the order should reopen, because the
  -- replacement bill is about to be raised against it. Reservations are
  -- released and retaken around the change so that `reserved` never counts the
  -- same goods twice.
  if v_inv.order_id is not null then
    perform app.release_order_reservation(v_inv.order_id);

    update public.sales_order_line sol
       set qty_invoiced_base = greatest(sol.qty_invoiced_base - x.qty, 0)
      from (select order_line_id, sum(qty_base) as qty
              from public.sales_invoice_line
             where invoice_id = p_invoice_id
               and order_line_id is not null
             group by order_line_id) x
     where sol.id = x.order_line_id;

    update public.sales_order so
       set status = case
                      when exists (select 1 from public.sales_order_line
                                    where order_id = v_inv.order_id
                                      and qty_invoiced_base > 0)
                      then 'PARTIALLY_INVOICED'::app.order_status
                      else 'SUBMITTED'::app.order_status
                    end,
           closed_at = null
     where so.id = v_inv.order_id;

    perform app.reserve_for_order(v_inv.order_id);
  end if;

  v_new := public.create_sales_invoice(
    v_inv.invoice_date,
    p_lines,
    v_inv.order_id,
    case when v_inv.order_id is null then v_inv.party_id end,
    p_bill_discount_amount,
    p_bill_discount_pct,
    coalesce(p_remarks, v_inv.remarks));

  -- The one new line: remember which bill this one replaced.
  update public.sales_invoice
     set replaces_invoice_id = p_invoice_id
   where id = (v_new ->> 'invoice_id')::uuid;

  return v_new || jsonb_build_object(
    'replaced_invoice_id', p_invoice_id,
    'replaced_doc_no',     v_inv.doc_no);
end;
$$;

grant execute on function
  public.revise_sales_invoice(uuid, jsonb, numeric, numeric, text)
to authenticated;
