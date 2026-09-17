-- =============================================================================
-- 007_sales_invoice.sql
-- Sales invoices and their cancellations.
--
-- An invoice, once posted, is IMMUTABLE. Its lines and amounts are never
-- rewritten. A correction is a separate invoice_cancellation document whose
-- value is subtracted from the invoice, so the original always remains legible.
-- =============================================================================

create table public.sales_invoice (
  id                   uuid primary key default gen_random_uuid(),
  doc_no               text        not null unique,
  party_id             uuid        not null references public.party (id) on delete restrict,

  -- Normally raised from an order. NULL means a direct counter sale, which
  -- reserves nothing and consumes stock immediately.
  order_id             uuid        references public.sales_order (id) on delete restrict,

  invoice_date         date        not null,

  gross_total          numeric(14,2) not null default 0 check (gross_total         >= 0),
  line_discount_total  numeric(14,2) not null default 0 check (line_discount_total >= 0),
  bill_discount_amount numeric(14,2) not null default 0 check (bill_discount_amount >= 0),
  round_off            numeric(14,2) not null default 0,
  net_total            numeric(14,2) not null default 0 check (net_total >= 0),

  -- Raised by cancellations. Never exceeds net_total.
  cancelled_value      numeric(14,2) not null default 0 check (cancelled_value >= 0),

  -- What the customer actually owes for this invoice before payments.
  effective_total      numeric(14,2)
    generated always as (net_total - cancelled_value) stored,

  status               app.invoice_status not null default 'ACTIVE',
  remarks              text,

  created_at           timestamptz not null default now(),
  created_by           uuid        references public.app_user (id),

  constraint sales_invoice_cancel_not_over
    check (cancelled_value <= net_total),

  constraint sales_invoice_status_consistent
    check (
      (status = 'ACTIVE'              and cancelled_value = 0)
      or (status = 'PARTIALLY_CANCELLED' and cancelled_value > 0 and cancelled_value < net_total)
      or (status = 'CANCELLED'            and cancelled_value = net_total)
    )
);

comment on column public.sales_invoice.cancelled_value is
  'Sum of all cancellation documents against this invoice. Maintained by trigger.';

create index sales_invoice_party_idx  on public.sales_invoice (party_id, invoice_date desc);
create index sales_invoice_date_idx   on public.sales_invoice (invoice_date desc);
create index sales_invoice_order_idx  on public.sales_invoice (order_id);
create index sales_invoice_status_idx on public.sales_invoice (status);

-- -----------------------------------------------------------------------------
-- Invoice lines. Immutable once written.
--
-- allocated_bill_discount is the invoice-level discount pushed down to this
-- line in proportion to its net value, so that product-wise margin reporting
-- is correct. effective_amount is what all such reporting uses.
-- -----------------------------------------------------------------------------

create table public.sales_invoice_line (
  id                      uuid primary key default gen_random_uuid(),
  invoice_id              uuid          not null references public.sales_invoice (id) on delete cascade,
  line_no                 smallint      not null check (line_no > 0),
  order_line_id           uuid          references public.sales_order_line (id) on delete restrict,
  product_id              uuid          not null references public.product (id) on delete restrict,

  uom                     app.uom_type  not null default 'BASE',
  qty                     numeric(14,4) not null check (qty > 0),
  pack_size               numeric(14,4) not null default 1 check (pack_size > 0),
  rate                    numeric(14,4) not null check (rate >= 0),

  qty_base                numeric(14,4)
    generated always as (qty * case when uom = 'PACK' then pack_size else 1 end) stored,

  -- Stored as a resolved amount. The percentage, if one was typed, is kept
  -- alongside purely so the invoice can be reprinted showing "10%".
  line_discount_pct       numeric(7,4)  check (line_discount_pct between 0 and 100),
  line_discount_amount    numeric(14,2) not null default 0 check (line_discount_amount >= 0),

  allocated_bill_discount numeric(14,2) not null default 0 check (allocated_bill_discount >= 0),

  gross_amount numeric(14,2)
    generated always as (round(qty * rate, 2)) stored,

  net_amount numeric(14,2)
    generated always as (round(qty * rate, 2) - line_discount_amount) stored,

  effective_amount numeric(14,2)
    generated always as (
      round(qty * rate, 2) - line_discount_amount - allocated_bill_discount
    ) stored,

  -- Base quantity cancelled by cancellation documents. Maintained by trigger.
  qty_cancelled_base      numeric(14,4) not null default 0 check (qty_cancelled_base >= 0),

  unique (invoice_id, line_no),

  constraint sales_invoice_line_discount_not_over
    check (line_discount_amount + allocated_bill_discount <= round(qty * rate, 2)),

  constraint sales_invoice_line_cancel_not_over
    check (
      qty_cancelled_base
      <= qty * case when uom = 'PACK' then pack_size else 1 end
    ),

  constraint sales_invoice_line_pack_sane
    check (uom = 'BASE' or pack_size > 1)
);

