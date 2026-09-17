# Sales Application

Internal order-to-cash system for a goods trading business: purchase entry,
stock with reservation, field order collection, invoicing, returns, and payment
collection with receivables ageing.

Delivered as a **Progressive Web App** — one codebase serving office desktops
and rep phones, installable to the home screen, no app store.

Full requirements are in the project document *Sales App — Requirements
Specification*.

---

## Status

| Layer | State |
|---|---|
| Database schema | **Done** — 13 migrations |
| Row-level security | **Done** |
| Business logic (RPC functions) | **Done** — purchase, order, invoice, cancellation |
| Test suite | **Done** — 49 assertions plus a concurrency race |
| Reporting views | Not started |
| Sales return / receipt functions | Not started |
| PWA frontend | Not started |

---

## Repository layout

```
supabase/
  migrations/     Schema, applied in filename order. Never edit one that has
                  been run on the live database — add a new one instead.
  local/          Helpers for running against plain PostgreSQL. Never run
                  these on Supabase.
  tests/          SQL assertion suites.
scripts/
  db-test.sh      Rebuild a local database, apply everything, run the tests.
```

---

## Design rules

These are load-bearing. Breaking one causes silent data corruption rather
than an error, which is why each is enforced by the database itself.

**1. Stock cannot go negative.**
`product_stock.on_hand` carries a `CHECK (on_hand >= 0)`. Application logic is
the first line of defence; this constraint is the last. A bug produces a failed
transaction, not a wrong stock figure.

**2. The stock ledger is append-only.**
`stock_ledger` rejects UPDATE and DELETE via trigger. Corrections are new
reversing rows. The ledger is the source of truth; `product_stock` is a cache
maintained by trigger, and `v_stock_reconciliation` proves the two agree.

**3. Invoices are immutable.**
A posted invoice's lines and amounts are never rewritten. A correction is an
`invoice_cancellation` document whose value is subtracted via
`sales_invoice.cancelled_value`, so the original can always be reprinted as it
was issued.

**4. Bill discount allocation must be exact.**
An invoice-level discount is pushed down to lines in proportion to line value,
using the largest-remainder method so the parts sum to the whole. A deferred
constraint trigger verifies this at COMMIT. A one-paisa drift fails the
transaction.

**5. Document totals must equal their line sums.**
Enforced at COMMIT for purchases, invoices and returns, so a header and its
lines can be inserted in separate statements but can never disagree.

**6. The audit log cannot be altered.**
`audit_log` rejects UPDATE and DELETE for every role including Admin.

**7. All stock-affecting work happens in the database.**
Order submit, invoice create, cancel, purchase post and adjustment run as
Postgres functions in a single transaction with row locks. The client never
computes stock. This is what prevents two simultaneous invoices both passing an
availability check and overselling.

---

## Units and packs

Stock is always held in the **base unit**. A product may define a pack:

```
base_uom  = PCS
pack_uom  = BOX
pack_size = 24
```

Every document line stores the entered `uom` (`BASE` or `PACK`), the `qty` as
typed, and a **snapshot of `pack_size`**. `qty_base` is a generated column.
Snapshotting means changing a product's pack size later never rewrites history.

---

## Running the database locally

Requires PostgreSQL 15 or later.

```bash
./scripts/db-test.sh
```

This rebuilds a local `salesapp` database, applies the auth shim and every
migration, then runs three suites:

| Suite | What it covers |
|---|---|
| `001_schema_tests.sql` | Constraints, generated columns, append-only tables, audit |
| `002_logic_tests.sql` | The functions end to end, plus RLS as a real user |
| `003_concurrency.sh` | Eight processes racing for the same stock |

The concurrency suite is the one that matters most. It demands more stock than
exists from eight simultaneous connections and asserts that exactly as many
succeed as the stock supports, that the rest are refused with the stock error
rather than a deadlock, and that nothing is oversold or double-reserved.

Any failure aborts the run.

The auth shim in `supabase/local/` recreates just enough of Supabase's `auth`
schema (`auth.users`, `auth.uid()`, the `anon` / `authenticated` /
`service_role` roles) to run outside Supabase. **It must never be run against
the real database.**

---

## Applying to Supabase

Run the files in `supabase/migrations/` in filename order, in the SQL editor or
via the Supabase CLI. Do not run anything from `supabase/local/`.

After the first run, as Admin:

```sql
select public.post_opening_stock();
```

This posts each product's `opening_qty` as an `OPENING` ledger row. It is
idempotent — running it twice does nothing the second time.

Then schedule the reservation release, which is the one job that must run
without a user present:

```sql
select cron.schedule('expire-stale-orders', '0 1 * * *',
                     $$select public.expire_stale_orders()$$);
```

(Enable the `pg_cron` extension in the Supabase dashboard first.)

---

## Client API

Clients never write to document tables. Everything goes through these:

| Function | Who |
|---|---|
| `create_sales_order(party, date, lines, remarks)` | any signed-in user |
| `modify_sales_order(order_id, lines)` | any signed-in user |
| `cancel_sales_order(order_id, reason)` | any signed-in user |
| `reinstate_sales_order(order_id)` | Accounts, Admin |
| `create_sales_invoice(date, lines, order_id, party_id, bill_discount_amount, bill_discount_pct, remarks)` | Accounts, Admin |
| `cancel_sales_invoice(invoice_id, reason, lines)` | Accounts, Admin |
| `post_purchase(supplier, date, lines, other_charges, bill_no, bill_date, remarks)` | Accounts, Admin |
| `post_opening_stock()` | Admin |

`cancel_sales_invoice` with `lines` omitted cancels everything still standing.

### Error codes

| Code | Meaning |
|---|---|
| `SA001` | Insufficient stock. `DETAIL` is a JSON array naming each short product, what was asked and what is available — this is what the rep's conflict dialog renders. |
| `SA002` | Invalid state (invoicing a cancelled order, over-invoicing, cancelling twice) |
| `SA003` | Permission denied |
| `SA004` | Invalid input |
| `SA005` | Not found |

---

## Conventions

- Money `numeric(14,2)`; quantities and rates `numeric(14,4)`.
- Masters are deactivated (`is_active = false`), never deleted.
- Every document carries `created_at` / `created_by`; cancellable documents
  also carry `cancelled_at` / `cancelled_by` / `cancel_reason`, with a CHECK
  that a cancelled document always has a reason.
- Helper functions live in the `app` schema, which is not exposed through the
  API. Only `public` is.
