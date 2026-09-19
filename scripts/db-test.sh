#!/usr/bin/env bash
# Clean-rebuild migration test (Step 15 P1 gate groundwork, Step 14 §6).
#
# Builds a brand-new database ONLY from version-controlled files:
#   stubs (test harness) -> supabase/migrations/*.sql (in order) -> seed.sql -> invariant tests
# twice, and requires both rebuilds to produce an identical schema.
#
# Usage:
#   scripts/db-test.sh                       # starts a throwaway local PostgreSQL cluster
#   ADMIN_DATABASE_URL=postgresql://... scripts/db-test.sh   # use an existing NON-PRODUCTION server (CI service)
#
# Safety: refuses to run against any hostname that looks like a Supabase-hosted project.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TEST_DB="hikarich_rebuild_test"
CLUSTER_DIR=""
PG_BIN=""

cleanup() {
  if [[ -n "$CLUSTER_DIR" && -d "$CLUSTER_DIR" ]]; then
    runuser -u postgres -- "$PG_BIN/pg_ctl" -D "$CLUSTER_DIR" -m immediate stop >/dev/null 2>&1 || true
    rm -rf "$CLUSTER_DIR"
  fi
}
trap cleanup EXIT

if [[ -z "${ADMIN_DATABASE_URL:-}" ]]; then
  PG_BIN="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1 || true)"
  if [[ -z "$PG_BIN" ]]; then
    echo "No local PostgreSQL server binaries found and ADMIN_DATABASE_URL not set." >&2
    exit 2
  fi
  CLUSTER_DIR="$(mktemp -d /tmp/hikarich-pg.XXXXXX)"
  chown postgres:postgres "$CLUSTER_DIR"
  runuser -u postgres -- "$PG_BIN/initdb" -D "$CLUSTER_DIR" -A trust -U postgres >/dev/null
  runuser -u postgres -- "$PG_BIN/pg_ctl" -D "$CLUSTER_DIR" -o "-p 54999 -k /tmp -c listen_addresses=127.0.0.1" \
    -w -l "$CLUSTER_DIR/log" start >/dev/null
  ADMIN_DATABASE_URL="postgresql://postgres@127.0.0.1:54999/postgres"
  echo "Using throwaway local cluster ($("$PG_BIN/postgres" --version))."
fi

if [[ "$ADMIN_DATABASE_URL" == *".supabase.co"* || "$ADMIN_DATABASE_URL" == *"supabase.com"* ]]; then
  echo "REFUSING: ADMIN_DATABASE_URL points at a Supabase-hosted database. Tests must never touch hosted projects." >&2
  exit 3
fi

# Replace the database name in the URL (last path segment, before any query string).
db_url() {
  local base="${ADMIN_DATABASE_URL%%\?*}"
  local query=""
  [[ "$ADMIN_DATABASE_URL" == *\?* ]] && query="?${ADMIN_DATABASE_URL#*\?}"
  echo "${base%/*}/$1${query}"
}

ADMIN_URL="$(db_url postgres)"
TEST_URL="$(db_url "$TEST_DB")"
PSQL=(psql -X -q -v ON_ERROR_STOP=1)

# --- migration file hygiene -------------------------------------------------
shopt -s nullglob
migrations=(supabase/migrations/*.sql)
if [[ ${#migrations[@]} -eq 0 ]]; then
  echo "No migrations found." >&2
  exit 1
fi
prev=""
for f in "${migrations[@]}"; do
  name="$(basename "$f")"
  if [[ ! "$name" =~ ^[0-9]{14}_[a-z0-9_]+\.sql$ ]]; then
    echo "Bad migration filename: $name (expected YYYYMMDDHHMMSS_snake_case.sql)" >&2
    exit 1
  fi
  ts="${name%%_*}"
  if [[ -n "$prev" && ! "$ts" > "$prev" ]]; then
    echo "Migration timestamps must be strictly increasing: $name" >&2
    exit 1
  fi
  prev="$ts"
done

rebuild() {
  "${PSQL[@]}" "$ADMIN_URL" -c "drop database if exists ${TEST_DB} with (force)"
  "${PSQL[@]}" "$ADMIN_URL" -c "create database ${TEST_DB}"
  "${PSQL[@]}" "$TEST_URL" -f supabase/tests/stubs/00_supabase_stubs.sql
  for f in "${migrations[@]}"; do
    echo "  applying $(basename "$f")"
    "${PSQL[@]}" "$TEST_URL" -1 -f "$f"
  done
  "${PSQL[@]}" "$TEST_URL" -f supabase/seed.sql
  for t in supabase/tests/[0-9]*.sql; do
    echo "  testing  $(basename "$t")"
    "${PSQL[@]}" "$TEST_URL" -f "$t"
  done
}

fingerprint() {
  pg_dump --schema-only --no-owner --no-privileges "$TEST_URL" | grep -v -E '^(--|SET |SELECT pg_catalog.set_config|\\restrict|\\unrestrict)' | sha256sum | cut -d' ' -f1
}

echo "Rebuild #1"
rebuild
fp1="$(fingerprint)"
echo "Rebuild #2 (from scratch)"
rebuild
fp2="$(fingerprint)"

if [[ "$fp1" != "$fp2" ]]; then
  echo "FAIL: two clean rebuilds produced different schemas." >&2
  exit 1
fi

"${PSQL[@]}" "$ADMIN_URL" -c "drop database if exists ${TEST_DB} with (force)"
echo "OK: clean rebuild reproducible (schema fingerprint ${fp1:0:12}), ${#migrations[@]} migration(s), invariants pass."
