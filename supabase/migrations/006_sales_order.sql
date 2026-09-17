-- =============================================================================
-- 006_sales_order.sql
-- Sales orders collected by reps. Submitting an order reserves stock.
--
-- Lifecycle:
--   DRAFT -> SUBMITTED -> PARTIALLY_INVOICED -> INVOICED
--                      -> CANCELLED
--                      -> EXPIRED  (auto-released after N days)
-- =============================================================================

create table public.sales_order (
  id            uuid primary key default gen_random_uuid(),
  doc_no        text        not null unique,
  party_id      uuid        not null references public.party (id) on delete restrict,
  order_date    date        not null,
  status        app.order_status not null default 'DRAFT',
  remarks       text,

  submitted_at  timestamptz,
  -- When the reservation lapses if nothing has been invoiced.
  expires_at    timestamptz,

  closed_at     timestamptz,
  cancelled_at  timestamptz,
  cancelled_by  uuid        references public.app_user (id),
  cancel_reason text,

  created_at    timestamptz not null default now(),
  created_by    uuid        references public.app_user (id),
  updated_at    timestamptz not null default now(),

  constraint sales_order_submitted_fields
    check (status = 'DRAFT' or submitted_at is not null),

  constraint sales_order_cancel_fields
    check (
      status <> 'CANCELLED'
      or (cancelled_at is not null
          and length(btrim(coalesce(cancel_reason, ''))) > 0)
    )
);

comment on column public.sales_order.expires_at is
  'Set on submit from app_setting.reservation_expiry_days. The release job
   compares against this, so changing the setting does not retroactively
   expire orders already in flight.';

create trigger sales_order_touch before update on public.sales_order
  for each row execute function app.touch_updated_at();

create index sales_order_party_idx  on public.sales_order (party_id, order_date desc);
create index sales_order_status_idx on public.sales_order (status);
create index sales_order_rep_idx    on public.sales_order (created_by, order_date desc);

-- Orders still holding a reservation, for the expiry job.
create index sales_order_expiry_idx on public.sales_order (expires_at)
  where status in ('SUBMITTED', 'PARTIALLY_INVOICED');

-- -----------------------------------------------------------------------------
-- Order lines
--
-- qty_invoiced_base and qty_cancelled_base are maintained by the invoice and
-- cancel functions. Whatever remains is what is still reserved.
-- -----------------------------------------------------------------------------

create table public.sales_order_line (
  id                 uuid primary key default gen_random_uuid(),
  order_id           uuid          not null references public.sales_order (id) on delete cascade,
  line_no            smallint      not null check (line_no > 0),
  product_id         uuid          not null references public.product (id) on delete restrict,

  uom                app.uom_type  not null default 'BASE',
  qty                numeric(14,4) not null check (qty > 0),
  pack_size          numeric(14,4) not null default 1 check (pack_size > 0),
  rate               numeric(14,4) not null check (rate >= 0),

  qty_base           numeric(14,4)
    generated always as (qty * case when uom = 'PACK' then pack_size else 1 end) stored,

  qty_invoiced_base  numeric(14,4) not null default 0 check (qty_invoiced_base  >= 0),
  qty_cancelled_base numeric(14,4) not null default 0 check (qty_cancelled_base >= 0),

  -- Still reserved, assuming the order is in a reserving status.
  qty_pending_base   numeric(14,4)
    generated always as (
      qty * case when uom = 'PACK' then pack_size else 1 end
      - qty_invoiced_base - qty_cancelled_base
    ) stored,

  unique (order_id, line_no),
  -- One row per product per order keeps reservation arithmetic unambiguous.
  unique (order_id, product_id),

  constraint sales_order_line_not_over_consumed
    check (
      qty_invoiced_base + qty_cancelled_base
      <= qty * case when uom = 'PACK' then pack_size else 1 end
    ),

  constraint sales_order_line_pack_sane
    check (uom = 'BASE' or pack_size > 1)
);

create index sales_order_line_order_idx   on public.sales_order_line (order_id);
create index sales_order_line_product_idx on public.sales_order_line (product_id);

-- -----------------------------------------------------------------------------
-- What the order is currently worth, and what it still holds in reserve.
-- -----------------------------------------------------------------------------

create or replace view public.v_sales_order_summary as
select
  so.id                        as order_id,
  so.doc_no,
  so.party_id,
  so.order_date,
  so.status,
  so.expires_at,
  so.created_by                as rep_id,
  count(sol.id)                as line_count,
  coalesce(sum(round(sol.qty * sol.rate, 2)), 0) as order_value,
  coalesce(sum(sol.qty_pending_base), 0)         as qty_pending_base,
  case
    when so.status in ('SUBMITTED', 'PARTIALLY_INVOICED')
    then coalesce(sum(sol.qty_pending_base), 0)
    else 0
  end                          as qty_reserved_base
from public.sales_order so
left join public.sales_order_line sol on sol.order_id = so.id
group by so.id;
