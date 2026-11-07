-- =============================================================================
-- check_order_discounts.sql
--
-- Reads only. Changes nothing. Safe on the live database.
--
-- "Some bills seem to have lost the discount the rep put on the order."
--
-- WHICH BILLS LOST A DISCOUNT, AND FOR HOW MUCH. One table, worst first, with
-- a TOTAL row at the top.
--
-- ⚠ THIS SCRIPT WAS REWRITTEN ON 7 NOVEMBER AND THE OLD ONE WAS USELESS TO
-- HIM. It had four separate SELECTs, and the Supabase SQL Editor shows only
-- the LAST statement's result — so running it showed him the fourth query, a
-- list of orders that never had a discount, and the three that answered the
-- question were invisible. A diagnostic meant for the SQL Editor has to be a
-- single SELECT returning a table. That is bug #29 in the handover, written
-- down before this script was, and this is the script that broke it.
--
-- TWO DISCOUNTS, AND THEY FAIL SEPARATELY. A discount per line and one on the
-- whole order travel to a bill by different routes, so they are counted in
-- separate columns. The bug fixed in migration 049 lost only the bill-wide
-- one, while the line discounts carried through and made the bill look right.
--
-- READING THE VERDICT
--
--   TOTAL                   the first row: how much is missing in all
--   BILL-WIDE LOST          the order had an order-wide discount and the
--                           bills carry none of it. This is 049's bug.
--   BILL-WIDE SHORT BY x    some of it reached the bills, but not enough
--   LINE DISC SHORT BY x    a per-line discount did not fully carry
--   part billed, in step    only some of the order is billed and the
--                           discount on it is in proportion — correct
--   ok                      nothing wrong
--   not billed yet          nothing to compare
--
-- `expected` is worked out the way the billing engine works it out, not by
-- apportioning a rupee figure: each bill line's own gross times the order
-- line's percentage, and the order-wide percentage applied to each bill after
-- its line discounts. So a part-billed order is expected to carry only its own
-- share, and two bills of one order should add up to what was quoted.
--
-- Orders with no discount at all are left out — there is nothing to lose. If a
-- rep is sure a discount was given on one of those, the order never had it,
-- which points at order entry and not at billing. The last column of the TOTAL
-- row counts those, so their number is visible without listing them.
-- =============================================================================

with ord as (
  select
    so.id,
    so.doc_no,
    so.order_date,
    u.full_name                                   as taken_by,
    p.name                                        as party_name,
    so.status::text                               as status,
    so.bill_discount_pct                          as billwide_pct,
    so.bill_discount_amount                       as billwide_amt,
    coalesce(sum(sol.line_discount_amount), 0)    as line_disc,
    coalesce(sum(sol.qty_base), 0)                as qty_base,
    coalesce(sum(sol.qty_base - sol.qty_pending_base), 0) as qty_billed
  from public.sales_order so
  join public.party p on p.id = so.party_id
  left join public.app_user u on u.id = so.created_by
  join public.sales_order_line sol on sol.order_id = so.id
  where so.status <> 'CANCELLED'
  group by so.id, so.doc_no, so.order_date, u.full_name, p.name, so.status,
           so.bill_discount_pct, so.bill_discount_amount
),

-- What each bill of an order actually carries, and what it ought to.
bill as (
  select
    si.order_id,
    si.id                                                        as invoice_id,
    si.doc_no,
    si.line_discount_total                                       as got_line,
    si.bill_discount_amount                                      as got_billwide,
    -- Each line's own gross at the order line's percentage: what the engine
    -- would have put there.
    coalesce(sum(round(sil.gross_amount
                       * coalesce(sol.line_discount_pct, 0) / 100, 2)), 0) as want_line,
    coalesce(sum(sil.gross_amount), 0)                           as gross
  from public.sales_invoice si
  join public.sales_invoice_line sil on sil.invoice_id = si.id
  left join public.sales_order_line sol on sol.id = sil.order_line_id
  where si.order_id is not null
    and si.status <> 'CANCELLED'
  group by si.order_id, si.id, si.doc_no, si.line_discount_total,
           si.bill_discount_amount
),

