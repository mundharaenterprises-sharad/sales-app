-- =============================================================================
-- 041_purchase_discounts.sql
-- A discount on a purchase — per line, and on the whole bill.
--
-- Run this in the Supabase SQL Editor. Committing it to git does nothing to
-- the database.
--
-- Sales have had both kinds of discount since 029; purchases had neither. A
-- scheme discount from Parle or Current had to be absorbed by typing a lower
-- rate than the supplier's bill actually shows, which makes the entry disagree
-- with the paper and loses the fact that a discount was given at all.
--
-- Stored the same way as on the sales side, so nothing has to be translated
-- between them: a line may carry a percentage, an amount, or neither, and
-- whichever was not given is worked out and stored beside it.
--
-- TWO THINGS HERE ARE CHOICES, NOT ARITHMETIC.
--
-- 1. THE DISCOUNT LOWERS THE RECORDED COST OF THE STOCK. He asked for this
--    directly. A carton bought at 1,900 with 5% off is costed at 1,805,
--    because that is what was paid, so that is what the stock is worth and
--    what any future margin is measured against. `stock_ledger.rate` takes the
--    NET figure per base unit, and `cancel_purchase` takes the same figure back
--    out — both read `purchase_line.net_amount`, so they cannot disagree, which
--    matters because cancelling at the gross rate would leave stock value
--    behind after the goods had gone.
--
-- 2. A BILL-WISE DISCOUNT COMES OFF THE GOODS, NOT OFF THE FREIGHT. The
--    supplier is not discounting the transporter. So: goods, less the
--    discounts, then other charges on top. 10,000 less 5% is 9,500, plus 300
--    freight is 9,800.
--
-- `other_charges` is still NOT spread into stock cost. That is how it has
-- always worked here and is left alone on purpose: freight on a mixed load
-- cannot be attributed to one product honestly.
--
-- Safe to run twice. Nothing already stored changes — existing purchases take
-- a zero discount, and their net totals already equal gross plus charges.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Columns, mirroring sales_invoice_line deliberately
-- -----------------------------------------------------------------------------

alter table public.purchase_line
  add column if not exists line_discount_pct       numeric(7,4),
  add column if not exists line_discount_amount    numeric(14,2) not null default 0,
  add column if not exists allocated_bill_discount numeric(14,2) not null default 0;

alter table public.purchase_line
  drop constraint if exists purchase_line_discount_pct_range;
alter table public.purchase_line
  add constraint purchase_line_discount_pct_range
  check (line_discount_pct is null or line_discount_pct between 0 and 100);

alter table public.purchase_line
  drop constraint if exists purchase_line_discount_not_negative;
alter table public.purchase_line
  add constraint purchase_line_discount_not_negative
  check (line_discount_amount >= 0 and allocated_bill_discount >= 0);

-- The two discounts together cannot exceed the line they come off. Written
-- against the expression rather than against the generated `amount` column,
-- because a check constraint may not read a generated column.
alter table public.purchase_line
  drop constraint if exists purchase_line_discount_not_over;
alter table public.purchase_line
  add constraint purchase_line_discount_not_over
  check (line_discount_amount + allocated_bill_discount <= round(qty * rate, 2));

-- What the line actually cost: the figure stock is valued at.
alter table public.purchase_line
  add column if not exists net_amount numeric(14,2)
  generated always as
    (round(qty * rate, 2) - line_discount_amount - allocated_bill_discount) stored;

alter table public.purchase
  add column if not exists line_discount_total  numeric(14,2) not null default 0,
  add column if not exists bill_discount_amount numeric(14,2) not null default 0;

alter table public.purchase
  drop constraint if exists purchase_discounts_not_negative;
alter table public.purchase
  add constraint purchase_discounts_not_negative
  check (line_discount_total >= 0 and bill_discount_amount >= 0);


-- -----------------------------------------------------------------------------
-- 2. Spreading one amount across lines so the parts sum to the whole
-- -----------------------------------------------------------------------------
-- Largest remainder: give every line its exact share truncated to the paisa,
-- then hand the leftover paisas out one each, to the lines that lost the most
-- in the truncation. Ten rupees across three lines is 3.34 / 3.33 / 3.33 and
-- never 9.99.
--
-- The sales engine has had this inline since 029. It is a pure function here
-- rather than a copy of that SQL, and the purchase discount suite asserts the two
-- agree on the same inputs — the billing engine is not being rewritten for
-- tidiness while it is in daily use.

