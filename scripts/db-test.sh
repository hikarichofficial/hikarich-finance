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


# Sales layer under real concurrency (Step 15 P5 gate, Step 13 §9): the same invoice, claim, payment and refund are
# attacked by several sessions at once. Money is never over-allocated, a retried request never books twice, and the
# racing commands (confirm vs reject, reverse vs refund, void vs pay) end in exactly one outcome. Every statement runs in
# its own transaction, as a browser request would.
SC_OWNER="d1000000-0000-0000-0000-000000000001"
sc_today() { echo "test_helpers.today('$SC_ENT')"; }
sc_pay() { # sc_pay <key> <invoice> <amount> [extra columns]
  echo "select public.record_payment('$SC_ENT', '$1', '$SC_CUST', '$SC_BANK', $(sc_today) - 1, $3, jsonb_build_array(jsonb_build_object('invoice_id', '$2', 'amount', $3)));"
}
sc_gen_pay() { local w="$1" i; for i in 1 2 3 4; do mc_as "$SC_OWNER" "$(sc_pay "sc-pay-${w}-${i}" "$SC_I1" 300000)"; done; }
sc_gen_samekey() { local w="$1" i; for i in 1 2 3 4 5; do mc_as "$SC_OWNER" "$(sc_pay "sc-same-key" "$SC_I5" 100000)"; done; }
sc_gen_claim() {
  local w="$1"
  if (( w % 2 )); then
    mc_as "$SC_OWNER" "select public.confirm_payment_submission('$SC_CLAIM', 'sc-conf-${w}', '$SC_BANK');"
  else
    mc_as "$SC_OWNER" "select public.reject_payment_submission('$SC_CLAIM', 'Concurrent rejection');"
  fi
}
sc_gen_revrefund() {
  local w="$1"
  if (( w % 2 )); then
    mc_as "$SC_OWNER" "select public.reverse_payment('$SC_PX', 'sc-rev-${w}', $(sc_today), 'Concurrent reversal test');"
  else
    mc_as "$SC_OWNER" "select public.create_refund('$SC_PX', 'sc-refund-${w}', '$SC_BANK', $(sc_today), jsonb_build_array(jsonb_build_object('allocation_id', '$SC_AX', 'amount', 400000)), null, 'Concurrent refund', null, null, true);"
  fi
}
sc_gen_voidpay() {
  local w="$1"
  if (( w % 2 )); then
    mc_as "$SC_OWNER" "select public.void_invoice('$SC_I4', 'sc-void-${w}', 'Concurrent void test');"
  else
    mc_as "$SC_OWNER" "$(sc_pay "sc-vpay-${w}" "$SC_I4" 300000)"
  fi
}
sc_gen_claimvoid() {
  local w="$1"
  if (( w % 2 )); then
    mc_as "$SC_OWNER" "select public.confirm_payment_submission('$SC_CLAIM2', 'sc-cv-conf-${w}', '$SC_BANK');"
  else
    mc_as "$SC_OWNER" "select public.void_invoice('$SC_I7', 'sc-cv-void-${w}', 'Concurrent void vs claim');"
  fi
}
sc_gen_refunds() {
  local w="$1" i
  for i in 1 2 3 4; do
    mc_as "$SC_OWNER" "select public.create_refund('$SC_PY', 'sc-rr-${w}-${i}', '$SC_BANK', $(sc_today), jsonb_build_array(jsonb_build_object('allocation_id', '$SC_AY', 'amount', 250000)), null, 'Concurrent refund', null, null, true);"
  done
}

