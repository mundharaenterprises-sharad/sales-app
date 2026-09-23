-- =============================================================================
-- 022_receive_payment.sql
-- Taking a payment and settling bills in one step.
--
-- The two halves already exist: create_receipt records the money,
-- allocate_credit decides which bills it pays. Doing them as two calls from
-- the screen works, but a failure between them leaves a payment sitting
-- unapplied while the person who typed it believes the bills are settled.
--
-- This wraps both in one transaction. Either the money is recorded and applied
-- exactly as typed, or nothing happened at all.
--
-- The amount may be more than the bills ticked: the difference stays on the
-- payment as credit, which is what happens when a customer pays a round figure.
-- It may not be less, because that would mean settling bills with money that
-- was never received.
--
-- Run this file once in the Supabase SQL Editor. Safe to run more than once.
-- =============================================================================

create or replace function public.receive_payment(
  p_party_id     uuid,
  p_receipt_date date,
  p_amount       numeric default null,
  p_allocations  jsonb   default '[]'::jsonb,
  p_collected_by uuid    default null,
  p_remarks      text    default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user      uuid := app.require_back_office();
  v_requested numeric(14,2);
  v_amount    numeric(14,2);
  v_receipt   jsonb;
  v_id        uuid;
begin
  if jsonb_typeof(coalesce(p_allocations, '[]'::jsonb)) <> 'array' then
    raise exception 'Allocations must be an array' using errcode = 'SA004';
  end if;

  select coalesce(sum(round(x.amount, 2)), 0)
    into v_requested
    from jsonb_to_recordset(coalesce(p_allocations, '[]'::jsonb))
         as x(invoice_id uuid, amount numeric)
   where coalesce(x.amount, 0) > 0;

  -- With no amount given, the payment is exactly what the bills come to.
  v_amount := coalesce(round(p_amount, 2), v_requested);

  if v_amount <= 0 then
    raise exception 'A payment needs an amount above zero' using errcode = 'SA004';
  end if;

  if v_requested > v_amount then
    raise exception 'The bills ticked come to % but the payment is only %.',
      v_requested, v_amount using errcode = 'SA004';
  end if;

  v_receipt := public.create_receipt(
    p_party_id, p_receipt_date, 'CASH'::app.payment_mode, v_amount,
    null, null, null, p_collected_by, p_remarks);

  v_id := (v_receipt ->> 'receipt_id')::uuid;

  if v_requested > 0 then
    -- Refuses if a bill belongs to another party, is already settled, or the
    -- money does not stretch — and that refusal takes the receipt with it.
    perform public.allocate_credit(p_allocations, v_id, null);
  end if;

  return v_receipt || jsonb_build_object(
    'allocated',   v_requested,
    'unallocated', v_amount - v_requested);
end;
$$;

revoke all on function
  public.receive_payment(uuid, date, numeric, jsonb, uuid, text)
from public, anon;

grant execute on function
  public.receive_payment(uuid, date, numeric, jsonb, uuid, text)
to authenticated;

comment on function public.receive_payment(uuid, date, numeric, jsonb, uuid, text) is
  'Records money received and settles the bills it pays, in one transaction.
   Anything over the bills ticked stays on the payment as credit.';
