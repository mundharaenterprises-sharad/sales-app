#!/usr/bin/env bash
# Rebuild a local database, apply every migration, run the full test suite.
#
#   ./scripts/db-test.sh
#
# Override connection details with the standard PG* environment variables,
# e.g. PGHOST=localhost PGPORT=5432 PGUSER=postgres ./scripts/db-test.sh

set -euo pipefail

DB="${SALESAPP_DB:-salesapp}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

rebuild() {
  psql -q -d postgres -c "drop database if exists ${DB};"
  psql -q -d postgres -c "create database ${DB};"
  psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/supabase/local/000_auth_shim.sql"
  for f in "$ROOT"/supabase/migrations/*.sql; do
    psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$f"
  done
}

strip() {
  sed 's/^psql:[^ ]* //; s/^NOTICE:  //; /does not exist, skipping/d; /^$/d'
}

# The schema suite and the logic suite each build their own fixtures with fixed
# ids, so they cannot share a database. Each gets a fresh one.

echo "==> Schema tests"
rebuild
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/supabase/tests/001_schema_tests.sql" 2>&1 | strip

echo
echo "==> Logic tests"
rebuild
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/supabase/tests/002_logic_tests.sql" 2>&1 | strip

echo
echo "==> Concurrency tests"
# Runs against the database the logic suite just built, reusing its fixtures.
"$ROOT/supabase/tests/003_concurrency.sh"

echo
echo "==> Go-live reset"
# Deliberately last against this database: it clears it out. Everything the
# suites above created is exactly what the reset has to be able to destroy.
"$ROOT/supabase/tests/010_reset.sh"

echo
echo "==> Money tests"
rebuild
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/supabase/tests/004_money_tests.sql" 2>&1 | strip

echo
echo "==> Import tests"
rebuild
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/supabase/tests/005_import_tests.sql" 2>&1 | strip

echo
echo "==> Master editing tests"
rebuild
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/supabase/tests/006_master_edit_tests.sql" 2>&1 | strip

echo
echo "==> Same-day correction tests"
rebuild
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/supabase/tests/007_revise_tests.sql" 2>&1 | strip

echo
echo "==> Receive payment tests"
rebuild
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/supabase/tests/008_receive_payment_tests.sql" 2>&1 | strip

echo
echo "==> Import update tests"
rebuild
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/supabase/tests/009_import_update_tests.sql" 2>&1 | strip

echo
echo "==> Master group tests"
rebuild
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/supabase/tests/011_master_group_tests.sql" 2>&1 | strip

echo
echo "==> Opening document tests"
rebuild
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/supabase/tests/012_opening_document_tests.sql" 2>&1 | strip

echo
echo "==> Purchase and day book tests"
rebuild
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/supabase/tests/013_purchase_daybook_tests.sql" 2>&1 | strip

echo
echo "==> Order discount tests"
rebuild
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/supabase/tests/014_order_discount_tests.sql" 2>&1 | strip

echo
echo "All suites passed."
