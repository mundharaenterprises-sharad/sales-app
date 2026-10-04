-- =============================================================================
-- 037_order_remarks_on_edit.sql
--
-- Run this in the Supabase SQL Editor. Committing it to git does nothing to
-- the database.
--
-- A remark written on an order never reached the bill.
--
-- `create_sales_order` has always taken one. `modify_sales_order` never has —
-- it takes the order, its lines and its discounts, and nothing else. So an
-- order could be given a remark at the moment it was first written and never
-- afterwards.
--
-- That used not to matter much, because an order was written once and
-- submitted. It matters now: since orders save themselves when the rep presses
-- back, an order that is opened again — by the rep to add a line, or by the
-- office to correct one — goes through modify every time. From then on its
-- remark is frozen, and a remark added at that point is simply dropped on the
-- floor, with no error and nothing on screen to say so.
--
-- The bill side was fine all along. The billing screen reads the order's
-- remark into its own box and passes it on, and the bill sheet prints it. It
-- was printing an empty remark faithfully.
--
-- **Absent means leave it alone; empty means clear it.** Not sent at all, the
-- remark stays as it was — so any caller that does not know about this
-- argument cannot wipe a remark by accident. Sent as an empty string, the
-- remark is removed, which is what somebody deleting the text in the box
-- means. The app always sends the box's current contents.
--
-- Safe to run twice.
-- =============================================================================

create or replace function public.modify_sales_order(
  p_order_id             uuid,
  p_lines                jsonb,
  p_bill_discount_amount numeric default null,
  p_bill_discount_pct    numeric default null,
  -- null: leave the remark as it is. '': clear it. Anything else: replace it.
  p_remarks              text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user     uuid := app.require_signed_in();
  v_status   app.order_status;
  v_net      numeric(14,2);
  v_billdisc numeric(14,2);
  v_round    numeric(14,2) := 0;
begin
  select status into v_status from public.sales_order where id = p_order_id for update;

  if not found then
    raise exception 'Unknown order' using errcode = 'SA005';
  end if;

  perform app.require_own_order_if_rep(p_order_id, 'change');

  if v_status <> 'SUBMITTED' then
    raise exception
      'This order is %, so it can no longer be modified. Cancel the pending quantity instead.',
      lower(replace(v_status::text, '_', ' '))
      using errcode = 'SA002';
  end if;

  if exists (select 1 from public.sales_invoice where order_id = p_order_id) then
    raise exception 'This order has already been invoiced and cannot be modified'
      using errcode = 'SA002';
  end if;

  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'An order needs at least one line' using errcode = 'SA004';
  end if;

  perform app.release_order_reservation(p_order_id);

  drop table if exists _ord_stage;
  create temp table _ord_stage on commit drop as
  select
    row_number() over ()                   as line_no,
    x.product_id,
    x.uom,
    x.qty,
    app.pack_size_for(x.product_id, x.uom) as pack_size,
    coalesce(x.rate, (select sale_rate from public.product where id = x.product_id)) as rate,
    x.line_discount_pct,
    x.line_discount_amount
  from jsonb_to_recordset(p_lines) as x(
         product_id           uuid,
         uom                  app.uom_type,
         qty                  numeric,
         rate                 numeric,
         line_discount_pct    numeric,
         line_discount_amount numeric);

  if exists (select 1 from pg_temp._ord_stage where qty is null or qty <= 0) then
    raise exception 'Every line needs a quantity above zero' using errcode = 'SA004';
  end if;

  perform app.order_line_discounts();

  if exists (select 1 from pg_temp._ord_stage where line_discount_amount > gross) then
    raise exception 'A line discount is larger than the line itself'
      using errcode = 'SA004';
  end if;

  select coalesce(sum(gross - line_discount_amount), 0) into v_net from pg_temp._ord_stage;

  -- Left out entirely, the order keeps the discount it already had.
  if p_bill_discount_amount is null and p_bill_discount_pct is null then
    select bill_discount_amount into v_billdisc
      from public.sales_order where id = p_order_id;
    v_billdisc := least(coalesce(v_billdisc, 0), v_net);
  else
    v_billdisc := coalesce(
      round(nullif(p_bill_discount_amount, 0), 2),
      round(v_net * coalesce(p_bill_discount_pct, 0) / 100, 2));
  end if;

  if v_billdisc > v_net then
    raise exception 'The discount on the order is larger than the order itself'
      using errcode = 'SA004';
  end if;

  if (app.settings()).round_invoice_total then
    v_round := round(v_net - v_billdisc, 0) - (v_net - v_billdisc);
  end if;

  delete from public.sales_order_line where order_id = p_order_id;

  insert into public.sales_order_line
    (order_id, line_no, product_id, uom, qty, pack_size, rate,
     line_discount_pct, line_discount_amount)
  select p_order_id, line_no, product_id, uom, qty, pack_size, rate,
         line_discount_pct, line_discount_amount
    from pg_temp._ord_stage;

  perform app.reserve_for_order(p_order_id);

  update public.sales_order
     set updated_at           = now(),
         bill_discount_amount = v_billdisc,
         round_off            = v_round,
         -- The one new line. nullif('') turns a cleared box into a null
         -- remark rather than an empty string, so "no remark" is one thing in
         -- the database and not two.
         remarks              = case when p_remarks is null then remarks
                                     else nullif(btrim(p_remarks), '') end,
         bill_discount_pct    = coalesce(
           p_bill_discount_pct,
           case when v_net > 0 and v_billdisc > 0
                then round(v_billdisc * 100 / v_net, 4) end)
   where id = p_order_id;

  return jsonb_build_object('order_id', p_order_id, 'modified', true,
                            'round_off', v_round);
end;
$$;

-- The four-argument version would otherwise still be there, and every call
-- that leaves the remark out would be ambiguous between the two.
drop function if exists public.modify_sales_order(uuid, jsonb, numeric, numeric);

revoke all on function
  public.modify_sales_order(uuid, jsonb, numeric, numeric, text) from public, anon;
grant execute on function
  public.modify_sales_order(uuid, jsonb, numeric, numeric, text) to authenticated;

comment on function public.modify_sales_order(uuid, jsonb, numeric, numeric, text) is
  'Replace an order''s lines, discounts and remark. The remark follows the
   usual rule for an optional field that may legitimately be emptied: absent
   leaves it alone, an empty string clears it.';

notify pgrst, 'reload schema';
