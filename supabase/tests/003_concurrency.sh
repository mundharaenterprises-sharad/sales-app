#!/usr/bin/env bash
# =============================================================================
# 003_concurrency.sh
#
# The single-session tests prove the arithmetic. This proves the locking.
#
# Eight processes race for the same stock at the same moment, demanding more
# than exists. Correct behaviour is that exactly as many succeed as the stock
# supports, the rest are refused, and the stock never goes negative or gets
# reserved twice. Anything else is an oversell.
#
#   ./supabase/tests/003_concurrency.sh
#
# Expects a database already built by scripts/db-test.sh.
# =============================================================================

set -uo pipefail

DB="${SALESAPP_DB:-salesapp}"
WORKERS=8
QTY=20          # each worker wants 20
STOCK=100       # only 100 exist, so exactly 5 should win

PARTY='dddddddd-0000-0000-0000-000000000001'
REP='33333333-3333-3333-3333-333333333333'
ACCOUNTS='22222222-2222-2222-2222-222222222222'
PROD_ORDER='eeeeeeee-0000-0000-0000-00000000000a'
PROD_INVOICE='eeeeeeee-0000-0000-0000-00000000000b'

fail() { echo "FAIL  $*" >&2; exit 1; }
pass() { echo "PASS  $*"; }

# -----------------------------------------------------------------------------
# Fixtures: two products with exactly STOCK units each
# -----------------------------------------------------------------------------

psql -q -v ON_ERROR_STOP=1 -d "$DB" >/dev/null <<SQL
insert into public.product
  (id, code, name, group_id, base_uom, sale_rate, purchase_rate,
   opening_qty, opening_rate, opening_date)
values
  ('${PROD_ORDER}',   'RACE-O', 'Race Product Order',
   'bbbbbbbb-0000-0000-0000-000000000001', 'PCS', 10, 8,
   ${STOCK}, 8, current_date),
  ('${PROD_INVOICE}', 'RACE-I', 'Race Product Invoice',
   'bbbbbbbb-0000-0000-0000-000000000001', 'PCS', 10, 8,
   ${STOCK}, 8, current_date)
on conflict (id) do nothing;

set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select public.post_opening_stock();
SQL

echo "Racing ${WORKERS} workers for ${QTY} units each against ${STOCK} in stock."
echo "Expecting $((STOCK / QTY)) to win."
echo

# -----------------------------------------------------------------------------
# Phase 1 — concurrent order submission (the reservation race)
# -----------------------------------------------------------------------------

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for i in $(seq 1 $WORKERS); do
  (
    psql -q -v ON_ERROR_STOP=1 -d "$DB" >/dev/null 2>"$TMP/order.$i.err" <<SQL
set request.jwt.claim.sub = '${REP}';
select public.create_sales_order(
  '${PARTY}'::uuid, current_date,
  '[{"product_id":"${PROD_ORDER}","uom":"BASE","qty":${QTY},"rate":10}]'::jsonb);
SQL
    echo $? > "$TMP/order.$i.rc"
  ) &
done
wait

ORDER_OK=0; ORDER_FAIL=0; ORDER_WRONG_ERR=0
for i in $(seq 1 $WORKERS); do
  if [ "$(cat "$TMP/order.$i.rc")" = "0" ]; then
    ORDER_OK=$((ORDER_OK + 1))
  else
    ORDER_FAIL=$((ORDER_FAIL + 1))
    # A refusal must be the stock refusal, not a deadlock or a crash.
    grep -q "Not enough stock" "$TMP/order.$i.err" || {
      ORDER_WRONG_ERR=$((ORDER_WRONG_ERR + 1))
      echo "  unexpected error in worker $i:" >&2
      head -3 "$TMP/order.$i.err" >&2
    }
  fi
done

echo "Orders:   ${ORDER_OK} succeeded, ${ORDER_FAIL} refused"

[ "$ORDER_WRONG_ERR" = "0" ] \
  || fail "$ORDER_WRONG_ERR worker(s) failed for the wrong reason (deadlock or crash)"

[ "$ORDER_OK" = "$((STOCK / QTY))" ] \
  || fail "expected $((STOCK / QTY)) orders to succeed, got $ORDER_OK"

read -r ON_HAND RESERVED AVAILABLE <<<"$(psql -tAq -F' ' -d "$DB" -c \
  "select on_hand, reserved, available from public.product_stock
    where product_id = '${PROD_ORDER}';")"

[ "${RESERVED%.*}" = "$STOCK" ] \
  || fail "reserved should be exactly $STOCK, got $RESERVED (stock was reserved twice)"

[ "${AVAILABLE%.*}" = "0" ] \
  || fail "available should be 0, got $AVAILABLE"

pass "concurrent orders reserved exactly the stock that exists, no more"

# -----------------------------------------------------------------------------
# Phase 2 — concurrent direct invoicing (the on-hand race)
# -----------------------------------------------------------------------------

for i in $(seq 1 $WORKERS); do
  (
    psql -q -v ON_ERROR_STOP=1 -d "$DB" >/dev/null 2>"$TMP/inv.$i.err" <<SQL
set request.jwt.claim.sub = '${ACCOUNTS}';
select public.create_sales_invoice(
  p_invoice_date => current_date,
  p_party_id     => '${PARTY}'::uuid,
  p_lines        => '[{"product_id":"${PROD_INVOICE}","uom":"BASE","qty":${QTY},"rate":10}]'::jsonb);
SQL
    echo $? > "$TMP/inv.$i.rc"
  ) &
done
wait

INV_OK=0; INV_FAIL=0; INV_WRONG_ERR=0
for i in $(seq 1 $WORKERS); do
  if [ "$(cat "$TMP/inv.$i.rc")" = "0" ]; then
    INV_OK=$((INV_OK + 1))
  else
    INV_FAIL=$((INV_FAIL + 1))
    grep -q "Not enough stock" "$TMP/inv.$i.err" || {
      INV_WRONG_ERR=$((INV_WRONG_ERR + 1))
      echo "  unexpected error in worker $i:" >&2
      head -3 "$TMP/inv.$i.err" >&2
    }
  fi
done

echo "Invoices: ${INV_OK} succeeded, ${INV_FAIL} refused"

[ "$INV_WRONG_ERR" = "0" ] \
  || fail "$INV_WRONG_ERR worker(s) failed for the wrong reason (deadlock or crash)"

[ "$INV_OK" = "$((STOCK / QTY))" ] \
  || fail "expected $((STOCK / QTY)) invoices to succeed, got $INV_OK"

read -r I_ON_HAND <<<"$(psql -tAq -d "$DB" -c \
  "select on_hand from public.product_stock where product_id = '${PROD_INVOICE}';")"

[ "${I_ON_HAND%.*}" = "0" ] \
  || fail "on hand should be exactly 0, got $I_ON_HAND"

pass "concurrent invoices sold exactly the stock that existed, none oversold"

# -----------------------------------------------------------------------------
# The ledger must still agree with the cache after all that contention.
# -----------------------------------------------------------------------------

DRIFT=$(psql -tAq -d "$DB" -c "select count(*) from public.v_stock_reconciliation;")
[ "$DRIFT" = "0" ] || fail "$DRIFT product(s) drifted from the ledger under contention"
pass "ledger and cache still agree after contention"

echo
echo "====================================="
echo " Concurrency tests passed."
echo "====================================="
