-- =============================================================================
-- 028_supplier_editing.sql
-- Suppliers can be added and edited in the app, under the same rule as every
-- other master: the code never changes.
--
-- Until now a supplier could only arrive through the import workbook. That is
-- fine for a list loaded once at go-live and wrong for a list that grows as
-- new principals and local suppliers turn up, so the app gets a screen.
--
-- Codes stay fixed for the same reason they do on parties and products: the
-- code is what a spreadsheet, an import and a person refer to. Renaming one
-- quietly breaks every re-import that mentions the old name.
--
-- Run this file once in the Supabase SQL Editor. Safe to run more than once.
-- =============================================================================

create or replace function app.supplier_guard()
returns trigger
language plpgsql
as $$
begin
  if new.code is distinct from old.code then
    raise exception 'A supplier code cannot be changed (% stays %).', old.name, old.code
      using errcode = 'SA004';
  end if;
  return new;
end;
$$;

drop trigger if exists supplier_guard on public.supplier;
create trigger supplier_guard
  before update on public.supplier
  for each row execute function app.supplier_guard();


-- -----------------------------------------------------------------------------
-- What the Suppliers screen reads
--
-- The purchase count is there so that switching one off is an informed
-- decision: a supplier with history is never deleted, only stopped from being
-- offered on new purchases.
-- -----------------------------------------------------------------------------

drop view if exists public.v_supplier_list;

create view public.v_supplier_list as
select
  s.*,
  coalesce(p.purchases, 0)   as purchase_count,
  coalesce(p.bought, 0)      as bought_value,
  p.last_purchase_date
from public.supplier s
left join (
  select supplier_id,
         count(*)                          as purchases,
         sum(net_total) filter (where status <> 'CANCELLED') as bought,
         max(purchase_date)                as last_purchase_date
    from public.purchase
   group by supplier_id
) p on p.supplier_id = s.id;

alter view public.v_supplier_list set (security_invoker = true);
grant select on public.v_supplier_list to authenticated;
