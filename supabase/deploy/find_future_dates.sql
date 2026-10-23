-- =============================================================================
-- find_future_dates.sql
--
-- Run the WHOLE file in the Supabase SQL Editor. It changes nothing.
--
-- Migration 042 stops anything NEW being dated ahead of today. It does not go
-- looking for what is already there. This does.
--
-- If it returns no rows, nothing in the database is dated in the future and
-- there is nothing to do. If it returns anything, each row names the document,
-- the date it carries, and how far ahead that is — a bill keyed 11/12 instead
-- of 11/02 shows up as about 330 days ahead, which is unmistakable.
--
-- What to do about one is a decision, not a cleanup: a bill cannot simply have
-- its date changed, because stock moved and money may have been applied
-- against it. Send me what this returns and we will work out each one.
--
-- One SELECT on purpose — the SQL Editor only shows the last statement's
-- result, so anything split into several would silently throw the earlier ones
-- away.
-- =============================================================================

select *
  from (

    select 'Bill'               as kind, si.doc_no, si.invoice_date   as dated,
           si.status::text      as status, p.name                     as who,
           si.net_total                                               as value
      from public.sales_invoice si
      join public.party p on p.id = si.party_id
     where si.invoice_date > current_date

    union all
    select 'Order', so.doc_no, so.order_date, so.status::text, p.name, null
      from public.sales_order so
      join public.party p on p.id = so.party_id
     where so.order_date > current_date

    union all
    select 'Purchase', pu.doc_no, pu.purchase_date, pu.status::text, s.name,
           pu.net_total
      from public.purchase pu
      join public.supplier s on s.id = pu.supplier_id
     where pu.purchase_date > current_date

    union all
    select 'Supplier bill date', pu.doc_no, pu.supplier_bill_date,
           pu.status::text, s.name, pu.net_total
      from public.purchase pu
      join public.supplier s on s.id = pu.supplier_id
     where pu.supplier_bill_date > current_date

    union all
    select 'Payment', r.doc_no, r.receipt_date, r.status::text, p.name, r.amount
      from public.receipt r
      join public.party p on p.id = r.party_id
     where r.receipt_date > current_date

    union all
    select 'Return', sr.doc_no, sr.return_date, sr.status::text, p.name,
           sr.total_value
      from public.sales_return sr
      join public.party p on p.id = sr.party_id
     where sr.return_date > current_date

    union all
    select 'Stock movement', sl.doc_type::text, sl.movement_date, '-', pr.name,
           null
      from public.stock_ledger sl
      join public.product pr on pr.id = sl.product_id
     where sl.movement_date > current_date

  ) x
 order by dated desc, kind, doc_no;
