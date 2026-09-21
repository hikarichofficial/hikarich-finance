# Phase / Task Board (Step 15)

Primary chain: P0 → P1 → P2 → P3 → P4 → P5 → P6 → P7 → P8 → P9 → P10 → P11 → P12 → P13 → P14 → P15.
Some work may run in parallel once its prerequisite is stable, but no phase bypasses its
dependency gate. Detailed scope and gates: Step 15 (phase) and Step 16 (acceptance).

Status values: Not Started / In Progress / Implemented / Verified.

| Phase | Name                              | Prerequisite | Gate (summary)                                                     | Status      |
| ----- | --------------------------------- | ------------ | ------------------------------------------------------------------ | ----------- |
| P0    | Project Bootstrap                 | —            | G0: typecheck/build/lint/tests pass; env contract; CI operational  | Verified    |
| P1    | Database Foundation               | P0           | Clean database rebuilds fully from migrations                      | Verified    |
| P2    | Auth / Entity / RLS               | P1           | G2: crafted cross-Entity reads/writes fail (automated)             | Verified    |
| P3    | Accounting Core                   | P2           | Trial postings balance; retries never double-post; immutable       | Verified    |
| P4    | Money & Reconciliation            | P3           | Transfers create no P&L; money equals ledger; recon never rewrites | Verified    |
| P5    | Sales / AR                        | P4           | Invoices post once; payments/refunds never exceed; AR = ledger     | Implemented |
| P6    | Purchases / AP                    | P5           | Bills post once; payments never exceed; AP = ledger; races exact   | Implemented |
| P7    | Tax                               | P6           | Step 15 (P7) / Step 16; re-verify tax baseline on the web          | Not Started |
| P8    | Assets / Loans / Equity           | P7           | Step 15 (P8) / Step 16                                             | Not Started |
| P9    | Payroll                           | P8           | Step 15 (P9) / Step 16                                             | Not Started |
| P10   | Planning / Recurring              | P9           | Step 15 (P10) / Step 16                                            | Not Started |
| P11   | Documents / Imports / Search      | P10          | Step 15 (P11) / Step 16                                            | Not Started |
| P12   | Reports                           | P11          | Statement equations and reconciliations pass                       | Not Started |
| P13   | Dashboard / UX Completion         | P12          | KPI equals its source report                                       | Not Started |
| P14   | Security / Performance / Recovery | P13          | Step 15 / Step 16 incl. backup export and restore drill            | Not Started |
| P15   | Production Launch                 | P14          | Step 15 / Step 16; taxpayer facts and OWNER sign-off               | Not Started |

## P0 checklist (Step 15 §4)

| Item                 | Done when                                              | Status                                                             |
| -------------------- | ------------------------------------------------------ | ------------------------------------------------------------------ |
| GitHub repository    | Private repo, `main`, baseline rules/checks            | Verified. Repo is public (OWNER decision); `main` ruleset active   |
| Next.js / TypeScript | App boots locally with the agreed structure            | Implemented                                                        |
| Supabase local/dev   | Config initialized; environment separation established | Implemented (config, migrations dir, dev/prod projects, env guard) |
| Vercel               | Project linked to GitHub; Preview deploy works         | Verified. Project linked; Production and Preview deploys work      |
| Environment contract | Typed validation; no secrets committed                 | Implemented and tested                                             |
| CI baseline          | Typecheck, lint, tests/build pipeline operational      | Verified. Both required checks pass on pull requests               |

## P1 checklist (Step 15 §5)

| Item                                   | Done when                                                                | Status      |
| -------------------------------------- | ------------------------------------------------------------------------ | ----------- |
| Entity ownership/reference conventions | Every Entity table has `entity_id`, composite FKs, immutable `entity_id` | Verified    |
| Master records                         | Entities, identity, roles, currencies, contacts, catalog, categories     | Implemented |
| Financial identifiers                  | Concurrency-safe Entity-aware numbering; ledger and journal identities   | Verified    |
| Constraints, indexes, audit metadata   | Audit columns, append-only audit trail, idempotency, outbox              | Verified    |
| Seed data (non-production only)        | `supabase/seed.sql`: synthetic Entities/COA/periods only                 | Implemented |
| DB tests for hard invariants           | Balanced/immutable journals, period rules, Entity isolation, numbering   | Verified    |
| Gate                                   | Clean database rebuilt twice from migrations only; identical schema      | Verified    |

Hosted databases (dev and production) are not changed in P1: migrations are applied to them in a
controlled step when the application first needs the schema (P2 for dev; production at release).

## P2 checklist (Step 15 §6)

| Item                              | Done when                                                               | Status      |
| --------------------------------- | ----------------------------------------------------------------------- | ----------- |
| Supabase Auth and app session     | Login, MFA enrol/challenge, step-up, logout; proxy + server gate        | Implemented |
| Entity membership and context     | `my_access()`, Entity switch, PT and Personal never merged              | Verified    |
| Step 06 RLS and permission model  | Catalog, role templates, overrides, policies, column privileges         | Verified    |
| Server authorization helpers      | `requireAccess`, `requirePermission`, `requireStepUp`, typed errors     | Implemented |
| Tests: isolation, staff, disabled | `supabase/tests/80_rls_authorization.sql`, `src/domain/authz` unit      | Verified    |
| Gate G2                           | Crafted requests fail across Entities; suite fails when RLS is weakened | Verified    |

