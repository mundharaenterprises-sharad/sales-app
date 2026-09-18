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
| Database schema | **Done** — 15 migrations |
| Row-level security | **Done** |
| Business logic (RPC functions) | **Done** — the whole order-to-cash cycle |
| Reporting views | **Done** — 16 views |
| Test suite | **Done** — 72 assertions plus a concurrency race |
| Excel import of masters | Not started |
| PWA frontend | Not started |

The back end is complete. Everything that touches stock or money is built,
enforced in the database, and covered by tests.

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
| `002_logic_tests.sql` | Order and invoice functions end to end, plus RLS as a real user |
| `003_concurrency.sh` | Eight processes racing for the same stock |
| `004_money_tests.sql` | Returns, receipts, allocation, cheques, and the reports |

Two suites matter more than the rest.

**`003_concurrency.sh`** demands more stock than exists from eight simultaneous
connections and asserts that exactly as many succeed as the stock supports,
that the rest are refused with the stock error rather than a deadlock, and that
nothing is oversold or double-reserved.

**Test 14 in `004`** computes the same party balance three independent ways —
from the balance view, straight from the documents, and as the closing running
balance of the party ledger — and requires all three to agree to the paisa. If
they ever diverge, the reports are lying about money.

Any failure aborts the run.

The auth shim in `supabase/local/` recreates just enough of Supabase's `auth`
schema (`auth.users`, `auth.uid()`, the `anon` / `authenticated` /
`service_role` roles) to run outside Supabase. **It must never be run against
the real database.**

---

## Deploying to Supabase

Two files, in order, pasted into the SQL Editor:

1. **`supabase/deploy/deploy_all.sql`** — every migration concatenated in
   order. It runs as a single transaction, so if anything fails nothing is
   applied and the database is left untouched.
2. **`supabase/deploy/bootstrap.sql`** — schedules the reservation-release job,
   creates the first Admin, records the business details for invoice printing,
   and ends with a sanity check that should report `OK` on every line. **Read
   and edit the marked values before running it.**

`deploy_all.sql` is generated from `supabase/migrations/`. After changing a
migration, regenerate it:

```bash
{ head -16 supabase/deploy/deploy_all.sql
  for f in supabase/migrations/*.sql; do
    printf '\n-- >>>>>>>>>>>>>>>>>>>>  %s  <<<<<<<<<<<<<<<<<<<<\n\n' "$(basename "$f")"
    cat "$f"
  done
} > /tmp/d.sql && mv /tmp/d.sql supabase/deploy/deploy_all.sql
```

**Never run anything from `supabase/local/` against Supabase.** That folder
fakes Supabase's own `auth` schema so the suite can run on plain PostgreSQL;
applying it to a real project would shadow the genuine `auth.users`.

Once masters and opening quantities are loaded, post the opening stock as
Admin:

```sql
select public.post_opening_stock();
```

It posts each product's `opening_qty` as an `OPENING` ledger row, and is
idempotent — running it twice does nothing the second time.

### After a schema change on a live project

`deploy_all.sql` is for a **new, empty** project only. Once a project holds
real data, add a new numbered migration and run only that file. Never re-run
`deploy_all.sql` against a live database and never edit a migration that has
already been applied.

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
| `post_sales_return(party, date, lines, reason, invoice_id, remarks)` | Accounts, Admin |
| `cancel_sales_return(return_id, reason)` | Accounts, Admin |
| `create_receipt(party, date, mode, amount, ref, instrument_date, bank, collected_by, remarks)` | Accounts, Admin |
| `cancel_receipt(receipt_id, reason)` | Accounts, Admin |
| `set_cheque_status(receipt_id, status, remarks)` | Accounts, Admin |
| `allocate_credit(allocations, receipt_id, sales_return_id)` | Accounts, Admin |
| `post_opening_stock()` | Admin |

`cancel_sales_invoice` with `lines` omitted cancels everything still standing.

**Allocation is always manual.** Creating a receipt settles nothing; someone
chooses which invoices it pays. `allocate_credit` takes the complete picture for
one credit — invoices left out are released, an empty array unallocates it
entirely. Money therefore never lands on an invoice by accident.

A sales return is a credit in exactly the same way a receipt is, and is
allocated through the same call. Its `restock` flag per line decides whether
returned goods go back into sellable stock or are written off; the customer is
credited either way.

### Reporting views

`v_invoice_outstanding`, `v_ageing`, `v_ageing_by_party`, `v_ageing_by_route`,
`v_unallocated_credit`, `v_party_balance`, `v_party_ledger`, `v_sales_register`,
`v_product_sales`, `v_collection_report`, `v_collection_by_collector`,
`v_pending_cheques`, `v_stock_report`, `v_pending_orders`,
`v_purchase_register`, `v_stock_reconciliation`.

All are `security_invoker`, so a rep sees exactly what RLS allows and no more.
Whether reps see money at all is governed by `app_setting.reps_see_outstanding`,
and the test suite proves that turning it off actually hides it.

Two honest limitations:

- **`v_product_sales.est_margin` uses each product's *current* purchase rate**,
  not the cost at the time of sale, which the schema does not capture. It drifts
  when buying prices move. Treat it as indicative until a costing method is
  chosen.
- **`v_collection_report.days_in_transit`** is the gap between the date a
  customer paid and the date the receipt was entered — for rep-collected cash,
  how long it sat with them. It only sees money that eventually arrived. Cash a
  rep never hands over produces no receipt and appears nowhere.

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