sales_concurrency_test() {
  echo "  testing  concurrent payments, claims, reversals, voids and refunds (6 sessions racing on the same documents)"
  "${PSQL[@]}" -o /dev/null "$TEST_URL" <<SQL
insert into public.entities (entity_type, code, legal_name) values ('company', 'conc_sales', 'Sales concurrency (synthetic)');
select app_private.provision_default_coa((select id from public.entities where code = 'conc_sales'));
select test_helpers.mk_user('$SC_OWNER', 'sc_owner');
select test_helpers.mk_member((select id from public.entities where code = 'conc_sales'), '$SC_OWNER', 'owner');
begin;
select test_helpers.login('$SC_OWNER');
select public.create_financial_account((select id from public.entities where code = 'conc_sales'), 'sc-bank-1', 'bank', 'SC Bank', 'IDR');
select public.create_contact((select id from public.entities where code = 'conc_sales'), 'sc-cust-1', 'customer', 'SC Customer');
commit;
SQL
  SC_ENT="$(mc_q "select id from public.entities where code = 'conc_sales'")"
  SC_BANK="$(mc_q "select id from public.financial_accounts where entity_id = '$SC_ENT'")"
  SC_CUST="$(mc_q "select id from public.contacts where entity_id = '$SC_ENT'")"
  local n
  for n in 1 2 3 4 5 6 7; do
    "${PSQL[@]}" -o /dev/null "$TEST_URL" <<SQL
begin;
select test_helpers.login('$SC_OWNER');
select public.issue_invoice(public.create_invoice_draft('$SC_ENT', 'sc-inv-$n', '$SC_CUST', test_helpers.today('$SC_ENT') - 3, test_helpers.today('$SC_ENT') + 30,
  jsonb_build_array(jsonb_build_object('description', 'Invoice $n', 'unit_price', case $n when 1 then 1000000 when 2 then 500000 when 3 then 400000 when 4 then 300000 when 5 then 1000000 when 6 then 600000 else 100000 end))), 'sc-iss-$n');
commit;
SQL
  done
  local q="select i.id from public.invoices i join public.invoice_lines l on l.invoice_id = i.id where i.entity_id = '$SC_ENT' and l.description ="
  SC_I1="$(mc_q "$q 'Invoice 1'")"; SC_I2="$(mc_q "$q 'Invoice 2'")"; SC_I3="$(mc_q "$q 'Invoice 3'")"
  SC_I4="$(mc_q "$q 'Invoice 4'")"; SC_I5="$(mc_q "$q 'Invoice 5'")"; SC_I6="$(mc_q "$q 'Invoice 6'")"
  "${PSQL[@]}" -o /dev/null "$TEST_URL" <<SQL
begin;
select test_helpers.login('$SC_OWNER');
select public.create_payment_claim('$SC_I2', 'sc-claim', 500000, test_helpers.today('$SC_ENT') - 1, 'Payer', 'CONC-CLAIM');
$(sc_pay "sc-payx-1" "$SC_I3" 400000)
$(sc_pay "sc-payy-1" "$SC_I6" 600000)
commit;
SQL
  SC_CLAIM="$(mc_q "select id from public.payment_submissions where entity_id = '$SC_ENT'")"
  SC_PX="$(mc_q "select p.id from public.payment_allocations a join public.payments p on p.id = a.payment_id where a.invoice_id = '$SC_I3'")"
  SC_AX="$(mc_q "select id from public.payment_allocations where invoice_id = '$SC_I3'")"
  SC_PY="$(mc_q "select p.id from public.payment_allocations a join public.payments p on p.id = a.payment_id where a.invoice_id = '$SC_I6'")"
  SC_AY="$(mc_q "select id from public.payment_allocations where invoice_id = '$SC_I6'")"

  # 1. four attempts per session to pay 300,000 of a 1,000,000 invoice: exactly three succeed, never a fourth
  money_workers pay 6 sc_gen_pay 'INVALID|CONFLICT'
  local result
  result="$(mc_q "select count(*) || '/' || sum(amount) from public.payment_allocations where invoice_id = '$SC_I1' and status = 'active'")"
  if [[ "$result" != "3/900000.0000" ]]; then
    echo "FAIL: concurrent payments produced $result, expected 3/900000.0000 (allocations/amount)." >&2
    exit 1
  fi

  # 2. one retried request, sent by six sessions five times each: one payment, one movement
  money_workers samekey 6 sc_gen_samekey 'INVALID|CONFLICT'
  result="$(mc_q "select (select count(*) from public.payment_allocations where invoice_id = '$SC_I5') || '/' || (select count(*) from public.money_movements m join public.payment_allocations a on a.payment_id = m.source_id where a.invoice_id = '$SC_I5' and m.source_type = 'payment')")"
  if [[ "$result" != "1/1" ]]; then
    echo "FAIL: a retried payment request booked $result (allocations/movements), expected 1/1." >&2
    exit 1
  fi

  # 3. confirm and reject the same claim at once: one outcome, consistent with the payment
  money_workers claim 6 sc_gen_claim
  result="$(mc_q "select (s.status = 'confirmed') = (select count(*) = 1 from public.payments p where p.submission_id = s.id) and s.status in ('confirmed', 'rejected') from public.payment_submissions s where s.id = '$SC_CLAIM'")"
  if [[ "$result" != "t" ]]; then
    echo "FAIL: a claim confirmed and rejected at once ended inconsistent." >&2
    exit 1
  fi

  # 4. reverse a payment and refund it at once: exactly one wins, never both
  money_workers revrefund 6 sc_gen_revrefund 'CONFLICT|INVALID'
  result="$(mc_q "select (p.status = 'reversed' and not exists (select 1 from public.refunds r where r.payment_id = p.id and r.status = 'confirmed'))
                       or (p.status = 'confirmed' and (select count(*) from public.refunds r where r.payment_id = p.id and r.status = 'confirmed') = 1) from public.payments p where p.id = '$SC_PX'")"
  if [[ "$result" != "t" ]]; then
    echo "FAIL: reversing and refunding one payment at once produced an impossible state." >&2
    exit 1
  fi

  # 5. void an invoice and pay it at once: either voided with nothing allocated, or paid and not voided
  money_workers voidpay 6 sc_gen_voidpay 'CONFLICT|INVALID'
  result="$(mc_q "select (i.status = 'void' and not exists (select 1 from public.payment_allocations a where a.invoice_id = i.id and a.status = 'active'))
                       or (i.status = 'issued' and (select count(*) from public.payment_allocations a where a.invoice_id = i.id and a.status = 'active') = 1) from public.invoices i where i.id = '$SC_I4'")"
  if [[ "$result" != "t" ]]; then
    echo "FAIL: voiding and paying one invoice at once produced an impossible state." >&2
    exit 1
  fi

  # 6. sixteen attempts to refund 250,000 of a 600,000 payment: exactly two succeed
  money_workers refunds 6 sc_gen_refunds 'INVALID|CONFLICT'
  result="$(mc_q "select count(*) || '/' || sum(amount) from public.refunds where payment_id = '$SC_PY' and status = 'confirmed'")"
  if [[ "$result" != "2/500000.0000" ]]; then
    echo "FAIL: concurrent refunds produced $result, expected 2/500000.0000 (refunds/amount)." >&2
    exit 1
  fi

  # 7. confirm a claim and void its invoice at once: the two paths lock the invoice first, so neither deadlocks
  SC_I7="$(mc_q "$q 'Invoice 7'")"
  "${PSQL[@]}" -o /dev/null "$TEST_URL" <<SQL
begin;
select test_helpers.login('$SC_OWNER');
select public.create_payment_claim('$SC_I7', 'sc-claim-2', 100000, test_helpers.today('$SC_ENT') - 1, 'Payer', 'CONC-CLAIM-2');
commit;
SQL
  SC_CLAIM2="$(mc_q "select id from public.payment_submissions where invoice_id = '$SC_I7'")"
  money_workers claimvoid 6 sc_gen_claimvoid 'CONFLICT|INVALID'
  result="$(mc_q "select (i.status = 'void' and not exists (select 1 from public.payment_allocations a where a.invoice_id = i.id and a.status = 'active'))
                       or (i.status = 'issued' and (select count(*) from public.payment_allocations a where a.invoice_id = i.id and a.status = 'active') = 1
                           and (select status from public.payment_submissions where id = '$SC_CLAIM2') = 'confirmed') from public.invoices i where i.id = '$SC_I7'")"
  if [[ "$result" != "t" ]]; then
    echo "FAIL: confirming a claim and voiding its invoice at once produced an impossible state ($result)." >&2
    exit 1
  fi

  # 8. after all of it the sales layer, the money layer and the ledger still agree
  if ! "${PSQL[@]}" -o /dev/null "$TEST_URL" -c "select test_helpers.controls('$SC_ENT', 'after concurrent sales operations')"; then
    echo "FAIL: after concurrent sales operations the layers disagree." >&2
    exit 1
  fi
}


