-- =============================================================================
-- 020_revise_invoice.sql
-- Correcting a bill on the day it was raised.
--
-- A posted invoice is immutable: stock movements, the customer's balance and
-- any print already given to the customer all hang off it. That rule is not
-- being relaxed. What this adds is a safe way to fix a bill typed wrongly
-- minutes ago, which in practice happens often and otherwise means an awkward
-- manual cancel-and-retype.
--
-- The correction is one transaction: the old bill is cancelled (goods back to
-- stock, order quantities back to pending, customer stops owing it) and a new
-- bill is raised from the corrected lines. Either both happen or neither does.
-- The old bill stays on record, marked cancelled, so the paper already handed
-- over can still be matched to something.
--
-- It is refused when:
--   * the bill was not raised today, or carries an earlier bill date;
--   * anything has already been cancelled on it;
--   * a payment or credit note has been applied to it — un-applying money is
--     a decision for a person, not a side effect of a typing correction.
--
-- The new bill gets the next number. The old number stays used and cancelled,
-- which is what an audit expects to see.
--
-- Run this file once in the Supabase SQL Editor. Safe to run more than once.
-- =============================================================================

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

  -- Cancel first: this returns the goods to stock and the order lines to
  -- pending, which is exactly the state the new bill needs to be checked
  -- against. Both happen inside this one transaction.
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

    -- Raises SA001 if the goods have gone in the meantime, which aborts the
    -- whole correction and leaves the original bill standing.
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

  return v_new || jsonb_build_object(
    'replaced_invoice_id', p_invoice_id,
    'replaced_doc_no',     v_inv.doc_no);
end;
$$;

revoke all on function
  public.revise_sales_invoice(uuid, jsonb, numeric, numeric, text)
from public, anon;

grant execute on function
  public.revise_sales_invoice(uuid, jsonb, numeric, numeric, text)
to authenticated;

comment on function public.revise_sales_invoice(uuid, jsonb, numeric, numeric, text) is
  'Same-day correction: cancels the bill and raises a replacement in one
   transaction. Refused once the bill is a day old, partly cancelled, or paid.';
