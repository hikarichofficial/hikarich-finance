# Phase / Task Board (Step 15)

Primary chain: P0 → P1 → P2 → P3 → P4 → P5 → P6 → P7 → P8 → P9 → P10 → P11 → P12 → P13 → P14 → P15.
Some work may run in parallel once its prerequisite is stable, but no phase bypasses its
dependency gate. Detailed scope and gates: Step 15 (phase) and Step 16 (acceptance).

Status values: Not Started / In Progress / Implemented / Verified.

| Phase | Name                              | Prerequisite | Gate (summary)                                                    | Status      |
| ----- | --------------------------------- | ------------ | ----------------------------------------------------------------- | ----------- |
| P0    | Project Bootstrap                 | —            | G0: typecheck/build/lint/tests pass; env contract; CI operational | Verified    |
| P1    | Database Foundation               | P0           | Clean database rebuilds fully from migrations                     | Verified    |
| P2    | Auth / Entity / RLS               | P1           | Step 15 (P2) / Step 16                                            | Not Started |
| P3    | Accounting Core                   | P2           | Step 15 (P3) / Step 16                                            | Not Started |
| P4    | Money & Reconciliation            | P3           | Step 15 (P4) / Step 16                                            | Not Started |
| P5    | Sales / AR                        | P4           | Step 15 (P5) / Step 16                                            | Not Started |
| P6    | Purchases / AP                    | P5           | Step 15 (P6) / Step 16                                            | Not Started |
| P7    | Tax                               | P6           | Step 15 (P7) / Step 16; re-verify tax baseline on the web         | Not Started |
| P8    | Assets / Loans / Equity           | P7           | Step 15 (P8) / Step 16                                            | Not Started |
| P9    | Payroll                           | P8           | Step 15 (P9) / Step 16                                            | Not Started |
| P10   | Planning / Recurring              | P9           | Step 15 (P10) / Step 16                                           | Not Started |
| P11   | Documents / Imports / Search      | P10          | Step 15 (P11) / Step 16                                           | Not Started |
| P12   | Reports                           | P11          | Statement equations and reconciliations pass                      | Not Started |
| P13   | Dashboard / UX Completion         | P12          | KPI equals its source report                                      | Not Started |
| P14   | Security / Performance / Recovery | P13          | Step 15 / Step 16 incl. backup export and restore drill           | Not Started |
| P15   | Production Launch                 | P14          | Step 15 / Step 16; taxpayer facts and OWNER sign-off              | Not Started |

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
