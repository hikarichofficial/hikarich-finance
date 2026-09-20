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

# Money layer under real concurrency (Step 15 P4 gate, Step 13 §9): several sessions confirm, reverse and match the SAME
# items at once. Each item must take effect exactly once; sessions that lose the race must fail with the ordinary
# CONFLICT message and nothing else. Every statement runs in its own transaction, as a browser request would.
money_workers() {
  # usage: money_workers <label> <workers> <statement generator function> [allowed error prefixes, default CONFLICT]
  local label="$1" workers="$2" gen="$3" allowed="${4:-CONFLICT}" pids=() w rc=0 errdir start_at
  errdir="$(mktemp -d)"
  start_at="$(python3 -c 'import time; print(time.time() + 2)')"
  for ((w = 1; w <= workers; w++)); do
    (
      {
        echo "select pg_sleep(greatest(0, ${start_at} - extract(epoch from clock_timestamp())));"
        "$gen" "$w"
      } | psql -X -q "$TEST_URL" -o /dev/null 2> "$errdir/worker-$w.err"
    ) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
  if [[ $rc -ne 0 ]] || { cat "$errdir"/*.err | grep 'ERROR:' | grep -Ev "ERROR:  (${allowed})" | grep -q .; }; then
    echo "FAIL: a concurrent money session (${label}) reported an unexpected error:" >&2
    cat "$errdir"/*.err >&2
    rm -rf "$errdir"
    exit 1
  fi
  rm -rf "$errdir"
}

MC_OWNER="d0000000-0000-0000-0000-000000000001"
MC_ACCT="d0000000-0000-0000-0000-000000000002"
mc_q() { "${PSQL[@]}" -tA "$TEST_URL" -c "$1"; }
mc_as() { echo "begin; select test_helpers.login('$1'); $2 commit;"; }

mc_gen_confirm() { local w="$1" d; for d in $MC_DRAFTS; do mc_as "$MC_OWNER" "select public.confirm_transfer('$d', 'conc-conf-${w}-${d:0:8}');"; done; }
mc_gen_reverse() { local w="$1" d; for d in $MC_DRAFTS; do mc_as "$MC_OWNER" "select public.reverse_transfer('$d', 'conc-rev-${w}-${d:0:8}', date '2026-11-20', 'Concurrent reversal test');"; done; }
mc_gen_match() {
  local w="$1" a b
  if (( w % 2 )); then a="$MC_L1"; b="$MC_L2"; else a="$MC_L2"; b="$MC_L1"; fi
  mc_as "$MC_ACCT" "select public.match_statement_line('$a', array['$MC_MOV']::uuid[]);"
  mc_as "$MC_ACCT" "select public.match_statement_line('$b', array['$MC_MOV']::uuid[]);"
}

mc_gen_mixed() {
  local w="$1" i
  for i in 1 2 3 4; do
    mc_as "$MC_ACCT" "select public.record_balance_adjustment('$MC_ENT', 'conc-adj-${w}-${i}', '$MC_A', 'in', 1000, null, date '2026-11-15', '$MC_INCOME', 'Concurrent adjustment');"
    mc_as "$MC_OWNER" "select public.create_transfer('$MC_ENT', 'conc-mix-${w}-${i}', '$MC_A', '$MC_B', date '2026-11-15', 1000, null, 0, null, null, 'Concurrent mixed transfer', null, true);"
  done
}
mc_gen_race() {
  local w="$1"
  if (( w % 2 )); then
    mc_as "$MC_ACCT" "select public.match_statement_line('$MC_LR', array['$MC_MOVR']::uuid[]);"
  else
    mc_as "$MC_OWNER" "select public.reverse_transfer('$MC_TR', 'conc-race-${w}', date '2026-11-20', 'Concurrent reversal race');"
  fi
}

money_concurrency_test() {
  echo "  testing  concurrent transfers, reversals and matches (6 sessions racing on the same items)"
  "${PSQL[@]}" -o /dev/null "$TEST_URL" <<SQL
insert into public.entities (entity_type, code, legal_name) values ('company', 'conc_money', 'Concurrency (synthetic)');
select app_private.provision_default_coa((select id from public.entities where code = 'conc_money'));
select test_helpers.mk_user('$MC_OWNER', 'conc_owner');
select test_helpers.mk_user('$MC_ACCT', 'conc_acct');
select test_helpers.mk_member((select id from public.entities where code = 'conc_money'), '$MC_OWNER', 'owner');
select test_helpers.mk_member((select id from public.entities where code = 'conc_money'), '$MC_ACCT', 'accountant');
begin;
select test_helpers.login('$MC_OWNER');
select public.create_financial_account((select id from public.entities where code = 'conc_money'), 'conc-acct-a', 'bank', 'Conc A', 'IDR');
select public.create_financial_account((select id from public.entities where code = 'conc_money'), 'conc-acct-b', 'bank', 'Conc B', 'IDR');
commit;
begin;
select test_helpers.login('$MC_ACCT');
select public.record_balance_adjustment((select id from public.entities where code = 'conc_money'), 'conc-fund-a', (select id from public.financial_accounts where name = 'Conc A'),
  'in', 1000000000, null, date '2026-11-01', (select id from public.ledger_accounts where entity_id = (select id from public.entities where code = 'conc_money') and system_key = 'INTEREST_INCOME'), 'Synthetic starting funds');
commit;
begin;
select test_helpers.login('$MC_OWNER');
select public.create_transfer((select id from public.entities where code = 'conc_money'), 'conc-draft-' || n, (select id from public.financial_accounts where name = 'Conc A'),
  (select id from public.financial_accounts where name = 'Conc B'), date '2026-11-05', 1000 + n * 100, null, 0, null, null, 'Concurrent draft ' || n, 'CONC-' || n, false)
from generate_series(1, 8) n;
select public.create_transfer((select id from public.entities where code = 'conc_money'), 'conc-draft-match', (select id from public.financial_accounts where name = 'Conc A'),
  (select id from public.financial_accounts where name = 'Conc B'), date '2026-11-10', 1000, null, 0, null, null, 'Transfer to be matched', 'CONC-M', true);
commit;
SQL
  local ent
  ent="$(mc_q "select id from public.entities where code = 'conc_money'")"
  MC_DRAFTS="$(mc_q "select id from public.transfers where entity_id = '$ent' and status = 'draft' order by reference")"

  # 1. confirm the same eight drafts from six sessions
  money_workers confirm 6 mc_gen_confirm
  local result
  result="$(mc_q "select count(*) || '/' || count(distinct t.transfer_number) || '/' || max(right(t.transfer_number, 4)::integer) from public.transfers t where t.entity_id = '$ent' and t.status = 'confirmed'")"
  if [[ "$result" != "9/9/9" ]]; then
    echo "FAIL: concurrent confirmation produced $result, expected 9/9/9 (confirmed/distinct numbers/highest number)." >&2
    exit 1
  fi
  result="$(mc_q "select (select count(*) from public.journal_entries where entity_id = '$ent' and source_type = 'transfer') || '/' || (select count(*) from public.money_movements where entity_id = '$ent' and source_type = 'transfer')")"
  if [[ "$result" != "9/18" ]]; then
    echo "FAIL: concurrent confirmation left $result journals/movements, expected 9/18." >&2
    exit 1
  fi

  # 2. reverse the same eight transfers from six sessions
  money_workers reverse 6 mc_gen_reverse
  result="$(mc_q "select (select count(*) from public.transfers where entity_id = '$ent' and status = 'reversed') || '/' || (select count(*) from public.journal_entries where entity_id = '$ent' and entry_type = 'reversal') || '/' || (select count(*) from public.money_movements where entity_id = '$ent' and reverses_movement_id is not null)")"
  if [[ "$result" != "8/8/16" ]]; then
    echo "FAIL: concurrent reversal produced $result, expected 8/8/16 (reversed/reversal journals/mirror movements)." >&2
    exit 1
  fi

  # 3. two statement lines and six sessions race to claim the same movement
  MC_MOV="$(mc_q "select m.id from public.money_movements m join public.transfers t on t.id = m.source_id where t.entity_id = '$ent' and t.reference = 'CONC-M' and m.direction = 'in'")"
  "${PSQL[@]}" -o /dev/null "$TEST_URL" <<SQL
begin;
select test_helpers.login('$MC_ACCT');
select public.create_reconciliation_session('$ent', 'conc-recon-1', (select id from public.financial_accounts where name = 'Conc B'), date '2026-11-01', date '2026-11-30', 0, 2000);
select public.add_statement_lines((select id from public.reconciliation_sessions where entity_id = '$ent'),
  '[{"date":"2026-11-10","amount":"1000","description":"LINE ONE"},{"date":"2026-11-10","amount":"1000","description":"LINE TWO"}]'::jsonb);
commit;
SQL
  MC_L1="$(mc_q "select id from public.statement_lines where entity_id = '$ent' and description = 'LINE ONE'")"
  MC_L2="$(mc_q "select id from public.statement_lines where entity_id = '$ent' and description = 'LINE TWO'")"
  money_workers match 6 mc_gen_match
  result="$(mc_q "select count(*) || '/' || count(distinct movement_id) from public.reconciliation_matches where entity_id = '$ent'")"
  if [[ "$result" != "1/1" ]]; then
    echo "FAIL: concurrent matching produced $result, expected 1/1 (matches/distinct movements)." >&2
    exit 1
  fi

  # 3b. adjustments and transfers on the same account race: the two paths lock in one order, so no deadlock
  MC_ENT="$ent"
  MC_A="$(mc_q "select id from public.financial_accounts where name = 'Conc A'")"
  MC_B="$(mc_q "select id from public.financial_accounts where name = 'Conc B'")"
  MC_INCOME="$(mc_q "select id from public.ledger_accounts where entity_id = '$ent' and system_key = 'INTEREST_INCOME'")"
  money_workers mixed 6 mc_gen_mixed
  result="$(mc_q "select (select count(*) from public.money_movements where entity_id = '$ent' and source_type = 'money_adjustment') || '/' || (select count(*) from public.transfers where entity_id = '$ent' and reference is null and status = 'confirmed')")"
  if [[ "$result" != "25/24" ]]; then
    echo "FAIL: concurrent adjustments and transfers produced $result, expected 25/24 (adjustments/transfers)." >&2
    exit 1
  fi

  # 3c. a match and a reversal of the same movement race: exactly one of them wins
  "${PSQL[@]}" -o /dev/null "$TEST_URL" <<SQL
begin;
select test_helpers.login('$MC_OWNER');
select public.create_transfer('$ent', 'conc-race-transfer', '$MC_A', '$MC_B', date '2026-11-12', 2000, null, 0, null, null, 'Transfer for the race', 'CONC-RACE', true);
commit;
begin;
select test_helpers.login('$MC_ACCT');
select public.add_statement_lines((select id from public.reconciliation_sessions where entity_id = '$ent'),
  '[{"date":"2026-11-12","amount":"2000","description":"LINE RACE"}]'::jsonb);
commit;
SQL
  MC_TR="$(mc_q "select id from public.transfers where entity_id = '$ent' and reference = 'CONC-RACE'")"
  MC_MOVR="$(mc_q "select id from public.money_movements where source_id = '$MC_TR' and direction = 'in'")"
  MC_LR="$(mc_q "select id from public.statement_lines where entity_id = '$ent' and description = 'LINE RACE'")"
  money_workers race 6 mc_gen_race 'CONFLICT|INVALID'
  result="$(mc_q "select (select count(*) from public.reconciliation_matches where movement_id = '$MC_MOVR') + (select count(*) from public.money_movements where reverses_movement_id = '$MC_MOVR')")"
  if [[ "$result" != "1" ]]; then
    echo "FAIL: a concurrent match and reversal of one movement left $result outcomes, expected exactly 1." >&2
    exit 1
  fi

  # 4. after all of it the money layer still equals the ledger and the books balance
  result="$(mc_q "select (select count(*) from app_private.money_control_rows('$ent', null) where ledger_balance <> movement_base_balance) || '/' || (select coalesce(sum(l.debit) - sum(l.credit), 0) from public.journal_lines l join public.journal_entries j on j.id = l.journal_id where j.entity_id = '$ent')")"
  if [[ "$result" != "0/0.0000" && "$result" != "0/0" ]]; then
    echo "FAIL: after concurrent money operations the layers disagree ($result)." >&2
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
  money_concurrency_test
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