# Purchases layer under real concurrency (Step 15 P6 gate, Step 13 §9): the same bill, payment and expense are attacked
# by several sessions at once. A bill is never over-paid, a retried payment never books twice, two approvals of the same
# vendor invoice never both go through, and the racing commands (void vs pay, reverse vs void, confirm vs cancel) end in
# exactly one outcome. Every statement runs in its own transaction, as a browser request would.
PC_OWNER="d2000000-0000-0000-0000-000000000001"
pc_today() { echo "test_helpers.today('$PC_ENT')"; }
pc_pay() { # pc_pay <key> <bill> <amount>
  echo "select public.record_vendor_payment('$PC_ENT', '$1', '$PC_VEND', '$PC_BANK', $(pc_today), $3, jsonb_build_array(jsonb_build_object('bill_id', '$2', 'amount', $3)));"
}
pc_gen_pay() { local w="$1" i; for i in 1 2 3 4; do mc_as "$PC_OWNER" "$(pc_pay "conc-pc-pay-${w}-${i}" "$PC_B1" 300000)"; done; }
pc_gen_samekey() { local w="$1" i; for i in 1 2 3 4 5; do mc_as "$PC_OWNER" "$(pc_pay "conc-pc-same-key" "$PC_B2" 100000)"; done; }
pc_gen_dup() {
  # Half of the sessions start with the first bill, half with the second, so the two approvals really overlap.
  local w="$1"
  if (( w % 2 )); then
    mc_as "$PC_OWNER" "select public.approve_bill('$PC_B3A', 'conc-pc-da-${w}');"
    mc_as "$PC_OWNER" "select public.approve_bill('$PC_B3B', 'conc-pc-db-${w}');"
  else
    mc_as "$PC_OWNER" "select public.approve_bill('$PC_B3B', 'conc-pc-db-${w}');"
    mc_as "$PC_OWNER" "select public.approve_bill('$PC_B3A', 'conc-pc-da-${w}');"
  fi
}
pc_gen_voidpay() {
  local w="$1"
  if (( w % 2 )); then
    mc_as "$PC_OWNER" "select public.void_bill('$PC_B4', 'conc-pc-void-${w}', 'Concurrent void test');"
  else
    mc_as "$PC_OWNER" "$(pc_pay "conc-pc-vpay-${w}" "$PC_B4" 300000)"
  fi
}
pc_gen_revvoid() {
  local w="$1"
  if (( w % 2 )); then
    mc_as "$PC_OWNER" "select public.reverse_vendor_payment('$PC_P5', 'conc-pc-rev-${w}', $(pc_today), 'Concurrent reversal test');"
  else
    mc_as "$PC_OWNER" "select public.void_bill('$PC_B5', 'conc-pc-void5-${w}', 'Concurrent void after payment');"
  fi
}
pc_gen_expense() {
  local w="$1"
  if (( w % 2 )); then
    mc_as "$PC_OWNER" "select public.confirm_expense('$PC_X1', 'conc-pc-xc-${w}');"
  else
    mc_as "$PC_OWNER" "select public.cancel_expense('$PC_X1', 'conc-pc-xx-${w}', 'Concurrent cancellation test');"
  fi
}
pc_gen_account() {
  # Odd sessions reverse payments made from the bank account while even sessions make new payments from the same
  # account: the two commands take the same locks (bills, payment, account, counters) in the same order.
  local w="$1" i k
  if (( w % 2 )); then
    for k in 0 1 2 3; do
      mc_as "$PC_OWNER" "select public.reverse_vendor_payment('${PC_RPS[$(( (w - 1) / 2 * 4 + k ))]}', 'conc-pc-acct-r-${w}-${k}', $(pc_today), 'Concurrent reversal on one account');"
    done
  else
    for i in 1 2 3 4; do mc_as "$PC_OWNER" "$(pc_pay "conc-pc-acct-p-${w}-${i}" "$PC_B6" 100000)"; done
  fi
}
pc_gen_expdup() {
  local w="$1"
  if (( w % 2 )); then
    mc_as "$PC_OWNER" "select public.confirm_expense('$PC_X2A', 'conc-pc-xda-${w}');"
    mc_as "$PC_OWNER" "select public.confirm_expense('$PC_X2B', 'conc-pc-xdb-${w}');"
  else
    mc_as "$PC_OWNER" "select public.confirm_expense('$PC_X2B', 'conc-pc-xdb-${w}');"
    mc_as "$PC_OWNER" "select public.confirm_expense('$PC_X2A', 'conc-pc-xda-${w}');"
  fi
}

