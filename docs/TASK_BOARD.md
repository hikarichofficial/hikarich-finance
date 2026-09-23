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
| P5    | Sales / AR                        | P4           | Invoices post once; payments/refunds never exceed; AR = ledger     | Verified    |
| P6    | Purchases / AP                    | P5           | Bills post once; payments never exceed; AP = ledger; races exact   | Verified    |
| P7    | Tax                               | P6           | Step 15 (P7) / Step 16; re-verify tax baseline on the web          | Verified    |
| P8    | Assets / Loans / Equity           | P7           | Step 15 (P8) / Step 16                                             | Verified    |
| P9    | Payroll                           | P8           | Step 15 (P9) / Step 16                                             | Verified    |
| P10   | Planning / Recurring              | P9           | Step 15 (P10) / Step 16                                            | Verified    |
| P11   | Documents / Imports / Search      | P10          | Step 15 (P11) / Step 16                                            | Verified    |
| P12   | Reports                           | P11          | Statement equations and reconciliations pass                       | In Progress |
| P13   | Dashboard / UX Completion         | P12          | KPI equals its source report                                       | In Progress |
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

Verified: the P5 pull request passed CI and the OWNER merged it. Open items: staff screens, step-up on
void/reversal/refund (DECISIONS 70, 75-76).

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