create or replace function app.spread_amount(
  p_amount  numeric,
  p_weights jsonb
)
returns table (line_no int, alloc numeric)
language sql
immutable
as $$
  with base as (
    select w.line_no, greatest(coalesce(w.net, 0), 0) as net
      from jsonb_to_recordset(coalesce(p_weights, '[]'::jsonb))
             as w(line_no int, net numeric)
  ),
  tot as (select coalesce(sum(net), 0) as s from base),
  exact as (
    select b.line_no, b.net, t.s,
           case when t.s = 0 then 0
                else coalesce(p_amount, 0) * b.net / t.s end as ex
      from base b cross join tot t
  ),
  floored as (
    select e.*,
           trunc(e.ex * 100) / 100        as flo,
           e.ex - trunc(e.ex * 100) / 100 as rem
      from exact e
  ),
  ranked as (
    select f.*,
           row_number() over (order by f.rem desc, f.net desc, f.line_no) as rk,
           -- The leftover paisas, and never more than one per line. Without
           -- the clamp, weights that are all zero make every line's exact
           -- share 0 while the whole amount is still "left over", and the
           -- function hands out a paisa per line for an amount it cannot
           -- place. The caller is expected to refuse a discount with nothing
           -- to weigh it against; this makes the function safe on its own.
           case when f.s = 0 then 0
                else least(
                       greatest(round((coalesce(p_amount, 0)
                                       - sum(f.flo) over ()) * 100)::int, 0),
                       count(*) over ())
           end as spare
      from floored f
  )
  select r.line_no,
         (r.flo + case when r.rk <= r.spare then 0.01 else 0 end)::numeric(14,2)
    from ranked r;
$$;

comment on function app.spread_amount(numeric, jsonb) is
  'Splits one amount across weighted lines by largest remainder, so the parts
   sum to the whole exactly. Weights are [{"line_no":1,"net":1000}, ...].';


-- -----------------------------------------------------------------------------
-- 3. Filling in whichever half of the discount pair was not given
-- -----------------------------------------------------------------------------
-- The same job app.order_line_discounts() does for orders, against the temp
-- table post_purchase builds. Enter the percentage or the rupees; the other one
-- is worked out and both are stored, so the paper can be reconciled either way.

create or replace function app.purchase_line_discounts()
returns void
language plpgsql
as $$
begin
  execute $q$
    alter table pg_temp._pur_lines
      add column if not exists gross numeric(14,2);
    update pg_temp._pur_lines
       set gross = round(qty * coalesce(rate, 0), 2)
     where true;

    update pg_temp._pur_lines
       set line_discount_amount =
             case
               when line_discount_amount is not null then round(line_discount_amount, 2)
               when line_discount_pct is not null
                 then round(gross * line_discount_pct / 100, 2)
               else 0
             end
     where true;

    update pg_temp._pur_lines
       set line_discount_pct =
             case
               when line_discount_pct is not null then line_discount_pct
               when gross > 0 and line_discount_amount > 0
                 then round(line_discount_amount * 100 / gross, 4)
               else line_discount_pct
             end
     where true;
  $q$;
end;
$$;


-- -----------------------------------------------------------------------------
-- 4. The header-against-lines check, which now has more to check
-- -----------------------------------------------------------------------------
-- Still a DEFERRED constraint trigger, so it fires at COMMIT and not on the
-- insert. Anything testing it has to commit or force it; see bug #10.

create or replace function app.check_purchase_totals(p_purchase_id uuid)
returns void
language plpgsql
as $$
declare
  v_head      public.purchase%rowtype;
  v_gross     numeric(14,2);
  v_line_disc numeric(14,2);
  v_bill_disc numeric(14,2);
  v_expected  numeric(14,2);