purchases_concurrency_test() {
  echo "  testing  concurrent bills, payments, voids, reversals and expenses (6 sessions racing on the same documents)"
  "${PSQL[@]}" -o /dev/null "$TEST_URL" <<SQL
insert into public.entities (entity_type, code, legal_name) values ('company', 'conc_purch', 'Purchases concurrency (synthetic)');
select app_private.provision_default_coa((select id from public.entities where code = 'conc_purch'));
select test_helpers.mk_user('$PC_OWNER', 'pc_owner');
select test_helpers.mk_member((select id from public.entities where code = 'conc_purch'), '$PC_OWNER', 'owner');
begin;
select test_helpers.login('$PC_OWNER');
select public.create_financial_account((select id from public.entities where code = 'conc_purch'), 'conc-pc-bank-1', 'bank', 'PC Bank', 'IDR');
select public.create_contact((select id from public.entities where code = 'conc_purch'), 'conc-pc-vend-1', 'vendor', 'PC Vendor');
commit;
SQL
  PC_ENT="$(mc_q "select id from public.entities where code = 'conc_purch'")"
  PC_BANK="$(mc_q "select id from public.financial_accounts where entity_id = '$PC_ENT'")"
  PC_VEND="$(mc_q "select id from public.contacts where entity_id = '$PC_ENT'")"
  local n amt
  for n in 1 2 4 5 6 $(seq 10 21); do
    case $n in 1) amt=1000000 ;; 2) amt=1000000 ;; 4) amt=300000 ;; 5) amt=400000 ;; 6) amt=5000000 ;; *) amt=100000 ;; esac
    "${PSQL[@]}" -o /dev/null "$TEST_URL" <<SQL
