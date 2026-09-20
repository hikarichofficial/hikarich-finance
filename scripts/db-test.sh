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

# Concurrency check (Step 08 §17, Step 13 §9): parallel sessions must receive distinct, gap-free numbers.
concurrency_test() {
  echo "  testing  concurrent document-number allocation (4 sessions x 25)"
  local workers=4 per_worker=25 pids=() w rc=0
  for ((w = 1; w <= workers; w++)); do
    (
      for ((i = 1; i <= per_worker; i++)); do
        echo "select app_private.allocate_document_number((select id from public.entities where code = 'demo_pt'), 'invoice', date '2026-09-01');"
      done | "${PSQL[@]}" -o /dev/null "$TEST_URL"
    ) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
  if [[ $rc -ne 0 ]]; then
    echo "FAIL: a concurrent allocation session failed." >&2
    exit 1
  fi
  local result
  result="$("${PSQL[@]}" -tA "$TEST_URL" -c "select count(*) || '/' || count(distinct full_number) || '/' || min(sequence_value) || '/' || max(sequence_value) from public.issued_document_numbers where scope = 'invoice'")"
  local expected="$((workers * per_worker))/$((workers * per_worker))/1/$((workers * per_worker))"
  if [[ "$result" != "$expected" ]]; then
    echo "FAIL: concurrent numbering produced $result, expected $expected (count/distinct/min/max)." >&2
    exit 1
  fi
}

# Duplicate/retry safety under real concurrency (Step 15 P3 gate, Step 13 §9): six sessions post the SAME ten
# source events at once, in a month that has no period row yet (so the first-use period race is exercised too);
# each event must end up as exactly one posted journal with its own gapless number. Several rounds, each in a
# fresh month, because a race is only visible when the sessions actually collide.
posting_concurrency_round() {
  local month="$1" workers=6 events=10 pids=() w rc=0 i errdir start_at
  errdir="$(mktemp -d)"
  # All sessions wait for the same start instant so their first statements really collide.
  start_at="$(python3 -c 'import time; print(time.time() + 2)')"
  for ((w = 1; w <= workers; w++)); do
    (
      {
      echo "select pg_sleep(greatest(0, ${start_at} - extract(epoch from clock_timestamp())));"
      for ((i = 1; i <= events; i++)); do
        echo "select app_private.post_system_journal((select id from public.entities where code = 'demo_pt'), 'conc_event', ('c0000000-0000-0000-0000-0000' || '${month//-/}' || lpad('${i}', 2, '0'))::uuid, 'conc.rule', 'v1', date '${month}-15', 'Concurrent duplicate test', '[{\"account_key\":\"BANK_OPERATING\",\"debit\":1000},{\"account_key\":\"OTHER_OPERATING_REVENUE\",\"credit\":1000}]'::jsonb);"
      done
      } | "${PSQL[@]}" -o /dev/null "$TEST_URL" 2> "$errdir/worker-$w.err"
    ) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
  # A duplicate that lost the race must replay quietly: ANY error in ANY session is a failure, even when
  # another session managed to post the same event.
  if [[ $rc -ne 0 ]] || grep -q . "$errdir"/*.err; then
    echo "FAIL: a concurrent posting session reported an error (month ${month}):" >&2
    cat "$errdir"/*.err >&2
    rm -rf "$errdir"
    exit 1
  fi
  rm -rf "$errdir"
  local result expected="${events}/${events}/${events}"
  result="$("${PSQL[@]}" -tA "$TEST_URL" -c "select count(*) || '/' || count(distinct journal_number) || '/' || count(distinct source_id) from public.journal_entries where source_type = 'conc_event' and status = 'posted' and to_char(entry_date, 'YYYY-MM') = '${month}'")"
  if [[ "$result" != "$expected" ]]; then
    echo "FAIL: concurrent duplicate posting in ${month} produced $result, expected $expected (journals/numbers/events)." >&2
    exit 1
  fi
}

posting_concurrency_test() {
  echo "  testing  concurrent duplicate posting (4 rounds x 6 sessions x 10 identical events)"
  local month
  for month in 2026-11 2026-12 2027-01 2027-02; do
    posting_concurrency_round "$month"
  done
  # Journal numbers stay unique and gap-free within each numbering year across everything posted above:
  # every posted journal has exactly one number, and each year's numbers run 1..n without holes.
  local numbers
  numbers="$("${PSQL[@]}" -tA "$TEST_URL" -c "select (select count(*) from public.journal_entries where status = 'posted') = (select count(*) from public.issued_document_numbers where scope = 'journal') and (select count(distinct journal_number) from public.journal_entries where status = 'posted') = (select count(*) from public.journal_entries where status = 'posted') and (select coalesce(bool_and(c = m), false) from (select count(*) c, max(sequence_value) m from public.issued_document_numbers where scope = 'journal' group by entity_id, period_key) q)")"
  if [[ "$numbers" != "t" ]]; then
    echo "FAIL: journal numbers are not unique and gap-free after concurrent posting." >&2
    exit 1
  fi
}

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
  concurrency_test
  posting_concurrency_test
}

fingerprint() {
  pg_dump --schema-only --no-owner --no-privileges --exclude-schema=test_helpers "$TEST_URL" | grep -v -E '^(--|SET |SELECT pg_catalog.set_config|\\restrict|\\unrestrict)' | sha256sum | cut -d' ' -f1
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
