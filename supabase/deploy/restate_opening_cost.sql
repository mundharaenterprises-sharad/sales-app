-- =============================================================================
-- restate_opening_cost.sql
-- Correcting what opening stock cost, once you have the supplier invoice.
--
-- Needs migration 047. Run the WHOLE thing in the Supabase SQL Editor, in one
-- go. It is one request: if anything in it is refused, nothing is changed.
--
-- This moves no stock and writes no ledger row — nothing happened, a figure
-- was wrong. What it does do is recompute every margin that leans on that
-- figure, back to go-live. That is the point, and it is why it is Admin only.
--
-- FILLED IN with the three costs Sharad gave on 1 November 2026, each one as
-- it appears on the supplier bill, PER CARTON:
--
--   PP68  Parle G Rs10            1,120.73
--   PP39  Happy Happy 135gm       1,415.66
--   PP40  Happy Happy 30gm        1,698.98
--
-- `product.opening_rate` is per BASE unit, so the script divides each figure
-- by that product's OWN `pack_size` rather than by a number typed in here.
-- Enter the figure in the unit the bill uses and say which unit that is;
-- nothing is assumed about how many pieces are in a carton.
--
-- The table it returns at the end is the record of what it did: the carton
-- rate, the per-piece cost derived from it, what the opening cost was, what it
-- is now, and the cost taken out of opening stock. The SQL Editor shows only
-- the last result and never shows notices, so that table is the output.
--
-- Running it again with the same figures changes nothing and is harmless.
-- A wrong figure is corrected by running it again with the right one.
-- =============================================================================

drop table if exists restated;
create temp table restated (
  code        text,
  name        text,
  pack_uom    text,
  pack_size   numeric,
  bill_rate   numeric,
  unit        text,
  per_base    numeric,
  was         numeric,
  now_        numeric,
  cost_change numeric
);

do $$
declare
  r       record;
  v       jsonb;
  v_pr    public.product%rowtype;
  v_base  numeric;
  v_admin uuid;
begin
  -- The SQL Editor is not signed in as anybody, and this function is Admin
  -- only — and records who made the change. So act as the Admin account.
  select id into v_admin
    from public.app_user
   where role = 'ADMIN' and is_active
   order by created_at
   limit 1;

  if v_admin is null then
    raise exception 'No active Admin user to record this against';
  end if;

  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  for r in
    -- code, the figure off the supplier bill, the unit that figure is in
    -- ('PACK' for a carton rate, 'BASE' for a per-piece rate), and why.
    -- The reason goes on the audit record, so write it for somebody reading
    -- it in a year.
    --
    -- A cost at or above the item's own selling price is refused unless the
    -- reason contains "sold at a loss". That guard is how this was found in
    -- the first place — leave it doing its job.
    select * from (values
      -- code     bill rate    unit     reason
      ('PP68',    1120.73,     'PACK',  'Opening cost restated to the supplier invoice — 1120.73 per carton'),
      ('PP39',    1415.66,     'PACK',  'Opening cost restated to the supplier invoice — 1415.66 per carton'),
      ('PP40',    1698.98,     'PACK',  'Opening cost restated to the supplier invoice — 1698.98 per carton')
    ) as t(code, bill_rate, unit, reason)
  loop
    select * into v_pr from public.product where code = r.code;

    if not found then
      raise exception 'No product with code %', r.code;
    end if;

    if r.unit not in ('PACK', 'BASE') then
      raise exception 'Unit for % must be PACK or BASE, not %', r.code, r.unit;
    end if;

    -- A carton rate on a product with no carton is a figure in the wrong
    -- unit, and dividing by 1 would silently accept it.
    if r.unit = 'PACK' and (v_pr.pack_uom is null or v_pr.pack_size <= 1) then
      raise exception
        '% (%) has no pack unit, so % cannot be a carton rate — enter it as BASE',
        r.code, v_pr.name, r.bill_rate using errcode = 'SA004';
    end if;

    v_base := case when r.unit = 'PACK'
                   then round(r.bill_rate / v_pr.pack_size, 4)
                   else round(r.bill_rate, 4) end;

    v := public.restate_opening_cost(v_pr.id, v_base, r.reason);

    insert into restated values (
      v_pr.code, v_pr.name, v_pr.pack_uom, v_pr.pack_size,
      r.bill_rate, r.unit, v_base,
      (v ->> 'was')::numeric, (v ->> 'now')::numeric,
      (v ->> 'cost_removed')::numeric);
  end loop;
end $$;

-- What it did, and what the three products now look like.
--
-- `last_purchase_cost` is the cross-check, and it is the column to read first.
-- It is the net cost per base unit of the most recent real purchase of that
-- product. If the restated cost lands on it, then the code, the carton rate
-- and the pack size all agree with a supplier bill the app already holds. If
-- it is a long way off — or the product has never been purchased, and it is
-- null — the figure has not been confirmed by anything and is worth a second
-- look before the margins are trusted.

with last_purchase as (
  select distinct on (pl.product_id)
         pl.product_id,
         round(pl.net_amount / nullif(pl.qty_base, 0), 4) as cost_per_base
    from public.purchase_line pl
    join public.purchase pu on pu.id = pl.purchase_id
   where pu.status <> 'CANCELLED'
   order by pl.product_id, pu.purchase_date desc, pu.created_at desc
)
select
  x.code,
  x.name,
  x.bill_rate                                               as bill_rate,
  x.unit                                                    as bill_rate_unit,
  x.pack_size                                               as base_units_per_pack,
  x.per_base                                                as cost_per_base_unit,
  lp.cost_per_base                                          as last_purchase_cost,
  x.was                                                     as opening_cost_was,
  x.now_                                                    as opening_cost_now,
  p.sale_rate,
  round(x.now_ / nullif(p.sale_rate, 0) * 100, 1)           as pct_of_sale_price,
  p.opening_qty,
  round(x.cost_change, 2)                                   as cost_taken_out,
  round(p.opening_qty * x.now_, 2)                          as opening_value_now
from restated x
join public.product p on p.code = x.code
left join last_purchase lp on lp.product_id = p.id
order by x.code;

-- Afterwards: Reports -> Profitability, and the margins on these three should
-- read like the business. Reports -> Stock ledger shows the corrected cost on
-- the OPENING row; the row itself is untouched, and audit_log has the old
-- figure, the new one, who changed it and why.