begin;
select test_helpers.login('$PC_OWNER');
select public.approve_bill(public.submit_bill(public.create_bill_draft('$PC_ENT', 'conc-pc-b-$n', '$PC_VEND', test_helpers.today('$PC_ENT') - 3, test_helpers.today('$PC_ENT') + 30,
  jsonb_build_array(jsonb_build_object('description', 'Bill $n', 'unit_price', $amt)), 'REF-$n'), 'conc-pc-s-$n'), 'conc-pc-a-$n');
commit;
SQL
  done
  # a pair of drafts carrying the same vendor invoice number, and two expenses with the same receipt
  "${PSQL[@]}" -o /dev/null "$TEST_URL" <<SQL
begin;
select test_helpers.login('$PC_OWNER');
select public.submit_bill(public.create_bill_draft('$PC_ENT', 'conc-pc-b-3a', '$PC_VEND', test_helpers.today('$PC_ENT') - 3, test_helpers.today('$PC_ENT') + 30,
  jsonb_build_array(jsonb_build_object('description', 'Bill 3a', 'unit_price', 200000)), 'DUP-1'), 'conc-pc-s-3a');
select public.submit_bill(public.create_bill_draft('$PC_ENT', 'conc-pc-b-3b', '$PC_VEND', test_helpers.today('$PC_ENT') - 3, test_helpers.today('$PC_ENT') + 30,
  jsonb_build_array(jsonb_build_object('description', 'Bill 3b', 'unit_price', 200000)), 'dup-1 '), 'conc-pc-s-3b');
select public.submit_expense(public.create_expense_draft('$PC_ENT', 'conc-pc-x-1', '$PC_BANK', test_helpers.today('$PC_ENT'),
  '[{"description":"Expense X1","unit_price":50000}]', null, 'Toko Konkurensi', 'CONC-X1'), 'conc-pc-xs-1');
select public.submit_expense(public.create_expense_draft('$PC_ENT', 'conc-pc-x-2a', '$PC_BANK', test_helpers.today('$PC_ENT'),
  '[{"description":"Expense X2a","unit_price":70000}]', null, 'Toko Ganda', 'CONC-DUP'), 'conc-pc-xs-2a');
