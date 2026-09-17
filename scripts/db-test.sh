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
echo "All suites passed."
