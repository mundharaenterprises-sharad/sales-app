-- =============================================================================
-- 030_discount_where_clause.sql
--
-- Run this in the Supabase SQL Editor. Committing it to git does nothing to
-- the database.
--
-- Fixes "UPDATE requires a WHERE clause" when taking an order.
--
-- 029 works out each line's discount by updating every row of a temporary
-- staging table — deliberately every row, since every line needs the
-- calculation. Three of those statements therefore had no WHERE clause.
--
-- Supabase runs with a safety net (supautils' safe-update) that refuses an
-- UPDATE or DELETE with no WHERE at all, because the overwhelming majority of
-- those are somebody about to wipe a table by accident. It does not care what
-- the table is, and a temporary one built inside a function is no exception.
-- A plain local Postgres has no such net, which is why the test suite was
-- perfectly happy and the live database was not.
--
-- The fix is `where true`: it says the same thing, out loud. Nothing about
-- what the function computes changes.
--
-- Safe to run twice.
-- =============================================================================

create or replace function app.order_line_discounts()
returns void
language plpgsql
as $$
begin
  -- Fill in whichever of the pair was not given, on the temp table the two
  -- order functions both build. Kept in one place so they cannot drift.
  --
  -- `where true` on each statement is not decoration. Every row is meant to be
  -- updated, and saying so explicitly is what distinguishes "I mean all of
  -- them" from "I forgot the WHERE" — a distinction the database enforces and
  -- cannot make for us.
  execute $q$
    alter table pg_temp._ord_stage
      add column if not exists gross numeric(14,2);

    update pg_temp._ord_stage
       set gross = round(qty * coalesce(rate, 0), 2)
     where true;

    update pg_temp._ord_stage
       set line_discount_amount =
             case
               when line_discount_amount is not null then round(line_discount_amount, 2)
               when line_discount_pct is not null
                 then round(gross * line_discount_pct / 100, 2)
               else 0
             end
     where true;

    update pg_temp._ord_stage
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

comment on function app.order_line_discounts() is
  'Fills in the missing half of each line''s discount pair on pg_temp._ord_stage.
   Every UPDATE carries an explicit `where true`: Supabase refuses a WHERE-less
   UPDATE outright, whatever the table.';

-- PostgREST caches which functions exist. Without this the app can keep
-- getting the old error for up to a minute after the fix is in place.
notify pgrst, 'reload schema';
