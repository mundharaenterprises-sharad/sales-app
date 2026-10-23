-- =============================================================================
-- diagnose_return.sql
--
-- SUPERSEDED, AND KEPT AS A WARNING. Do not reach for this one again.
--
-- It rolls back, so it could never have found the bug it was written to find.
-- The guard that was refusing returns is a DEFERRED constraint trigger: it
-- does not fire on the insert, it fires at COMMIT, and a transaction that is
-- rolled back never commits. This script reported "both halves work on this
-- bill" over and over while the live app was refusing the same bill.
--
-- The fault is in migrations 039 and 040. The test that actually catches it is
-- supabase/tests/023_return_precision_tests.sql, and the thing that makes it
-- work is that it COMMITS.
--
-- Anything that has to test a deferred check must either commit, or force the
-- check with `set constraints all immediate`. A rolled-back diagnostic cannot
-- see this class of failure at all.
--
-- What follows is the original, unchanged.
--
-- Run the WHOLE file in the Supabase SQL Editor. It changes nothing.
--
-- "One of the values is not allowed" is Postgres refusing a value, and it
-- refuses with the name of the rule that was broken — but the app only shows
-- the friendly sentence, so that name never reaches anybody.
--
-- This attempts a return the way the Returns screen does, on your most recent
-- bill, catches whatever comes back, and prints the rule's actual name. Then
-- it rolls the whole thing back, so nothing is written: no return, no stock
-- movement, no credit. The document numbering is not advanced either.
--
-- Send me the last block of output.
-- =============================================================================

begin;

do $$
declare
  v_inv      record;
  v_line     record;
  v_return   jsonb;
  v_state    text;
  v_msg      text;
  v_detail   text;
  v_constraint text;
  v_table    text;
  v_column   text;
begin
  -- Act as a real office user, since every one of these functions checks.
  perform set_config('request.jwt.claim.sub',
    (select id::text from public.app_user
      where role in ('ACCOUNTS', 'ADMIN') and is_active
      order by created_at limit 1), true);

  -- The newest bill that still has something on it that could come back.
  select si.id, si.doc_no, si.invoice_date, si.party_id, si.status,
         si.net_total, si.cancelled_value
    into v_inv
    from public.sales_invoice si
   where si.status <> 'CANCELLED'
     and not si.is_opening
     and exists (select 1 from public.sales_invoice_line l
                  where l.invoice_id = si.id
                    and l.qty_base > l.qty_cancelled_base)
   order by si.invoice_date desc, si.created_at desc
   limit 1;

  if v_inv.id is null then
    raise notice 'No bill found to test against.';
    return;
  end if;

  select sil.id, sil.product_id, sil.uom, sil.qty, sil.qty_base, sil.pack_size,
         sil.rate, sil.qty_cancelled_base, p.code, p.name, p.pack_uom,
         p.pack_size as product_pack_size
    into v_line
    from public.sales_invoice_line sil
    join public.product p on p.id = sil.product_id
   where sil.invoice_id = v_inv.id
     and sil.qty_base > sil.qty_cancelled_base
   order by sil.line_no
   limit 1;

  raise notice '--------------------------------------------------------------';
  raise notice 'Testing against bill % of %', v_inv.doc_no, v_inv.invoice_date;
  raise notice '  status %, net %, cancelled %',
    v_inv.status, v_inv.net_total, v_inv.cancelled_value;
  raise notice 'Line: % (%)  billed in % x %  pack_size %  rate %',
    v_line.name, v_line.code, v_line.qty, v_line.uom, v_line.pack_size, v_line.rate;
  raise notice '  product pack: %  x %', coalesce(v_line.pack_uom, '(none)'),
    v_line.product_pack_size;
  raise notice '--------------------------------------------------------------';

  begin
    v_return := public.post_sales_return(
      v_inv.party_id,
      current_date,
      -- Exactly the shape the screen sends: one base unit, at the rate per
      -- base unit, going back on the shelf.
      jsonb_build_array(jsonb_build_object(
        'product_id',      v_line.product_id,
        'invoice_line_id', v_line.id,
        'uom',             'BASE',
        'qty',             1,
        'rate',            v_line.rate / case when v_line.uom = 'PACK'
                                              then nullif(v_line.pack_size, 0)
                                              else 1 end,
        'restock',         true)),
      'Diagnostic — rolled back',
      v_inv.id,
      null);

    raise notice 'The return itself SAVED. value %', v_return ->> 'total_value';

    -- Then the second half of what the screen does: put the credit on the
    -- bill. If the first half worked, this is where it is going wrong.
    begin
      perform public.allocate_credit(
        jsonb_build_array(jsonb_build_object(
          'invoice_id', v_inv.id,
          'amount', least((v_return ->> 'total_value')::numeric,
                          (select outstanding from public.v_invoice_outstanding
                            where invoice_id = v_inv.id)))),
        null,
        (v_return ->> 'return_id')::uuid);
      raise notice 'The allocation SAVED too. Both halves work on this bill.';
    exception when others then
      get stacked diagnostics
        v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT,
        v_detail = PG_EXCEPTION_DETAIL, v_constraint = CONSTRAINT_NAME,
        v_table = TABLE_NAME, v_column = COLUMN_NAME;
      raise notice '>> THE ALLOCATION FAILED';
      raise notice '   sqlstate   %', v_state;
      raise notice '   message    %', v_msg;
      raise notice '   detail     %', coalesce(v_detail, '-');
      raise notice '   constraint %', coalesce(v_constraint, '-');
      raise notice '   table      %', coalesce(v_table, '-');
      raise notice '   column     %', coalesce(v_column, '-');
    end;

  exception when others then
    get stacked diagnostics
      v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT,
      v_detail = PG_EXCEPTION_DETAIL, v_constraint = CONSTRAINT_NAME,
      v_table = TABLE_NAME, v_column = COLUMN_NAME;
    raise notice '>> THE RETURN FAILED';
    raise notice '   sqlstate   %', v_state;
    raise notice '   message    %', v_msg;
    raise notice '   detail     %', coalesce(v_detail, '-');
    raise notice '   constraint %', coalesce(v_constraint, '-');
    raise notice '   table      %', coalesce(v_table, '-');
    raise notice '   column     %', coalesce(v_column, '-');
  end;
end $$;


-- -----------------------------------------------------------------------------
-- Is the returns half of the database actually installed?
-- -----------------------------------------------------------------------------

select
  to_regprocedure('public.post_sales_return(uuid,date,jsonb,text,uuid,text)')
    is not null                                   as post_sales_return_exists,
  to_regprocedure('public.allocate_credit(jsonb,uuid,uuid)')
    is not null                                   as allocate_credit_exists,
  to_regclass('public.v_return_list') is not null as migration_038_run,
  (select count(*) from public.sales_return)      as returns_so_far;

rollback;