-- The order-wide percentage applies to each bill after its line discounts, so
-- it has to be worked out per bill and then added up.
per_order as (
  select
    b.order_id,
    count(*)                                             as bills,
    string_agg(b.doc_no, ', ' order by b.doc_no)         as bill_nos,
    sum(b.got_line)                                      as got_line,
    sum(b.want_line)                                     as want_line,
    sum(b.got_billwide)                                  as got_billwide,
    sum(round((b.gross - b.got_line)
              * coalesce(o.billwide_pct, 0) / 100, 2))   as want_billwide
  from bill b
  join ord o on o.id = b.order_id
  group by b.order_id
),

joined as (
  select
    o.*,
    coalesce(b.bills, 0)                       as bills,
    coalesce(b.bill_nos, '—')                  as bill_nos,
    coalesce(b.got_line, 0)                    as got_line,
    coalesce(b.want_line, 0)                   as want_line,
    coalesce(b.got_billwide, 0)                as got_billwide,
    coalesce(b.want_billwide, 0)               as want_billwide,
    b.order_id is null                         as unbilled
  from ord o
  left join per_order b on b.order_id = o.id
  -- Only orders that had something to lose.
  where o.line_disc > 0
     or coalesce(o.billwide_amt, 0) > 0
     or coalesce(o.billwide_pct, 0) > 0
),

scored as (
  select
    j.*,
    round(greatest((j.want_line + j.want_billwide)
                   - (j.got_line + j.got_billwide), 0), 2) as short_by
  from joined j
)

select * from (

  -- The money, first, so it is visible without reading the list.
  select
    0                                                        as sort,
    'TOTAL'                                                  as verdict,
    (select count(*) from scored
      where not unbilled and short_by > 1)::text || ' of '
      || (select count(*) from scored where not unbilled)::text
      || ' discounted orders are short'                      as order_no,
    null::date                                               as order_date,
    'orders with no discount at all: '
      || (select count(*) from public.sales_order so
           where so.status <> 'CANCELLED'
             and coalesce(so.bill_discount_amount, 0) = 0
             and coalesce(so.bill_discount_pct, 0) = 0
             and not exists (select 1 from public.sales_order_line l
                              where l.order_id = so.id
                                and l.line_discount_amount > 0))::text as taken_by,
    null::text                                               as party_name,
    null::text                                               as bills,
    round((select coalesce(sum(want_line), 0) from scored where not unbilled), 2)
                                                             as expected_line,
    round((select coalesce(sum(got_line), 0) from scored where not unbilled), 2)
                                                             as on_bills_line,
    round((select coalesce(sum(want_billwide), 0) from scored where not unbilled), 2)
                                                             as expected_billwide,
    round((select coalesce(sum(got_billwide), 0) from scored where not unbilled), 2)
                                                             as on_bills_billwide,
    round((select coalesce(sum(short_by), 0) from scored where not unbilled), 2)
                                                             as short_by

  union all

  select
    case when s.unbilled then 3
         when s.short_by > 1 then 1
         else 2 end                                          as sort,
    case
      when s.unbilled                                        then 'not billed yet'
      when s.want_billwide > 1 and s.got_billwide = 0        then 'BILL-WIDE LOST'
      when s.want_billwide - s.got_billwide > 1              then
        'BILL-WIDE SHORT BY ' || round(s.want_billwide - s.got_billwide, 2)::text
      when s.want_line - s.got_line > 1                      then
        'LINE DISC SHORT BY ' || round(s.want_line - s.got_line, 2)::text
      when s.qty_billed < s.qty_base                         then 'part billed, in step'
      else 'ok'
    end                                                      as verdict,
    s.doc_no,
    s.order_date,
    s.taken_by,
    s.party_name,
    s.bill_nos,
    round(s.want_line, 2),
    round(s.got_line, 2),
    round(s.want_billwide, 2),
    round(s.got_billwide, 2),
    s.short_by
  from scored s

) x
order by x.sort, x.short_by desc, x.order_date desc, x.order_no desc;

-- If only the TOTAL row comes back, no order in the database has ever carried
-- a discount — and the question becomes whether discounts are being entered on
-- orders at all, which is a different problem from them being lost on the way
-- to a bill.
