-- =============================================================================
-- 008_sales_return.sql
-- Goods physically returned by a customer after delivery.
--
-- Distinct from an invoice cancellation: a cancellation says the sale never
-- properly happened, a return says goods came back. A return puts stock back
-- and creates a credit that can be allocated against outstanding invoices.
-- =============================================================================

create table public.sales_return (
  id            uuid primary key default gen_random_uuid(),
  doc_no        text        not null unique,
  party_id      uuid        not null references public.party (id) on delete restrict,

  -- Optional: a return can reference the invoice it came from, which pre-fills
  -- products and rates, or stand alone when the original cannot be traced.
  invoice_id    uuid        references public.sales_invoice (id) on delete restrict,

  return_date   date        not null,
  total_value   numeric(14,2) not null default 0 check (total_value >= 0),

  status        app.doc_status not null default 'ACTIVE',
  reason        text        not null check (length(btrim(reason)) > 0),
  remarks       text,

  created_at    timestamptz not null default now(),
  created_by    uuid        references public.app_user (id),
  cancelled_at  timestamptz,
  cancelled_by  uuid        references public.app_user (id),
  cancel_reason text,

  constraint sales_return_cancel_fields
    check (
      (status = 'ACTIVE'    and cancelled_at is null)
      or
      (status = 'CANCELLED' and cancelled_at is not null
                            and length(btrim(coalesce(cancel_reason, ''))) > 0)
    )
);

create index sales_return_party_idx   on public.sales_return (party_id, return_date desc);
create index sales_return_invoice_idx on public.sales_return (invoice_id);
create index sales_return_date_idx    on public.sales_return (return_date desc);

create table public.sales_return_line (
  id              uuid primary key default gen_random_uuid(),
  return_id       uuid          not null references public.sales_return (id) on delete cascade,
  line_no         smallint      not null check (line_no > 0),
  product_id      uuid          not null references public.product (id) on delete restrict,
  invoice_line_id uuid          references public.sales_invoice_line (id) on delete restrict,

  uom             app.uom_type  not null default 'BASE',
  qty             numeric(14,4) not null check (qty > 0),
  pack_size       numeric(14,4) not null default 1 check (pack_size > 0),
  rate            numeric(14,4) not null check (rate >= 0),

  qty_base        numeric(14,4)
    generated always as (qty * case when uom = 'PACK' then pack_size else 1 end) stored,

  amount          numeric(14,2)
    generated always as (round(qty * rate, 2)) stored,

  -- Returned goods are not always resaleable. Damaged returns credit the
  -- customer but do not go back into sellable stock.
  restock         boolean       not null default true,

  unique (return_id, line_no),

  constraint sales_return_line_pack_sane
    check (uom = 'BASE' or pack_size > 1)
);

comment on column public.sales_return_line.restock is
  'false means the customer is credited but the goods are written off rather
   than added back to on_hand.';

create index sales_return_line_return_idx  on public.sales_return_line (return_id);
create index sales_return_line_product_idx on public.sales_return_line (product_id);

-- -----------------------------------------------------------------------------
-- Header total must equal the sum of the lines, at COMMIT.
-- -----------------------------------------------------------------------------

create or replace function app.check_return_totals(p_return_id uuid)
returns void
language plpgsql
as $$
declare
  v_head     public.sales_return%rowtype;
  v_line_sum numeric(14,2);
begin
  select * into v_head from public.sales_return where id = p_return_id;
  if not found then
    return;
  end if;

  select coalesce(sum(amount), 0) into v_line_sum
    from public.sales_return_line where return_id = p_return_id;

  if v_head.total_value <> v_line_sum then
    raise exception 'Sales return % total_value % <> line sum %',
      v_head.doc_no, v_head.total_value, v_line_sum
      using errcode = 'check_violation';
  end if;
end;
$$;

create or replace function app.tg_check_return_totals_head()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    return null;
  end if;
  perform app.check_return_totals(new.id);
  return null;
end;
$$;

create or replace function app.tg_check_return_totals_line()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    perform app.check_return_totals(old.return_id);
  else
    perform app.check_return_totals(new.return_id);
  end if;
  return null;
end;
$$;

create constraint trigger sales_return_totals_check
  after insert or update on public.sales_return
  deferrable initially deferred
  for each row execute function app.tg_check_return_totals_head();

create constraint trigger sales_return_line_totals_check
  after insert or update or delete on public.sales_return_line
  deferrable initially deferred
  for each row execute function app.tg_check_return_totals_line();