create index sales_invoice_line_invoice_idx on public.sales_invoice_line (invoice_id);
create index sales_invoice_line_product_idx on public.sales_invoice_line (product_id);
create index sales_invoice_line_order_idx   on public.sales_invoice_line (order_line_id);

-- -----------------------------------------------------------------------------
-- Header totals must equal the sum of the lines, at COMMIT.
--
-- This is what guarantees the bill-discount allocation adds up exactly. If the
-- largest-remainder allocation ever drifts by a paisa, the transaction fails
-- rather than quietly writing an invoice whose lines do not sum to its total.
-- -----------------------------------------------------------------------------

create or replace function app.check_invoice_totals(p_invoice_id uuid)
returns void
language plpgsql
as $$
declare
  v_head      public.sales_invoice%rowtype;
  v_gross     numeric(14,2);
  v_line_disc numeric(14,2);
  v_bill_disc numeric(14,2);
  v_effective numeric(14,2);
begin
  select * into v_head from public.sales_invoice where id = p_invoice_id;
  if not found then
    return;
  end if;

  select coalesce(sum(gross_amount), 0),
         coalesce(sum(line_discount_amount), 0),
         coalesce(sum(allocated_bill_discount), 0),
         coalesce(sum(effective_amount), 0)
    into v_gross, v_line_disc, v_bill_disc, v_effective
    from public.sales_invoice_line
   where invoice_id = p_invoice_id;

  if v_head.gross_total <> v_gross then
    raise exception 'Invoice % gross_total % <> line sum %',
      v_head.doc_no, v_head.gross_total, v_gross using errcode = 'check_violation';
  end if;

  if v_head.line_discount_total <> v_line_disc then
    raise exception 'Invoice % line_discount_total % <> line sum %',
      v_head.doc_no, v_head.line_discount_total, v_line_disc using errcode = 'check_violation';
  end if;

  -- The allocation must consume the bill discount exactly, to the paisa.
  if v_head.bill_discount_amount <> v_bill_disc then
    raise exception
      'Invoice %: bill discount % was allocated to lines as % — allocation must be exact',
      v_head.doc_no, v_head.bill_discount_amount, v_bill_disc
      using errcode = 'check_violation';
  end if;

  if v_head.net_total <> v_effective + v_head.round_off then
    raise exception 'Invoice % net_total % <> effective line sum % plus round off %',
      v_head.doc_no, v_head.net_total, v_effective, v_head.round_off
      using errcode = 'check_violation';
  end if;
end;
$$;

create or replace function app.tg_check_invoice_totals_head()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    return null;
  end if;
  perform app.check_invoice_totals(new.id);
  return null;
end;
$$;

create or replace function app.tg_check_invoice_totals_line()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    perform app.check_invoice_totals(old.invoice_id);
  else
    perform app.check_invoice_totals(new.invoice_id);
  end if;
  return null;
end;
$$;

create constraint trigger sales_invoice_totals_check
  after insert or update on public.sales_invoice
  deferrable initially deferred
  for each row execute function app.tg_check_invoice_totals_head();

create constraint trigger sales_invoice_line_totals_check
  after insert or update or delete on public.sales_invoice_line
  deferrable initially deferred
  for each row execute function app.tg_check_invoice_totals_line();

-- =============================================================================
-- Invoice cancellation documents
-- =============================================================================

create table public.invoice_cancellation (
  id                uuid primary key default gen_random_uuid(),
  doc_no            text        not null unique,
  invoice_id        uuid        not null references public.sales_invoice (id) on delete restrict,
  cancellation_date date        not null,

  -- true when every remaining line and quantity was cancelled at once.
  is_full           boolean     not null default false,

  cancelled_value   numeric(14,2) not null check (cancelled_value > 0),
  reason            text        not null check (length(btrim(reason)) > 0),

  created_at        timestamptz not null default now(),
  created_by        uuid        references public.app_user (id)
);

comment on table public.invoice_cancellation is
  'Reverses part or all of an invoice. The invoice itself is never modified,
   so the original document can always be reprinted as issued.';

create index invoice_cancellation_invoice_idx
  on public.invoice_cancellation (invoice_id);

create table public.invoice_cancellation_line (
  id               uuid primary key default gen_random_uuid(),
  cancellation_id  uuid          not null references public.invoice_cancellation (id) on delete cascade,
  invoice_line_id  uuid          not null references public.sales_invoice_line (id) on delete restrict,
  product_id       uuid          not null references public.product (id) on delete restrict,

  qty_base         numeric(14,4) not null check (qty_base > 0),

  -- The invoice line's effective value, pro-rated to the cancelled quantity.
  cancelled_value  numeric(14,2) not null check (cancelled_value >= 0),

  unique (cancellation_id, invoice_line_id)
);

create index invoice_cancellation_line_cancel_idx
  on public.invoice_cancellation_line (cancellation_id);
create index invoice_cancellation_line_invline_idx
  on public.invoice_cancellation_line (invoice_line_id);
