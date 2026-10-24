-- =============================================================================
-- 045_register_bill_number.sql
-- A bill number you can actually filter by.
--
-- Run this in the Supabase SQL Editor. Committing it to git does nothing to
-- the database.
--
-- He asked the sales register for bills 126 to 131 and got a file with no
-- product sheet and no salesman sheet in it. Nothing was broken; the report
-- was doing exactly what it was built to do, and what it was built to do was
-- wrong.
--
-- The bill-number boxes have always been a filter applied IN THE BROWSER, on
-- top of whatever the date range had already fetched — and the date range
-- starts at "this month". So asking for bills 126 to 131 fetched this month's
-- bills and then kept the ones numbered 126 to 131, of which there are none.
-- The register came back empty, and the extra sheets are left out of the file
-- when there is nothing to put in them.
--
-- Two filters where one silently decides the other is a trap: typing a bill
-- number is an unambiguous request for a particular bill, and it should find
-- that bill whatever the dates happen to say. It cannot, while the filtering
-- happens after the fetch.
--
-- So the number becomes something the database can filter on. `doc_seq` is the
-- digits of the document number as a number — INV-000126 is 126 — which is
-- also the only honest way to compare them: as text, '99' sorts after '101',
-- which is why the browser-side version parsed the digits out too. The digits
-- are taken with a regexp rather than by chopping a known prefix off the
-- front, because the prefix and the padding both live in `app.doc_sequence`
-- and can be changed there.
--
-- Appended at the end of each view rather than inserted beside doc_no:
-- `create or replace view` cannot move or insert a column, and both of these
-- have dependants. Column order in a view is cosmetic and the app selects by
-- name. Bug #9.
--
-- Both definitions are rebuilt from the migration that LAST defined them —
-- v_sales_register from 036, which took opening balances out of it, and
-- v_sales_register_lines from 034 — and not from 015, which created them. Bug
-- #23, which has cost this project a view's worth of columns twice.
--
-- Safe to run twice. Nothing already stored changes; this only adds a column
-- to two views.
-- =============================================================================

create or replace view public.v_sales_register as
select
  si.id           as invoice_id,
  si.doc_no,
  si.invoice_date,
  p.code          as party_code,
  p.name          as party_name,
  rt.name         as route_name,
  mg.code         as master_code,
  mg.name         as master_name,
  u.full_name     as created_by_name,
  so.doc_no       as order_no,
  rep.full_name   as rep_name,
  si.gross_total,
  si.line_discount_total,
  si.bill_discount_amount,
  si.round_off,
  si.net_total,
  si.cancelled_value,
  si.effective_total,
  si.status,
  -- The digits of the bill number, as a number.
  nullif(regexp_replace(si.doc_no, '\D', '', 'g'), '')::bigint as doc_seq
from public.sales_invoice si
join public.party p       on p.id  = si.party_id
join public.route rt      on rt.id = p.route_id
left join public.master_group mg on mg.id = si.master_group_id
left join public.app_user u   on u.id = si.created_by
left join public.sales_order so on so.id = si.order_id
left join public.app_user rep on rep.id = so.created_by
where not si.is_opening;

create or replace view public.v_sales_register_lines as
select
  sil.id                     as line_id,
  si.id                      as invoice_id,
  si.doc_no,
  si.invoice_date,
  si.status,

  p.code                     as party_code,
  p.name                     as party_name,
  rt.name                    as route_name,
  mg.code                    as master_code,
  mg.name                    as master_name,
  rep.full_name              as rep_name,
  u.full_name                as created_by_name,

  pr.id                      as product_id,
  pr.code                    as product_code,
  pr.name                    as product_name,
  pg.name                    as group_name,
  pr.base_uom,
  pr.pack_uom,
  -- The product's carton size from the master, NOT sil.pack_size, which is
  -- this line's unit multiplier. See 034 for the whole reasoning.
  pr.pack_size,

  (sil.qty_base - sil.qty_cancelled_base)          as qty_base,
  sil.uom                                          as billed_uom,
  sil.pack_size                                    as billed_pack_size,
  sil.rate,
  (sil.effective_amount
     - round(sil.effective_amount * sil.qty_cancelled_base
             / nullif(sil.qty_base, 0), 2))        as net_amount,
  -- Same number as on the bill row, so the two sheets of the download filter
  -- on exactly the same thing.
  nullif(regexp_replace(si.doc_no, '\D', '', 'g'), '')::bigint as doc_seq
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

alter view public.v_sales_register       set (security_invoker = true);
alter view public.v_sales_register_lines set (security_invoker = true);

comment on view public.v_sales_register is
  'One row per bill for the sales register. doc_seq is the bill number as a
   number, so a range can be filtered on the server rather than after the
   fetch.';

notify pgrst, 'reload schema';
