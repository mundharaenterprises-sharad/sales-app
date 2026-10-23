-- =============================================================================
-- 039_return_rate_precision.sql
--
-- Run this in the Supabase SQL Editor. Committing it to git does nothing to
-- the database.
--
-- "One of the values is not allowed." Returning all 240 pieces of a line that
-- was billed as 4 cartons at 2,200 failed every time, while returning one or
-- two pieces of the same line worked.
--
-- The real message, which the app was hiding:
--
--     Sales return SR-000006 total_value 8800.00 <> line sum 8800.01
--
-- One paisa. Here is where it came from.
--
-- The Returns screen enters quantities in pieces, so it divides the carton
-- rate to get a rate per piece: 2200 / 60 = 36.666666666666664 — a number with
-- seventeen digits, because that is what binary floating point makes of two
-- thirds.
--
-- post_sales_return then used that number TWICE, at two different precisions:
--
--   the header total  round(240 * 36.666666666666664, 2)  = 8800.00
--   the line's amount is a generated column over the STORED rate, and the
--   column is numeric(14,4), so the stored rate is 36.6667 — very slightly
--   larger — giving round(240 * 36.6667, 2) = 8800.01
--
-- A deferred trigger checks at COMMIT that a return's header equals the sum of
-- its lines, found 8800.00 against 8800.01, and refused the whole thing.
--
-- That is why it looked so arbitrary. It needs a rate that does not fit in
-- four decimal places AND a quantity big enough to turn a rounding difference
-- into a whole paisa. One piece is fine. Two hundred and forty is not.
--
-- The fix is to round at the door: the staged rate and quantity are brought to
-- the precision their columns actually hold, BEFORE anything is computed from
-- them. Then the header and the lines are two sums of the same numbers, which
-- is the only way they can be relied on to agree.
--
-- Safe to run twice. Nothing already stored changes.
-- =============================================================================

create or replace function public.post_sales_return(
  p_party_id    uuid,
  p_return_date date,
  p_lines       jsonb,
  p_reason      text,
  p_invoice_id  uuid default null,
  p_remarks     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user     uuid := app.require_back_office();
  v_doc_no   text;
  v_id       uuid;
  v_total    numeric(14,2);
  v_restock  numeric(14,4);
begin
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'A return needs a reason' using errcode = 'SA004';
  end if;

  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'A return needs at least one line' using errcode = 'SA004';
  end if;

  if p_invoice_id is not null
     and not exists (select 1 from public.sales_invoice
                      where id = p_invoice_id and party_id = p_party_id) then
    raise exception 'That invoice does not belong to this party'
      using errcode = 'SA004';
  end if;

  drop table if exists _ret_lines;
  create temp table _ret_lines on commit drop as
  select
    row_number() over ()                        as line_no,
    x.product_id,
    x.invoice_line_id,
    coalesce(x.uom, 'BASE')                     as uom,
    -- Rounded to what the columns actually hold — numeric(14,4) — so that
    -- every later sum is made from the same numbers the rows will contain.
    -- Without this the header total is computed from one rate and the lines
    -- from another, and they disagree by a paisa on a large enough quantity.
    round(x.qty, 4)                             as qty,
    app.pack_size_for(x.product_id, coalesce(x.uom, 'BASE')) as pack_size,
    round(x.rate, 4)                            as rate,
    coalesce(x.restock, true)                   as restock
  from jsonb_to_recordset(p_lines) as x(
         product_id      uuid,
         invoice_line_id uuid,
         uom             app.uom_type,
         qty             numeric,
         rate            numeric,
         restock         boolean);

  if exists (select 1 from pg_temp._ret_lines where qty is null or qty <= 0) then
    raise exception 'Every return line needs a quantity above zero'
      using errcode = 'SA004';
  end if;

  if exists (select 1 from pg_temp._ret_lines where rate is null or rate < 0) then
    raise exception 'Every return line needs a rate' using errcode = 'SA004';
  end if;

  select coalesce(sum(round(qty * rate, 2)), 0) into v_total from pg_temp._ret_lines;

  v_doc_no := app.next_doc_no('SALES_RETURN');

  insert into public.sales_return
    (doc_no, party_id, invoice_id, return_date, total_value, reason, remarks, created_by)
  values
    (v_doc_no, p_party_id, p_invoice_id, p_return_date, v_total,
     p_reason, p_remarks, v_user)
  returning id into v_id;

  insert into public.sales_return_line
    (return_id, line_no, product_id, invoice_line_id, uom, qty, pack_size, rate, restock)
  select v_id, line_no, product_id, invoice_line_id, uom, qty, pack_size, rate, restock
    from pg_temp._ret_lines;

  -- Only resaleable goods go back into stock. The rest are written off: the
  -- customer is still credited, but the goods are gone.
  insert into public.stock_ledger
    (product_id, movement_date, qty_in, rate, doc_type, doc_id, doc_line_id, created_by)
  select srl.product_id, p_return_date, srl.qty_base, srl.rate,
         'SALE_RETURN', v_id, srl.id, v_user
    from public.sales_return_line srl
   where srl.return_id = v_id
     and srl.restock;

  select coalesce(sum(qty_base), 0) into v_restock
    from public.sales_return_line where return_id = v_id and restock;

  return jsonb_build_object(
    'return_id', v_id, 'doc_no', v_doc_no,
    'total_value', v_total, 'restocked_qty', v_restock,
    'note', 'This credit is not applied to any invoice until it is allocated.');
end;
$$;

revoke all on function
  public.post_sales_return(uuid,date,jsonb,text,uuid,text) from public, anon;
grant execute on function
  public.post_sales_return(uuid,date,jsonb,text,uuid,text) to authenticated;

comment on function public.post_sales_return(uuid,date,jsonb,text,uuid,text) is
  'Record goods coming back. Quantities and rates are rounded to the precision
   the columns hold before any total is computed from them, so the header and
   the lines cannot disagree by a rounding artefact.';

notify pgrst, 'reload schema';