begin
  select * into v_head from public.purchase where id = p_purchase_id;
  if not found then
    return;  -- header removed in the same transaction; nothing to verify
  end if;

  select coalesce(sum(amount), 0),
         coalesce(sum(line_discount_amount), 0),
         coalesce(sum(allocated_bill_discount), 0)
    into v_gross, v_line_disc, v_bill_disc
    from public.purchase_line where purchase_id = p_purchase_id;

  if v_head.gross_total <> v_gross then
    raise exception
      'Purchase % gross_total is % but its lines sum to %',
      v_head.doc_no, v_head.gross_total, v_gross
      using errcode = 'check_violation';
  end if;

  if v_head.line_discount_total <> v_line_disc then
    raise exception
      'Purchase % line discount is % but its lines discount %',
      v_head.doc_no, v_head.line_discount_total, v_line_disc
      using errcode = 'check_violation';
  end if;

  -- The bill discount has to be fully accounted for on the lines, or it is
  -- money off the total that no product carries and stock cost is overstated.
  if v_head.bill_discount_amount <> v_bill_disc then
    raise exception
      'Purchase % bill discount is % but % is allocated to its lines',
      v_head.doc_no, v_head.bill_discount_amount, v_bill_disc
      using errcode = 'check_violation';
  end if;

  v_expected := v_head.gross_total
              - v_head.line_discount_total
              - v_head.bill_discount_amount
              + v_head.other_charges;

  if v_head.net_total <> v_expected then
    raise exception
      'Purchase % net_total % does not equal goods % less discounts % and % plus charges %',
      v_head.doc_no, v_head.net_total, v_head.gross_total,
      v_head.line_discount_total, v_head.bill_discount_amount, v_head.other_charges
      using errcode = 'check_violation';
  end if;
end;
$$;


-- -----------------------------------------------------------------------------
-- 5. Posting a purchase
-- -----------------------------------------------------------------------------

