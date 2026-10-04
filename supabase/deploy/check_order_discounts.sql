-- =============================================================================
-- check_order_discounts.sql
--
-- Reads only. Changes nothing. Safe to run any time, on the live database.
--
-- "Some bills seem to have lost the discount the rep put on the order."
--
-- This answers the question underneath that: was the discount ever recorded
-- on the order at all? There are only three possibilities, and they want
-- different responses:
--
--   A. The order has no discount stored. The rep remembers applying one, but
--      the app never saved it — so the bill was right about what it was
--      given. Look at WHEN those orders were taken: if they all stop at a
--      date, we know which bug it was and that it is already fixed.
--
--   B. The order has a discount and the bill has none. The discount was
--      recorded and then lost on the way to the bill. That is a live bug and
--      the bills are wrong.
--
--   C. The order has a discount, the bill has a smaller one, and the bill
--      covers only part of the order. That is correct and expected: a
--      percentage is carried, so a bill for 60 of 100 pieces gets 60% of the
--      money. Section 3 works that out so it can be told apart from B.
--
-- Run the whole file. Four results come back, in order.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. How many orders carry a discount at all, by month
--
-- If discounts suddenly appear or disappear at a date, this is where it shows.
-- -----------------------------------------------------------------------------

select
  to_char(so.order_date, 'YYYY-MM')                            as month,
  count(*)                                                     as orders,
  count(*) filter (where so.bill_discount_amount > 0)          as with_bill_discount,
  count(*) filter (where exists (
    select 1 from public.sales_order_line l
     where l.order_id = so.id and l.line_discount_amount > 0)) as with_line_discount,
  count(*) filter (where so.bill_discount_amount = 0
                     and not exists (
    select 1 from public.sales_order_line l
     where l.order_id = so.id and l.line_discount_amount > 0)) as with_no_discount
from public.sales_order so
where so.status <> 'CANCELLED'
group by 1
order by 1;


-- -----------------------------------------------------------------------------
-- 2. The same question per rep
--
-- A discount that one rep's orders never carry and another's always do is a
-- habit, not a bug. Worth knowing before chasing code.
-- -----------------------------------------------------------------------------

select
  coalesce(u.full_name, 'unknown')                             as taken_by,
  count(*)                                                     as orders,
  count(*) filter (where so.bill_discount_amount > 0
                      or exists (select 1 from public.sales_order_line l
                                  where l.order_id = so.id
                                    and l.line_discount_amount > 0)) as any_discount,
  min(so.order_date)                                           as first_order,
  max(so.order_date)                                           as last_order
from public.sales_order so
left join public.app_user u on u.id = so.created_by
where so.status <> 'CANCELLED'
group by 1
order by 2 desc;


-- -----------------------------------------------------------------------------
-- 3. Every order that had a discount, beside the bills raised from it
--
-- `expected_on_bills` is what the discount should come to once the order is
-- billed in full or in part: the line discounts on what was actually billed,
-- plus the order-wide discount in the same proportion.
--
-- Read the `verdict` column:
--
--   matches                — nothing wrong
--   part billed, in step   — only some of the order is billed, and the
--                            discount on it is in proportion. Correct.
--   BILL HAS NO DISCOUNT   — the order had one and the bill has none
--   SHORT BY <amount>      — the bill has some of it but not enough
--
-- An order with no bills yet is shown too, so you can see what is still to
-- come rather than wondering why it is missing from the list.
-- -----------------------------------------------------------------------------

with order_totals as (
  select
    so.id,
    so.doc_no,
    so.order_date,
    u.full_name                                          as taken_by,
    p.name                                               as party_name,
    so.status,
    so.bill_discount_amount,
    coalesce(sum(sol.line_discount_amount), 0)           as line_discount,
    coalesce(sum(round(sol.qty * sol.rate, 2)), 0)       as gross,
    coalesce(sum(sol.qty_base), 0)                       as qty_base,
    coalesce(sum(sol.qty_base - sol.qty_pending_base), 0) as qty_billed_base
  from public.sales_order so
  join public.party p on p.id = so.party_id
  left join public.app_user u on u.id = so.created_by
  join public.sales_order_line sol on sol.order_id = so.id
  where so.status <> 'CANCELLED'
  group by so.id, so.doc_no, so.order_date, u.full_name, p.name, so.status,
           so.bill_discount_amount
),
bill_totals as (
  select
    si.order_id,
    count(*)                                                      as bills,
    string_agg(si.doc_no, ', ' order by si.doc_no)                as bill_nos,
    coalesce(sum(si.line_discount_total), 0)
      + coalesce(sum(si.bill_discount_amount), 0)                 as bill_discount
  from public.sales_invoice si
  where si.order_id is not null
    and si.status <> 'CANCELLED'
  group by si.order_id
)
select
  o.doc_no                                       as order_no,
  o.order_date,
  o.taken_by,
  o.party_name,
  o.status,
  round(o.line_discount + o.bill_discount_amount, 2) as discount_on_order,
  coalesce(b.bill_nos, '—')                      as bills,
  round(coalesce(b.bill_discount, 0), 2)         as discount_on_bills,
  -- What the bills ought to carry, given how much of the order they cover.
  round(
    (o.line_discount + o.bill_discount_amount)
      * case when o.qty_base > 0 then o.qty_billed_base / o.qty_base else 0 end,
    2)                                           as expected_on_bills,
  case
    when b.order_id is null                        then 'not billed yet'
    when coalesce(b.bill_discount, 0) = 0          then 'BILL HAS NO DISCOUNT'
    when abs(coalesce(b.bill_discount, 0)
             - (o.line_discount + o.bill_discount_amount)
               * case when o.qty_base > 0
                      then o.qty_billed_base / o.qty_base else 0 end) <= 1.00
                                                   then
      case when o.qty_billed_base < o.qty_base then 'part billed, in step'
           else 'matches' end
    else 'SHORT BY ' || round(
      (o.line_discount + o.bill_discount_amount)
        * case when o.qty_base > 0 then o.qty_billed_base / o.qty_base else 0 end
      - coalesce(b.bill_discount, 0), 2)::text
  end                                            as verdict
from order_totals o
left join bill_totals b on b.order_id = o.id
where o.line_discount + o.bill_discount_amount > 0
order by o.order_date desc, o.doc_no desc;


-- -----------------------------------------------------------------------------
-- 4. The other direction: bills whose order had NO discount recorded
--
-- These are the ones to read against the reps' memory. If somebody is sure a
-- discount was given on one of these, the order never had it — which points
-- at the app at the time the order was taken, not at the billing.
--
-- Most recent first, because the recent ones are the ones worth arguing about.
-- -----------------------------------------------------------------------------

select
  so.doc_no                                   as order_no,
  so.order_date,
  u.full_name                                 as taken_by,
  p.name                                      as party_name,
  si.doc_no                                   as bill_no,
  si.invoice_date,
  si.gross_total,
  si.net_total
from public.sales_order so
join public.party p on p.id = so.party_id
left join public.app_user u on u.id = so.created_by
join public.sales_invoice si on si.order_id = so.id and si.status <> 'CANCELLED'
where so.bill_discount_amount = 0
  and not exists (select 1 from public.sales_order_line l
                   where l.order_id = so.id and l.line_discount_amount > 0)
order by so.order_date desc, so.doc_no desc
limit 100;