select public.submit_expense(public.create_expense_draft('$PC_ENT', 'conc-pc-x-2b', '$PC_BANK', test_helpers.today('$PC_ENT'),
  '[{"description":"Expense X2b","unit_price":70000}]', null, 'toko ganda', 'conc-dup'), 'conc-pc-xs-2b');
commit;
SQL
  local q="select b.id from public.bills b join public.bill_lines l on l.bill_id = b.id where b.entity_id = '$PC_ENT' and l.description ="
  PC_B1="$(mc_q "$q 'Bill 1'")"; PC_B2="$(mc_q "$q 'Bill 2'")"; PC_B4="$(mc_q "$q 'Bill 4'")"; PC_B5="$(mc_q "$q 'Bill 5'")"
  PC_B6="$(mc_q "$q 'Bill 6'")"
  PC_B3A="$(mc_q "$q 'Bill 3a'")"; PC_B3B="$(mc_q "$q 'Bill 3b'")"
  local qx="select x.id from public.expenses x join public.expense_lines l on l.expense_id = x.id where x.entity_id = '$PC_ENT' and l.description ="
  PC_X1="$(mc_q "$qx 'Expense X1'")"; PC_X2A="$(mc_q "$qx 'Expense X2a'")"; PC_X2B="$(mc_q "$qx 'Expense X2b'")"
  "${PSQL[@]}" -o /dev/null "$TEST_URL" <<SQL
begin;
select test_helpers.login('$PC_OWNER');
$(pc_pay "conc-pc-pay5" "$PC_B5" 400000)
commit;
SQL
  PC_P5="$(mc_q "select payment_id from public.vendor_payment_allocations where bill_id = '$PC_B5'")"
  # twelve small bills, each paid once, for the account race below
  PC_RPS=()
  local rb
  for n in $(seq 10 21); do
    rb="$(mc_q "$q 'Bill $n'")"
    "${PSQL[@]}" -o /dev/null "$TEST_URL" <<SQL
