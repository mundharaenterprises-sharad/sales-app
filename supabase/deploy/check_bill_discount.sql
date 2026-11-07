-- =============================================================================
-- check_bill_discount.sql
--
-- Reads only. Changes nothing. Safe on the live database.
--
-- "Was a discount put on the order and missed on the bill, or was there no
-- discount?" — for ONE bill, line by line.
--
-- Put the bill number in the one place below and run the whole file. The SQL
-- Editor shows only the last result, so everything comes back in a single
-- table: one row per bill line, plus a `— BILL —` row at the top for the
-- order-wide discount, which is the one that can go missing on its own.
--
-- READING THE VERDICT COLUMN
--
--   no order              The bill was typed directly, not raised from an
--                         order. There was no order discount to lose.
--   no discount on order  The order carries none. The bill was right about
--                         what it was given — whoever remembers a discount is
--                         remembering it being agreed, not entered.
--   carried               The order had one and the bill has it.
--   part billed, in step  Only some of the order is on this bill, and the
--                         discount on it is in proportion. Correct.
--   LOST                  The order had one and the bill has none.
--   SHORT BY <amount>     The bill has some of it, but not enough.
--
-- A line discount and the order-wide discount travel by different routes and
-- can fail separately, which is why they are shown separately. The order-wide
-- one is the `— BILL —` row.
-- =============================================================================

with ask as (
  -- The bill to look at. 732, '732' and 'INV-000732' all mean the same bill:
  -- the digits are compared as a number, because the prefix and the padding
  -- both live in app.doc_sequence and can be changed there.
  select 732 as bill_no
),

bill as (
  select si.*
    from public.sales_invoice si, ask
   where nullif(regexp_replace(si.doc_no, '[^0-9]', '', 'g'), '')::bigint = ask.bill_no
     and not si.is_opening
),

ord as (
  select so.*
    from public.sales_order so
   where so.id = (select order_id from bill)
),

-- What is on this bill, and the order line each line came off.
lines as (
  select
    sil.line_no,
    pr.code                                  as product_code,
    pr.name                                  as product_name,
    sol.qty_base                             as order_qty,
    sol.rate                                 as order_rate,
    sol.line_discount_pct                    as order_disc_pct,
    sol.line_discount_amount                 as order_disc_amt,
    sil.qty_base                             as bill_qty,
    sil.rate                                 as bill_rate,
    sil.gross_amount,
    sil.line_discount_pct                    as bill_disc_pct,
    sil.line_discount_amount                 as bill_disc_amt,
    sil.allocated_bill_discount,
    -- A percentage is what carries, so what this bill ought to show on this
    -- line is that percentage of THIS line's gross — not the rupee figure
    -- agreed on the whole order quantity.
    round(sil.gross_amount
          * coalesce(sol.line_discount_pct, 0) / 100, 2) as expected_disc_amt
  from public.sales_invoice_line sil
  join public.product pr on pr.id = sil.product_id
  left join public.sales_order_line sol on sol.id = sil.order_line_id
  where sil.invoice_id = (select id from bill)
),

-- The order-wide discount, which is allocated across the bill's lines rather
-- than sitting on any one of them.
header as (
  select
    (select bill_discount_pct    from ord)                        as order_disc_pct,
    (select bill_discount_amount from ord)                        as order_disc_amt,
    (select bill_discount_amount from bill)                       as bill_disc_amt,
    (select coalesce(sum(allocated_bill_discount), 0) from lines) as allocated,
    (select coalesce(sum(gross_amount - bill_disc_amt), 0) from lines) as net_before_bill_disc
)

select * from (

  -- The order-wide discount.
  select
    0                                             as line_no,
    '— BILL —'                                    as product,
    (select doc_no from bill)                     as bill_no,
    coalesce((select doc_no from ord), '—')       as order_no,
    null::numeric                                 as qty_ordered,
    null::numeric                                 as qty_billed,
    h.order_disc_pct                              as order_disc_pct,
    h.order_disc_amt                              as order_disc_on_full_qty,
    round(h.net_before_bill_disc
          * coalesce(h.order_disc_pct, 0) / 100, 2) as expected_on_this_bill,
    h.bill_disc_amt                               as actually_on_bill,
    case
      when (select id from ord) is null                     then 'no order'
      when coalesce(h.order_disc_pct, 0) = 0
       and coalesce(h.order_disc_amt, 0) = 0                then 'no discount on order'
      when coalesce(h.bill_disc_amt, 0) = 0                 then 'LOST'
      when abs(coalesce(h.bill_disc_amt, 0)
               - round(h.net_before_bill_disc
                       * coalesce(h.order_disc_pct, 0) / 100, 2)) <= 1.00
                                                            then 'carried'
      else 'SHORT BY ' || round(
        round(h.net_before_bill_disc * coalesce(h.order_disc_pct, 0) / 100, 2)
        - coalesce(h.bill_disc_amt, 0), 2)::text
    end                                           as verdict
  from header h

  union all

  -- Each line's own discount.
  select
    l.line_no,
    l.product_code || ' · ' || l.product_name,
    (select doc_no from bill),
    coalesce((select doc_no from ord), '—'),
    l.order_qty,
    l.bill_qty,
    l.order_disc_pct,
    l.order_disc_amt,
    l.expected_disc_amt,
    l.bill_disc_amt,
    case
      when l.order_qty is null                              then 'no order'
      when coalesce(l.order_disc_pct, 0) = 0
       and coalesce(l.order_disc_amt, 0) = 0                then 'no discount on order'
      when coalesce(l.bill_disc_amt, 0) = 0                 then 'LOST'
      when abs(l.bill_disc_amt - l.expected_disc_amt) <= 0.50 then
        case when l.bill_qty < l.order_qty then 'part billed, in step'
             else 'carried' end
      else 'SHORT BY ' || round(l.expected_disc_amt - l.bill_disc_amt, 2)::text
    end
  from lines l

) x
order by x.line_no;

-- If this comes back empty there is no bill with that number — check it on the
-- Bills list. A cancelled bill IS shown, deliberately: a discount missing from
-- one that was later replaced is still worth knowing about.
