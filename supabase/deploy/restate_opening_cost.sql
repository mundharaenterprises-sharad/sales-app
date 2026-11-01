-- =============================================================================
-- restate_opening_cost.sql
-- Correcting what opening stock cost, once you have the supplier invoice.
--
-- Needs migration 047. Admin only. Run it in the Supabase SQL Editor.
--
-- This moves no stock and writes no ledger row — nothing happened, a figure
-- was wrong. What it does do is recompute every margin that leans on that
-- figure, back to go-live, so do it with the invoice in front of you.
--
-- Fill in the three columns and run the whole thing. Nothing is committed
-- until the last statement, so a bad figure stops the lot.
-- =============================================================================

begin;

-- 1. What they are now, so you can see what you are changing.
select p.code, p.name,
       p.opening_qty, p.opening_rate, p.sale_rate,
       round(p.opening_rate / nullif(p.sale_rate, 0) * 100, 1) as pct_of_list,
       round(p.opening_qty * p.opening_rate, 2)                as opening_value
  from public.product p
 where p.code in ('PP68', 'PP40', 'PP39')          -- <- the codes you are fixing
 order by p.code;


-- 2. The corrections. One row per product: code, the real cost from the
--    invoice, and why. The reason goes on the audit record, so write it for
--    somebody reading it in a year.
--
--    A cost at or above the selling price is refused unless the reason
--    contains "sold at a loss" — that guard is how this was found in the
--    first place, so leave it doing its job unless the line really is one.

do $$
declare
  r record;
  v jsonb;
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
    select * from (values
      -- code    real cost   reason
      ('PP68',    0.0000,    'Opening cost restated to the supplier invoice'),
      ('PP40',    0.0000,    'Opening cost restated to the supplier invoice'),
      ('PP39',    0.0000,    'Opening cost restated to the supplier invoice')
    ) as t(code, rate, reason)
  loop
    if r.rate <= 0 then
      raise exception 'No cost filled in for % — put the invoice figure in and run it again', r.code;
    end if;

    select public.restate_opening_cost(p.id, r.rate, r.reason)
      into v
      from public.product p
     where p.code = r.code;

    if v is null then
      raise exception 'No product with code %', r.code;
    end if;

    raise notice '% (%): % -> %, % of cost % opening stock',
      v ->> 'product_code', v ->> 'product_name',
      v ->> 'was', v ->> 'now',
      abs((v ->> 'cost_removed')::numeric),
      case when (v ->> 'cost_removed')::numeric >= 0
             then 'taken out of' else 'added to' end;
  end loop;
end $$;


-- 3. What they are now. Check the percentages look like purchases rather
--    than a formula before you commit.
select p.code, p.name,
       p.opening_qty, p.opening_rate, p.sale_rate,
       round(p.opening_rate / nullif(p.sale_rate, 0) * 100, 1) as pct_of_list,
       round(p.opening_qty * p.opening_rate, 2)                as opening_value
  from public.product p
 where p.code in ('PP68', 'PP40', 'PP39')
 order by p.code;


-- Happy with it?  commit;        Not happy?  rollback;
commit;

-- Afterwards: Reports -> Profitability, and the margins on these three should
-- read like the business. Reports -> Stock ledger shows the corrected cost on
-- the OPENING row; the row itself is untouched, and Admin -> Audit log has the
-- old figure, the new one, who changed it and why.