begin;
select test_helpers.login('$PC_OWNER');
$(pc_pay "conc-pc-rp-$n" "$rb" 100000)
commit;
SQL
    PC_RPS+=("$(mc_q "select payment_id from public.vendor_payment_allocations where bill_id = '$rb'")")
  done

  # 1. four attempts per session to pay 300,000 of a 1,000,000 bill: exactly three succeed, never a fourth
  money_workers pay 6 pc_gen_pay 'INVALID|CONFLICT'
  local result
  result="$(mc_q "select count(*) || '/' || sum(amount) from public.vendor_payment_allocations where bill_id = '$PC_B1' and status = 'active'")"
  if [[ "$result" != "3/900000.0000" ]]; then
    echo "FAIL: concurrent vendor payments produced $result, expected 3/900000.0000 (allocations/amount)." >&2
    exit 1
  fi

  # 2. one retried request, sent by six sessions five times each: one payment, one movement
  money_workers samekey 6 pc_gen_samekey 'INVALID|CONFLICT'
  result="$(mc_q "select (select count(*) from public.vendor_payment_allocations where bill_id = '$PC_B2') || '/' || (select count(*) from public.money_movements m join public.vendor_payment_allocations a on a.payment_id = m.source_id where a.bill_id = '$PC_B2' and m.source_type = 'vendor_payment')")"
  if [[ "$result" != "1/1" ]]; then
    echo "FAIL: a retried vendor payment request booked $result (allocations/movements), expected 1/1." >&2
    exit 1
  fi

  # 3. two approvals of the same vendor invoice number at once: exactly one goes through
  money_workers duplicate 6 pc_gen_dup 'CONFLICT|INVALID'
  result="$(mc_q "select (select count(*) from public.bills where id in ('$PC_B3A', '$PC_B3B') and status = 'approved') || '/' || (select count(*) from public.bills where id in ('$PC_B3A', '$PC_B3B') and status = 'submitted') || '/' || (select count(*) from public.journal_entries where source_type = 'bill' and source_id in ('$PC_B3A', '$PC_B3B'))")"
  if [[ "$result" != "1/1/1" ]]; then
    echo "FAIL: concurrent approval of a duplicate bill produced $result, expected 1/1/1 (approved/still submitted/journals)." >&2
    exit 1
  fi

  # 4. void a bill and pay it at once: either voided with nothing allocated, or paid and not voided
  money_workers voidpay 6 pc_gen_voidpay 'CONFLICT|INVALID'
  result="$(mc_q "select (b.status = 'void' and not exists (select 1 from public.vendor_payment_allocations a where a.bill_id = b.id and a.status = 'active'))
                       or (b.status = 'approved' and (select count(*) from public.vendor_payment_allocations a where a.bill_id = b.id and a.status = 'active') = 1) from public.bills b where b.id = '$PC_B4'")"
  if [[ "$result" != "t" ]]; then
    echo "FAIL: voiding and paying one bill at once produced an impossible state." >&2
    exit 1
  fi

  # 5. reverse the payment of a bill and void the bill at once: never a void bill with a live payment
  money_workers reversevoid 6 pc_gen_revvoid 'CONFLICT|INVALID'
  result="$(mc_q "select p.status = 'reversed' and (b.status = 'approved' or (b.status = 'void' and not exists (select 1 from public.vendor_payment_allocations a where a.bill_id = b.id and a.status = 'active')))
                       from public.vendor_payments p, public.bills b where p.id = '$PC_P5' and b.id = '$PC_B5'")"
  if [[ "$result" != "t" ]]; then
    echo "FAIL: reversing a payment and voiding its bill at once produced an impossible state." >&2
    exit 1
  fi

  # 6. confirm and cancel the same expense at once: one outcome, consistent with the ledger
  money_workers expense 6 pc_gen_expense 'CONFLICT|INVALID'
  result="$(mc_q "select (x.status = 'confirmed' and (select count(*) from public.journal_entries j where j.source_type = 'expense' and j.source_id = x.id) = 1
                          and (select count(*) from public.money_movements m where m.source_type = 'expense' and m.source_id = x.id) = 1)
                       or (x.status = 'cancelled' and not exists (select 1 from public.journal_entries j where j.source_id = x.id)) from public.expenses x where x.id = '$PC_X1'")"
  if [[ "$result" != "t" ]]; then
    echo "FAIL: confirming and cancelling one expense at once produced an impossible state ($result)." >&2
    exit 1
  fi

  # 7. two expenses with the same receipt confirmed at once: exactly one goes through
  money_workers expensedup 6 pc_gen_expdup 'CONFLICT|INVALID'
  result="$(mc_q "select count(*) from public.expenses where id in ('$PC_X2A', '$PC_X2B') and status = 'confirmed'")"
  if [[ "$result" != "1" ]]; then
    echo "FAIL: concurrent confirmation of a duplicate expense confirmed $result, expected exactly 1." >&2
    exit 1
  fi

  # 7b. payments and reversals on the same account at once: no deadlock, every command completes
  money_workers account 6 pc_gen_account 'CONFLICT|INVALID'
  result="$(mc_q "select (select count(*) from public.vendor_payment_allocations where bill_id = '$PC_B6' and status = 'active') || '/' || (select count(*) from public.vendor_payments where id in ($(printf "'%s'," "${PC_RPS[@]}" | sed 's/,$//')) and status = 'reversed')")"
  if [[ "$result" != "12/12" ]]; then
    echo "FAIL: payments racing reversals on one account produced $result, expected 12/12 (new payments/reversed payments)." >&2
    exit 1
  fi

  # 8. after all of it the purchase sub-ledger, the money layer and the ledger still agree, and the books balance
  result="$(mc_q "select (select c.sub_ledger = c.ledger_purchases from app_private.ap_control('$PC_ENT') c) || '/' || (select count(*) from app_private.money_control_rows('$PC_ENT', null) where ledger_balance <> movement_base_balance) || '/' || (select coalesce(sum(l.debit) - sum(l.credit), 0) from public.journal_lines l where l.entity_id = '$PC_ENT')")"
  if [[ "$result" != "true/0/0.0000" && "$result" != "t/0/0.0000" && "$result" != "true/0/0" && "$result" != "t/0/0" ]]; then
    echo "FAIL: after concurrent purchase operations the layers disagree ($result)." >&2
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
  sales_concurrency_test
  purchases_concurrency_test
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
