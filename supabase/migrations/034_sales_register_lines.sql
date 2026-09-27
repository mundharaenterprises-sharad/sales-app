-- =============================================================================
-- 034_sales_register_lines.sql
--
-- Run this in the Supabase SQL Editor. Committing it to git does nothing to
-- the database.
--
-- The sales register answers "which bills went out". It cannot answer "how
-- much Parle G went out", because it has one row per bill and the products are
-- inside them. That is the question the company asks, and the one that decides
-- what to order next.
--
-- So: the same register, one row per bill LINE. Every column the register can
-- be filtered by is carried down to the line — date, route, master group, rep,
-- status — so a product summary built from this covers exactly the same bills
-- as the list beside it. Two sheets in one file that disagreed about which
-- bills they cover would be worse than one sheet.
--
-- Quantities come out in base units. Turning 100 pieces into "2 cartons and 20
-- pieces" is the reader's arithmetic, not the database's, so pack_size and
-- pack_uom ride along and the split happens where it is displayed. A pack size
-- that changes next year must not silently rewrite what last year's report
-- said, which is also why the size is snapshotted on the line itself.
--
-- v_product_sales stays as it is: it answers a different question (margin over
-- time) and the Product sales screen reads it.
--
-- Safe to run twice.
-- =============================================================================

drop view if exists public.v_sales_register_lines;

create view public.v_sales_register_lines as
select
  sil.id                     as line_id,
  si.id                      as invoice_id,
  si.doc_no,
  si.invoice_date,
  si.status,

  -- Everything the register filters by, repeated on the line.
  p.code                     as party_code,
  p.name                     as party_name,
  rt.name                    as route_name,
  mg.code                    as master_code,
  mg.name                    as master_name,
  -- The rep who TOOK the order, which is what the register means by rep —
  -- not whoever in the office typed the bill. Taken from the same place the
  -- register takes it, or the two would quietly disagree about whose sale it
  -- was, and a rep's own report is exactly where that would be noticed.
  rep.full_name              as rep_name,
  u.full_name                as created_by_name,

  pr.id                      as product_id,
  pr.code                    as product_code,
  pr.name                    as product_name,
  pg.name                    as group_name,
  pr.base_uom,
  pr.pack_uom,
  -- The product's carton size, from the master.
  --
  -- NOT sil.pack_size, which is how many base units this line's unit stood
  -- for — 40 on a line billed in cartons, 1 on a line billed loose. That is
  -- the right number for pricing the line and the wrong one for saying how
  -- many cartons a quarter's sales come to.
  --
  -- The cost of using the master is that changing a product's carton size
  -- changes how old sales are described, though never how much they were.
  -- Carton sizes are a fact about the goods and effectively never change, and
  -- the alternative — a second size snapshotted on every line — would be a
  -- column carried on every sale for a case that has not arisen.
  pr.pack_size,

  -- What actually left the building: billed less anything cancelled off it.
  (sil.qty_base - sil.qty_cancelled_base)          as qty_base,
  -- What the line itself was billed in, which is a different question.
  sil.uom                                          as billed_uom,
  sil.pack_size                                    as billed_pack_size,
  sil.rate,
  -- Value after line and bill discounts, less the cancelled share of it.
  (sil.effective_amount
     - round(sil.effective_amount * sil.qty_cancelled_base
             / nullif(sil.qty_base, 0), 2))        as net_amount
from public.sales_invoice_line sil
join public.sales_invoice si  on si.id = sil.invoice_id
join public.party p           on p.id  = si.party_id
join public.route rt          on rt.id = p.route_id
join public.product pr        on pr.id = sil.product_id
join public.product_group pg  on pg.id = pr.group_id
left join public.master_group mg on mg.id = si.master_group_id
left join public.app_user u   on u.id = si.created_by
left join public.sales_order so on so.id = si.order_id
left join public.app_user rep on rep.id = so.created_by
where si.status <> 'CANCELLED'
  and sil.qty_base > sil.qty_cancelled_base;

alter view public.v_sales_register_lines set (security_invoker = true);
grant select on public.v_sales_register_lines to authenticated;

comment on view public.v_sales_register_lines is
  'The sales register at line level: one row per product on a bill, carrying
   every column the register filters by so a product summary and the bill list
   always cover the same bills.';

notify pgrst, 'reload schema';
