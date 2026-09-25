#!/usr/bin/env bash
# =============================================================================
# 010_reset.sh
#
# The go-live clear-out (supabase/deploy/reset_for_go_live.sql).
#
# It is the one script in this repository that destroys data on purpose, so it
# gets tested on the real thing rather than on a paraphrase of it: the file
# itself is run against a database full of documents.
#
# What must be true:
#   * it refuses to do anything until the confirmation word is changed
#   * it empties every table except the logins and the settings row
#   * document numbering starts again at 1
#   * the app still works afterwards — a fresh import and a bill go through,
#     including codes reused from the data it just destroyed
#
#   ./supabase/tests/010_reset.sh
#
# Expects a database already built and populated by scripts/db-test.sh.
# =============================================================================

set -uo pipefail

DB="${SALESAPP_DB:-salesapp}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/supabase/deploy/reset_for_go_live.sql"
ADMIN='11111111-1111-1111-1111-111111111111'

fail() { echo "FAIL  $*" >&2; exit 1; }
pass() { echo "PASS  $*"; }

q() { psql -tAq -d "$DB" -c "$1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# -----------------------------------------------------------------------------
# There has to be something to lose, or this proves nothing.
# -----------------------------------------------------------------------------

BILLS_BEFORE=$(q "select count(*) from public.sales_invoice;")
PARTIES_BEFORE=$(q "select count(*) from public.party;")
USERS_BEFORE=$(q "select count(*) from public.app_user;")

[ "$BILLS_BEFORE" -gt 0 ]   || fail "no bills in the test database — nothing to clear"
[ "$PARTIES_BEFORE" -gt 0 ] || fail "no parties in the test database"
[ "$USERS_BEFORE" -gt 0 ]   || fail "no logins in the test database"

# The codes about to be destroyed. Reusing one afterwards is the whole point of
# clearing the list, so the test reuses one.
PARTY_CODE=$(q "select code from public.party order by code limit 1;")
ROUTE_CODE=$(q "select code from public.route order by code limit 1;")

echo "Before: ${BILLS_BEFORE} bills, ${PARTIES_BEFORE} parties, ${USERS_BEFORE} logins."
echo "Will reuse the party code '${PARTY_CODE}' afterwards."
echo

# -----------------------------------------------------------------------------
# 1. It does nothing until it is told to
# -----------------------------------------------------------------------------

psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$SCRIPT" >/dev/null 2>"$TMP/unconfirmed.err"
[ $? -ne 0 ] || fail "the script ran without the confirmation word being changed"
grep -q "change NO to ERASE" "$TMP/unconfirmed.err" \
  || { echo "--- got ---"; head -5 "$TMP/unconfirmed.err"; fail "refused, but not for the right reason"; }

STILL=$(q "select count(*) from public.sales_invoice;")
[ "$STILL" = "$BILLS_BEFORE" ] || fail "a refused run still destroyed something"
pass "refuses to run until the confirmation word is changed, and touches nothing"

# -----------------------------------------------------------------------------
# 2. Confirmed, it empties the app
# -----------------------------------------------------------------------------

sed "s/v_confirm text := 'NO';/v_confirm text := 'ERASE';/" "$SCRIPT" > "$TMP/confirmed.sql"
grep -q "v_confirm text := 'ERASE';" "$TMP/confirmed.sql" \
  || fail "could not arm the script — has the confirmation line been reworded?"

psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$TMP/confirmed.sql" > "$TMP/run.out" 2>&1 \
  || { cat "$TMP/run.out"; fail "the confirmed run failed"; }

grep -q "WRONG" "$TMP/run.out" && { grep "WRONG" "$TMP/run.out"; fail "the script's own checks did not all pass"; }
pass "the script's own checks all report OK"

for t in sales_invoice sales_invoice_line sales_order sales_order_line \
         sales_return receipt credit_allocation invoice_cancellation \
         purchase stock_adjustment stock_ledger product_stock \
         product product_group supplier party route audit_log; do
  N=$(q "select count(*) from public.$t;")
  [ "$N" = "0" ] || fail "$t still has $N row(s)"
done
pass "every table is empty — customers and routes included"

[ "$(q "select count(*) from public.app_user;")" = "$USERS_BEFORE" ] \
  || fail "the logins did not survive"
[ "$(q "select count(*) from public.app_setting;")" = "1" ] \
  || fail "the settings row did not survive"
pass "logins and business settings survive"

NEXT=$(q "select count(*) from app.doc_sequence where next_number <> 1;")
[ "$NEXT" = "0" ] || fail "$NEXT document series did not restart at 1"
pass "document numbering restarts at 1"

# -----------------------------------------------------------------------------
# 3. The app still works on the far side of it
#
# A clear-out that leaves the database unusable would pass every check above.
# So: import a whole workbook's worth of masters — reusing a code the clear-out
# destroyed, which is the reason for clearing the list at all — post the stock,
# raise a bill, and look at the number on it.
# -----------------------------------------------------------------------------

psql -q -v ON_ERROR_STOP=1 -d "$DB" > "$TMP/after.out" 2>&1 <<SQL
set request.jwt.claim.sub = '${ADMIN}';

select public.import_masters('route',
  '[{"code":"${ROUTE_CODE}","name":"Town"}]'::jsonb, false);

select public.import_masters('product_group',
  '[{"code":"G1","name":"Biscuits","master_code":"OTHERS"}]'::jsonb, false);

select public.import_masters('party',
  '[{"code":"${PARTY_CODE}","name":"Ram Store","route_code":"${ROUTE_CODE}",
     "opening_balance":"7500","opening_balance_date":"2026-04-01"}]'::jsonb, false);

select public.import_masters('product',
  '[{"code":"P1","name":"Fresh Product","group_code":"G1","base_uom":"PCS",
     "sale_price":"25","opening_qty":"500","opening_price":"20",
     "opening_date":"2026-04-01"}]'::jsonb, false);

select public.post_opening_stock();

select public.create_sales_invoice(
  p_invoice_date => current_date,
  p_party_id     => (select id from public.party where code = '${PARTY_CODE}'),
  p_lines        => jsonb_build_array(jsonb_build_object(
                      'product_id', (select id from public.product where code = 'P1'),
                      'uom', 'BASE', 'qty', 10, 'rate', 25)));
SQL

[ $? -eq 0 ] || { cat "$TMP/after.out"; fail "the app did not work after the reset"; }
pass "a destroyed party code can be used again by the fresh import"

FIRST=$(q "select doc_no from public.sales_invoice order by created_at limit 1;")
[ "$FIRST" = "INV-000001" ] || fail "the first bill after the reset is $FIRST, expected INV-000001"
pass "the first bill after the reset is INV-000001"

BAL=$(q "select round(balance) from public.v_party_balance
          where party_id = (select id from public.party where code = '${PARTY_CODE}');")
[ "$BAL" = "7750" ] || fail "party balance is $BAL, expected 7750 (7500 opening + 250 bill)"
pass "the party ledger adds the opening balance to the new bill"

STOCK=$(q "select round(on_hand) from public.product_stock
            where product_id = (select id from public.product where code = 'P1');")
[ "$STOCK" = "490" ] || fail "stock is $STOCK, expected 490 (500 opening less 10 billed)"
pass "opening stock posts and the bill draws it down"

echo
echo "====================================="
echo " Go-live reset tests passed."
echo "====================================="