Verified: the P6 pull request (#11) passed CI and the OWNER merged it. Open items: staff screens, step-up on
void/reversal, OWNER choices in DECISIONS 87.

## P7 checklist (Step 15 §11, Step 16 §15)

| Item                       | Done when                                                                                        | Status      |
| -------------------------- | ------------------------------------------------------------------------------------------------ | ----------- |
| Rule master and facts      | Versioned, dated, sourced rules; taxpayer and counterparty facts with history; engine switch     | Implemented |
| Line facts                 | VAT treatment on invoice lines; input VAT, tax-invoice reference and withholding object on lines | Implemented |
| Determination              | Output VAT, input VAT, PPh 23; effective-date boundaries; NEEDS_REVIEW; trace and rule versions  | Implemented |
| Overrides and confirmation | OWNER override with reason, evidence and step-up; tax-reviewer confirmation; both on the record  | Implemented |
| Recognition with documents | VAT and withholding post with the invoice, bill and expense; reversal, void and correction       | Implemented |
| Payments                   | Cash and input-VAT offset, penalty as its own expense, reversal, capacity per period             | Implemented |
| Filings and evidence       | Append-only filings with amendments; evidence on filings and payments, never removable           | Implemented |
| Reconciliation and control | Period snapshots with differences and notes; tax sub-ledger = ledger; Close blocker and warnings | Implemented |
| PPh Final UMKM             | Monthly computation from issued turnover; recompute posts the difference only                    | Implemented |
| Calendar and overview      | Calculate, pay, file, evidence per period with nominal dates and state                           | Implemented |
| Application contracts      | `src/schemas/tax.ts`, `src/services/tax`, `src/domain/tax`; tax facts on the line schemas        | Implemented |
| Gate                       | Scenarios balance; mutation checks; full suite and clean rebuild reproducible                    | Implemented |

Status becomes Verified when the P7 pull request has passed CI and the OWNER has merged it. Open items: the
tax baseline (rates, formulas, deadlines, facts) must be re-verified by the OWNER's tax adviser before P15;
customer-withheld PPh 23 credit, VAT refund, holiday calendar and staff screens are not in P7 (DECISIONS 88-100).

Verified: the P7 pull request (#12) passed CI and the OWNER merged it.

## P8 checklist (Step 15 §12, Step 16 §16-17)

| Item                       | Done when                                                                                                  | Status      |
| -------------------------- | ---------------------------------------------------------------------------------------------------------- | ----------- |
| Asset register             | Draft assets from approved purchase lines; activation, plan, split, transfer, condition, cancel            | Implemented |
| Depreciation               | Straight-line and declining balance, month by month after month-end; reversal; re-plan; fiscal memo        | Implemented |
| Disposal                   | Sale, scrap, loss, damage, donation; gain/loss; receivable for a sale on credit; reversal                  | Implemented |
| Other receivables/payables | Recognition (cash or offset), part settlement with interest and fee, write-off, reversal, void             | Implemented |
| Loans received and given   | Versioned schedules (annuity, flat, interest-only, manual); allocation; write-off; restructure; asset link | Implemented |
| Equity                     | Contributions, capital returns, dividends in parts, Personal investment and distribution events            | Implemented |
| Opening data               | `asset_load_opening`, `loan_load_opening`; obligations by offset (DATA_CUTOVER 10-12)                      | Implemented |
| Controls and Close         | Asset, loan, other AR/AP and dividend controls = ledger; depreciation due; tax-review warnings             | Implemented |
| Tax review of financing    | Queue and `financing_tax_review` (`tax.confirm_facts`); nothing guessed                                    | Implemented |
| Application contracts      | `src/schemas/{assets,financing}.ts`, `src/services/{assets,financing}`, `src/domain/{assets,financing}`    | Implemented |
| Gate                       | Scenarios balance; controls equal the ledger; full suite and clean rebuild reproducible                    | Implemented |

Verified: the P8 pull request (#13) passed CI and the OWNER merged it. Open items: the fiscal depreciation groups and
the tax treatment of interest, forgiven debt, dividends and capital returns must be verified by the OWNER's tax adviser
before P15; screens and the depreciation run schedule are not in P8 (DECISIONS 101-118).

## P9 checklist (Step 15 §13, Step 16 §18)

| Item                    | Done when                                                                                                 | Status      |
| ----------------------- | --------------------------------------------------------------------------------------------------------- | ----------- |
| Employees               | Master, employment terms, compensation, tax facts, BPJS enrolment: effective-dated, append-only, redacted | Implemented |
| Permission boundary     | Closed tables; per-RPC capability (`payroll.*`); tax fields empty without `payroll.tax_view`              | Implemented |
| Rule data               | PPh 21 TER and annual, BPJS Kes/JHT/JP/JKK/JKM as effective-dated versions; lines record the version used | Implemented |
| Calculation             | TER months, annual last tax month, gross-up, BPJS caps, review flags, fingerprint, stale detection        | Implemented |
| Run workflow            | Create, calculate, adjust, submit, approve, post, close; return, discard, reopen, correct                 | Implemented |
| Posting and payslips    | Journal, PPh 21 determination and payslips in one transaction; payslips immutable, voided on correction   | Implemented |
| Payments                | Net pay per employee and BPJS in one amount; capacity; step-up; maker-checker; reversal                   | Implemented |
| PPh 21 in the tax layer | Tax type `wht_pph21`; payment, filing and reconciliation through P7                                       | Implemented |
| Reports and controls    | Summary, liabilities, employee tax ledger, annual reconciliation, payroll control, period-close checks    | Implemented |
| Opening data            | `employee_set_tax_opening` (DATA_CUTOVER 13)                                                              | Implemented |
| Application contracts   | `src/schemas/payroll.ts`, `src/services/payroll`, `src/domain/payroll`                                    | Implemented |
| Gate                    | Hand-calculated scenarios; controls equal the ledger; full suite and clean rebuild reproducible           | Implemented |

Verified: the P9 pull request (#14) passed CI and the OWNER merged it. Open items: the payroll tax
baseline must be verified by the OWNER's tax adviser before P15; screens, payslip documents, THR/severance and the
e-bupot export are not in P9 (DECISIONS 119-133).

## P10 checklist (Step 15 Phase 10, Step 01 #22/#23/#26)

| Item                  | Done when                                                                                                            | Status      |
| --------------------- | -------------------------------------------------------------------------------------------------------------------- | ----------- |
| Permission boundary   | `planning.*` catalog and role grants                                                                                 | Implemented |
| Recurring rules       | Templates (invoice/bill/expense), pause/resume/end, editing never mutates generated history                          | Implemented |
| Recurring generation  | Idempotent occurrence identity, at most one due occurrence per rule per call, failed-generation retry, outbox events | Implemented |
| Budgets               | Entity -> Category -> Subcategory grid; Budget/Actual/Committed/Remaining/%Used/Variance (computed, never stored)    | Implemented |
| Revenue targets       | Annual/monthly targets with editable monthly breakdown; target vs actual vs open AR                                  | Implemented |
| Forecast              | Deferred to an OWNER decision (no locked spec defines a methodology); not guessed (DECISIONS 139)                    | Not Started |
| Application contracts | `src/schemas/planning.ts`, `src/services/planning`, `src/domain/planning`                                            | Implemented |
| Tests                 | pgTAP suite covering recurring idempotency/retry and the budget/target reports                                       | Implemented |
| Gate                  | Editing recurring rules never mutates historical generated transactions; full suite and clean rebuild reproducible   | Implemented |

Status: branch `p10-planning-recurring` merged to `main` via PR #16 (merge commit `7d0a257`);
migrations, application layer and the pgTAP suite (`supabase/tests/99_p10_planning.sql`) are all
done and merged; `scripts/db-test.sh` (double clean rebuild, all migrations, all test files, all
concurrency suites) passed with zero errors before merge, and CI (quality, migration clean-rebuild,
Vercel Preview) was green. Open items carried forward: the Forecast methodology and the "Committed"
reading for budgets need OWNER confirmation (DECISIONS 138-139); recurring rule/budget/revenue
target screens are a later slice (DECISIONS 134-139), like every other phase's screens.

## P11 checklist (Step 15 Phase 11, Step 01 #34/#35/#43/#44)

| Item                  | Done when                                                                                                         | Status      |
| --------------------- | ----------------------------------------------------------------------------------------------------------------- | ----------- |
| Documents generalized | Data-driven target-kind catalog; eleven target types linkable; storage-path/versioning plumbing                   | Implemented |
| Import engine core    | Batch/row staging, validation, preview, commit and lineage; rollback where safely reversible                      | Implemented |
| Import domains        | `contacts`, `legacy_open_receivables`, `legacy_open_payables` (DATA_CUTOVER items 7-8)                            | Implemented |
| Global search         | Permission-safe index kept current from the outbox; payroll/tax excluded                                          | Implemented |
| Application contracts | `src/schemas/documents.ts`/`imports.ts`/`search.ts`, matching `src/services`/`src/domain`                         | Implemented |
| Tests                 | pgTAP suite covering the guard/permission catalog, import staging/commit/rollback and search permission filtering | Implemented |
| Gate                  | Search cannot leak inaccessible Entity/payroll/tax records; import cannot bypass normal validation/posting rules  | Implemented |

Status: branch `p11-documents-imports-search` merged to `main` via PR #17. Documents
generalization, the import engine and the search index are all done and merged. Documents:
migrations `20260930100000_p11_permissions.sql` (system.import/
system.rollback_import/documents.export grants to finance_admin) and
`20260930100100_p11_documents.sql` (`app_private.document_target_kinds` catalog covering
bill/expense/invoice/fixed_asset/loan/other_obligation/equity_event/contact/journal_entry as
generic-linker kinds plus tax_filing/tax_payment as dedicated-linker kinds so P7's existing
tax-evidence linker keeps working unchanged; versioning via `supersedes_document_id`;
`finalize_document_upload`/`get_document_download_grant`/`list_documents`/`replace_document_link`).
Imports: `20260930100200_p11_imports.sql` (`import_batches`/`import_rows` staging -> validate ->
commit -> rollback with row-level errors and target_type/target_record_id as the batch lineage;
`contacts` domain delegates to `create_contact` so contacts keep one creation path;
`legacy_open_receivables`/`legacy_open_payables` land in the new non-posting `legacy_open_items`
table per DATA_CUTOVER items 7-8; within- and cross-batch fingerprint duplicate detection; rollback
archives an imported contact only when it has zero references elsewhere in the Entity, otherwise
retains and reports it; `import_batch` added as a linkable document-evidence kind). Search:
`20260930100300_p11_search.sql` (decision 145: `search_index` covers the nine `generic_linker=true`
kinds minus `import_batch`; a generic AFTER INSERT OR UPDATE trigger on each of the nine source
tables queues a `SearchReindexRequested` outbox event so freshness never depends on a command
function remembering to emit one; `refresh_search_index_batch` claims and re-derives pending events;
`search()` filters by `app_authz.has_permission(entity, row.permission_key)` BEFORE ranking, so an
inaccessible record is excluded from the result set itself, not merely hidden in the UI, Step 06
§11; `rebuild_search_index` is the full derived recovery path, Step 08 §22; payroll and tax are
never indexed, decisions 131/145). All three pass the full local pgTAP suite
(`supabase/tests/99_p11_1_documents.sql`, `99_p11_2_imports.sql`, `99_p11_3_search.sql`; all 29 test
files green on a clean rebuild). The application-layer contracts (`src/schemas/documents.ts`/
`imports.ts`/`search.ts` with matching `src/services`/`src/domain` modules, plus unit tests for the
label/schema completeness in `src/domain/documents/documents.test.ts`,
`src/domain/imports/imports.test.ts`, `src/domain/search/search.test.ts`) are typechecked, linted
and covered by the local unit suite (`pnpm check` green). The full `scripts/db-test.sh` (double
clean rebuild from migrations only, all 29 test files, all five concurrency suites including the
new document-number allocation check) passed with zero errors and identical schema fingerprints
across both rebuilds. `main`'s tip after the merge is the P11 merge commit. Open items: Command
Menu and the Documents Center/Import Wizard screens are a later slice (P13, DECISIONS 140); the
file-upload/signed-download route needs Supabase Storage configured outside this repo's migrations
(DECISIONS 142); OWNER to confirm the `legacy_open_items` rollback rule and the
`system.import`/`system.rollback_import` grant to `finance_admin` (DECISIONS 144, 146) before real
opening-balance data is imported at the P15 cutover.

## P12 checklist (Step 15 Phase 12, Step 12 §3-§5, §15, §17, §19, §31)

| Item                  | Done when                                                                                                         | Status      |
| --------------------- | ----------------------------------------------------------------------------------------------------------------- | ----------- |
| Canonical statements  | Profit & Loss, Balance Sheet, Statement of Changes in Equity, Cash Flow Statement, General Ledger drill-down      | Implemented |
| Year-end closing      | Idempotent close, P&L nets to zero into retained earnings, reversal with step-up, re-close after reversal         | Implemented |
| Custom Report Builder | Three curated datasets (invoices/customer, bills/vendor, expenses/payee), fixed branch -- never dynamic SQL       | Implemented |
| Consolidated Analysis | Cross-Entity cash position, `reports.cross_entity` gated, fails closed on any one unauthorized Entity             | Implemented |
| Application contracts | `src/schemas/reports.ts`, `src/services/reports`, `src/domain/reports`                                            | Implemented |
| Tests                 | pgTAP suite covering closing/reversal/re-close, all three statements, both curated-dataset and consolidated gates | Implemented |
| Gate                  | Statement equations and reconciliations pass; reports never invent a second financial truth (Step 12 Table 1)     | Implemented |

Status: branch `p12-reports` built from the post-P11 `main`. Year-end closing
(`20260930200000_p12_year_end_closing.sql`: `close_fiscal_year`/`reverse_fiscal_year_closing`,
`fiscal_year_closures`; fixed during this phase's own real-database testing to exclude a closing
journal's own housekeeping period from the "every period of the fiscal year must be closed" gate,
so a partial (non-December-ending) fiscal year can be re-closed after a reversal without the prior
closing permanently blocking it -- DECISIONS 148). Canonical statements
(`20260930200100_p12_financial_statements.sql`: `profit_and_loss`, `balance_sheet` with
`CURRENT_YEAR_EARNINGS` always computed live from posted P&L movement rather than a stored balance,
`statement_of_changes_in_equity`, `cash_flow_statement` direct-method from `money_movements`,
`general_ledger` drill-down with a running balance) reuse `trial_balance`'s raw debit/credit
convention (Step 13 §25); the natural-direction sign is applied once, in `src/domain/reports`, never
duplicated per statement (DECISIONS 149-150). Custom Report Builder and Consolidated Analysis
(`20260930200200_p12_consolidated_and_custom_reports.sql`: `run_custom_report` over three
PL/pgSQL-branched curated datasets plus the `report_datasets` discovery catalog,
`consolidated_cash_position` failing closed per-Entity on `reports.cross_entity`) match Step 12
§19's "never arbitrary SQL" constraint and §15's cross-Entity safety test (DECISIONS 151-152). All
three pgTAP files (`99_p12_1_closing.sql`, `99_p12_2_statements.sql`, `99_p12_3_reports.sql`) pass
the full local suite; the full `scripts/db-test.sh` (double clean rebuild from migrations only, all
32 test files, all five concurrency suites) passed with zero errors and identical schema
fingerprints across both rebuilds. The application-layer contracts (`src/schemas/reports.ts`,
`src/services/reports/reports.ts`, `src/domain/reports/reports.ts` with unit tests in
`src/domain/reports/reports.test.ts`) are typechecked, linted, formatted and covered by the local
unit suite (`pnpm check` and `pnpm build` both green). Open items: Reports screens (statement
viewers, the Custom Report Builder UI, Consolidated Analysis dashboard) are a later slice (P13),
like every other phase's screens; the Forecast projection methodology remains an open OWNER decision
from P10 (DECISIONS 139) and is out of scope for P12's reports.

PR #18 (`p12-reports` -> `main`): the CI job "Migration clean-rebuild and invariants" initially
failed -- a sync gap left the corrected `00_baseline_invariants.sql` (with the 9 new P12 RPCs added
to `rpc_allowlist`) out of commit `404a3a7`, even though the fix had already passed a full local
`scripts/db-test.sh` run before being committed (DECISIONS 153). Found via the CI log, fixed in a
follow-up commit that touches only that one file, and pushed; every other P12 file was re-verified
byte-identical between the build/test environment and the device. Awaiting CI green and the OWNER's
merge (same pattern as every prior PR: opened in a browser tab for the OWNER to click, work
continues on P13 rather than waiting idle).

## P13 checklist (Step 15 Phase 13, Step 09, Step 10, Step 11)

| Part                        | Scope                                                                                                                                                                  | Status      |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- |
| Part 1: Foundation & shell  | Design tokens (Step 10 §2, §4-§6), application shell -- sidebar, top bar, Entity switcher, Global Search, Command Menu, responsive shell (Step 09 §2-§8)               | Implemented |
| Part 2: Dashboard           | Overview screen reading only already-built report RPCs, no independent frontend financial truth (Step 09 §8, Step 10 §10-§13)                                          | Implemented |
| Part 3: Module screens      | Standard list/detail patterns (Step 09 §9-§10) applied to Sales, Purchases, Money, Accounting, Tax, Assets/Loans/Equity, Payroll, Planning (Step 09 §11-§18)           | In Progress |
| Part 4: Reports & Documents | Statement viewers, Custom Report Builder UI, Consolidated Analysis (DECISIONS 148); Documents Center (Step 09 §20); Command Menu quick-create registry (DECISIONS 140) | Not Started |
| Part 5: Documents & polish  | Invoice/Receipt customer-document templates (Step 11); responsive/mobile, accessibility, motion polish across every part (Step 09 §23, §25-§27; Step 10 §21-§25)       | Not Started |
| Gate                        | Dashboard KPI drill-down reconciles to report/source values; mobile essential workflows pass (Step 15 P13)                                                             | Not Started |

Status: unblocked this session -- the OWNER supplied every remaining Step spec document (Steps
02-17), including the three P13 depends on (Step 09 UI Sitemap + Screen Architecture, Step 10
Dashboard + Design System, Step 11 Invoice/Receipt Visual Specification), which were previously
absent from this environment. All three were read in full before any P13 code was written
(DECISIONS 154). Before this phase, the repository had no screens beyond the auth flow
(`/login`, `/auth/mfa`, `/auth/step-up`) and the public invoice token page (`/i/[token]`); every
other module is backend-only. Given that size, P13 ships as five parts, each its own PR with the
same `pnpm check`/`pnpm build`/`pnpm db:test` and docs-trail rigor as every P0-P12 slice
(DECISIONS 155). This row stays "In Progress" once Part 1 starts, and only reaches "Verified" once
every part has shipped and the Step 15 gate is demonstrated end-to-end -- not per-part, to avoid
implying Step 16 acceptance before the whole phase is done.

Part 1 (Foundation & shell) is implemented (DECISIONS 156): the full Step 10 token set (light/dark,
reduced-motion), `AppShell`/`Sidebar`/`TopBar`/`EntitySwitcher`/`CommandMenu` under
`src/features/shell/`, the permission-filtered sitemap in `src/domain/shell/navigation.ts` (single
source for both the Sidebar and the Command Menu's navigation results), the `(app)` route group
applying the shell to every authenticated screen, and a catch-all placeholder route so all ~50
sitemap destinations are already linkable even before their own screens exist. `pnpm check` and
`pnpm build` pass; `pnpm db:test` does not apply to this part (no migration or RPC touched -- pure
frontend). Not yet done in Part 1: wiring the Command Menu to search/quick-create beyond navigation
(deferred to Part 4 by design, DECISIONS 155) and the OWNER's review of the tuned token colors
(Open items, DECISIONS #243 equivalent).

Part 2 (Dashboard) is implemented (DECISIONS 160-163): `src/domain/dashboard/dashboard.ts` (pure,
unit-tested -- period resolution, the equity-statement net-result extraction, P&L/aging/cash/tax
aggregation, the Attention and Recent Activity merges) and `src/services/dashboard/dashboard.ts`
(`getDashboardSnapshot`, permission-gated per section against the actual RPC `has_permission`
checks, `Promise.all`-parallel) compose Finance, Cashflow Trend (6 trailing months), Receivables &
Payables, Tax Snapshot, Tasks & Attention, Account Snapshot and Recent Activity from RPCs P3/P5/P6/
P7/P9/P12 already shipped -- no new RPC, no independent frontend financial truth. The Profit/Surplus
KPI reads `statement_of_changes_in_equity`'s "Net result for the period" row, so it is structurally
guaranteed to reconcile to that statement once Part 4 builds its viewer (the Step 15 P13 gate).
`src/features/dashboard/*` renders it under `src/app/(app)/page.tsx` (replacing Part 1's
placeholder), with `?month=YYYY-MM` as the period selector. Scope-trim: Tasks & Attention excludes
pending invoice/bill approvals (Part 3's own workflow, DECISIONS 163). `pnpm check` and `pnpm build`
pass (325 tests, up from 303); `pnpm db:test` does not apply (no migration touched -- pure frontend
composition over existing RPCs).

### Part 3 sub-checklist (DECISIONS 164)

| Slice                                 | Scope (Step 09)     | Status      |
| ------------------------------------- | ------------------- | ----------- |
| 3a: Sales                             | §11 Invoice screens | In Progress |
| 3b: Purchases & Expenses              | §12                 | In Progress |
| 3c: Money / Accounts / Reconciliation | §13                 | In Progress |
| 3d: Accounting                        | §14                 | In Progress |
| 3e: Tax                               | §15                 | In Progress |
| 3f: Assets, Loans & Equity            | §16                 | In Progress |
| 3g: Payroll                           | §17                 | Not Started |
| 3h: Planning & Recurring              | §18                 | Not Started |

Part 3a (Sales) first increment is implemented (DECISIONS 165-166): Invoices List
(`/sales/invoices`, filter tabs from `invoiceFilterSchema` + a `?q=` search over the page's own
already-fetched rows) and Invoice Detail (`/sales/invoices/[id]`, Header/Summary/Activity/
Accounting/Tax/Documents/Audit per the Standard Record Detail Pattern, Documents reusing the
existing `InvoiceDocumentView`). Status actions Issue/Void/Correct/Copy Link call the unmodified P5
RPCs through small `useActionState` forms (`src/features/sales/actions.ts`,
`InvoiceActions.tsx`), gated per-permission exactly as each RPC's own migration checks. `pnpm check`
and `pnpm build` pass (342 tests, up from 325); `pnpm db:test` does not apply (no migration touched).
Not yet done in 3a: the Create/Edit invoice builder, Send, Payment Confirmation queue, Refund
actions, Customers, Products & Services, aging, Quick Preview's side drawer, saved views and export
(DECISIONS 165 records each as a deferred increment, not a silent omission).

Part 3b (Purchases) first increment is implemented (DECISIONS 167-168): Bills List
(`/purchases/bills`, filter tabs over a merged list -- `list_bill_positions` for approved/void plus
a direct RLS-governed read of draft/submitted/cancelled bills, decision 167's extension of the
direct-read pattern -- + a `?q=` search over the page's own already-fetched rows) and Bill Detail
(`/purchases/bills/[id]`, Header/Summary/Rincian Item (line items)/Activity/Accounting/Tax/
Documents/Audit per the Standard Record Detail Pattern plus one extra Line Items section, since
that data already exists and Step 09 §12 names it specifically). Status actions Submit/Recall/
Reject/Approve/Void/Correct/Cancel call the unmodified P6 RPCs through small `useActionState` forms
(`src/features/purchases/actions.ts`, `BillActions.tsx`), gated per-permission exactly as each
RPC's own migration checks. `pnpm check` and `pnpm build` pass (363 tests, up from 342); `pnpm
db:test` does not apply (no migration touched). A genuine `contacts.view`/`bills.view` permission
gap was found and filed for the OWNER rather than papered over (DECISIONS 168): the `approver`/
`tax` role templates lack `contacts.view`, so vendor-name resolution for in-preparation bills falls
back to `vendor_reference`/"Vendor" for those roles; the code is defensive (never throws) and the
gap is documented, not silently worked around. Not yet done in 3b: the Record Bill/Record Expense
builders, the Payment action, Expenses, Vendors, evidence upload, aging, Quick Preview's side
drawer, saved views and export (DECISIONS 167 records each as a deferred increment).

Part 3c (Money) first increment is implemented (DECISIONS 169): Accounts List (`/money/accounts`,
filter tabs over `money_control` merged with `reconciliation_status` by `financial_account_id` +
a `?q=` search) and Account Detail (`/money/accounts/[id]`, Header/Summary-as-Activity with the
account's own ledger from `account_activity` -- running balance, a `?from=`/`?to=` date filter,
and a `sourceTypeLabel` humanizer for each line's origin). Unlike Invoice/Bill Detail, an account
has no issue/void/correct-style actions, so the Accounting/Tax/Documents/Audit placeholders are
not repeated here -- a narrower, not different, application of the "coming soon" principle. `pnpm
check` and `pnpm build` pass (384 tests, up from 363); `pnpm db:test` does not apply (no migration
touched). Not yet done in 3c: the Transfer form, the Reconciliation workspace, balance
adjustments, Cash/Bank Activity (the Entity-wide feed), Create/Edit Account, and source links from
a ledger line to its originating record (DECISIONS 169 records each as a deferred increment).

Part 3c second increment adds Transfers List (`/money/transfers`), a Transfer create form
(`/money/transfers/new`) and Transfer Detail (`/money/transfers/[id]`) (DECISIONS 170): a direct
read of `public.transfers` (no RPC reads one), status actions Confirm/Cancel/Reverse gated exactly
as `confirm_transfer`/`cancel_transfer`/`reverse_transfer`'s own migrations check, and a Transfer
form whose account pickers only list the active Entity's own accounts so a PT<->Personal or
cross-Entity pair is structurally unselectable (Step 09 §13). Unlike Sales/Purchases, this create
form ships alongside List/Detail rather than deferred, since it is small (a handful of fields, no
line items). `pnpm check` and `pnpm build` pass (399 tests, up from 384); `pnpm db:test` does not
apply (no migration touched). Still not done in 3c: the Reconciliation workspace, balance
adjustments, Cash/Bank Activity, and Create/Edit Account.

Part 3c third increment adds Cash/Bank Activity (`/money/activity`, DECISIONS 171): an Entity-wide,
chronological feed across every account's `money_movements`, following the Standard List Screen
Pattern with an account-filter `<select>` in place of status tabs (this feed has no workflow status
of its own) plus the same `?from=`/`?to=` range filter and `?q=` search as elsewhere. Journal
numbers are resolved defensively (`getJournalNumbers`): a second authorization-model gap of the
same shape as DECISIONS 168 was found (`accounting.view` vs. this page's own `money.view`, affecting
the `finance_staff`/`approver` role templates) and handled the same way -- caught, returns an empty
`Map`, screen falls back to "—" rather than throwing; filed as an OWNER call, not silently resolved.
No running-balance column, unlike Account Detail's ledger: a running balance across mixed accounts
and currencies would not be meaningful. `pnpm check` and `pnpm build` pass (407 tests, up from 399);
`/money/activity` registers as a route; `pnpm db:test` does not apply (no migration touched). Still
not done in 3c: the Reconciliation workspace, balance adjustments, and Create/Edit Account.

Part 3d (Accounting) first increment is implemented (DECISIONS 172): Journal List
(`/accounting/journal`, a three-way `entry_type`/status/period filter toolbar + a `?q=` search) and
Journal Detail (`/accounting/journal/[id]`, Header/Lines (debit-credit grid)/Activity -- narrower
than the full Standard Record Detail Pattern, the same application decision 169 gave Account Detail,
since a journal's own lines already ARE its accounting detail) plus Chart of Accounts
(`/accounting/coa`, a read-only depth-first hierarchical tree with status/search filter and
protected-control indicators for Step 09 §14's "COA uses hierarchical tree/list with search, account
status and protected-control indicators"). No RPC lists or reads a journal, a journal's lines, a
ledger account or a period at all, so `src/services/accounting/ledger.ts` extends the direct-read
pattern (decisions 161/167/170/171) to `journal_entries`/`journal_lines`/`ledger_accounts`/
`accounting_periods`. Status actions Post/Discard Draft/Reverse call the unmodified P3 RPCs
(`post_journal`/`discard_journal_draft`/`reverse_journal`) through small `useActionState` forms
(`src/features/accounting/actions.ts`, `JournalActions.tsx`), gated per-permission exactly as each
RPC's own migration checks (`accounting.journal_post`/`accounting.journal_create`), and shown only
for `entry_type` manual/adjusting, matching what the RPCs themselves refuse. `pnpm check` and `pnpm
build` pass (448 tests, up from 407); `/accounting/journal`, `/accounting/journal/[id]` and
`/accounting/coa` register as routes; `pnpm db:test` does not apply (no migration touched). Not yet
done in 3d: Period Close, Opening Balances, the Manual Journal debit/credit grid builder, and
Advanced Adjustments (DECISIONS 172 records each as a deferred increment).

Part 3e (Tax) first increment is implemented (DECISIONS 173): Tax Overview (`/tax`, outstanding
balances by tax type, the Entity's own recorded tax facts, needs-review count, calendar steps due or
overdue in the last two months), Tax Ledger (`/tax/ledger`, Step 09 §15's own "filterable by tax
family, period, source, status and Entity" -- a four-way filter toolbar + `?q=` search) and Tax
Determination Detail (`/tax/determination/[sourceType]/[sourceId]`, answering Step 09 §15's "what
tax, why, rule/version, basis, rate/formula, amount and source transaction" for one document, current
determinations first and superseded ones kept underneath as history). Unlike every earlier Part 3
sub-slice, P7's tax RPCs were already fully service-wrapped before this increment
(`src/schemas/tax.ts`/`src/services/tax/tax.ts`, built during P7 itself), so this increment mostly
completed two under-typed schemas (`taxOverviewSchema`'s `profile`/`attention`, and a
`taxLedgerRowSchema.source_id` nullability bug fixed to match what the RPC actually returns) and
added the one genuinely missing read, `listTaxDeterminations`, extending the direct-read pattern
(decisions 161/167/170/171/172) to `tax_determinations`. Only `invoice`/`bill`/`expense` ledger
entries get a Determination Detail link; a `period` source (PPh Final UMKM's own monthly
determination, no single document) is deferred along with that whole family of screens. `pnpm check`
and `pnpm build` pass (463 tests, up from 448); `/tax`, `/tax/ledger` and
`/tax/determination/[sourceType]/[sourceId]` register as routes; `pnpm db:test` does not apply (no
migration touched). Not yet done in 3e: tax-facts recording forms, the rule master, the review queue
and line-confirmation workflow, payments/filings/evidence/reconciliation, PPh Final UMKM's compute
screen, Tax Calendar, Filing & Evidence, Tax Rules/Configuration, and the PPh Final/Withholding/PPN
family views (DECISIONS 173 records each as a deferred increment).

Part 3f (Assets, Loans & Equity) first increment is implemented (DECISIONS 174): Asset Register
(`/assets`, Step 09 §16's own "asset detail, acquisition source, depreciation, documents and
lifecycle" -- a status filter sent server-side to `asset_register`'s own `p_status` argument, plus a
client-side code/name search) and Asset Detail (`/assets/[id]`, Header/Summary/Schedule/Activity, plus
a Disposal section when the asset has been disposed). Like Tax, P8's fixed-asset RPCs were already
fully service-wrapped before this increment, so `listAssets`/`getAsset` needed no new wrapper at all;
only `getEntityBaseCurrency` (the same per-module direct-read duplicate every screen family now has)
was added. `pnpm check` and `pnpm build` pass (472 tests, up from 463); `/assets` and `/assets/[id]`
register as routes; `pnpm db:test` does not apply (no migration touched).

Part 3f second increment is implemented (DECISIONS 175): Loan Register (`/assets/loans`, Step 09
§16's own "Loan dashboard shows principal outstanding, next due, interest/fee split and schedule" --
direction and status filters sent server-side to `loan_list`'s own arguments, plus a client-side
loan-number/counterparty search) and Loan Detail (`/assets/loans/[id]`, Header/Ringkasan/Jadwal
Cicilan/Riwayat Pembayaran, plus a schedule-version history section when more than one version
exists). Like Assets, P8's loan RPCs were already fully service-wrapped before this increment, so
`listLoans`/`getLoan`/`getLoanSchedule` needed no new wrapper at all; only `getEntityBaseCurrency`
(the same per-module direct-read duplicate) was added. `pnpm check` and `pnpm build` pass (483 tests,
up from 472); `/assets/loans` and `/assets/loans/[id]` register as routes; `pnpm db:test` does not
apply (no migration touched). Not yet done in 3f: the Depreciation report, Other Receivables/Payables,
and Capital & Equity -- each its own independent capability with its own permission key -- plus the
loan origination/repayment/restructure/write-off action forms and the Loans Due/Loan Summary reports
(DECISIONS 174, 175 record each as a deferred increment).
