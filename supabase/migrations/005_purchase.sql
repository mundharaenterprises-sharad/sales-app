-- =============================================================================
-- 005_purchase.sql
-- Purchase entry. The only routine way stock increases.
--
-- A posted purchase is never edited. Correction is cancellation plus re-entry,
-- exactly as with a sales invoice.
-- =============================================================================

create table public.purchase (
  id                 uuid primary key default gen_random_uuid(),
  doc_no             text        not null unique,
  supplier_id        uuid        not null references public.supplier (id) on delete restrict,
  purchase_date      date        not null,
  supplier_bill_no   text,
  supplier_bill_date date,

  gross_total        numeric(14,2) not null default 0 check (gross_total   >= 0),
  other_charges      numeric(14,2) not null default 0 check (other_charges >= 0),
  net_total          numeric(14,2) not null default 0 check (net_total     >= 0),

  status             app.doc_status not null default 'ACTIVE',
  remarks            text,

  created_at         timestamptz not null default now(),
  created_by         uuid        references public.app_user (id),
  cancelled_at       timestamptz,
  cancelled_by       uuid        references public.app_user (id),
  cancel_reason      text,

  constraint purchase_cancel_fields
    check (
      (status = 'ACTIVE'    and cancelled_at is null and cancel_reason is null)
      or
      (status = 'CANCELLED' and cancelled_at is not null
                            and length(btrim(coalesce(cancel_reason, ''))) > 0)
    )
);

create index purchase_supplier_idx on public.purchase (supplier_id, purchase_date desc);
create index purchase_date_idx     on public.purchase (purchase_date desc);

create table public.purchase_line (
  id          uuid primary key default gen_random_uuid(),
  purchase_id uuid          not null references public.purchase (id) on delete cascade,
  line_no     smallint      not null check (line_no > 0),
  product_id  uuid          not null references public.product (id) on delete restrict,

  uom         app.uom_type  not null default 'BASE',
  qty         numeric(14,4) not null check (qty > 0),
  pack_size   numeric(14,4) not null default 1 check (pack_size > 0),
  rate        numeric(14,4) not null check (rate >= 0),

  -- Quantity in base units. Stock only ever moves in base units.
  qty_base    numeric(14,4)
    generated always as (qty * case when uom = 'PACK' then pack_size else 1 end) stored,

  amount      numeric(14,2)
    generated always as (round(qty * rate, 2)) stored,

  unique (purchase_id, line_no),

  -- A PACK line is meaningless when the product has no pack.
  constraint purchase_line_pack_sane
    check (uom = 'BASE' or pack_size > 1)
);

create index purchase_line_purchase_idx on public.purchase_line (purchase_id);
create index purchase_line_product_idx  on public.purchase_line (product_id);

-- -----------------------------------------------------------------------------
-- Header totals must equal the sum of the lines. Checked at COMMIT so that a
-- multi-statement insert (header, then lines) is legal in between.
-- -----------------------------------------------------------------------------

-- The check itself, addressed by purchase id.
create or replace function app.check_purchase_totals(p_purchase_id uuid)
returns void
language plpgsql
as $$
declare
  v_head     public.purchase%rowtype;
  v_line_sum numeric(14,2);
begin
  select * into v_head from public.purchase where id = p_purchase_id;
  if not found then
    return;  -- header removed in the same transaction; nothing to verify
  end if;

  select coalesce(sum(amount), 0) into v_line_sum
    from public.purchase_line where purchase_id = p_purchase_id;

  if v_head.gross_total <> v_line_sum then
    raise exception
      'Purchase % gross_total is % but its lines sum to %',
      v_head.doc_no, v_head.gross_total, v_line_sum
      using errcode = 'check_violation';
  end if;

  if v_head.net_total <> v_head.gross_total + v_head.other_charges then
    raise exception
      'Purchase % net_total % does not equal gross % plus charges %',
      v_head.doc_no, v_head.net_total, v_head.gross_total, v_head.other_charges
      using errcode = 'check_violation';
  end if;
end;
$$;

-- Two thin wrappers rather than one shared function: plpgsql resolves NEW and
-- OLD field references against the triggering table, so a single function
-- referencing both purchase.id and purchase_line.purchase_id fails on whichever
-- table lacks the column. NEW is also unassigned on DELETE.
create or replace function app.tg_check_purchase_totals_head()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    return null;
  end if;
  perform app.check_purchase_totals(new.id);
  return null;
end;
$$;

create or replace function app.tg_check_purchase_totals_line()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    perform app.check_purchase_totals(old.purchase_id);
  else
    perform app.check_purchase_totals(new.purchase_id);
  end if;
  return null;
end;
$$;

create constraint trigger purchase_totals_check
  after insert or update on public.purchase
  deferrable initially deferred
  for each row execute function app.tg_check_purchase_totals_head();

create constraint trigger purchase_line_totals_check
  after insert or update or delete on public.purchase_line
  deferrable initially deferred
  for each row execute function app.tg_check_purchase_totals_line();
