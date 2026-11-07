-- =============================================================================
-- check_lost_discount_bills.sql
--
-- Reads only. Changes nothing. Safe on the live database.
--
-- The bills that lost their order's bill-wide discount (the bug fixed in
-- migration 049), with what the shop has paid and what is still outstanding —
-- grouped by customer, because the decision is taken per customer and not per
-- bill.
--
-- WHY PAID-OR-NOT MATTERS. A shop that has already paid in full has paid more
-- than it was quoted, and the only way to put that right is to give it the
-- money back on something — the next bill. A shop that has not paid yet can
-- simply be collected less, but that leaves a small permanent balance sitting
-- on that bill in the ageing report for ever, which is its own nuisance. So
-- this says which situation each customer is in.
--
-- One table. Customers first, worst first, then the individual bills.
-- =============================================================================

with ord as (
  select
    so.id,
    so.doc_no                                     as order_no,
    so.order_date,
    so.party_id,
    so.bill_discount_pct                          as billwide_pct
  from public.sales_order so
  where so.status <> 'CANCELLED'
    and coalesce(so.bill_discount_pct, 0) > 0
),

bill as (
  select
    si.order_id,
    si.id                                                   as invoice_id,
    si.doc_no,
    si.invoice_date,
    si.bill_discount_amount                                 as got_billwide,
    si.line_discount_total                                  as got_line,
    coalesce(sum(sil.gross_amount), 0)                      as gross
  from public.sales_invoice si
  join public.sales_invoice_line sil on sil.invoice_id = si.id
  where si.order_id is not null
    and si.status <> 'CANCELLED'
  group by si.id, si.order_id, si.doc_no, si.invoice_date,
           si.bill_discount_amount, si.line_discount_total
),

short as (
  select
    o.party_id,
    o.order_no,
    b.invoice_id,
    b.doc_no                                                as bill_no,
    b.invoice_date,
    round((b.gross - b.got_line) * o.billwide_pct / 100, 2) as should_have_been,
    b.got_billwide                                          as actually_given,
    round((b.gross - b.got_line) * o.billwide_pct / 100, 2)
      - b.got_billwide                                      as short_by
  from ord o
  join bill b on b.order_id = o.id
  where round((b.gross - b.got_line) * o.billwide_pct / 100, 2) - b.got_billwide > 1
),

withpay as (
  select
    s.*,
    il.party_code,
    il.party_name,
    il.route_name,
    il.net_total,
    il.settled,
    il.outstanding
  from short s
  join public.v_invoice_list il on il.invoice_id = s.invoice_id
)

select * from (

  -- One row per customer: the decision is taken here.
  select
    1                                            as sort,
    w.party_code,
    w.party_name,
    w.route_name,
    count(*)::text || ' bill(s)'                 as scope,
    null::text                                   as bill_no,
    null::date                                   as invoice_date,
    round(sum(w.short_by), 2)                    as short_by,
    round(sum(w.net_total), 2)                   as billed,
    round(sum(w.outstanding), 2)                 as still_outstanding,
    case when sum(w.outstanding) = 0 then 'paid in full — give it back on the next bill'
         when sum(w.outstanding) >= sum(w.short_by) then 'not yet paid — can be collected less'
         else 'part paid' end                    as note
  from withpay w
  group by w.party_code, w.party_name, w.route_name

  union all

  -- And the bills behind each, so the figure can be checked.
  select
    2,
    w.party_code,
    w.party_name,
    w.route_name,
    w.order_no,
    w.bill_no,
    w.invoice_date,
    round(w.short_by, 2),
    round(w.net_total, 2),
    round(w.outstanding, 2),
    'should have been ' || round(w.should_have_been, 2)::text
      || ', was ' || round(w.actually_given, 2)::text
  from withpay w

) x
order by
  (select round(sum(w2.short_by), 2) from withpay w2 where w2.party_code = x.party_code) desc,
  x.party_code,
  x.sort,
  x.short_by desc;
