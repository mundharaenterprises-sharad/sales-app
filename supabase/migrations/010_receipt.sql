-- =============================================================================
-- 010_receipt.sql
-- Payment receipts and the allocation of credits against invoices.
--
-- A credit is either money received or the value of returned goods. Both are
-- allocated to invoices through one table, so ageing works identically for
-- each and an invoice is settled the same way regardless of how.
-- =============================================================================

create table public.receipt (
  id               uuid primary key default gen_random_uuid(),
  doc_no           text        not null unique,
  party_id         uuid        not null references public.party (id) on delete restrict,
  receipt_date     date        not null,

  mode             app.payment_mode not null,
  amount           numeric(14,2) not null check (amount > 0),

  reference_no     text,
  instrument_date  date,
  bank_name        text,

  -- Only meaningful for CHEQUE. NULL for every other mode.
  clearing_status  text check (clearing_status in ('PENDING', 'CLEARED', 'BOUNCED')),

  -- Who physically took the money. For a rep collecting cash in the field this
  -- is the rep, while created_by is the Accounts user who entered it.
  collected_by     uuid        references public.app_user (id),

  status           app.doc_status not null default 'ACTIVE',
  remarks          text,

  created_at       timestamptz not null default now(),
  created_by       uuid        references public.app_user (id),
  cancelled_at     timestamptz,
  cancelled_by     uuid        references public.app_user (id),
  cancel_reason    text,

  constraint receipt_cheque_fields
    check (
      (mode = 'CHEQUE' and clearing_status is not null)
      or
      (mode <> 'CHEQUE' and clearing_status is null)
    ),

  constraint receipt_cancel_fields
    check (
      (status = 'ACTIVE'    and cancelled_at is null)
      or
      (status = 'CANCELLED' and cancelled_at is not null
                            and length(btrim(coalesce(cancel_reason, ''))) > 0)
    )
);

comment on column public.receipt.clearing_status is
  'Cheques only. A BOUNCED cheque keeps its receipt but its allocations are
   reversed, putting the invoices back into outstanding.';

create index receipt_party_idx     on public.receipt (party_id, receipt_date desc);
create index receipt_date_idx      on public.receipt (receipt_date desc);
create index receipt_collector_idx on public.receipt (collected_by, receipt_date desc);
create index receipt_pending_cheque_idx on public.receipt (instrument_date)
  where mode = 'CHEQUE' and clearing_status = 'PENDING';

-- -----------------------------------------------------------------------------
-- Credit allocation
--
-- Exactly one source per row: a receipt or a sales return, never both.
-- -----------------------------------------------------------------------------

create table public.credit_allocation (
  id              uuid primary key default gen_random_uuid(),
  receipt_id      uuid references public.receipt (id)      on delete cascade,
  sales_return_id uuid references public.sales_return (id) on delete cascade,
  invoice_id      uuid not null references public.sales_invoice (id) on delete restrict,

  amount          numeric(14,2) not null check (amount > 0),

  created_at      timestamptz not null default now(),
  created_by      uuid        references public.app_user (id),

  constraint credit_allocation_one_source
    check (num_nonnulls(receipt_id, sales_return_id) = 1)
);

-- One line per source-and-invoice pair; change the amount rather than adding
-- a second row, so the allocation screen always shows one figure per invoice.
create unique index credit_allocation_receipt_invoice_idx
  on public.credit_allocation (receipt_id, invoice_id)
  where receipt_id is not null;

create unique index credit_allocation_return_invoice_idx
  on public.credit_allocation (sales_return_id, invoice_id)
  where sales_return_id is not null;

create index credit_allocation_invoice_idx on public.credit_allocation (invoice_id);

-- -----------------------------------------------------------------------------
-- Allocations may never exceed either side: not the credit that funds them,
-- nor the invoice they settle. Checked at COMMIT.
-- -----------------------------------------------------------------------------