create or replace function public.post_purchase(
  p_supplier_id          uuid,
  p_purchase_date        date,
  p_lines                jsonb,
  p_other_charges        numeric default 0,
  p_supplier_bill_no     text    default null,
  p_supplier_bill_date   date    default null,
  p_remarks              text    default null,
  p_bill_discount_amount numeric default 0,
  p_bill_discount_pct    numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user      uuid := app.require_back_office();
  v_doc_no    text;
  v_id        uuid;
  v_gross     numeric(14,2);
  v_line_disc numeric(14,2);
  v_bill_disc numeric(14,2);
  v_charges   numeric(14,2) := round(coalesce(p_other_charges, 0), 2);
  v_net       numeric(14,2);
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'A purchase needs at least one line' using errcode = 'SA004';
  end if;

  drop table if exists _pur_lines;
  create temp table _pur_lines on commit drop as
  select
    row_number() over ()                        as line_no,
    x.product_id,
    x.uom,
    -- Rounded to the four decimal places the columns hold, before anything is
    -- totalled from them. See 039 and 040.
    round(x.qty, 4)                             as qty,
    app.pack_size_for(x.product_id, x.uom)      as pack_size,
    round(x.rate, 4)                            as rate,
    x.line_discount_pct,
    x.line_discount_amount
  from jsonb_to_recordset(p_lines)
       as x(product_id           uuid,
            uom                  app.uom_type,
            qty                  numeric,
            rate                 numeric,
            line_discount_pct    numeric,
            line_discount_amount numeric);

  if exists (select 1 from pg_temp._pur_lines where qty is null or qty <= 0) then
    raise exception 'Every purchase line needs a quantity above zero'
      using errcode = 'SA004';
  end if;

  if exists (select 1 from pg_temp._pur_lines where rate is null or rate < 0) then
    raise exception 'Every purchase line needs a rate' using errcode = 'SA004';
  end if;

  if exists (select 1 from pg_temp._pur_lines
              where line_discount_pct is not null
                and (line_discount_pct < 0 or line_discount_pct > 100)) then
    raise exception 'A line discount has to be between 0 and 100 per cent'
      using errcode = 'SA004';
  end if;

  perform app.purchase_line_discounts();

  if exists (select 1 from pg_temp._pur_lines
              where line_discount_amount > gross) then
    raise exception 'A line discount is larger than the line it comes off'
      using errcode = 'SA004';
  end if;

  select coalesce(sum(gross), 0), coalesce(sum(line_discount_amount), 0)
    into v_gross, v_line_disc
    from pg_temp._pur_lines;

  -- An amount beats a percentage when both are sent, the same way round as on
  -- a sales bill.
  v_bill_disc := coalesce(
    nullif(round(coalesce(p_bill_discount_amount, 0), 2), 0),
    round((v_gross - v_line_disc) * coalesce(p_bill_discount_pct, 0) / 100, 2),
    0);

  if v_bill_disc < 0 then
    raise exception 'A discount cannot be negative' using errcode = 'SA004';
  end if;

  if v_bill_disc > (v_gross - v_line_disc) then
    raise exception
      'The bill discount of % is larger than the goods on this purchase (%)',
      v_bill_disc, v_gross - v_line_disc
      using errcode = 'SA004';
  end if;

  -- Spread across the lines in proportion to what each one is worth after its
  -- own discount, so every product carries its share of the cost reduction.
  drop table if exists _pur_alloc;
  create temp table _pur_alloc on commit drop as
  select s.line_no, s.alloc
    from app.spread_amount(
           v_bill_disc,
           (select coalesce(jsonb_agg(jsonb_build_object(
                     'line_no', line_no,
                     'net', gross - line_discount_amount)), '[]'::jsonb)
              from pg_temp._pur_lines)) s;

  v_net := v_gross - v_line_disc - v_bill_disc + v_charges;

  v_doc_no := app.next_doc_no('PURCHASE');

  insert into public.purchase
    (doc_no, supplier_id, purchase_date, supplier_bill_no, supplier_bill_date,
     gross_total, line_discount_total, bill_discount_amount,
     other_charges, net_total, remarks, created_by)
  values
    (v_doc_no, p_supplier_id, p_purchase_date, p_supplier_bill_no,
     p_supplier_bill_date, v_gross, v_line_disc, v_bill_disc,
     v_charges, v_net, p_remarks, v_user)
  returning id into v_id;

  insert into public.purchase_line
    (purchase_id, line_no, product_id, uom, qty, pack_size, rate,
     line_discount_pct, line_discount_amount, allocated_bill_discount)
  select v_id, pl.line_no, pl.product_id, pl.uom, pl.qty, pl.pack_size, pl.rate,
         pl.line_discount_pct, pl.line_discount_amount, coalesce(a.alloc, 0)
    from pg_temp._pur_lines pl
    left join pg_temp._pur_alloc a on a.line_no = pl.line_no;

  -- Stock in, at what it cost after the discount — his instruction. Reads
  -- net_amount, exactly as cancel_purchase does, so the two are symmetric by
  -- construction rather than by my remembering to change both.
  insert into public.stock_ledger
    (product_id, movement_date, qty_in, rate, doc_type, doc_id, doc_line_id, created_by)
  select pl.product_id, p_purchase_date, pl.qty_base,
         case when pl.qty_base > 0 then round(pl.net_amount / pl.qty_base, 4) else 0 end,
         'PURCHASE', v_id, pl.id, v_user
    from public.purchase_line pl
   where pl.purchase_id = v_id;

  return jsonb_build_object(
    'purchase_id', v_id, 'doc_no', v_doc_no,
    'gross_total', v_gross, 'line_discount_total', v_line_disc,
    'bill_discount_amount', v_bill_disc, 'other_charges', v_charges,
    'net_total', v_net);
end;
$$;

-- The seven-argument version has to go, or every call is ambiguous — bug #5.
drop function if exists public.post_purchase(uuid, date, jsonb, numeric, text, date, text);

revoke all on function
  public.post_purchase(uuid,date,jsonb,numeric,text,date,text,numeric,numeric)
  from public, anon;
grant execute on function
  public.post_purchase(uuid,date,jsonb,numeric,text,date,text,numeric,numeric)
  to authenticated;

comment on function
  public.post_purchase(uuid,date,jsonb,numeric,text,date,text,numeric,numeric) is
  'Records goods in and what they cost. Discounts may be per line or on the
   whole bill; a bill discount is spread across the lines so each product
   carries its share. Stock is costed net of discount, and other charges are
   added after the discount and are not capitalised into stock cost.';


-- -----------------------------------------------------------------------------
-- 6. Cancelling one takes the stock back out at the same cost it came in at
-- -----------------------------------------------------------------------------
-- The only change from 027 is `pl.net_amount` in place of `pl.amount`. Left as
-- a whole function rather than a patch so the version in the database is the
-- version in one file.

create or replace function public.cancel_purchase(
  p_purchase_id uuid,
  p_reason      text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user  uuid := app.require_back_office();
  v_pur   public.purchase%rowtype;
  v_short jsonb;
begin
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'A cancellation needs a reason' using errcode = 'SA004';
  end if;

  select * into v_pur from public.purchase where id = p_purchase_id for update;

  if not found then
    raise exception 'That purchase does not exist' using errcode = 'SA005';
  end if;

  if v_pur.status <> 'ACTIVE' then
    raise exception '% is already cancelled', v_pur.doc_no using errcode = 'SA002';
  end if;

  -- Locked in product order, the same order every other stock operation uses,
  -- so two of them running at once queue instead of deadlocking.
  perform 1
     from public.product_stock ps
    where ps.product_id in (select distinct pl.product_id
                              from public.purchase_line pl
                             where pl.purchase_id = p_purchase_id)
    order by ps.product_id
      for update;

  select coalesce(jsonb_agg(jsonb_build_object(
           'product', pr.name, 'taking_back', x.qty, 'in_stock', ps.on_hand)), '[]'::jsonb)
    into v_short
    from (select pl.product_id, sum(pl.qty_base) as qty
            from public.purchase_line pl
           where pl.purchase_id = p_purchase_id
           group by pl.product_id) x
    join public.product_stock ps on ps.product_id = x.product_id
    join public.product pr       on pr.id = x.product_id
   where ps.on_hand < x.qty;

  if jsonb_array_length(v_short) > 0 then
    raise exception
      'Some of what this purchase brought in has already gone out, so it cannot be cancelled.'
      using errcode = 'SA001', detail = v_short::text;
  end if;

  insert into public.stock_ledger
    (product_id, movement_date, qty_out, rate, doc_type, doc_id, doc_line_id, created_by)
  select pl.product_id, current_date, pl.qty_base,
         case when pl.qty_base > 0 then round(pl.net_amount / pl.qty_base, 4) else 0 end,
         'PURCHASE_CANCEL', v_pur.id, pl.id, v_user
    from public.purchase_line pl
   where pl.purchase_id = p_purchase_id;

  update public.purchase
     set status        = 'CANCELLED',
         cancelled_at  = now(),
         cancelled_by  = v_user,
         cancel_reason = btrim(p_reason)
   where id = p_purchase_id;

  return jsonb_build_object(
    'purchase_id', p_purchase_id, 'doc_no', v_pur.doc_no, 'net_total', v_pur.net_total);
end;
$$;


-- -----------------------------------------------------------------------------
-- 7. The screens
-- -----------------------------------------------------------------------------
-- Appended at the end of each view rather than inserted next to gross_total,
-- because `create or replace view` cannot move or insert a column and these
-- two have dependants — bug #9. Column order in a view is cosmetic; the app
-- selects by name.

create or replace view public.v_purchase_list as
select
  pu.id            as purchase_id,
  pu.doc_no,
  pu.purchase_date,
  pu.supplier_id,
  s.code           as supplier_code,
  s.name           as supplier_name,
  pu.supplier_bill_no,
  pu.supplier_bill_date,
  pu.master_group_id,
  mg.code          as master_code,
  mg.name          as master_name,
  pu.gross_total,
  pu.other_charges,
  pu.net_total,
  pu.status,
  pu.cancel_reason,
  pu.remarks,
  u.full_name      as created_by_name,
  pu.created_at,
  coalesce(l.lines, 0) as line_count,
  coalesce(l.qty_base, 0) as qty_base,
  pu.line_discount_total,
  pu.bill_discount_amount,
  (pu.line_discount_total + pu.bill_discount_amount) as discount_total
from public.purchase pu
join public.supplier s on s.id = pu.supplier_id
left join public.master_group mg on mg.id = pu.master_group_id
left join public.app_user u on u.id = pu.created_by
left join (
  select purchase_id, count(*) as lines, sum(qty_base) as qty_base
    from public.purchase_line
   group by purchase_id
) l on l.purchase_id = pu.id;

create or replace view public.v_purchase_register as
select
  pu.id        as purchase_id,
  pu.doc_no,
  pu.purchase_date,
  s.code       as supplier_code,
  s.name       as supplier_name,
  pu.supplier_bill_no,
  pu.supplier_bill_date,
  pu.gross_total,
  pu.other_charges,
  pu.net_total,
  pu.status,
  u.full_name  as created_by_name,
  pu.line_discount_total,
  pu.bill_discount_amount,
  (pu.line_discount_total + pu.bill_discount_amount) as discount_total
from public.purchase pu
join public.supplier s on s.id = pu.supplier_id
left join public.app_user u on u.id = pu.created_by;

alter view public.v_purchase_list     set (security_invoker = true);
alter view public.v_purchase_register set (security_invoker = true);

notify pgrst, 'reload schema';