Live Supabase Auth (real password + authenticator) is exercised by the OWNER on the dev project
after the first bootstrap; the database tests emulate the verified JWT claims exactly as PostgREST
provides them.

## P3 checklist (Step 15 §7)

| Item                                     | Done when                                                                     | Status   |
| ---------------------------------------- | ----------------------------------------------------------------------------- | -------- |
| COA and protected/control accounts       | Templates, stable keys, override rule enforced for manual journals (P1 + P3)  | Verified |
| Journal / posting engine                 | One path, source linkage, posting key, numbering, reversal, adjusting journal | Verified |
| Idempotency and retry safety             | Replay, mismatch refusal, four-session concurrency test                       | Verified |
| Accounting periods open / close / reopen | Review, blockers, OWNER reopen with step-up and reason, all audited           | Verified |
| Opening-balance workflow                 | Balance-sheet only, clearing to zero or documented, completion ends window    | Verified |
| Decimal-safe money, currency, rounding   | Database primitives and application `Decimal` with shared test vectors        | Verified |
| Gate                                     | 250 random scenarios balance; duplicates cannot double-post; posted immutable | Verified |

Open items carried forward: approval workflow for manual journals, year-end closing entries and
sub-ledger reconciliation of opening balances (DECISIONS 41, 44, 45).

## P4 checklist (Step 15 §8)

| Item                                 | Done when                                                                         | Status   |
| ------------------------------------ | --------------------------------------------------------------------------------- | -------- |
| Financial accounts                   | Cash, bank, e-wallet, foreign currency; mapped to protected control accounts      | Verified |
| Money movements and derived balances | Append-only, journal-backed, equal to the ledger (`money_control`)                | Verified |
| Balance adjustments                  | Explicit counter account and reason, audited, never silent                        | Verified |
| Internal transfers                   | Fee, FX difference, approval rule, numbering, reversal; no revenue or expense     | Verified |
| Bank reconciliation                  | Sessions, statement lines, match / unmatch / exclude, complete / reopen, evidence | Verified |
| Period-close checks                  | Money/ledger mismatch blocks Close; reconciliation warnings                       | Verified |
| Application contracts                | `src/schemas/money.ts`, `src/services/money`, `src/domain/money/transfer.ts`      | Verified |
| Gate                                 | Random transfers and reversals keep money = ledger; concurrent races stay exact   | Verified |

Open items: money screens and statement file import (DECISIONS 62); the OWNER's choice of account
kinds that may never go negative (DECISIONS 55).

## P5 checklist (Step 15 §9)

| Item                       | Done when                                                                            | Status      |
| -------------------------- | ------------------------------------------------------------------------------------ | ----------- |
| Customers                  | Duplicate-aware, sensitive tax identifier, Entity-scoped                             | Implemented |
| Invoices                   | Server arithmetic, gapless numbering, frozen snapshots, posting, cancel/void/correct | Implemented |
| Payments and claims        | One writer, allocation, advance, FX per part, claim workflow, maker-checker          | Implemented |
| Reversals and credit       | Payment, credit application and refund reversals; exact restoration                  | Implemented |
| Refunds                    | Limits under lock, contra revenue / advance, receipts                                | Implemented |
| Customer page and receipts | Token surface (anon: three functions), throttles, invoice and receipt pages          | Implemented |
| AR control, aging, Close   | Sub-ledger = ledger; blockers and warnings; aging buckets                            | Implemented |
| Application contracts      | `src/schemas/sales.ts`, `src/services/sales`, `src/domain/sales`                     | Implemented |
| Gate                       | Random-free scenarios balance; races on pay, reverse, refund, void stay exact        | Implemented |

Status becomes Verified when the P5 pull request has passed CI and the OWNER has merged it. Open items:
staff screens, step-up on void/reversal/refund, `PUBLIC_CLAIM_SALT` in Production (DECISIONS 70, 75-76).

## P6 checklist (Step 15 §10)

| Item                     | Done when                                                                          | Status      |
| ------------------------ | ---------------------------------------------------------------------------------- | ----------- |
| Vendors and bills        | Duplicate-aware, server arithmetic, draft/submit/approve, frozen snapshot, posting | Implemented |
| Vendor payments          | One writer, allocation, FX per part, date rules, maker-checker, derived status     | Implemented |
| Cancel, void, correct    | Cancel without effect, void by linked reversal, correction as replacement draft    | Implemented |
| Direct expenses          | Confirm with money movement, payee snapshot, reverse, correct                      | Implemented |
| Duplicates and evidence  | Exact duplicates need a reason; documents by hash, links, missing-evidence list    | Implemented |
| AP control, aging, Close | Sub-ledger = ledger as of every date; blockers and warnings; aging buckets         | Implemented |
| Application contracts    | `src/schemas/purchases.ts`, `src/services/purchases`, `src/domain/purchases`       | Implemented |
| Gate                     | Scenarios balance; races on pay, reverse, void, approve, confirm stay exact        | Implemented |

Status becomes Verified when the P6 pull request has passed CI and the OWNER has merged it. Open items:
staff screens, step-up on void/reversal, OWNER choices in DECISIONS 87.
