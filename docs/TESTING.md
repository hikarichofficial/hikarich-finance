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
