-- =============================================================================
-- 009_stock_adjustment.sql
-- Manual stock corrections: damage, samples, physical count differences.
--
-- Every adjustment requires a reason. These are the rows an owner looks at
-- first when stock does not match the shelf, so they are always audited and
-- never anonymous.
-- =============================================================================

create table public.stock_adjustment (
  id              uuid primary key default gen_random_uuid(),
  doc_no          text        not null unique,
  adjustment_date date        not null,
  reason          app.adjustment_reason not null,
  notes           text,

  status          app.doc_status not null default 'ACTIVE',

  created_at      timestamptz not null default now(),
  created_by      uuid        references public.app_user (id),
  cancelled_at    timestamptz,
  cancelled_by    uuid        references public.app_user (id),
  cancel_reason   text,

  -- OTHER is free-form, so it must be explained.
  constraint stock_adjustment_other_needs_notes
    check (reason <> 'OTHER' or length(btrim(coalesce(notes, ''))) > 0),

  constraint stock_adjustment_cancel_fields
    check (
      (status = 'ACTIVE'    and cancelled_at is null)
      or
      (status = 'CANCELLED' and cancelled_at is not null
                            and length(btrim(coalesce(cancel_reason, ''))) > 0)
    )
);

create index stock_adjustment_date_idx on public.stock_adjustment (adjustment_date desc);

create table public.stock_adjustment_line (
  id             uuid primary key default gen_random_uuid(),
  adjustment_id  uuid          not null references public.stock_adjustment (id) on delete cascade,
  line_no        smallint      not null check (line_no > 0),
  product_id     uuid          not null references public.product (id) on delete restrict,

  direction      text          not null check (direction in ('IN', 'OUT')),
  uom            app.uom_type  not null default 'BASE',
  qty            numeric(14,4) not null check (qty > 0),
  pack_size      numeric(14,4) not null default 1 check (pack_size > 0),
  rate           numeric(14,4) not null default 0 check (rate >= 0),

  qty_base       numeric(14,4)
    generated always as (qty * case when uom = 'PACK' then pack_size else 1 end) stored,

  unique (adjustment_id, line_no),

  constraint stock_adjustment_line_pack_sane
    check (uom = 'BASE' or pack_size > 1)
);

create index stock_adjustment_line_adj_idx     on public.stock_adjustment_line (adjustment_id);
create index stock_adjustment_line_product_idx on public.stock_adjustment_line (product_id);
