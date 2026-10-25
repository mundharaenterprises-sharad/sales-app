-- =============================================================================
-- 046_revise_purchase_net_stock.sql
-- Correcting a purchase should only need back the goods you are changing.
--
-- Run this in the Supabase SQL Editor. Committing it to git does nothing to
-- the database.
--
-- 044 made a purchase correctable by cancelling it and entering a replacement,
-- and it did those two things in that order. That is what made it stricter
-- than it needed to be: cancelling demands EVERY product on the document back
-- on the shelf, including the ten lines you are not touching.
--
-- PUR-000015 is the case that showed it. Eleven lines, nearly all still in
-- stock, one item wrongly entered — and the correction was refused because one
-- OTHER line, Creams Chocolate, was fourteen dozen short. A line nobody was
-- changing, whose cancellation and re-entry cancel each other out exactly,
-- blocked the whole document.
--
-- THE FIX IS THE ORDER. Post the replacement FIRST, then cancel the original.
--
--   a line that is unchanged   +96 then -96. Never dips, never checked
--                              against an empty shelf, nets to nothing.
--   the line being changed     the old product is not on the replacement, so
--                              nothing is added back before it is taken away:
--                              its 96 must genuinely be on hand.
--   a quantity reduced         +50 then -96, so 46 has to be there — which is
--                              exactly how much is actually leaving.
--
-- So the rule becomes the one he described, and the one it should always have
-- been: **you can correct a line if that line's goods are still there.** No
-- new check was written to achieve it — `cancel_purchase` does the same test
-- it always did, and simply does it at a moment when the arithmetic is right.
-- One rule, one place, still.
--
-- The document model is unchanged: the original is still cancelled and the
-- replacement still linked to it, so the trail reads the same as before. Only
-- the order of the two halves inside the transaction moved.
--
-- A better refusal, too. When it IS blocked, the message said "some of what
-- this purchase brought in has already gone out", which was about the whole
-- document. Now the only goods that can block a correction are the ones being
-- changed, so it says that instead, and keeps the per-product detail.
--
-- Safe to run twice. Nothing already stored changes.
-- =============================================================================

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
  v_user   uuid := app.require_back_office();
  v_pur    public.purchase%rowtype;
  v_new    jsonb;
  v_detail text;
begin
  select * into v_pur from public.purchase where id = p_purchase_id for update;

  if not found then
    raise exception 'That purchase does not exist' using errcode = 'SA005';
  end if;

  if v_pur.status <> 'ACTIVE' then
    raise exception '% has already been cancelled, so it cannot be corrected',
      v_pur.doc_no using errcode = 'SA002';
  end if;

  if jsonb_typeof(coalesce(p_lines, 'null'::jsonb)) <> 'array'
     or jsonb_array_length(p_lines) = 0 then
    raise exception 'A corrected purchase still needs at least one line'
      using errcode = 'SA004';
  end if;

  -- ---------------------------------------------------------------------------
  -- The replacement goes in FIRST.
  -- ---------------------------------------------------------------------------
  -- This is the whole migration. Stock rises by the corrected lines before the
  -- original is taken back out, so every product that appears on both
  -- documents is comfortably covered by its own replacement and the
  -- cancellation below can never drive it towards zero. `product_stock.on_hand`
  -- carries a NOT NULL CHECK (>= 0) that fires immediately, so the old order
  -- did not merely refuse too often — on a document whose goods had moved it
  -- could not have completed at all.
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

  -- ---------------------------------------------------------------------------
  -- Then the original comes out.
  -- ---------------------------------------------------------------------------
  -- Same function, same shortfall test it has always applied. What changed is
  -- when it runs: the only quantity it can now fail to find is quantity the
  -- replacement did not put back, which is precisely the goods being changed.
  begin
    perform public.cancel_purchase(
      p_purchase_id,
      'Corrected and re-entered as ' || (v_new ->> 'doc_no'));
  exception when sqlstate 'SA001' then
    get stacked diagnostics v_detail = PG_EXCEPTION_DETAIL;
    raise exception
      'This correction changes an item whose goods have already gone out, so the original quantity cannot be taken back.'
      using errcode = 'SA001', detail = coalesce(v_detail, '[]');
  end;

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
  'Enters a corrected purchase and cancels the original, in that order, so a
   line left unchanged needs no stock on hand and only the goods actually being
   changed have to still be there. Changing a rate changes the average cost
   from that date on, and so margins already reported.';

notify pgrst, 'reload schema';
