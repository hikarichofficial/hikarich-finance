# Testing

Step 16 defines the acceptance gates (G0–G9). CI verifies a release candidate; it does not
replace Step 16 evidence. "Implemented" is not "Verified".

## Commands

| Command              | What it does                                                                  |
| -------------------- | ----------------------------------------------------------------------------- |
| `pnpm typecheck`     | TypeScript strict type check                                                  |
| `pnpm lint`          | ESLint (Next.js core-web-vitals + TypeScript)                                 |
| `pnpm format:check`  | Prettier check                                                                |
| `pnpm test`          | Vitest unit tests (`tests/unit`)                                              |
| `pnpm secrets:check` | Scans the working tree for committed secrets (prints locations, never values) |
| `pnpm build`         | Production build (needs the environment contract; see `.env.example`)         |
| `pnpm db:test`       | Rebuilds a throwaway database from migrations twice and runs SQL invariants   |
| `pnpm check`         | typecheck + lint + test + secrets                                             |

`pnpm db:test` starts its own throwaway PostgreSQL cluster when server binaries are installed
locally, or uses `ADMIN_DATABASE_URL` (a non-production server). It refuses any Supabase-hosted URL.

## Suites

| Suite          | Location                                  | Status (P1)                                                                                                                       |
| -------------- | ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Unit / domain  | `tests/unit`, `src/**/*.test.ts`          | Environment contract and production-isolation guard; authorization helpers, step-up window, redirect safety                       |
| Migration / DB | `supabase/tests`                          | Clean rebuild x2; structure, Entity isolation, journal, period, numbering, audit and master-data invariants; concurrent numbering |
| Integration    | `tests/integration`                       | Empty until P3+                                                                                                                   |
| RLS / security | `supabase/tests/80_rls_authorization.sql` | Anonymous, PT-only, staff, viewer, payroll, disabled-user, crafted-write, step-up, admin-guard and last-OWNER cases (P2)          |
| End-to-end     | `tests/e2e`                               | Empty until UI phases                                                                                                             |

Every fixed financial-integrity bug gets a permanent regression test (Step 13 (testing strategy)).

## Database tests (P1)

`supabase/tests/[0-9]*.sql` run in order after the migrations and `supabase/seed.sql`. Each file
runs inside a transaction that is rolled back, and asserts failures with an exact SQLSTATE through
`test_helpers.expect_error` (`01_helpers.sql`, test harness only). `10_structure.sql` inspects the
catalog, so every future table must keep the Entity/audit/append-only conventions. After the
files, `scripts/db-test.sh` runs four parallel sessions allocating document numbers and requires
distinct, gap-free values.

## RLS tests (P2)

`80_rls_authorization.sql` acts as `anon` / `authenticated` with `request.jwt.claims` set the way
PostgREST sets them, so it exercises the same privilege and policy path as a crafted HTTP request.
It covers: anonymous access to every table and function; every Entity-scoped table for users
without Personal access; guessed IDs; forged `entity_id`, system columns and cross-Entity
references; the staff/admin/viewer/payroll/accountant matrix; deny overrides; disabled users and
memberships (effective on the next statement); MFA and step-up; membership administration guards;
sensitive-field reveal. The suite was checked against deliberately weakened policies (membership
check always true, deny override ignored) and fails on both.

## Accounting core tests (P3)

`90_p3_posting.sql` covers, in order: money primitives (rounding vectors, conversion, 400 random
allocations that must sum exactly); line validation; the system posting service (numbering, retry,
different content refused, immutability at every level); 250 random balanced scenarios with
unique gapless journal numbers; the public journal RPCs as browser roles (permission matrix,
idempotent replay, protected-account override, reversal, cross-Entity refusal, trial balance);
period controls (review, blockers, closed-period blocks, OWNER reopen with step-up and audited
reason); and the opening-balance workflow. `db-test.sh` then runs four rounds of six sessions
posting the same ten events at once into months without a period row, and fails on any error in
any session, on a missing or duplicated journal, or on a hole in the year's journal numbers. The suite was checked
against deliberately broken code (posting key no longer identifying the event, the opening
account-class filter removed, the reopen step-up removed, the period-creation lock removed, the
numbering trigger removed) and fails on each. An independent review of the migrations found 6
medium and 8 low issues; all but the documented deferrals were fixed and each has a regression
check (DECISIONS 47-50).

Application unit tests (`src/domain/money`, `src/domain/accounting`) use the same rounding and
allocation vectors as the database tests, so both engines are held to identical behaviour.

## Money and reconciliation tests (P4)

`91_p4_money.sql` covers, in order: financial accounts (creation, mapping, permissions, audit
without the account number); opening balances that create cash movements; balance adjustments;
transfers (draft, approval rule and maker-checker, fee, FX, negative-balance setting, closed
period, reversal); the movement guard and the money/ledger control (a raw posting on a bank
account without its movement blocks Close); statement reconciliation (staging and idempotent
re-upload, matching rules, many-to-one, manual matches, exclusion, unmatch, completion evidence,
reopen, accepted differences, discard, status report, visibility); a seeded random run of 90
transfers and reversals that must keep money equal to the ledger, the books balanced, profit and
loss moved only by fees and FX differences, and transfer numbers gapless; and one regression block
for each defect found by the independent review (DECISIONS 51-63).

`db-test.sh` adds `money_concurrency_test`: six sessions confirm the same eight drafts, then
reverse the same eight transfers, then race two statement lines for one movement, then mix
balance adjustments with transfers on one account, then race a match against a reversal of the
same movement. Every item must take effect exactly once; a losing session may fail only with the
ordinary CONFLICT / INVALID message. The suite was checked against deliberately broken code (FX
line direction, exact-sum matching, the date-tolerance rule, the matched-movement reversal lock,
the accepted-difference rule, the journal coverage check of the movement guard, and the account
lock that prevents a deadlock between adjustments and transfers) and fails on each. An independent
review found 1 high, 7 medium and 2 low issues; all were fixed or documented as accepted
(DECISIONS 63) with a regression check.