create or replace function app.check_allocation_limits(
  p_receipt_id uuid,
  p_return_id  uuid,
  p_invoice_id uuid
)
returns void
language plpgsql
as $$
declare
  v_receipt_id uuid := p_receipt_id;
  v_return_id  uuid := p_return_id;
  v_invoice_id uuid := p_invoice_id;
  v_allocated  numeric(14,2);
  v_limit      numeric(14,2);
  v_doc_no     text;
begin
  if v_receipt_id is not null then
    select r.amount, r.doc_no into v_limit, v_doc_no
      from public.receipt r where r.id = v_receipt_id;

    if found then
      select coalesce(sum(amount), 0) into v_allocated
        from public.credit_allocation where receipt_id = v_receipt_id;

      if v_allocated > v_limit then
        raise exception
          'Receipt %: allocated % exceeds the receipt amount %',
          v_doc_no, v_allocated, v_limit using errcode = 'check_violation';
      end if;
    end if;
  end if;

  if v_return_id is not null then
    select sr.total_value, sr.doc_no into v_limit, v_doc_no
      from public.sales_return sr where sr.id = v_return_id;

    if found then
      select coalesce(sum(amount), 0) into v_allocated
        from public.credit_allocation where sales_return_id = v_return_id;

      if v_allocated > v_limit then
        raise exception
          'Sales return %: allocated % exceeds the return value %',
          v_doc_no, v_allocated, v_limit using errcode = 'check_violation';
      end if;
    end if;
  end if;

  select si.effective_total, si.doc_no into v_limit, v_doc_no
    from public.sales_invoice si where si.id = v_invoice_id;

  if found then
    select coalesce(sum(amount), 0) into v_allocated
      from public.credit_allocation where invoice_id = v_invoice_id;

    if v_allocated > v_limit then
      raise exception
        'Invoice %: allocated % exceeds what the invoice is worth (%)',
        v_doc_no, v_allocated, v_limit using errcode = 'check_violation';
    end if;
  end if;
end;
$$;

-- NEW is unassigned on DELETE and OLD on INSERT, so each case is read
-- separately rather than coalesced.
create or replace function app.tg_check_allocation_limits()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    perform app.check_allocation_limits(
      old.receipt_id, old.sales_return_id, old.invoice_id);
  else
    perform app.check_allocation_limits(
      new.receipt_id, new.sales_return_id, new.invoice_id);

    -- An UPDATE that moves an allocation to a different invoice or source
    -- leaves the old one needing a re-check too.
    if tg_op = 'UPDATE' then
      if old.invoice_id is distinct from new.invoice_id
         or old.receipt_id is distinct from new.receipt_id
         or old.sales_return_id is distinct from new.sales_return_id then
        perform app.check_allocation_limits(
          old.receipt_id, old.sales_return_id, old.invoice_id);
      end if;
    end if;
  end if;
  return null;
end;
$$;

create constraint trigger credit_allocation_limits_check
  after insert or update or delete on public.credit_allocation
  deferrable initially deferred
  for each row execute function app.tg_check_allocation_limits();

-- A cancellation that reduces an invoice below what is allocated to it would
-- break the rule above. The cancel function moves the excess to on-account
-- first, so this trigger exists to catch the case where that is ever missed.
create or replace function app.check_invoice_allocation_after_cancel()
returns trigger
language plpgsql
as $$
declare
  v_allocated numeric(14,2);
begin
  select coalesce(sum(amount), 0) into v_allocated
    from public.credit_allocation where invoice_id = new.id;

  if v_allocated > new.effective_total then
    raise exception
      'Invoice % is now worth % but has % allocated to it; release the excess to on-account first',
      new.doc_no, new.effective_total, v_allocated
      using errcode = 'check_violation';
  end if;

  return null;
end;
$$;

create constraint trigger sales_invoice_allocation_check
  after update of cancelled_value on public.sales_invoice
  deferrable initially deferred
  for each row execute function app.check_invoice_allocation_after_cancel();
