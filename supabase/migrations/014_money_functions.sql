-- =============================================================================
-- 014_money_functions.sql
-- Sales returns, receipts, and the allocation of credits against invoices.
--
-- Policy decision: allocation is ALWAYS manual. Creating a receipt settles
-- nothing on its own; someone chooses which invoices it pays. Money therefore
-- never lands on an invoice by accident, at the cost of a second step.
-- =============================================================================

-- =============================================================================
-- SALES RETURN
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
    x.qty,
    app.pack_size_for(x.product_id, coalesce(x.uom, 'BASE')) as pack_size,
    x.rate,
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

create or replace function public.cancel_sales_return(
  p_return_id uuid,
  p_reason    text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user  uuid := app.require_back_office();
  v_ret   public.sales_return%rowtype;
  v_ids   uuid[];
  v_short jsonb;
begin
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'A cancellation reason is required' using errcode = 'SA004';
  end if;

  select * into v_ret from public.sales_return where id = p_return_id for update;

  if not found then
    raise exception 'Unknown sales return' using errcode = 'SA005';
  end if;

  if v_ret.status = 'CANCELLED' then
    raise exception 'This return is already cancelled' using errcode = 'SA002';
  end if;

  -- Taking the goods back out needs them to still be there. If they have been
  -- resold in the meantime, say so plainly rather than letting stock go wrong.
  select array_agg(distinct product_id) into v_ids
    from public.sales_return_line where return_id = p_return_id and restock;

  perform app.lock_products(coalesce(v_ids, '{}'::uuid[]));

  select jsonb_agg(jsonb_build_object(
           'product_code', p.code,
           'product_name', p.name,
           'needed',       t.qty,
           'on_hand',      ps.on_hand))
    into v_short
    from (select product_id, sum(qty_base) as qty
            from public.sales_return_line
           where return_id = p_return_id and restock
           group by product_id) t
    join public.product       p  on p.id = t.product_id
    join public.product_stock ps on ps.product_id = t.product_id
   where t.qty > ps.on_hand;

  if v_short is not null then
    raise exception
      'Cannot cancel this return: the goods have already been sold again'
      using errcode = 'SA001', detail = v_short::text;
  end if;

  insert into public.stock_ledger
    (product_id, movement_date, qty_out, rate, doc_type, doc_id, doc_line_id, created_by)
  select srl.product_id, current_date, srl.qty_base, srl.rate,
         'SALE_RETURN_CANCEL', p_return_id, srl.id, v_user
    from public.sales_return_line srl
   where srl.return_id = p_return_id
     and srl.restock;

  -- Its credit stops existing, so anything it was paying goes back to owing.
  delete from public.credit_allocation where sales_return_id = p_return_id;

  update public.sales_return
     set status = 'CANCELLED', cancelled_at = now(),
         cancelled_by = v_user, cancel_reason = p_reason
   where id = p_return_id;

  return jsonb_build_object('return_id', p_return_id, 'status', 'CANCELLED');
end;
$$;

-- =============================================================================
-- RECEIPT
-- =============================================================================

create or replace function public.create_receipt(
  p_party_id        uuid,
  p_receipt_date    date,
  p_mode            app.payment_mode,
  p_amount          numeric,
  p_reference_no    text default null,
  p_instrument_date date default null,
  p_bank_name       text default null,
  p_collected_by    uuid default null,
  p_remarks         text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user   uuid := app.require_back_office();
  v_doc_no text;
  v_id     uuid;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'A receipt needs an amount above zero' using errcode = 'SA004';
  end if;

  if not exists (select 1 from public.party where id = p_party_id) then
    raise exception 'Unknown party' using errcode = 'SA005';
  end if;

  if p_collected_by is not null
     and not exists (select 1 from public.app_user where id = p_collected_by) then
    raise exception 'Unknown collector' using errcode = 'SA005';
  end if;

  v_doc_no := app.next_doc_no('RECEIPT');

  insert into public.receipt
    (doc_no, party_id, receipt_date, mode, amount, reference_no,
     instrument_date, bank_name, clearing_status, collected_by, remarks, created_by)
  values
    (v_doc_no, p_party_id, p_receipt_date, p_mode, p_amount, p_reference_no,
     p_instrument_date, p_bank_name,
     case when p_mode = 'CHEQUE' then 'PENDING' else null end,
     coalesce(p_collected_by, v_user), p_remarks, v_user)
  returning id into v_id;

  return jsonb_build_object(
    'receipt_id', v_id, 'doc_no', v_doc_no, 'amount', p_amount,
    'unallocated', p_amount,
    'note', 'Not applied to any invoice yet. Allocate it to settle invoices.');
end;
$$;

create or replace function public.cancel_receipt(
  p_receipt_id uuid,
  p_reason     text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user   uuid := app.require_back_office();
  v_status app.doc_status;
begin
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'A cancellation reason is required' using errcode = 'SA004';
  end if;

  select status into v_status from public.receipt where id = p_receipt_id for update;

  if not found then
    raise exception 'Unknown receipt' using errcode = 'SA005';
  end if;

  if v_status = 'CANCELLED' then
    raise exception 'This receipt is already cancelled' using errcode = 'SA002';
  end if;

  delete from public.credit_allocation where receipt_id = p_receipt_id;

  update public.receipt
     set status = 'CANCELLED', cancelled_at = now(),
         cancelled_by = v_user, cancel_reason = p_reason
   where id = p_receipt_id;

  return jsonb_build_object('receipt_id', p_receipt_id, 'status', 'CANCELLED');
end;
$$;

-- -----------------------------------------------------------------------------
-- Cheque clearing
--
-- A bounced cheque keeps its receipt, for the record, but stops being money:
-- its allocations are reversed and the invoices go back into outstanding.
-- -----------------------------------------------------------------------------

create or replace function public.set_cheque_status(
  p_receipt_id uuid,
  p_status     text,
  p_remarks    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user     uuid := app.require_back_office();
  v_rct      public.receipt%rowtype;
  v_reversed numeric(14,2) := 0;
begin
  if p_status not in ('PENDING', 'CLEARED', 'BOUNCED') then
    raise exception 'Cheque status must be PENDING, CLEARED or BOUNCED'
      using errcode = 'SA004';
  end if;

  select * into v_rct from public.receipt where id = p_receipt_id for update;

  if not found then
    raise exception 'Unknown receipt' using errcode = 'SA005';
  end if;

  if v_rct.mode <> 'CHEQUE' then
    raise exception 'Only a cheque receipt has a clearing status'
      using errcode = 'SA002';
  end if;

  if v_rct.status = 'CANCELLED' then
    raise exception 'This receipt is cancelled' using errcode = 'SA002';
  end if;

  if p_status = 'BOUNCED' then
    select coalesce(sum(amount), 0) into v_reversed
      from public.credit_allocation where receipt_id = p_receipt_id;

    delete from public.credit_allocation where receipt_id = p_receipt_id;
  end if;

  update public.receipt
     set clearing_status = p_status,
         remarks = coalesce(p_remarks, remarks)
   where id = p_receipt_id;

  return jsonb_build_object(
    'receipt_id', p_receipt_id, 'clearing_status', p_status,
    'allocations_reversed', v_reversed);
end;
$$;

-- =============================================================================
-- ALLOCATION
--
-- One call sets the allocations for a single credit. Whatever is passed becomes
-- the complete picture for that credit: invoices not mentioned are released.
-- Passing an empty array unallocates it entirely.
--
-- Input: [{"invoice_id": "...", "amount": 1000.00}, ...]
-- =============================================================================

create or replace function public.allocate_credit(
  p_allocations    jsonb,
  p_receipt_id     uuid default null,
  p_sales_return_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user      uuid := app.require_back_office();
  v_party     uuid;
  v_limit     numeric(14,2);
  v_requested numeric(14,2);
  v_bad       jsonb;
begin
  if num_nonnulls(p_receipt_id, p_sales_return_id) <> 1 then
    raise exception 'Allocate from exactly one receipt or one sales return'
      using errcode = 'SA004';
  end if;

  if jsonb_typeof(coalesce(p_allocations, '[]'::jsonb)) <> 'array' then
    raise exception 'Allocations must be an array' using errcode = 'SA004';
  end if;

  -- Identify the credit and check it is still live.
  if p_receipt_id is not null then
    select party_id, amount into v_party, v_limit
      from public.receipt
     where id = p_receipt_id and status = 'ACTIVE'
     for update;

    if not found then
      raise exception 'Unknown or cancelled receipt' using errcode = 'SA005';
    end if;

    if exists (select 1 from public.receipt
                where id = p_receipt_id and clearing_status = 'BOUNCED') then
      raise exception 'A bounced cheque cannot settle invoices'
        using errcode = 'SA002';
    end if;
  else
    select party_id, total_value into v_party, v_limit
      from public.sales_return
     where id = p_sales_return_id and status = 'ACTIVE'
     for update;

    if not found then
      raise exception 'Unknown or cancelled sales return' using errcode = 'SA005';
    end if;
  end if;

  drop table if exists _alloc;
  create temp table _alloc on commit drop as
  select x.invoice_id, round(x.amount, 2) as amount
    from jsonb_to_recordset(coalesce(p_allocations, '[]'::jsonb))
         as x(invoice_id uuid, amount numeric)
   where coalesce(x.amount, 0) > 0;

  if exists (select 1 from pg_temp._alloc group by invoice_id having count(*) > 1) then
    raise exception 'The same invoice appears twice in this allocation'
      using errcode = 'SA004';
  end if;

  -- Money only moves between documents of the same party.
  select jsonb_agg(jsonb_build_object('invoice_id', a.invoice_id))
    into v_bad
    from pg_temp._alloc a
    left join public.sales_invoice si on si.id = a.invoice_id
   where si.id is null or si.party_id <> v_party;

  if v_bad is not null then
    raise exception 'An invoice in this allocation is unknown or belongs to another party'
      using errcode = 'SA004', detail = v_bad::text;
  end if;

  select coalesce(sum(amount), 0) into v_requested from pg_temp._alloc;

  if v_requested > v_limit then
    raise exception 'Allocating % exceeds the credit of %', v_requested, v_limit
      using errcode = 'SA004';
  end if;

  -- Replace this credit's allocations wholesale.
  delete from public.credit_allocation
   where (p_receipt_id is not null and receipt_id = p_receipt_id)
      or (p_sales_return_id is not null and sales_return_id = p_sales_return_id);

  insert into public.credit_allocation
    (receipt_id, sales_return_id, invoice_id, amount, created_by)
  select p_receipt_id, p_sales_return_id, a.invoice_id, a.amount, v_user
    from pg_temp._alloc a;

  -- The deferred triggers verify at COMMIT that nothing over-allocates an
  -- invoice; this is here so the caller gets the number back immediately.
  return jsonb_build_object(
    'allocated',   v_requested,
    'unallocated', v_limit - v_requested,
    'invoices',    (select count(*) from pg_temp._alloc));
end;
$$;

-- =============================================================================
-- Grants
-- =============================================================================

grant execute on function
  public.post_sales_return(uuid, date, jsonb, text, uuid, text),
  public.cancel_sales_return(uuid, text),
  public.create_receipt(uuid, date, app.payment_mode, numeric, text, date, text, uuid, text),
  public.cancel_receipt(uuid, text),
  public.set_cheque_status(uuid, text, text),
  public.allocate_credit(jsonb, uuid, uuid)
to authenticated;
