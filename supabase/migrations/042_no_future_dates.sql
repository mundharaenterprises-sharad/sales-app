-- =============================================================================
-- 042_no_future_dates.sql
-- Nothing can be dated later than today.
--
-- Run this in the Supabase SQL Editor. Committing it to git does nothing to
-- the database.
--
-- "Don't allow post dated entries for anything — sales, purchases, payments,
-- nothing." Until now nothing stopped one. A bill keyed as 11/12 instead of
-- 11/02 lands eleven months ahead, and once there it is quietly wrong in a way
-- that is hard to see: it misses every month-end total, it never appears in
-- the ageing (nothing is overdue that has not been raised yet), and the stock
-- it moved has already left the building. Somebody finds it a year later.
--
-- BACK-DATING IS STILL ALLOWED, deliberately. A day of collections keyed in
-- the following morning, a purchase entered when the paperwork arrives, the
-- opening documents dated before go-live — all normal, all past. Only the
-- future is closed.
--
-- WHY A TRIGGER AND NOT A CHECK CONSTRAINT. A check constraint has to be
-- immutable, and "later than today" is not: a row that satisfies it today
-- fails it tomorrow, which breaks a dump and reload and would make the live
-- database refuse to restore. A trigger is evaluated when the row is written,
-- which is the moment the question is actually being asked.
--
-- WHY NOT ONLY IN THE POSTING FUNCTIONS. That would cover every path there is
-- today and none of the ones added later. On the table it holds whatever route
-- the row takes.
--
-- ONE DATE IS LEFT FREE: `receipt.instrument_date`. A post-dated cheque is a
-- real thing somebody is handed, and if cheque handling is ever switched on
-- that date legitimately runs ahead of today. It is the instrument's own date,
-- not the date of the entry, and `receipt_date` — the one that decides which
-- day's collections a payment counts in — is guarded.
--
-- Safe to run twice. Nothing already stored is touched or re-checked; if a
-- future-dated document is already in there this does not find it. Run
-- `supabase/deploy/find_future_dates.sql` for that.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- The guard
-- -----------------------------------------------------------------------------
-- One function for every table. It reads the column out of `to_jsonb(new)`
-- rather than naming it, because plpgsql resolves a `new.<column>` reference
-- against the triggering table and a shared function that named one would fail
-- on every table that did not have it — bug #2, learned on the totals checks.

create or replace function app.tg_no_future_date()
returns trigger
language plpgsql
as $$
declare
  v_col  text := tg_argv[0];
  v_noun text := tg_argv[1];
  v_new  date;
  v_old  date;
begin
  v_new := nullif(to_jsonb(new) ->> v_col, '')::date;

  -- No date given: not this trigger's business. A column that must be filled
  -- in says so with NOT NULL.
  if v_new is null then
    return new;
  end if;

  -- On an update, only a date that actually moved is re-checked. Cancelling a
  -- document from last year must not be refused because of when it was raised.
  if tg_op = 'UPDATE' then
    v_old := nullif(to_jsonb(old) ->> v_col, '')::date;
    if v_old is not distinct from v_new then
      return new;
    end if;
  end if;

  if v_new > current_date then
    raise exception '% cannot be dated in the future. % is later than today, %.',
      v_noun,
      to_char(v_new, 'FMDD Mon YYYY'),
      to_char(current_date, 'FMDD Mon YYYY')
      using errcode = 'SA004';
  end if;

  return new;
end;
$$;

comment on function app.tg_no_future_date() is
  'Refuses a row whose date is later than today. The column and the noun for
   the message come from the trigger arguments, so one function serves every
   table.';


-- -----------------------------------------------------------------------------
-- Applied to every date that records when something happened
-- -----------------------------------------------------------------------------

do $$
declare
  r record;
begin
  for r in
    select * from (values
      ('sales_invoice',        'invoice_date',         'A bill'),
      ('sales_order',          'order_date',           'An order'),
      ('purchase',             'purchase_date',        'A purchase'),
      ('purchase',             'supplier_bill_date',   'A supplier''s bill'),
      ('receipt',              'receipt_date',         'A payment'),
      ('sales_return',         'return_date',          'A return'),
      ('invoice_cancellation', 'cancellation_date',    'A cancellation'),
      ('stock_adjustment',     'adjustment_date',      'A stock adjustment'),
      ('stock_ledger',         'movement_date',        'A stock movement'),
      ('party',                'opening_balance_date', 'An opening balance'),
      ('product',              'opening_date',         'Opening stock')
    ) as t(tbl, col, noun)
  loop
    -- Skip anything a future migration has renamed or dropped, rather than
    -- failing the whole file.
    if not exists (select 1 from information_schema.columns
                    where table_schema = 'public'
                      and table_name = r.tbl
                      and column_name = r.col) then
      raise notice 'skipping %.% — not present', r.tbl, r.col;
      continue;
    end if;

    execute format('drop trigger if exists %I on public.%I',
                   r.tbl || '_' || r.col || '_not_future', r.tbl);

    execute format(
      'create trigger %I before insert or update on public.%I
         for each row execute function app.tg_no_future_date(%L, %L)',
      r.tbl || '_' || r.col || '_not_future', r.tbl, r.col, r.noun);
  end loop;
end $$;

notify pgrst, 'reload schema';
