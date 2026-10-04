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
| P14   | Security / Performance / Recovery | P13          | Step 15 / Step 16 incl. backup export and restore drill            | In Progress |
| P15   | Production Launch                 | P14          | Step 15 / Step 16; taxpayer facts and OWNER sign-off               | In Progress |

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
| Part 3: Module screens      | Standard list/detail patterns (Step 09 §9-§10) applied to Sales, Purchases, Money, Accounting, Tax, Assets/Loans/Equity, Payroll, Planning (Step 09 §11-§18)           | Implemented |
| Part 4: Reports & Documents | Statement viewers, Custom Report Builder UI, Consolidated Analysis (DECISIONS 148); Documents Center (Step 09 §20); Command Menu quick-create registry (DECISIONS 140) | Implemented |
| Part 5: Documents & polish  | Invoice/Receipt customer-document templates (Step 11); responsive/mobile, accessibility, motion polish across every part (Step 09 §23, §25-§27; Step 10 §21-§25)       | In Progress |
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
| 3a: Sales                             | §11 Invoice screens | Implemented |
| 3b: Purchases & Expenses              | §12                 | Implemented |
| 3c: Money / Accounts / Reconciliation | §13                 | Implemented |
| 3d: Accounting                        | §14                 | Implemented |
| 3e: Tax                               | §15                 | Implemented |
| 3f: Assets, Loans & Equity            | §16                 | Implemented |
| 3g: Payroll                           | §17                 | Implemented |
| 3h: Planning & Recurring              | §18                 | Implemented |

Each 3a-3h row carries its own List/Detail/report surface only, exactly as its own increment
paragraphs below describe -- action forms and builders each increment explicitly deferred (create
flows, status-transition forms, the Recurring Rule template builder) are now shipped too (decisions
164-188), but a handful of report screens each sub-slice pushed to "the Reports Architecture slice"
(Loans Due/Loan Summary, Payroll Summary/Payroll Control, the Fiscal Depreciation Schedule/Asset
Movement/Asset GL reconciliation reports) remain open items for Part 4, not silently dropped.

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
apply (no migration touched).

Part 3f third increment is implemented (DECISIONS 176): Other Receivables (`/assets/other-receivables`)
and Other Payables (`/assets/other-payables`, Step 09 §16's own "simplified obligation screens without
forcing invoice/bill semantics" -- one screen component serving both, `kind` fixed per page, status
filtered server-side, a client-side number/counterparty/purpose search), sharing one Detail route
(`/assets/obligations/[id]`, Header/Ringkasan/Riwayat Pelunasan). A nav permission bug was found and
fixed while checking the RPC gate directly against its migration SQL: `src/domain/shell/navigation.ts`
listed `assets.view` for these two nav items, but `obligation_list`/`obligation_detail` actually check
`loans.view` -- fixed to match what the RPC already enforces. Like Loans, P8's obligation RPCs were
already fully service-wrapped, so `listObligations`/`getObligation` needed no new wrapper; only
`getEntityBaseCurrency` was added. `pnpm check` and `pnpm build` pass (491 tests, up from 483);
`/assets/other-receivables`, `/assets/other-payables` and `/assets/obligations/[id]` register as
routes; `pnpm db:test` does not apply (no migration touched).

Part 3f fourth increment is implemented (DECISIONS 177): Capital & Equity (`/assets/equity`,
`/assets/equity/[id]`, Step 09 §16's own "clearly separates contribution, return, dividend/distribution
and history" -- a `kind` filter alongside `status`, both sent server-side to `equity_list`'s own
arguments, plus a client-side number/counterparty/purpose search). Unlike Other Receivables/Payables,
the nav's own `equity.view` permission was already correct. Like every Part 3f screen family, P8's
equity RPCs were already fully service-wrapped, so `listEquityEvents`/`getEquityEvent` needed no new
wrapper; only `getEntityBaseCurrency` was added, plus a small domain gap filled (`EQUITY_CLASS_LABELS`,
which had no label map anywhere yet). Equity Detail is Header/Ringkasan, plus Riwayat Pembayaran only
when the event carries dividend payments. `pnpm check` and `pnpm build` pass (499 tests, up from 491);
`/assets/equity` and `/assets/equity/[id]` register as routes; `pnpm db:test` does not apply (no
migration touched). Only the Depreciation report remains unbuilt in 3f, plus every action form across
the whole capability (loan/obligation/equity) and the Loans Due/Loan Summary reports (DECISIONS 174,
175, 176, 177 record each as a deferred increment).

Part 3f fifth and final increment is implemented (DECISIONS 178): the Depreciation report
(`/assets/depreciation`, Step 12's report catalogue "Accounting Depreciation Schedule by asset/period").
This is the first report-shaped screen in the codebase -- it follows Step 09 §19's "filter bar + summary

- table" pattern instead of the Standard List Screen Pattern: a `?from=`/`?to=` date-range filter sent
  straight to `asset_depreciation_report`'s own arguments (`resolveDepreciationRange`, a trailing-12-months
  default, mirroring Cash/Bank Activity's own range resolver), a posted/scheduled totals summary band, and
  an attention band of `asset_depreciation_due` rows still postable, above the schedule-line table.
  `?q=` is a client-side asset code/name search. The nav's own `assets.view` permission was already
  correct, confirmed against the RPCs' migration SQL. Like every Part 3f screen family, P8's
  `depreciationReport`/`depreciationDue` were already fully service-wrapped, so no new RPC wrapper was
  needed; `getEntityBaseCurrency` was already on the Assets module from decision 174, so no new duplicate
  either. The schedule-line status badge reuses Asset Detail's own `depreciationLineStatusBadge` rather
  than a second copy, since both share the exact same status vocabulary. `src/domain/assets/depreciationReport.ts`
  (pure, unit-tested, 9 cases) is the only new domain file. `pnpm check` and `pnpm build` pass (508 tests,
  up from 499); `/assets/depreciation` registers as a route; `pnpm db:test` does not apply (no migration
  touched). Part 3f is now fully closed out (DECISIONS 174-178); remaining for a later slice: every action
  form across the whole capability, the depreciation run action (`postDepreciation`), the Fiscal
  Depreciation Schedule/Asset Movement/Asset GL reconciliation reports, and the Loans Due/Loan Summary
  reports (which belong with the Reports Architecture slice, P13 Part 5).

Part 3g first increment is implemented (DECISIONS 179): Employee Register (`/payroll/employees`) and
Employee Detail (`/payroll/employees/[id]`), Step 09 §17's own "Payroll is isolated as a sensitive
module; compensation is permission-gated." Like most of Part 3f, P9's employee RPCs were already
fully service-wrapped, so `listEmployees`/`getEmploymentHistory`/`getCompensation`/`getBpjsEnrolment`/
`getTaxProfile` needed no new wrapper; only `getEntityBaseCurrency` was added. The permission-gating
requirement is enforced by the database itself (`employee_list` never returns a compensation figure;
`employee_compensation_get`/`employee_bpjs_get` check the separate `payroll.compensation_view`,
`employee_tax_profile_get` checks `payroll.tax_view`) -- Employee Detail is the first screen in this
codebase to fetch optional sections conditionally on the viewer's own permission (`can()`, the same
helper Journal Detail uses for its action buttons) rather than gating the whole page. No per-employee
RPC exists, so Employee Detail looks the row up from the Entity-scoped `employee_list`, the same shape
Account Detail already uses. `pnpm check` and `pnpm build` pass (518 tests, up from 508);
`/payroll/employees` and `/payroll/employees/[id]` register as routes; `pnpm db:test` does not apply
(no migration touched). Remaining in 3g after the first increment: Payroll Runs (the full wizard),
Payslips, Payroll Tax & Liabilities, and every employee action form (DECISIONS 179 records each as a
deferred increment).

Part 3g second increment is implemented (DECISIONS 180): Payroll Run Register (`/payroll/runs`) and
Payroll Run Detail (`/payroll/runs/[id]`), Step 09 §17's own period -> employees -> calculation ->
review -> approval -> post/pay -> close wizard -- the List+Detail read surface only, same precedent as
every other Part 3 family; the wizard's own actions (calculate/adjust/submit/approve/post/pay/close/
reopen/correct, all already service-wrapped) get no button here yet. A new authorization shape was
found and matched exactly rather than approximated: `payroll_run_list`/`payroll_run_get` and friends
require BOTH `payroll.compensation_view` AND at least one of `payroll.run`/`payroll.approve`/
`payroll.pay` -- a compound rule `requirePermission`'s single-permission check cannot express, so both
pages call `requireAccess` directly and assert the same compound rule themselves with `can()`. The
"Payroll Runs" nav item had no permission of its own (inherited the parent's `payroll.employee_view`,
which plays no part in the RPC's own check) -- fixed to `payroll.compensation_view`, the closest match
the nav's OR-only permission model allows for a compound AND rule, honestly recorded as imperfect
rather than glossed over (DECISIONS 180 spells out the residual gap). Tax-specific fields on a run/line
are null for a viewer without `payroll.tax_view`, enforced by the RPC row-by-row -- shown as "—".
`pnpm check` and `pnpm build` pass (526 tests, up from 518); `/payroll/runs` and `/payroll/runs/[id]`
register as routes; `pnpm db:test` does not apply (no migration touched). Remaining in 3g after the
second increment: Payslips, Payroll Tax & Liabilities, and every payroll action form (employee and
run alike).

Part 3g third increment is implemented (DECISIONS 181): Payslip Register (`/payroll/payslips`) and
Payslip Detail (`/payroll/payslips/[id]`). Shares the exact same compound permission rule as Payroll
Runs (`payroll.compensation_view` AND at least one of `payroll.run`/`payroll.approve`/`payroll.pay`),
so both pages reuse the same `requireAccess` + manual `can()` pattern, and the "Payslips" nav item gets
the same permission fix. No Create button -- unlike every other Register screen, this is not deferred:
a payslip is issued as a side effect of the payroll run wizard, never created directly. Payslip Detail
is the first Detail screen with nothing that can go stale (`payroll_payslip_get` returns an immutable
issued-at snapshot, not a live recomputation), and introduces a third distinct tax-masking shape: the
whole `tax` key is absent from the snapshot for a viewer without `payroll.tax_view` (Employee Detail
skips the RPC call entirely; Payroll Run Detail nulls individual columns; here the key itself is gone).
`pnpm check` and `pnpm build` pass (533 tests, up from 526); `/payroll/payslips` and
`/payroll/payslips/[id]` register as routes; `pnpm db:test` does not apply (no migration touched).
Remaining in 3g after the third increment: Payroll Tax & Liabilities, and every payroll action form
(employee and run alike).

Part 3g fourth increment is implemented (DECISIONS 182): Payroll Tax & Liabilities (`/payroll/tax`).
Ships two of the five payroll report RPCs -- Payroll Liabilities (always visible, needs only the base
compound permission) and, gated further behind `payroll.tax_view`, Annual Reconciliation and the
Employee Tax Ledger (both hard-FORBIDDEN without it, so fetched only when the viewer holds it).
Payroll Summary and Payroll Control are deferred to the Reports Architecture slice (P13 Part 5), same
treatment as the Loans Due/Loan Summary reports. The nav item's permission (`payroll.tax_view` alone)
was wrong for the same reason as Payroll Runs/Payslips and got the identical fix
(`payroll.compensation_view`). Two new pure helpers with no prior precedent: `resolveAsOfDate` and
`resolveTaxYear`, each mirroring the matching RPC's own default/validation rather than inventing a new
one. `pnpm check` and `pnpm build` pass (538 tests, up from 533); `/payroll/tax` registers as a route;
`pnpm db:test` does not apply (no migration touched). This closes out every Payroll nav item except
the action forms -- Part 3g's List/Detail/report surface is now fully shipped.

Part 3h (Planning & Recurring) first increment is implemented (DECISIONS 183): Recurring Rules
Register (`/planning/recurring`) and Recurring Rule Detail (`/planning/recurring/[id]`), Step 09
§9-§10, §18. This is Part 3's own final lettered sub-slice (decision 164). Unlike every Payroll
increment, Planning's read RPCs check a single permission (`planning.view`) confirmed directly
against `app_private.planning_authorize`, and the nav item's own permission was already correct --
no fix needed here, the first Part 3 family where that has been true. No per-rule RPC exists, so
Detail fetches `list_recurring_rules` and finds the row by id (the same precedent decisions 169/179
established); occurrence history (`list_recurring_occurrences`) is always rendered with an
empty-state message since generated history is this screen's own reason to exist per Step 09 §18's
own wording. A generated occurrence links onward only for `invoices`/`bills` (both have a Detail
route); a generated `expense` shows as plain text since no Expense Detail screen exists yet. The
rule's own template (arbitrary per-kind jsonb line items) is not rendered -- a later builder
increment needs to interpret it anyway. `pauseRecurringRule`/`resumeRecurringRule`/
`endRecurringRule`/`runDueRecurringOccurrences` and the create/edit template builder are deferred
together to a later increment; `recurringRuleActions`' eligibility booleans are shown only as an
inert hint sentence for now. `getEntityBaseCurrency` was added to the planning service module ahead
of need, for the Budgets/Revenue Targets increments still to come. `pnpm check` and `pnpm build`
pass (545 tests, up from 538); `/planning/recurring` and `/planning/recurring/[id]` register as
routes; `pnpm db:test` does not apply (no migration touched). Remaining in 3h: Budgets, Revenue
Targets (list/detail/report for both), Forecasts (folds into the Budget/Target report screens rather
than becoming its own route, per decision 139's "no locked projection methodology" ruling), and
every Recurring/Budget/Target action form.

Part 3h second increment is implemented (DECISIONS 184): Budget Register (`/planning/budgets`) and
Budget Detail (`/planning/budgets/[id]`). Same single `planning.view` read permission as Recurring
Rules, confirmed against each RPC's own SQL; writes check `planning.budget_edit` instead, deferred
with the rest of the action forms. Detail fetches the register and finds the row by id (no per-budget
RPC exists) and uses `get_budget_report` alone for its own Anggaran vs Aktual table -- the report RPC
is a strict superset of `get_budget_lines`, already carrying budgeted/actual/committed/remaining/%
used/variance per category and month. `forecast_amount` gets no column (always null, decision 139).
`src/domain/planning/budgetList.ts` introduces the shared `PlanStatus` badge/filter helpers, kept in
one file since Revenue Targets (still pending) uses the identical enum, not duplicated a second time.
`pnpm check` and `pnpm build` pass (551 tests, up from 545); `/planning/budgets` and
`/planning/budgets/[id]` register as routes; `pnpm db:test` does not apply (no migration touched).
Remaining in 3h: Revenue Targets (list/detail/report), and every Recurring/Budget/Target action form.

Part 3h third increment is implemented (DECISIONS 185): Revenue Target Register (`/planning/targets`)
and Revenue Target Detail (`/planning/targets/[id]`). Completes Part 3h's list/detail surface. Same
single `planning.view` read permission as Recurring Rules and Budgets; writes check the same
`planning.budget_edit` Budgets uses (no separate revenue-target permission), deferred with the rest of
the action forms. Detail fetches the register and finds the row by id (no per-target RPC exists) and
uses `get_revenue_target_report` alone -- unlike Budgets, a revenue target has no category breakdown
(Step 01 #23 names none), so the report is one row per month, entity-wide (Target/Actual/AR
Outstanding/Variance), with no Committed or %Used column since neither concept exists without a
category. `forecast_amount` gets no column (always null, decision 139). `src/domain/planning/
budgetList.ts` gains `matchesRevenueTargetQuery`/`filterRevenueTargetRows` alongside the existing
Budget pair, reusing the same shared `PlanStatus` badge/filter helpers -- no new file. `pnpm check`
and `pnpm build` pass (554 tests, up from 551); `/planning/targets` and `/planning/targets/[id]`
register as routes; `pnpm db:test` does not apply (no migration touched). This completes Part 3h's
list/detail surface. Remaining in 3h: Forecasts (folds into the Budget/Target report screens rather
than becoming its own route, per decision 139's ruling), and every Recurring/Budget/Target action
form. Completing those closes out all of Part 3 (decision 164) -- Part 4 is next per decision 155.

Part 3h fourth increment is implemented (DECISIONS 186): status-transition action forms --
Recurring Rule pause/resume/end plus the entity-wide manual "generate now" button
(`planning.recurring_run`), and Budget/Revenue Target activate/close (sharing `planning.budget_edit`).
New `src/features/planning/actions.ts` mirrors `transferActions.ts` exactly; a new `budgetActions`
helper in `budgetList.ts` mirrors the existing `recurringRuleActions`, shared by Budget and Revenue
Target. Pause/End require a 5-1000 character reason (reveal-confirm, `ReverseForm` shape); Resume and
Activate need no reason; Close is terminal for both plan types and gets a reveal-confirm with no
reason field. "Generate now" is entity-wide, not per-rule, so its button sits on the Recurring Rules
Register header rather than Detail. All three Detail screens and their `page.tsx` files now compute
and pass a `permissions` prop via the same active-Entity `can()` pattern Invoice Detail uses.
`pnpm check` and `pnpm build` pass (557 tests, up from 554); `pnpm db:test` passes (no migration
touched). This closes out every action form decision 185 listed as remaining except create and the
"set lines"/template builders, still deferred (genuinely new UI territory, no editable multi-row grid
precedent exists in this codebase) -- Part 3h's status-transition surface is otherwise complete.

Part 3h fifth increment is implemented (DECISIONS 187): Budget/Revenue Target create forms
(`/planning/budgets/new`, `/planning/targets/new`, gated on `planning.budget_edit`, redirecting to
the new record's own Detail page on success) and their "set lines" editable grids on Detail
(`BudgetLinesEditor`/`RevenueTargetLinesEditor`, wholesale-replacing via `set_budget_lines`/
`set_revenue_target_lines`, pre-populated from `get_budget_lines`/`get_revenue_target_lines`). A new
`listActiveCategories` (`src/services/accounting/categories.ts`, backed by `src/schemas/
categories.ts`) is the first direct table read this codebase has added purely to back a picker --
`categories_select` needs only Entity membership, no new permission or RPC required, and it is not
filtered by `kind` since neither `budget_lines`'s FK nor `set_budget_lines` restricts one. One shared
`CreatePlanForm` covers both Budget and Revenue Target (identical create-shell fields); the two "set
lines" editors deliberately differ in shape -- Budget is a real category x month grid, Revenue Target
a flat month list -- matching the same category/no-category asymmetry their own report tables already
have (decision 185). Both editors share a new pure `monthRangeInclusive` helper
(`src/domain/planning/planning.ts`, unit-tested) for their month columns/rows, and both serialize their
row state into one hidden `lines` JSON field per submit rather than a dynamic per-cell field set.
`pnpm check` and `pnpm build` pass (560 tests, up from 557); `/planning/budgets/new` and
`/planning/targets/new` register as routes; `pnpm db:test` does not apply (no migration touched --
this was a pure application-layer increment). Remaining in 3h: Recurring Rule's own create/edit
template builder (invoice/bill/expense line items), materially larger and still deferred to a later
increment (decisions 164, 183, 186-187's own ordering) -- every other Part 3h screen and action form is
now complete.

Part 3h sixth increment is implemented (DECISIONS 188): Recurring Rule's own create/edit template
builder -- the one piece deferred since decision 186. Most of the backend (schemas, service wrappers)
already existed from P10; this increment is UI plus three new pickers (`listActiveContacts`/
`listActiveFinancialAccounts`/`listActivePaymentChannels` in `src/services/planning/planning.ts`,
the same "no RPC exists, direct RLS-scoped table read" shape `listActiveCategories` set in decision
187). One shared `RecurringRuleForm` (new) covers both create (`/planning/recurring/new`, gated on
`planning.recurring_edit`) and edit (rendered inline on Recurring Rule Detail, gated by
`permissions.canManage` and `recurringRuleActions(status).canEdit`) since `create_recurring_rule`/
`update_recurring_rule` both take the whole `template` as one jsonb parameter; `kind`/`frequency`/
`start_date` are immutable after creation (confirmed against `update_recurring_rule`'s own SQL) and
rendered read-only in edit mode, while every template header field and the lines grid stay editable
in both modes. `RecurringLinesEditor` (new) is a plain repeating-row grid (not Budget's category x
month shape) covering description/quantity/unit price/category for every kind plus treatment
(expense/asset/prepaid) for bill/expense, filtering the category picker by kind and treatment
together exactly as `purchase_prepare_lines` itself validates; every other optional tax/discount field
those RPCs accept stays unexposed in this v1 UI (defaulted at generation time) but is preserved
verbatim on a re-save via each row's own `extra` bag. The Register screen gained a "Buat Aturan Baru"
button (`canCreate`), the same conditional-Link-button precedent Budget/Revenue Target use. `pnpm
check` and `pnpm build` pass (560 tests, unchanged -- no new domain logic, only UI/service/schema
plumbing); `/planning/recurring/new` registers as a route; `pnpm db:test` does not apply (no migration
touched). This closes out Part 3h in full, and with it all of Part 3 (decision 164) -- Part 4 (Reports
Architecture, Documents Center, Command Menu quick-create) is next per decision 155's own sequence.

Part 4 first increment is implemented (DECISIONS 189): the Financial Reports statement viewer
(`/reports`, nav's "Financial Reports" sub-item), the four canonical statements P12 already computes
-- Profit & Loss, Balance Sheet, Statement of Changes in Equity, Cash Flow Statement -- switched by
`?statement=` (`list-filter-tabs`, the same pattern every Part 3 status-filter toolbar already uses),
each with its own date filter form (`?from=`/`?to=` year-to-date default for P&L/Equity/Cash Flow,
`?as_of=` today default for Balance Sheet). No new RPC, schema or service wrapper beyond
`getEntityBaseCurrency` (decision 161's exact duplicated-per-service shape) -- every figure is P12's
own already-computed debit/credit, re-signed once via `naturalAmount`. New pure domain helpers in
`src/domain/reports/reports.ts` (unit-tested, 560 -> 577 tests): `resolveReportRange`/
`resolveAsOfDate` (the same fallback shape as `resolveActivityRange`/`resolveDashboardPeriod`, but
year-to-date rather than a trailing window -- the reading a person actually wants on first opening a
statement), `groupByAccountClass` (sections a statement's rows by `account_class` in a fixed order,
skipping empty classes), `pnlNetIncome`/`balanceSheetTotals`/`equityRowAmounts`/`equityClosingTotal`/
`cashFlowTotals` (each a display-only reconciliation check -- Balanced/Tidak seimbang, Rekonsiliasi
cocok/Tidak cocok -- never a correction, since a Balance Sheet or Cash Flow Statement built from
posted double-entry journals always reconciles by construction; `pnlNetIncome`'s income-minus-cost
split is algebraically identical to `balance_sheet`'s and `statement_of_changes_in_equity`'s own
"Current Year Earnings"/"Net result for the period" `v_pl_net := v_pl_credit - v_pl_debit`
derivation, so the P&L's own net total is structurally guaranteed to reconcile to both of those,
satisfying the Step 15 P13 gate's reconciliation requirement for this slice). Three new
`.record-table` row classes (`statement-section-row`/`statement-subtotal-row`/`tfoot` styling) added
to `globals.css`, reusing the table's own existing look rather than a new component. `pnpm check`
and `pnpm build` pass (577 tests, up from 560); `/reports` registers as a route; `pnpm db:test`
passes (double clean rebuild, no migration touched -- confirms nothing in this pure frontend
increment disturbed the schema). Deferred to later Part 4 increments, recorded rather than silently
dropped: General Ledger drill-down (`general_ledger`, the fifth P12 statement RPC -- an account
picker plus running-balance card), the P&L comparison-period columns (`compare_start_date`/
`compare_end_date`, already in the schema/service but not surfaced in this v1 UI), the Custom Report
Builder UI, Consolidated Analysis, the Documents Center, and the Command Menu quick-create registry.
The other Reports nav sub-items (Sales/Purchase, a standalone Cashflow view, Tax, Payroll,
Assets/Loans, Saved Reports) have no P12 RPC behind them at all and correctly fall through to the
`[...slug]` "coming soon" placeholder (decision 157's precedent) rather than getting an empty screen
of their own; each of the P13 3f/3g "belongs with the Reports Architecture slice" report deferrals
(Loans Due/Loan Summary, Payroll Summary/Payroll Control, the three Asset reconciliation reports)
remains open for a future Part 4 increment too.

Part 4 second increment is implemented (DECISIONS 190): the General Ledger drill-down, a fifth tab
(`?statement=gl`) on the same `/reports` screen -- an account picker plus a running-balance card,
exactly the shape the first increment's own deferred-item note named. Reads `general_ledger` (P12,
already typed and wrapped, unused until now) with a specific `p_account`, never the RPC's other mode
(`p_account` omitted, a flat cross-account Journal Report) -- that remains its own future increment,
not silently folded into this one. The account picker reads `listLedgerAccounts` (already built for
the Chart of Accounts screen), filtered to posting accounts. New pure domain helper
`resolveGeneralLedgerAccount` in `src/domain/reports/reports.ts` (unit-tested, 577 -> 584 tests)
falls back to the first posting account by code on a missing/unknown/group id, matching
`resolveReportRange`/`resolveAsOfDate`'s own "never block on a missing filter" shape; `null` only
when the Entity has no posting account at all. `generalLedgerTotals` sums the period's own
debit/credit and reads the closing balance off the last row's own `running_balance` -- explicitly
the balance _within the requested range_, not a true carried-forward opening balance, since the RPC
itself has no opening-balance parameter. Each row links its journal number to the existing Journal
Detail screen rather than duplicating it. No new RPC, schema or service wrapper. `pnpm check`,
`pnpm format:check` and `pnpm build` pass (584 tests, up from 577); `/reports?statement=gl` renders;
`pnpm db:test` passes (schema fingerprint unchanged at `5335133e42e3`). Still deferred, per the first
increment's own list minus this item: the P&L comparison-period columns, the Custom Report Builder
UI, Consolidated Analysis, the Documents Center, and the Command Menu quick-create registry.

Part 4 third increment is implemented (DECISIONS 191): the P&L comparison-period columns, an
optional second date pair on the same `/reports?statement=pnl` RangeForm -- when set, the table
grows a "Periode Pembanding" and "Selisih" column, sourced entirely from `profit_and_loss`'s own
already-typed `p_compare_start`/`p_compare_end`/`compare_debit`/`compare_credit`, unused since the
first increment (DECISIONS 189). New pure domain helpers `resolveCompareRange` (falls back to no
comparison, never a guessed default period, on anything missing/partial/invalid/inverted) and
`hasPnlComparison`/`pnlCompareAmount`/`pnlCompareSubtotal`/`pnlCompareNetIncome` (mirroring
`pnlNetIncome`'s own income-minus-cost split for the comparison figures). No comparison requested
renders the v1 table unchanged. No new RPC, schema or service wrapper. `pnpm check`,
`pnpm format:check` and `pnpm build` pass (593 tests, up from 584); `pnpm db:test` passes (schema
fingerprint unchanged at `5335133e42e3`). Still deferred, per the second increment's own list minus
this item: the Custom Report Builder UI, Consolidated Analysis, the Documents Center, and the
Command Menu quick-create registry.

Part 4 fourth increment is implemented (DECISIONS 192): the Custom Report Builder UI, a sixth
`/reports?statement=custom` tab over `run_custom_report`'s three curated datasets (invoices by
customer, bills by vendor, expenses by payee) -- `runCustomReport`/`listReportDatasets` and their
schemas already existed since P12, unused until now. The dataset picker only ever lists datasets the
active membership's own `required_permission` actually covers (checked locally via `can`, no second
round trip), so it never offers a choice the RPC would reject. New pure domain helpers
`resolveCustomReportDataset` (falls back to the first permitted dataset on anything missing, unknown,
or filtered out) and `customReportTotals` (grand-total row over the RPC's own per-dimension count/sum).
Column headers come from the selected dataset's own catalog row (`dimension_label`/`measure_label`),
not a hardcoded label, so a future dataset needs no frontend change. No new RPC, schema or service
wrapper. `pnpm check`, `pnpm format:check` and `pnpm build` pass (600 tests, up from 593); `pnpm
db:test` passes (schema fingerprint unchanged at `5335133e42e3`). Still deferred, per the third
increment's own list minus this item: Consolidated Analysis, the Documents Center, and the Command
Menu quick-create registry.

Part 4 fifth increment is implemented (DECISIONS 193): the Consolidated Analysis dashboard, a
seventh `/reports?statement=consolidated` tab over `consolidated_cash_position`'s cross-Entity cash
position -- `getConsolidatedCashPosition` and its schemas already existed since P12, unused until
now. Unlike every other Reports tab this one is not scoped to a single active Entity: the Entity
checkboxes only ever list what the caller holds `reports.cross_entity` for (checked locally via
`can` against the already-loaded access snapshot), mirroring the fourth increment's own
filter-before-offering shape for datasets. New pure domain helpers `resolveConsolidatedEntityIds`
(falls back to every eligible Entity when nothing requested survives the permission filter) and
`consolidatedCashPositionTotals` (grand total across Entities, `null` rather than a silently wrong
number whenever the selected Entities do not all share one base currency -- each Entity's own
currency is looked up separately, since the RPC returns none and Company/Personal books are never
merged). No new RPC, schema or service wrapper. `pnpm check`, `pnpm format:check` and `pnpm build`
pass (608 tests, up from 600); `pnpm db:test` passes (schema fingerprint unchanged at
`5335133e42e3`). Still deferred, per the fourth increment's own list minus this item: the Documents
Center and the Command Menu quick-create registry.

Part 4 sixth increment is implemented (DECISIONS 194): the Documents Center listing at `/documents`
-- search by name, filter by target kind, permission-scoped, the only requirement traced for Step
09 §20 in this repository. `listDocuments` and its schemas already existed since P11, unused until
now. New pure domain helpers `DOCUMENT_TARGET_TYPE_FILTER_OPTIONS`/`parseDocumentTargetTypeFilter`
mirror `parseBillFilter`'s "unrecognized filter shows everything" shape (a listing's natural
default is unfiltered, unlike a report's "always pick one" account/dataset selector), and
`documentTargetTypesLabel` renders a document's possibly-multiple linked target kinds as one
string. Unlike every List screen before Part 4, `list_documents` filters and paginates
server-side, so the route passes `?target_type=`/`?q=`/`?offset=` straight through as RPC
arguments. Deliberately excluded this increment: Upload (Storage is not yet configured), a
per-document detail/download view (not traced as required), and the `/documents/uploads`,
`/documents/evidence`, `/documents/archive` nav sub-routes (their exact semantics are not stated
anywhere in this repository, so they keep falling through to the "coming soon" placeholder). No new
RPC, schema or service wrapper. `pnpm check`, `pnpm format:check` and `pnpm build` pass (616 tests,
up from 608); `pnpm db:test` passes (schema fingerprint unchanged at `5335133e42e3`). Still
deferred, per the fifth increment's own list minus this item: the Command Menu quick-create
registry, the three Documents nav sub-routes, and Documents Center upload/download/detail.

Part 4 seventh increment is implemented (DECISIONS 195): the Loans Due and Loan Summary reports, an
eighth and ninth `/reports` tab over `loan_due`/`loan_summary` -- `loansDue`/`loanSummary` and their
schemas already existed since P8, unused until now. Imported straight from the financing module
into the Reports screen/route rather than duplicated into the reports schemas/services, the same
shape the General Ledger tab already uses for `listLedgerAccounts`. Unlike every other Reports tab,
these two RPCs are gated by `loans.view`, not `reports.view` -- the `tax` role holds the latter but
not the former in the seed catalog -- so the route checks `can(access, membership.entity_id,
"loans.view")` before calling either RPC and shows a plain permission message instead of an error
when it is false, the same "never surface a choice the RPC would reject" rule the Custom Report
Builder and Consolidated Analysis tabs already follow. New pure domain helpers
`resolveLoanDueThrough` (mirrors `resolveAsOfDate`, but defaults to 30 days out, matching the RPC's
own default) and `loanDueTotals`/`loanSummaryTotals` (grand-total rows, the same "already in each
row" shape every other totals helper uses); Loan Summary's own period reuses `resolveReportRange`
unchanged, needing no new helper. Both tables reuse `loanScheduleStateBadge`/`LOAN_DIRECTION_LABELS`
from Loan Register/Detail unchanged, and each row links to the existing Loan Detail screen. No new
RPC, schema or service wrapper. `pnpm check`, `pnpm format:check` and `pnpm build` pass (622 tests,
up from 616); `pnpm db:test` passes (schema fingerprint unchanged at `5335133e42e3`). Still
deferred, per the sixth increment's own list minus this item: the Command Menu quick-create
registry, the three Documents nav sub-routes, Documents Center upload/download/detail, and the
Payroll Summary/Control and Fiscal asset reports.

Part 4 eighth increment is implemented (DECISIONS 196): the Payroll Summary and Payroll Control
reports, a tenth and eleventh `/reports` tab over `payroll_summary_report`/`payroll_control_report`
-- `getPayrollSummary`/`getPayrollControl` and their schemas already existed since P9, unused until
now. Before building, whether these tabs would be practically reachable was raised with the OWNER:
no seeded role holds `reports.view` together with the full payroll-run permission set these RPCs
require. The OWNER confirmed the `owner` role's own unconditional access (every `has_permission`
check passes for `role_key = 'owner'`) resolves this -- the tabs are reachable by the OWNER, same as
every other Reports tab, so building them under `/reports` was correct. The route computes
`canViewPayroll` (the compound base rule already used by Payroll Runs/Payslips/Tax: `payroll.
compensation_view` AND run/approve/pay) once and reuses it for both tabs, Payroll Control's own
`canView` additionally requiring `accounting.view` (a hard RPC-level FORBIDDEN, not a mask) -- never
surfacing a call either RPC would reject, showing a plain permission message instead of an error
when false. New pure domain helpers `payrollSummaryTotals` (grand totals, with a private
`sumMaskedColumn` returning `null` rather than a misleading zero when a tax-masked column is fully
masked in view, the same "has*-or-null" idiom as the P&L comparison columns), `payrollControlAccountLabel`
(labels the two fixed account keys, falls back to the raw key), `payrollControlSummary` (a mismatch
count, deliberately no grand total across the two unrelated liability accounts) and
`payrollControlRowBalanced` (the same zero-check, exposed per row for the table's badges). No new
RPC, schema or service wrapper. `pnpm check`, `pnpm format:check` and `pnpm build` pass (631 tests,
up from 622); `pnpm db:test` passes (schema fingerprint unchanged at `5335133e42e3`). Still deferred,
per the seventh increment's own list minus this item: the Command Menu quick-create registry, the
three Documents nav sub-routes, Documents Center upload/download/detail, and the Fiscal Depreciation
Schedule/Asset Movement/Asset GL reconciliation reports.

Part 4 ninth increment is implemented (DECISIONS 197): the Fiscal Depreciation Schedule and Asset GL
Reconciliation reports, a twelfth and thirteenth `/reports` tab over `asset_fiscal_schedule`/
`asset_control_report` -- `fiscalSchedule`/`assetControl` and their schemas already existed since P8,
unused until now. Both are gated by `assets.view` plus a second hard-required permission (`tax.view`
for the schedule, `accounting.view` for the reconciliation) -- unlike Payroll Summary/Control, the
`accountant` and `viewer_auditor` seed roles already hold every permission either tab needs together
with `reports.view`, so no OWNER-reachability question arose here. Unlike every other Reports tab,
`asset_fiscal_schedule` takes one asset, not the active Entity, so this tab needed its own record
picker: the route reads `listAssets` and resolves the requested one with a new
`resolveFiscalScheduleAsset`, mirroring `resolveGeneralLedgerAccount`'s exact "always resolve to
something sensible" contract. The RPC itself legitimately returns an empty schedule for an asset
with no fiscal class or in `draft`/`cancelled` status, so the picker is never filtered down to only
depreciable assets. New pure domain helpers: `resolveFiscalScheduleAsset` (above);
`fiscalScheduleTotalDepreciation` (grand total of the schedule's own `depreciation` column);
`assetControlAccountLabel`/`assetControlSummary`/`assetControlRowBalanced`, a second, asset-specific
copy of Payroll Control's own three small helpers (same shape, different account keys and labels)
rather than repurposing the payroll-named ones across an unrelated module. No new RPC, schema or
service wrapper. `pnpm check`, `pnpm format:check` and `pnpm build` pass (643 tests, up from 631);
`pnpm db:test` passes (schema fingerprint unchanged at `5335133e42e3`). Still deferred, per the
eighth increment's own list minus these two items: the Command Menu quick-create registry, the three
Documents nav sub-routes, Documents Center upload/download/detail, and the Asset Movement/Disposal
Report (no dedicated RPC yet -- new backend work).

Part 4 tenth increment is implemented (DECISIONS 198): the Documents Center's `/documents/uploads`
("Unggahan Belum Ditautkan") and `/documents/evidence` ("Bukti Tertaut") sub-routes, both already
declared in the nav but previously falling through to the "coming soon" placeholder since their exact
semantics were unstated anywhere in this repository. Two scoping questions were put to the OWNER first:
Command Menu quick-create (OWNER chose the 4-item registry limited to the four existing `/new` routes,
a separate increment, not yet built) and Documents Center scope (OWNER's free-text answer, "harus di
selesaikan", did not match either offered option). Resolved as far as the schema itself grounds an
answer: `list_documents` already returns `link_count` per document, which distinguishes a raw upload
nothing has been linked to yet (`link_count = 0`) from evidence attached to a real record
(`link_count > 0`) -- exactly what the nav's own "Uploads"/"Linked Evidence" labels already name. New
pure domain helper: `filterDocumentsByLinkStatus`, a plain display filter over an already
permission-scoped, already-fetched page (never a second permission check or financial computation).
`list_documents`'s own WHERE clause returns an unlinked document only when no `target_type` filter is
supplied, so `/documents/uploads` never sends one and hides its filter-tab row entirely rather than
offering a combination that would always come back empty. `DocumentsListScreen` was generalized with
four optional props (`basePath`, `title`, `showTargetTypeFilter`, `hasMore`), all defaulting to the
exact prior `/documents` behavior, instead of two near-duplicate screens. Filtering the fetched page
client-side by link status meant "Berikutnya" needed its own fix: both new routes compute `hasMore`
from the _raw_ fetched page length before filtering, passed down as an explicit prop, so pagination
keeps reflecting the RPC's real windowing even though the displayed row count shrinks. The third
declared sub-route, `/documents/archive`, stays deferred with a precise reason: `supersedes_document_id`
exists on the table but no RPC, including `list_documents`, ever reads or returns it -- there is no way
to render a supersession chain without new backend work. No new RPC, schema or service wrapper for
Uploads/Evidence themselves. `pnpm check`, `pnpm format:check` and `pnpm build` pass (646 tests, up
from 643); `pnpm db:test` passes (schema fingerprint unchanged at `5335133e42e3`). Still deferred, per
the ninth increment's own list minus this item: the Command Menu quick-create registry (OWNER-approved
4-item scope, not yet built), the `/documents/archive` sub-route, Documents Center upload/download/
detail, and the Asset Movement/Disposal Report.

Part 4 eleventh increment is implemented (DECISIONS 199): the Command Menu quick-create registry, the
OWNER's answer to the first of two scoping questions asked alongside the Documents Center question in
DECISIONS 198. Most modules (invoices, bills, loans, obligations, equity, assets, and more) have no
create form/UI yet, so the OWNER chose to scope this to exactly the four `/new` routes that already
exist ("Registry terbatas 4 item dulu"): Transfer Uang, Anggaran, Aturan Berulang and Target Pendapatan.
New domain module `src/domain/shell/quickCreate.ts`: `QUICK_CREATE_REGISTRY` (the four entries) and
`visibleQuickCreate(permissions)`, mirroring `visibleNavigation`'s own "unavailable by permission is
omitted" contract but gated on a single required permission per item, since every `/new` route checks
exactly one permission (never a compound/OR rule the way some nav items only approximate). `CommandMenu`
takes a new `quickCreate` prop, already filtered by `AppShell` the same way its existing `groups` prop
is; quick-create entries are flattened into the same searchable result list as navigation entries
(labelled "Buat Baru"), not a separate always-visible section, so they search and sort through the
identical pipeline. Global Search stays unwired into the Command Menu -- still no settled data-fetching
pattern for a server-backed result source inside this synchronous local-filter shell. No new RPC, schema
or service wrapper; no component-level test file, matching the existing convention that `src/features/**`
components have none of their own. `pnpm check`, `pnpm format:check` and `pnpm build` pass (653 tests,
up from 646); `pnpm db:test` passes (schema fingerprint unchanged at `5335133e42e3`). Still deferred, per
the tenth increment's own list minus this item: the `/documents/archive` sub-route, Documents Center
upload/download/detail, and the Asset Movement/Disposal Report. The registry itself grows automatically
as future increments ship more `/new` routes.

Part 4 is closed (DECISIONS 200): every screen decision 155 assigned to it has shipped. Part 5 opens
with its first increment: bringing `InvoiceDocumentView`/`ReceiptDocumentView` (`src/features/sales/`,
built in P5 before P13 existed) up to Step 11 -- Invoice/Receipt Visual Specification, which
`globals.css`'s own `.doc*` comment had flagged since P5 as "final design comes with P13." Three
concrete gaps fixed: (1) the Invoice document view's own local three-tone status label had drifted from
`invoiceDocumentStatus`, the exact status the Invoice List/Detail screens already show for the same
invoice -- fixed by calling that existing helper directly; the Receipt view gets a matching new
`paymentReceiptStatus` (`src/domain/sales/receiptDocument.ts`), since no receipt-status helper existed
yet. (2) Every `.doc*` CSS rule inherited the app's own dark-mode-aware tokens while `.doc` hard-coded a
white background -- in dark mode this put near-white text on that white canvas, a genuine contrast
failure against Step 11 §2/§18. Fixed with `.doc`'s own fixed `--doc-*` tokens, never redefined under
`prefers-color-scheme: dark`; the surrounding print/download chrome deliberately keeps the app's own
theme-aware tokens, since Step 11 §8 allows that. (3) Step 11 §12's VOID state had no watermark -- added
a faint, print-visible diagonal mark; REFUNDED is now shown as a totals line using the already-fetched
`refunded` figure (no new computation); CORRECTED/SUPERSEDED stays unrepresented since `invoices.status`
has no such value and no supersession column exists to read (recorded, not guessed at, the same "no new
backend" boundary as Documents Archive). Print CSS gained `@page` A4 sizing, a repeated line-item table
header on continuation pages (Step 11 §13's own line verbatim) and break-inside-avoid on totals/blocks;
a running invoice-identity header on every page beyond that is recorded as not achievable with this
codebase's browser-print-to-PDF approach (no reliable Chrome support for `@page` margin-box content).
No new RPC, schema or service wrapper. `pnpm check`, `pnpm format:check` and `pnpm build` pass (655
tests, up from 653); `pnpm db:test` passes (schema fingerprint unchanged at `5335133e42e3`). Deferred:
the Refund Receipt view/template, Step 11 §23's named component primitives, the Public Invoice Page's
responsive/mobile treatment and "Saya Sudah Bayar" field audit, and the broader responsive/accessibility/
motion polish pass across every other P13 part.

Part 5's second increment (DECISIONS 201): the Public Invoice/Receipt page's own Mobile treatment,
Step 11 §22, read with §8's own "no horizontal table scrolling" note. Desktop and Tablet already matched
§22's wording from the existing `.doc-page`/`.doc-actions` layout -- confirmed by inspection, not
assumed -- so only a `max-width: 640px` breakpoint was added. Three changes: (1) the line-item table
becomes stacked cards under 640px (each `<tr>` a block, the description an unlabelled full-width
heading, every other cell reading its own column header back via a new `data-label` attribute plus
`content: attr(data-label)`) so nothing needs horizontal scrolling to read; the Receipt view needed no
change since its only tabular content is a `<dl>`/`<ul>` that already stacks once `.doc-head`/`.doc-meta`
switch to a column. (2) `.doc-actions` (print/download, and the receipt page's "back to invoice" link)
becomes `position: sticky; top: 0` so it stays reachable without scrolling back up. (3) the claim form's
submit button becomes `position: sticky; bottom: 12px`, full width, with a shadow, so the payment CTA
stays obvious once the form is in view. All CSS-only plus one markup attribute; a page-wide fixed bottom
bar was considered and rejected as a bigger redesign than the spec calls for. Two related audits,
resulting in no code change, are recorded rather than left undocumented: "Saya Sudah Bayar"
(`PublicClaimForm.tsx`)'s five fields were checked against Step 11 §9 and against
`public_submit_payment_claim`'s own RPC signature and found already fully compliant for everything the
backend can accept -- §9's own payment-source field and proof-upload are genuine backend gaps, not
frontend oversights. `invoice_document`'s full JSON return was checked against Step 11 §16's
customer-vs-internal table and confirmed already compliant by construction (no journal ID, tax-engine
trace, staff note or database ID is ever included). No new RPC, schema, service wrapper or test file (a
pure CSS/markup increment). `pnpm check`, `pnpm format:check` and `pnpm build` pass (655 tests,
unchanged); `pnpm db:test` passes (schema fingerprint unchanged at `5335133e42e3`). Still deferred: the
Refund Receipt view/template, Step 11 §23's named component primitives, §9's backend-blocked fields, and
the broader responsive/accessibility/motion polish pass across every other P13 part.

Part 5's third increment (DECISIONS 202): the first step of the broader Step 09/Step 10 responsive pass,
decision 200's last remaining deferred item. Step 09 §23 says dense tables convert to cards/stacked rows
on mobile, but `.record-table` -- the shared class every List/Detail screen uses (38 files across Sales,
Purchases, Money, Accounting, Tax, Assets/Loans/Equity, Payroll, Planning, Reports and Documents) -- only
had `overflow-x: auto`. The App Shell and Dashboard were checked first and confirmed already compliant
(built in Part 1). Converting all 38 files at once was rejected: `.record-table` is also what the Reports
statement viewer, Chart of Accounts and Journal debit/credit grid use, and those are genuinely columnar
tables where stacking would break the alignment a reader needs -- exactly what §23's own carve-out
anticipates for "advanced report building." So a new opt-in `record-table-stacked` class (reusing decision
201's own `.doc-lines` pattern: hidden `<thead>`, each `<tr>` a block, each `<td>` reading its column
header back via `data-label`/`content: attr()`) is being rolled out module by module rather than as one
blanket change. `InvoicesListScreen.tsx` ships first, since §23 explicitly names invoice viewing as
mobile-priority; its seven columns become a card per invoice, No. Faktur as the unlabelled heading link.
No new RPC, schema, service wrapper or test file. `pnpm check`, `pnpm format:check` and `pnpm build` pass
(655 tests, unchanged); `pnpm db:test` passes (schema fingerprint unchanged at `5335133e42e3`). Still
deferred: the other 37 `.record-table` screens (Money Accounts/Cash Activity and Purchases Bills next),
the Refund Receipt view/template, Step 11 §23's named component primitives, and the rest of the broader
responsive/accessibility/motion polish pass.

Part 5's fourth increment (DECISIONS 203): the `record-table-stacked` rollout continues onto
`AccountsListScreen.tsx`, `BillsListScreen.tsx` and `CashActivityScreen.tsx`. The first two follow
decision 202's own pattern exactly. `CashActivityScreen` needed one judgment call: its first column is
`Tanggal` (date), not a drill-down link -- the `Akun` link is its second column, since this screen is a
chronological cross-account feed rather than a register of one record kind. Rather than mechanically
making a bare date the only unlabelled line, the column order was kept exactly as it already reads on
desktop: Tanggal stays the unlabelled heading, `Akun`'s link stays reachable and clearly labelled one row
down. No new RPC, schema, service wrapper or test file, and no `globals.css` change (`record-table-stacked`
already exists). `pnpm check`, `pnpm format:check` and `pnpm build` pass (655 tests, unchanged); `pnpm
db:test` passes (schema fingerprint unchanged at `5335133e42e3`). Still deferred: 34 more `.record-table`
screens, the Refund Receipt view/template, Step 11 §23's named component primitives, and the rest of the
broader responsive/accessibility/motion polish pass.

Part 5's fifth increment (DECISIONS 204): the rollout continues onto four Assets/Loans/Equity Register
screens -- `AssetRegisterScreen.tsx`, `EquityRegisterScreen.tsx`, `LoanRegisterScreen.tsx` and
`ObligationRegisterScreen.tsx` -- all an exact structural match to the Register/List pattern already
established (identifying number/code as the unlabelled heading link, every other column labelled via
`data-label`). No new RPC, schema, service wrapper or test file, and no `globals.css` change. `pnpm check`,
`pnpm format:check` and `pnpm build` pass (655 tests, unchanged); `pnpm db:test` passes (schema fingerprint
unchanged at `5335133e42e3`). Still deferred: 30 more `.record-table` screens (remaining Register screens
next, then Detail screens needing individual inspection for their own secondary tables, then the
LinesEditor components pending a reachability check), the Refund Receipt view/template, Step 11 §23's named
component primitives, and the rest of the broader responsive/accessibility/motion polish pass.

Part 5's sixth increment (DECISIONS 205): the rollout continues onto Payroll's three Register screens plus
Money's Transfers List -- `EmployeeRegisterScreen.tsx`, `PayrollRunRegisterScreen.tsx`,
`PayslipRegisterScreen.tsx` and `TransfersListScreen.tsx` -- all an exact structural match to the
Register/List pattern already established. No new RPC, schema, service wrapper or test file, and no
`globals.css` change. `pnpm check`, `pnpm format:check` and `pnpm build` pass (655 tests, unchanged); `pnpm
db:test` passes (schema fingerprint unchanged at `5335133e42e3`). Still deferred: 26 more `.record-table`
screens (Budget/Recurring Rule/Revenue Target/Journals List next, then Detail screens needing individual
inspection, then the LinesEditor components pending a reachability check), the Refund Receipt view/template,
Step 11 §23's named component primitives, and the rest of the broader responsive/accessibility/motion polish
pass.

Part 5's seventh increment (DECISIONS 206): the rollout continues onto Planning's three Register screens
plus Accounting's Journals List -- `BudgetRegisterScreen.tsx`, `RecurringRuleRegisterScreen.tsx`,
`RevenueTargetRegisterScreen.tsx` and `JournalsListScreen.tsx` -- all an exact structural match to the
Register/List pattern already established; `JournalsListScreen.tsx` is confirmed to be the plain journal
list, not the excluded debit/credit grid (`JournalDetailScreen.tsx`). No new RPC, schema, service wrapper or
test file, and no `globals.css` change. `pnpm check`, `pnpm format:check` and `pnpm build` pass (655 tests,
unchanged); `pnpm db:test` passes (schema fingerprint unchanged at `5335133e42e3`). Every simple Register/List
screen has now shipped `record-table-stacked`. Still deferred: the 13 Detail screens (each needing individual
inspection for their own secondary activity/ledger/lines sub-table; `JournalDetailScreen` excluded by
design), `PayrollTaxScreen.tsx`/`TaxLedgerScreen.tsx`/`DocumentsListScreen.tsx`/`DepreciationReportScreen.tsx`
not yet read/categorized, the LinesEditor components pending a reachability check, the Refund Receipt
view/template, Step 11 §23's named component primitives, and the rest of the broader
responsive/accessibility/motion polish pass.

Part 5's eighth increment (DECISIONS 207): all 13 Detail screens named as remaining are inspected, each read
in full before editing. 10 carry a simple line-item/activity/schedule table safe to stack --
`AccountDetailScreen.tsx`, `BillDetailScreen.tsx`, `RecurringRuleDetailScreen.tsx`, `AssetDetailScreen.tsx`,
`EmployeeDetailScreen.tsx` (3 tables), `PayslipDetailScreen.tsx` (3 tables), `PayrollRunDetailScreen.tsx` (3
tables), `EquityDetailScreen.tsx`, `ObligationDetailScreen.tsx` and `LoanDetailScreen.tsx` (3 tables) -- 18
tables in total, each table's own first column staying the unlabelled heading. The remaining 3 stay excluded
by design: `BudgetDetailScreen.tsx`'s and `RevenueTargetDetailScreen.tsx`'s own "vs Aktual" comparison tables
(the same columnar/comparative shape as Reports' statement viewer) and `JournalDetailScreen.tsx`'s debit/
credit grid (reconfirming decision 202's original exclusion). No new RPC, schema, service wrapper or test
file, and no `globals.css` change. `pnpm check`, `pnpm format:check` and `pnpm build` pass (655 tests,
unchanged); `pnpm db:test` passes (schema fingerprint unchanged at `5335133e42e3`). This exhausts every
`.record-table` consumer that fits the stacked-card pattern. Still deferred:
`PayrollTaxScreen.tsx`/`TaxLedgerScreen.tsx`/`DocumentsListScreen.tsx`/`DepreciationReportScreen.tsx` not yet
read/categorized, the LinesEditor components pending a reachability check, the Refund Receipt view/template,
Step 11 §23's named component primitives, and the rest of the broader responsive/accessibility/motion polish
pass.

Part 5's ninth increment (DECISIONS 208): the last 4 not-yet-categorized `.record-table` screens are
inspected -- `DepreciationReportScreen.tsx`, `PayrollTaxScreen.tsx`, `TaxLedgerScreen.tsx` and
`DocumentsListScreen.tsx`. None of their 7 tables is a period-by-period comparison the way Reports'
statement viewer or Budget/Revenue Target's "vs Aktual" tables are, despite three being named
"report"/"ledger" screens -- every one is a per-row schedule/liability/reconciliation/ledger/document list,
so all 4 ship `record-table-stacked`. No new RPC, schema, service wrapper or test file, and no `globals.css`
change. `pnpm check`, `pnpm format:check` and `pnpm build` pass (655 tests, unchanged); `pnpm db:test` passes
(schema fingerprint unchanged at `5335133e42e3`). This closes out the `record-table-stacked` rollout
entirely: 30 of 38 `.record-table` screens are now mobile-stacked, and the remaining 8 are confirmed genuine
columnar/comparative tables that stay excluded by design (Reports' statement viewer, the Chart of Accounts,
the Journal debit/credit grid, Budget/Revenue Target Detail's own "vs Aktual" tables). Still deferred: the
LinesEditor components pending a reachability check, the Refund Receipt view/template, Step 11 §23's named
component primitives, and the rest of the broader responsive/accessibility/motion polish pass.

Part 5's tenth increment (DECISIONS 209): decision 204's own deferred reachability question for the Budget/
Recurring/Revenue-Target "LinesEditor" components is finally answered. All three are confirmed live,
reachable components -- `BudgetLinesEditor` inside `BudgetDetailScreen.tsx`, `RevenueTargetLinesEditor`
inside `RevenueTargetDetailScreen.tsx`, `RecurringLinesEditor` inside `RecurringRuleForm.tsx` (rendered by
`RecurringRuleDetailScreen.tsx`) -- not orphaned code belonging to a still-deferred form. Being reachable
does not automatically make a component safe to stack: `BudgetLinesEditor.tsx` and
`RevenueTargetLinesEditor.tsx` are genuine category x month editable matrices, the same period-by-period-
comparison shape decision 202/207 already excludes for read-only tables, so both stay on plain
`.record-table` by design. `RecurringLinesEditor.tsx` is structurally different -- a plain repeating row list
with a fixed, small column set and no month columns, the same shape as `BillDetailScreen.tsx`'s own line
items (decision 207) just editable -- so it ships `record-table-stacked`: Deskripsi's own input stays the
unlabelled heading, every other cell (including each `<select>`) reads its own column header back via
`data-label`, and the trailing "Hapus" delete-button column carries no `data-label` since its header has no
visible text to echo. No new RPC, schema, service wrapper or test file, and no `globals.css` change.
`pnpm check`, `pnpm format:check` and `pnpm build` pass (655 tests, unchanged); `pnpm db:test` passes (schema
fingerprint unchanged at `5335133e42e3`). This closes out the `record-table-stacked` rollout genuinely
entirely: every `.record-table`-class consumer in the codebase, screens and reachable editing components
alike, has now been read and either converted or confirmed excluded by design -- 31 of 39 consumers are
mobile-stacked, and the remaining 8 stay on plain `.record-table` as confirmed columnar/comparative tables.
Still deferred: the Refund Receipt view/template, Step 11 §23's named component primitives, and the rest of
the broader responsive/accessibility/motion polish pass that decision 155's plan places in Part 5.

Part 5's eleventh increment (DECISIONS 210): the accessibility/motion polish pass decision 155's plan
places at the end of Part 5 opens with its first concrete item -- keyboard focus visibility (WCAG 2.4.7).
An audit of every `:focus-visible`/`:focus` rule in `globals.css` found four component classes already
established the app's own treatment (`.form input`/`.form button`/`.entities a` from P2, `.app-nav-link`/
`.icon-button` from Part 1, all four `.btn-*` variants from Part 3, all sharing the identical
`outline: 2px solid var(--accent); outline-offset: 2px`), but nothing else had any override at all: every
`.record-table` drill-down link, every `.record-form`/`.record-form-wide`/`.plan-lines-table` input/select/
textarea (the field shell shared by every Create/Edit form and editable grid in the app, `RecurringLinesEditor`
included), `.list-search-form`/`.invoice-link-row` inputs, `.invoice-action-form`'s textarea, and
`.list-filter-tab` links all fell back to the browser's own inconsistent default outline -- the majority of
the app's interactive surface. One base-level rule keyed off the plain tag (`a`/`button`/`input`/`select`/
`textarea`, placed right after the `* { box-sizing: border-box; }` reset) extends the existing pattern to
cover them, without visibly changing any already-covered element (identical declaration) and without
affecting `.command-menu-input:focus { outline: none }` (a class selector, still wins on specificity).
Touch-target sizing (`.icon-button` renders at 36x36px, clearing WCAG 2.5.8's AA 24x24 minimum but not the
stricter AAA 44x44) was investigated and deliberately left out pending the exact Step 10 spec number rather
than guessed at. No new RPC, schema, service wrapper, test file, or markup change -- pure CSS. `pnpm check`,
`pnpm format:check` and `pnpm build` pass (655 tests, unchanged); `pnpm db:test` passes (schema fingerprint
unchanged at `5335133e42e3`). Still deferred: the Refund Receipt view/template (blocked on the Refunds list/
detail screens, a Part 3-scope gap), Step 11 §23's named component primitives, touch-target sizing, and the
rest of the empty/loading/error visuals, micro-interactions and dashboard-personalization work.

Part 5's twelfth increment (DECISIONS 211): the "loading visuals"/"error visuals" items of the accessibility
polish pass. A repo-wide check found zero `loading.tsx`/`error.tsx` anywhere in `src/app` apart from the
public invoice token page's own `not-found.tsx` -- a genuine structural gap, since every route under the
`(app)` route group fetches its own data via RPC before it can render and Next.js's own App Router
convention already defines exactly these two files for segment-level loading/error UI. Two new files:
`src/app/(app)/loading.tsx` ("Memuat…", `role="status" aria-live="polite"`) and `src/app/(app)/error.tsx`
(`"use client"`, a generic "Terjadi masalah saat memuat halaman ini." message with a "Coba Lagi" button
calling Next.js's own `reset()`, `role="alert"`) -- `(app)/layout.tsx` and `AppShell` (sidebar/top bar) sit
outside both Next.js boundaries and keep rendering immediately, so only the content area shows either
fallback. Both reuse `.list-empty` (`globals.css`) verbatim rather than inventing a new visual language.
`error.tsx` deliberately never renders `error.message`, since an RPC failure's own text can carry internal
detail (a raised Postgres exception, a `FORBIDDEN: missing <permission>` string) -- the same
customer-facing-vs-internal boundary already established for document data (decision 201). No new RPC,
schema, service wrapper, or test file. `pnpm check`, `pnpm format:check` and `pnpm build` pass (655 tests,
unchanged); `pnpm db:test` passes (schema fingerprint unchanged at `5335133e42e3`). Scoped to the `(app)`
segment only -- `/login`/`/auth/*`/`/i/[token]` still have neither, recorded as a further deferred item
rather than folded in here. Still deferred: the Refund Receipt view/template, Step 11 §23's named component
primitives, touch-target sizing against a concrete number, loading/error UI for the non-`(app)` segments,
and the rest of the polish pass (micro-interactions, dashboard personalization) which has no further
objectively-verifiable gap to ground against without OWNER input or the actual spec text.

Part 5's thirteenth increment (DECISIONS 212): decision 211's own deferred "loading/error UI for the
non-`(app)` route segments" item. `/login`, `/auth/mfa`, `/auth/step-up` and the public
`/i/[token]`/`/i/[token]/receipt` pages sit outside the `(app)` route group, so decision 211's
`(app)/loading.tsx`/`error.tsx` never covered them. Two new root-level files, `src/app/loading.tsx` and
`src/app/error.tsx` -- Next.js only falls back to a root `loading.tsx`/`error.tsx` for a segment with no
closer one of its own, so neither overrides `(app)`'s pair. Styled with `.shell`/`.card` (the layout
`/login`, `/auth/mfa`, `/auth/step-up` and this route's own `not-found.tsx` already use) rather than
the `.shell`/`.card` layout, since none of these routes render inside `AppShell`'s chrome. The public
invoice page mattered most for `error.tsx`: an unhandled exception there (distinct from the deliberate
`notFound()` call already made for an invalid/expired token) previously reached a customer as Next.js's
bare default error screen. `loading.tsx` renders a small `.skeleton-panel` (three pulsing lines) rather
than plain text, per the real Step 09/Step 10 spec text read for the first time this increment (see
decision 213); `error.tsx` otherwise matches decision 211: a generic "Terjadi masalah saat memuat halaman
ini." with a "Coba Lagi" button calling `reset()`, `error.message` never rendered. A `global-error.tsx` for
the root layout itself was considered and left out since that layout has no data fetching to fail. No new
RPC, schema, service wrapper, or test file. `pnpm check`, `pnpm format:check` and `pnpm build` pass (655
tests, unchanged); `pnpm db:test` passes (schema fingerprint unchanged at `5335133e42e3`).

Process correction (DECISIONS 213): decisions 210-212 were built reasoning indirectly from the existing
codebase rather than the actual Step 09/Step 10 spec DOCX text, on a mistaken belief those files were not
reachable from this session -- asked directly by the OWNER, they turned out to sit one level up from the
git repo in the same connected device folder. Reading them in full confirmed decisions 210 and the
error-boundary halves of 211/212, but found the loading-state halves did not comply: Step 09 §25/Step 10
§23-§24 require skeleton loading ("match final geometry," "neutral shimmer or subtle pulse compatible with
reduced-motion"), not plain text. Both `(app)/loading.tsx` (decision 211, already merged) and the root
`loading.tsx` (corrected before it ever shipped) now render a new `.skeleton-panel`/`.skeleton-block` pulse
treatment (`globals.css`), fully disabled under `prefers-reduced-motion: reduce`. The same spec read
surfaced two further, now-concretely-scoped gaps deliberately left out of this correction: the plain-text
`.list-empty` empty-state panel (roughly 40 screens) falls short of the spec's "action-oriented... one
clear CTA" wording, and Step 10 §25 Dashboard Personalization describes a genuine per-user/per-Entity
widget reorder/hide feature the Dashboard does not have at all -- a schema-plus-feature build, not a
CSS-only polish item. `pnpm check`, `pnpm format:check` and `pnpm build` pass (655 tests, unchanged);
`pnpm db:test` passes (schema fingerprint unchanged at `5335133e42e3`). This closes out every
objectively-verifiable item the accessibility/motion polish pass had left to ground without OWNER input,
now that the actual spec text is being read directly going forward. Still deferred: the Refund Receipt
view/template (Part 3-scope), Step 11 §23's named component primitives, the `.list-empty` CTA gap, Dashboard
Personalization, touch-target sizing against a concrete number, and the rest of the polish pass
(micro-interactions).

Reusable-primitive audit (DECISIONS 214): per the OWNER's "pastikan bahwa P13 selesai dengan baik"
instruction, this session audited the codebase directly against Step 09 §28's and Step 10 §26's own named
primitive lists rather than assuming P13 Parts 1-4 already covered them, since Step 15 §17's own P13 gate
names "drawers" as an explicit completion criterion. Found present, as consistent CSS-class-plus-JSX
conventions rather than literal named components (this codebase's established style throughout, same as
`record-table-stacked` and the focus-visible rule): PageHeader, StatusBadge, CommandMenu (⌘K), EntitySwitcher,
a functional FilterBar-equivalent (search + status filter, no saved views/export yet), and ConfirmAction (met
by the shared `ReasonForm` inline reason-required confirm, not a literal modal). Found genuinely missing, not
just differently implemented: Global Search (Step 09 §6/§28) -- `CommandMenu.tsx`'s own doc comment already
states search-across-records stays unwired, even though the backend RPC (`public.search`, P11) has existed
since P11; and Drawer (Step 09 §2/§9/§27/§28, Step 10 §19/§26) -- no `.drawer` CSS, no component, every List
screen links straight to a full Detail page instead of a quick-preview side drawer. DetailTabs (Step 09
§10/§28) is a third, softer gap: Detail screens stack their sections on one page in the spec's own order
rather than as interactive tabs. No code changed in this increment -- retrofitting Drawer/Global Search would
touch most of the ~30 List/Detail screen pairs already shipped across P3-P12, which is new frontend scope
rather than CSS-only polish, so per this project's own standing rule that a user-workflow change goes to the
OWNER as a question, this was surfaced for a decision rather than built or silently deferred unilaterally.

Drawer + Global Search primitives (DECISIONS 215): the OWNER chose "Bangun penuh: Drawer + Global Search" --
build both fully. This increment ships the two shared primitives; retrofitting them onto the ~30 already-
shipped List screens is planned as two further PRs grouped by module, at the OWNER's own request to reduce
the number of merges needed, rather than one PR per screen. `Drawer` (`src/features/shell/Drawer.tsx`): a
generic right-side panel, Escape/backdrop-click to close, focus moved in on open, a one-shot slide-in
`animation` (Step 10 §8) disabled outright under `prefers-reduced-motion: reduce`. `RecordPreviewLink`
(`src/features/shell/RecordPreviewLink.tsx`): the List-row Quick Preview pattern (Step 09 §9) built on
`Drawer`, deliberately zero-network -- every prop is data the row's own table already renders, so using it
on a screen is a presentational change only. The underlying link stays real (⌘/Ctrl/Shift/Alt-click or
middle-click still opens the full Detail page in a new tab), and the Drawer always offers a "Lihat Detail
Lengkap" link to it -- the full Summary/Activity/Accounting/Tax/Documents/Audit page (Step 09 §10) is
unchanged and still the place for deep work.

Global Search needed far less new work than decision 214 implied: P11 had already shipped the backend RPC
and a typed service wrapper end-to-end (`public.search`, `src/services/search/search.ts`,
`src/schemas/search.ts`, `SEARCH_TARGET_TYPE_LABELS`) -- only the UI wiring was missing. A new
`searchRecordsAction` server action is a thin call-site for that existing service; `CommandMenu.tsx` now
debounces the query (250ms, 2-character floor matching the RPC's own), drops out-of-order responses via a
ref, and shows results in a second, separately-labelled section below navigation/quick-create per Step 13
§17's own "Command Menu navigation/action search remains separate from financial content search." A new
`searchResultHref` (`src/domain/search/routes.ts`, unit-tested) routes 7 of the 9 indexed kinds to their
Detail page; `contact` and `expense` render as plain, non-clickable rows since neither has a Detail screen
yet (Sales/Purchases screens still remaining, decisions 286/290/294) -- documented rather than guessed
around, the same choice this project already makes elsewhere. No RPC, schema, migration or service file
changed; `pnpm check`, `pnpm format:check`, `pnpm build` pass (658 tests, +3) and `pnpm db:test`'s schema
fingerprint stays `5335133e42e3`.

Drawer retrofit, first module group (DECISIONS 216): `RecordPreviewLink` is wired onto the identity-column
link of every Sales/Purchases/Money/Accounting List screen -- `InvoicesListScreen`, `BillsListScreen`,
`AccountsListScreen`, `TransfersListScreen`, `JournalsListScreen`. Each change swaps a plain `<Link>` for
`RecordPreviewLink` carrying the exact same fields and status badge that row's own table cell already
computes, so no new data fetching or RPC/service call was added anywhere. `CashActivityScreen` is
deliberately left unchanged: its one link per row already goes to the account a movement belongs to, not
to "this movement" (which has no Detail screen of its own), and `AccountsListScreen` already gives that
account its own Quick Preview one screen up -- adding a second, redundant drawer here would preview the
wrong record for what the row represents. `pnpm check` (658 tests, unchanged), `pnpm format:check`,
`pnpm build` all pass; no RPC/schema/service touched, so no `pnpm db:test` fingerprint change. This is PR
2 of the OWNER-agreed 3-PR plan; the remaining module group (Assets & Financing, Payroll, Planning,
Documents) is the third and final increment.

Drawer retrofit, second and final module group (DECISIONS 217): `RecordPreviewLink` is wired onto the
identity-column link of the ten remaining Register screens across Assets & Financing (`AssetRegisterScreen`,
`EquityRegisterScreen`, `LoanRegisterScreen`, `ObligationRegisterScreen`), Payroll (`EmployeeRegisterScreen`,
`PayrollRunRegisterScreen`, `PayslipRegisterScreen`) and Planning (`BudgetRegisterScreen`,
`RecurringRuleRegisterScreen`, `RevenueTargetRegisterScreen`) -- the exact same swap decision 216 already
established, each Drawer carrying only fields/badges that row's own table cell already computes. `Link` from
`next/link` is dropped from the seven files that had no other use for it once their identity-column swapped
over, and kept in the three Planning screens whose own "Buat ... Baru" create button still needs it.
`DocumentsListScreen`, the eleventh screen decision 214 named, stays deliberately excluded -- not the same
reason as `CashActivityScreen`, but because its filename cell was never a `<Link>` to begin with: no document
Detail screen exists yet (Storage itself is still unconfigured, decision 142), so there is no `href` to build
a preview toward without inventing one. `pnpm check` (658 tests, unchanged), `pnpm format:check`, `pnpm build`
all pass; no RPC/schema/service touched, so no `pnpm db:test` fingerprint change. This is PR 3 of 3 and closes
Part 6 in full -- every List/Register screen decision 214's audit found reachable now has Quick Preview, and
Global Search is wired end to end, closing the Step 15 §17 P13 gate's own "drawers" criterion. `DetailTabs`
(decision 214's softer gap) stays open, unchanged, since it was never part of the OWNER's "Bangun penuh:
Drawer + Global Search" scope.

Empty-state CTA and touch-target close-out (DECISIONS 218): with Part 6 closed, the OWNER chose "Lanjut item
kecil dulu" over Dashboard Personalization or moving straight to P14/P15 -- concretely-scoped, presentational
items built directly from spec, no further OWNER decision needed. A new `.list-empty-action` CSS slot
(`globals.css`) plus a real CTA wired onto the 7 List/Register screens with a `canCreate` prop
(`InvoicesListScreen`, `BillsListScreen`, `AccountsListScreen`, `TransfersListScreen`, `BudgetRegisterScreen`,
`RecurringRuleRegisterScreen`, `RevenueTargetRegisterScreen`): "Hapus Saringan" (back to the screen's own base
URL) when a search/filter produced zero rows, else the exact same create action the header already
conditionally shows -- never a third, invented action. The ~30 screens with no `canCreate` prop at all keep
the plain-text panel, since there is no create destination to link to yet; their own CTA arrives only when
their own create form ships. Touch-target sizing (decision 210's open question) is now closed definitively:
re-reading Step 09/Step 10's actual text found no numeric minimum anywhere in either document ("Touch targets
remain usable on mobile/tablet" is the only line), so this stays a permanently open item pending an
OWNER-supplied number rather than something this session can resolve further. `pnpm check` (658 tests,
unchanged), `pnpm format:check`, `pnpm build`, `pnpm db:test` (fingerprint unchanged) all pass. Dashboard
Personalization and `DetailTabs` remain open, unchanged from decisions 213/214.

Phase 14 (Hardening, Recovery & Performance) opens (DECISIONS 219): with P13 substantially closed, Step 15's
own build order (read directly, `pandoc`, continuing decision 213's discipline) moves next to Phase 14.
Security review: Supabase Security Advisor found one WARN, `public.rls_auto_enable()` -- confirmed a
Supabase-platform `event_trigger` handler absent from this repo's own migrations, structurally uninvokable
outside the event-trigger machinery by ordinary Postgres semantics regardless of its nominal `anon`/
`authenticated` EXECUTE grant. A live empirical check was attempted and declined by this session's own
tool-permission layer, so the conclusion rests on the function's definition and standard semantics rather
than an executed test -- stated plainly rather than glossed over. Performance review: Advisor returned zero
findings, low-signal pre-launch with no real data volume yet. Concurrency audit: `docs/TESTING.md`/
`scripts/db-test.sh` read directly confirm five existing, independently reviewed and mutation-tested
concurrency suites (numbering, duplicate posting, money P4, sales P5, purchases P6) -- covering four of
Phase 14's five named concurrency areas ("payment, refund, posting, numbering and recurring generation").
**No recurring-generation concurrency stress test exists yet** -- confirmed by the test-file listing and the
absence of any recurring-named concurrency function -- a concrete, spec-named, well-scoped next small item
fitting the established `db-test.sh` pattern exactly. Payroll has no concurrency suite either but isn't named
in Phase 14's own bullet. Phase 14's remaining bullets (backup/recovery + Storage recovery verification,
migration-from-clean/upgrade tests, accessibility/browser/device/failure-mode testing) are substantial and
some may need OWNER-level Supabase/Vercel account actions -- surfaced to the OWNER as a scoping question
rather than assumed. No files changed -- an audit only, like decision 214; schema fingerprint unchanged.

Recurring-generation concurrency stress test (DECISIONS 220): the OWNER chose decision 219's own proposed
next item over backup/recovery, migration/upgrade testing or moving to P15. `recurring_concurrency_test`
added to `scripts/db-test.sh`, following the established `concurrency_test`/`money_concurrency_test`/
`sales_concurrency_test`/`purchases_concurrency_test` pattern exactly: a synthetic Entity with six active,
due `expense`-kind recurring rules, six sessions calling `run_due_recurring_occurrences` at once. The
engine's `for update skip locked` claim (read directly from `20260928100200_p10_recurring_engine.sql`) means
two concurrent runs structurally never process the same rule; `recurring_occurrences`' UNIQUE constraint is
the backstop. Asserts exactly 6 generated occurrences / 6 distinct documents / 0 still-due rules after the
race, and a pure no-op on a second concurrent wave with nothing left due. **Mutation-tested for real**: the
`for update skip locked` clause was temporarily removed and `pnpm db:test` re-run -- the new test correctly
failed, catching the exact double-processing race (an unhandled UNIQUE-constraint error) the lock exists to
prevent -- then the migration was restored byte-identical (diffed against a backup) before shipping.

Incidentally, running `pnpm db:test` today (2026-09-30, the last day of the month) surfaced a pre-existing
calendar-boundary bug in the already-closed P8 test suite (`96_p8_assets.sql`): its "not through a month
that is not over" case posted depreciation through the _current_ month's own end, which only fails when
that end is strictly in the future -- on the one day per month when it equals today, the call legitimately
succeeds and the test's own expectation, not the app code, was wrong. Fixed directly (pure test-arithmetic,
not economic/tax/authorization/workflow) to use _next_ month's end instead, unconditionally future on every
calendar day. `pnpm check` (658 tests, unchanged), `npx prettier --check .` and `pnpm db:test` (two clean
rebuilds, fingerprint `5335133e42e3` unchanged, new suite passes both times) all pass. Phase 14's remaining
bullets (backup/recovery, migration/upgrade tests, accessibility/browser/device/failure-mode testing) stay
open.

Migration-from-clean and upgrade-from-previous-version tests (DECISIONS 221): OWNER's next chosen item.
"Migration-from-clean" already existed since P0/P1 (the clean-rebuild-x2 fingerprint check). This project
has no shipped production release yet, so there's no real "previous version" to upgrade from -- the honest,
buildable subset built instead: prove migrations are safe against a database that already holds real
records, not only an empty one, which `rebuild()`'s own check never exercised (`supabase/seed.sql` only
ever runs after every migration is already applied). New `upgrade_test` in `scripts/db-test.sh`: applies
every migration except the newest, seeds real records (`supabase/seed.sql`), applies the newest migration
on top, and asserts it applies without error, the resulting schema fingerprints identically to a normal
clean rebuild, and the seeded records survive intact. Deliberately holds back only the single newest
migration so the check is automatically exercised against whichever migration is newest at any time, no
manual update needed later. Not formally mutation-tested like decision 220's concurrency test -- its
failure detection reuses only already-proven mechanisms (`ON_ERROR_STOP=1` exit codes, the `fingerprint()`
comparison), not novel logic needing empirical proof; stated plainly rather than assumed equivalent rigor.
`pnpm check` (658 tests, unchanged), `pnpm db:test` (two clean rebuilds, fingerprint `5335133e42e3`
unchanged, new `upgrade_test` passes on first run against the newest migration,
`20260930200200_p12_consolidated_and_custom_reports.sql`), `npx prettier --check .` all pass. Phase 14's
remaining bullets (backup/recovery, accessibility/browser/device/failure-mode testing) stay open.

Accessibility, browser/device and failure-mode testing (DECISIONS 222): continued automatically per the
OWNER's explicit "don't stop, even without merge confirmation" instruction, without waiting for a
sequencing choice. Live browser/device (E2E) testing investigated and found infeasible here on two
grounds, both recorded rather than worked around: Docker's CLI is present but its daemon is unreachable in
this sandbox, so `supabase start`'s local stack cannot run; and `hikarich-finance-dev` (the hosted
Preview/dev Supabase backend) is 57 migrations behind the repo (only through P3, `list_migrations`
confirms) -- both rule out real E2E against a working backend today. The second finding is flagged as a
separate, OWNER-relevant live-infrastructure gap, not applied to unilaterally. Pivoted to the buildable,
zero-infrastructure-risk half: wired `eslint-plugin-jsx-a11y`'s full 34-rule `recommended` set into
`eslint.config.mjs` (only 6 of its rules were enabled via `eslint-config-next`'s bundle) as a permanent
automated check. Surfaced 9 real pre-existing errors in `Drawer.tsx`/`CommandMenu.tsx`'s modal-backdrop
pattern and `CommandMenu.tsx`'s search-input `autoFocus`; fixed with targeted, justified
`eslint-disable-next-line` comments (not restructuring) because both already wire a real Escape-key
handler as the keyboard equivalent the static rule can't see, and `autoFocus` only fires in direct response
to the same explicit keyboard shortcut that opens the palette. `pnpm lint` now clean (0 errors, 0
warnings), `pnpm check` (658 tests, unchanged), `pnpm db:test` (fingerprint `5335133e42e3` unchanged, no
migration touched), `npx prettier --check .` all pass. Phase 14's remaining bullets: backup/recovery
verification (needs OWNER dashboard action) and the `hikarich-finance-dev` migration-drift gap stay open.

Backup/recovery and Storage recovery procedure verification in non-production, scope audit (DECISIONS 223):
re-read the OWNER's own existing decision (line 10, 2026-09-19) -- recovery relies on the in-app Backup &
Restore Center (Step 01 #36), not paid Supabase managed backups -- then found that Center was never built:
only a nav placeholder exists. Read Step 01 #36, Step 01 #44 and Step 16 §34 directly from the FINAL spec
docx files (via pandoc) to ground the real scope: this bullet requires BUILDING Full/Data-only/Documents-
Archive backup export, validation-before-restore, history/reminders and the restore path itself, before a
restore drill can even run against it -- a materially larger, higher-stakes item (writes recovered data
back over real records) than any other Phase 14 bullet shipped so far. Two questions are OWNER-only and not
resolvable from spec text alone: the V1 "external storage" target (plain download vs. a named integration),
and re-confirming the free-tier infrastructure assumption behind §34's "actual subscribed infrastructure
plan" language. No files changed -- an audit only, like decisions 214/219. Surfaced to the OWNER directly
with a concrete recommended V1 scope rather than built on an assumed scope or silently skipped.
Backup & Restore Center, Part 1: export backend + screen (DECISIONS 224): OWNER confirmed decision 223's V1
scope (plain manual download, no external-storage integration; free-tier Supabase stays current). Builds
Step 01 #36's Center for real: `export_backup_snapshot` (Full/Data-only/Documents Archive, dynamically
enumerating every Entity-scoped table via `information_schema` so a future new table is never silently
missed), `validate_backup_payload` (read-only shape/Entity-isolation check before any restore), a new
`backup_jobs` history table, and `/admin/backup` (gated on the already-catalogued-but-never-granted
`backup.create`/`backup.restore` permissions -- OWNER already holds both via the owner-bypass rule, no grant
migration needed). Data-only excludes `audit_events`/`documents`/`document_links`; Documents Archive
honestly reports `storage_configured: false` since Supabase Storage still isn't configured (decision 142).
The actual restore-WRITE path is deliberately deferred to Part 2 -- this increment is read-only/append-only
throughout, on purpose, given the stakes. New `99_p14_1_backup.sql` test suite (two synthetic Entities,
authorization, table-set shape, Entity isolation, four validation scenarios, RLS) caught and fixed two real
bugs before passing: a `jsonb_agg(... order by t.id)` that broke on a table with no `id` column, and a
`text[] || text` array-append mistake that should have been `array_append`. `pnpm check` (673 tests, up
from 658), `pnpm build` (`/admin/backup` is a real route now), `pnpm db:test` (schema fingerprint changed
to `f1427317e184` -- one new table, two new RPCs, both clean rebuilds and the upgrade_test pass), `npx
prettier --check .` all pass. Phase 14's remaining items: Backup & Restore Center Part 2 (the restore-write
path and its non-production restore drill, the drill itself still blocked on the already-flagged
`hikarich-finance-dev` migration-drift gap or a fresh non-production project) and the live browser/device
E2E half of accessibility testing (decision 222).

## Unbuilt-screens backlog (OWNER instruction: "kerjakan saja semuanya")

A nav-vs-route audit (60 `navigation.ts` hrefs diffed against every real `page.tsx`) found 32 still served
by the `[...slug]` catch-all. Almost all backend work behind them is already Verified/Implemented (P3-P12
above) -- this is P13's own screens/action-forms backlog that decisions 165-208 already carried forward as
open items, not a new phase. Building proceeds item by item, one PR per slice, without pausing between items.

Decision 225, first increment (Customers/Vendors): `/sales/customers`, `/sales/customers/[id]`,
`/purchases/vendors`, `/purchases/vendors/[id]` -- both read `public.contacts` directly (no RPC lists/reads
one), one shared `ContactsListScreen`/`ContactDetailScreen` pair serves both roles. `tax_identifier` is
never selected (column-level grant excludes it for `authenticated`; revealing it on demand is deferred).
`pnpm check` (673 tests, unchanged), `pnpm build` (4 new real routes), `pnpm db:test` N/A (no migration),
`npx prettier --check .` clean. Full detail in `docs/DECISIONS.md` decision 225 (this branch's own
numbering, built from `main`; a differently-numbered 225/226 exists only in a separate, still-unmerged PR
that branched earlier -- see that decision's own closing note).

Decision 226, second increment (Accounting Periods): `/accounting/periods`, `/accounting/periods/[id]` --
Step 09 §14's "Period Close screen presents a checklist of blockers/warnings before Close." No new RPC,
schema or service wrapper -- every function (`listAccountingPeriods`/`getPeriodChecks`/`beginPeriodClose`/
`cancelPeriodClose`/`closePeriod`/`reopenPeriod`) was already wrapped since decision 172, just never given a
UI. Detail always fetches the checklist (not only while `closing_review`); actions follow the exact
`JournalActions` shape, including Reopen's reason-gated reveal-confirm and its `STEP_UP_REQUIRED` handling
via the existing generic `AuthzError` mapping. `pnpm check` (673 tests, unchanged), `pnpm build` (2 new real
routes), `pnpm db:test` N/A, `npx prettier --check .` clean. Full detail in `docs/DECISIONS.md` decision 226.

Decision 229, third increment (Payments Received and Refunds): `/sales/payments`,
`/sales/payments/[id]`, `/sales/refunds` -- both read `list_payments` (no `list_refunds` RPC exists), Refunds
built as a filtered view of payments with refund activity, the same shared-screen-via-a-view-prop pattern
the earlier increments already established. Payment Detail's row comes from `list_payments` matched by id
(no single-item RPC, matching decision 226's own precedent); the already-shipped `ReceiptDocumentView` is
reused for the printable Dokumen section. Only Reverse Payment is wired as a status action -- refund
creation stays deferred to its own queue-screen-level increment, per `actions.ts`'s own long-standing scope
note. `/sales/refunds` is gated on `refunds.view` (matching `navigation.ts`), while `list_payments` itself
needs `invoices.view` at the database level -- every role holding the former currently also holds the
latter, flagged as an OWNER-relevant observation rather than silently patched over. `pnpm check` (673 tests,
unchanged), `pnpm build` (3 new real routes), `pnpm db:test` N/A (no migration), `npx prettier --check .`
clean. Full detail in `docs/DECISIONS.md` decision 229.

Decision 230, fourth increment (Payments Made): `/purchases/payments`, `/purchases/payments/[id]` --
reads `list_vendor_payments` (P6), gated `bills.view`. No Refunds counterpart on the Purchases side. Detail
has no single-item RPC and no printable document RPC, so it stays Header/Actions/Ringkasan only (the same
narrower pattern Transfer Detail already uses). Only Reverse is wired, gated `bills.pay`. `pnpm check` (673
tests, unchanged), `pnpm build` (2 new real routes), `pnpm db:test` N/A, `npx prettier --check .` clean.
Full detail in `docs/DECISIONS.md` decision 230.

Decision 231, fifth increment (Reconciliation List, read-only): `/money/reconciliation` -- reads
`reconciliation_status` joined against `money_control` for currency, gated `money.view`. Starting a
session and the full matching workspace were drafted and then cut back out: no RPC anywhere returns a
`reconciliation_sessions` row's own fields (status/period/statement balances), so a workspace page could
not honestly render its own header or gate its own actions -- needs a new read RPC, flagged for the OWNER.
The same audit confirmed `/sales/products` (no RPC of any kind exists over `public.products`) and
`/purchases/expenses` (full write lifecycle exists, but no `list_expenses` RPC) are backend gaps too, not
just missing UI. `pnpm check` (678 tests, up from 673), `pnpm build` (1 new real route), `pnpm db:test`
N/A, `npx prettier --check .` clean. Full detail in `docs/DECISIONS.md` decision 231.

Decision 232, sixth increment (Advanced Adjustments): `/accounting/adjustments` -- a single form (no
List+New split), posting immediately via `record_balance_adjustment` (already wrapped as
`recordBalanceAdjustment`, just never given a UI). Gated `money.adjust` matching the RPC exactly, not the
nav section's `accounting.view`. Counter-account picker uses new `eligibleCounterAccounts` domain helper,
matching the RPC's own validation exactly (active, non-group, non-control, not the opening-balance
clearing account). Redirects to the affected account's own Detail page on success, since there is no
adjustment record of its own to show. Reached after finding `/accounting/opening-balances` (next on the
catch-all) is the same class of gap as Reconciliation's workspace: `post_opening_balances`/
`complete_opening_balances` post immediately but `opening_balance_batches` has no reading RPC at all, so
Advanced Adjustments was built instead. `pnpm check` (684 tests, up from 678), `pnpm build` (1 new real
route), `pnpm db:test` N/A, `npx prettier --check .` clean. Full detail in `docs/DECISIONS.md` decision 232.

Decision 233, seventh increment (Tax Calendar): `/tax/calendar` -- the first of the Tax family's six
remaining nav items. Before building, ran the same exhaustive RPC-inventory discipline decisions 231/232
established across all six P7 tax migrations, and found the whole Tax family is backend-ready: every
read/write RPC it needs is already wrapped in `src/services/tax/tax.ts`, and `tax_rule_versions`/
`tax_filings` both carry their own direct-select RLS policy (`tax.view`), so `/tax/rules` and
`/tax/filing` need no new RPC either -- unlike `/sales/products`/`/purchases/expenses`/Reconciliation's
workspace/Opening Balances. Built as a pure List over `getTaxCalendar`; new `resolveTaxCalendarRange`
widens the RPC's own backward-looking default (past 3 months) to one month back through two months ahead
of today, `CashActivityScreen`'s own `from`/`to` toolbar shape. Gated `tax.view` directly, matching
`tax_calendar`'s own check exactly (already the Tax nav section's own parent permission, no gate mismatch
here). `pnpm check` (689 tests, up from 684), `pnpm build` (1 new real route), `pnpm db:test` N/A, `npx
prettier --check .` clean. Full detail in `docs/DECISIONS.md` decision 233.

Decision 234, eighth increment (PPh Final UMKM): `/tax/pph` -- the second Tax family item, the one with
its own compute step (`tax_final_compute`) since the UMKM final-tax regime recognises a flat rate on
turnover once a month rather than line by line. New `resolveTaxPeriod` resolves a native
`<input type="month">` value into a tax period. Shows `tax_final_preview`'s live evaluation alongside
`tax_period_position`'s recorded figures, both already service-wrapped. Gated `tax.view`, matching the
read RPCs; `tax_final_compute` itself needs the narrower `tax.confirm_facts` (only the `tax` role template
holds both), so the Compute button's own server action lets that `AuthzError` surface on submit rather than
gating the whole page, and is disabled client-side whenever the live preview's status is not
`auto_determined`. `pnpm check` (695 tests, up from 689), `pnpm build` (1 new real route), `pnpm db:test`
N/A, `npx prettier --check .` clean. Full detail in `docs/DECISIONS.md` decision 234.

Decision 235, ninth increment (Withholding PPh 23 and PPN): `/tax/withholding` and `/tax/ppn` -- the third
and fourth Tax family items, shipped together since both are pure period-position reports with no compute
step, unlike PPh Final UMKM (withholding and VAT are determined per document at invoice/bill/expense time,
Step 05). New shared `TaxPositionScreen` (`taxType`/`title` prop) serves both routes, the same
shared-screen-via-a-prop pattern decisions 198/176/225/229 already established; reuses decision 234's own
`resolveTaxPeriod` unchanged. The input-VAT-credit fields (`accrued_asset`/`applied_asset`/
`asset_available`) render only when `taxType === "vat"`. Gated `tax.view` on both, matching
`tax_period_position` exactly. `recordTaxPayment`/`recordTaxFiling`/`tax_reconcile_period` (needs the
narrower `tax.mark_filed`) are deliberately left out of both screens -- paying, filing, reconciling and
evidence belong together in a future `/tax/filing` increment, not scattered across the position reports.
`pnpm check` (695 tests, unchanged -- no new domain logic needed), `pnpm build` (2 new real routes), `pnpm
db:test` N/A, `npx prettier --check .` clean. Full detail in `docs/DECISIONS.md` decision 235.

Decision 238, tenth increment (Filing & Evidence): `/tax/filing` -- the fifth Tax family item, the
period-closing action set decision 235 deferred: recording a payment (and reversing one), recording a
filing (original or amendment), reconciling the period, and attaching evidence to the period's filing. One
screen serves all three tax types the write RPCs accept (new `resolveFilingTaxType`/`FILING_TAX_TYPES`;
`wht_pph21` is excluded -- it is settled through `/payroll/tax` instead) via its own `?type=` selector.
Reused domain groundwork already sitting unused from earlier P7 work (`checkTaxPayment`/
`PAYMENT_ISSUE_LABELS`, `EVIDENCE_PURPOSE_LABELS`); added `eligibleTaxPaymentAccounts` (mirroring decision
232's own `eligibleCounterAccounts`) and extended `periodPositionSchema` to read the `reconciliation`
object `tax_period_position` already returns but nothing had read yet. Evidence targets the period's own
filing only in this increment (not per-payment) -- documented as a deliberate scope cut, same as decision
235's own deferral. Every write action's own server action lets `tax.mark_filed`'s `AuthzError` surface on
submit rather than gating the page. `pnpm check` (701 tests, up from 695), `pnpm build` (1 new real route),
`pnpm db:test` N/A, `npx prettier --check .` clean. Full detail in `docs/DECISIONS.md` decision 238.

Decision 239, eleventh increment (Tax Rules / Configuration, read-only): `/tax/rules` -- the sixth and last
Tax family item, a List/Detail over the global statutory rule master (`public.tax_rule_versions`). No RPC
lists every version of every rule, so both screens read the table directly (new `listTaxRuleVersions`),
covered by its own pre-existing `tax.view`-gated RLS policy -- the same direct-table-read precedent
decisions 161/167/170/171/172/173 established. Deliberately **read-only**: `saveRuleDraft`/`publishRule`/
`discardRule` were already fully built with no UI, but the rule-authoring workflow is filed as an **OWNER
QUESTION** rather than built blind -- the params shape is deeply family-specific JSON the Step 05 spec text
(kept outside this repo) may already prescribe a UX for, and publishing changes real tax output for every
document evaluated afterwards, squarely inside the "tax/economic meaning goes to the OWNER" rule. New
vocabulary: `RuleFamily`/`RULE_FAMILY_LABELS`, `RuleStatus`/`RULE_STATUS_LABELS`/`RULE_STATUS_TONE`,
`RuleVerificationStatus`/`RULE_VERIFICATION_LABELS`, and `taxRulesList.ts` mirroring `taxLedgerList.ts`'s
own filter/search pattern. Deliberately does not compute "in force right now" client-side, given decision
237's own finding that "today" is ambiguous between an Entity's and a caller's timezone. `pnpm check` (713
tests, up from 701), `pnpm build` (2 new real routes), `pnpm db:test` N/A, `npx prettier --check .` clean.
Full detail in `docs/DECISIONS.md` decision 239. This closes the Tax family.

Decision 240, twelfth increment (`/reports/*` routing): `/reports/cashflow`, `/reports/payroll` and
`/reports/custom` now redirect to their existing `/reports?statement=` tab (`cashflow`/`payroll_summary`/
`custom`), keeping `?entity=`; one shared mapping (`REPORT_SUBROUTE_STATEMENTS`/`reportSubrouteHref`).
`/reports/sales-purchase` and `/reports/saved` have no backend; `/reports/tax` and `/reports/assets-loans`
have no single obvious destination and stay on the catch-all pending the OWNER's choice. `pnpm check` (716
tests, up from 713), `pnpm build` (3 new real routes), `pnpm db:test` N/A. Full detail in
`docs/DECISIONS.md` decision 240.

Decision 241, thirteenth increment (Import history, read-only): `/admin/imports`, `/admin/imports/[id]`
-- `list_import_batches`/`get_import_batch_rows` (P11) given a screen, gated `system.import`, domain and
row-status filters passed through as the RPCs' own arguments. Row payloads are deliberately not rendered
(a contacts import can carry a tax identifier decision 225 keeps hidden); Validate/Commit/Rollback and
staging stay with the Import Wizard. `pnpm check` (720 tests, up from 716), `pnpm build` (2 new real
routes), `pnpm db:test` N/A. Full detail in `docs/DECISIONS.md` decision 241.

Decision 242, fourteenth increment (Audit Log, read-only): `/admin/audit` -- `public.audit_events` read
directly under its `audit.view` RLS policy, filter by operation, server-side paging (50), changed field
names shown but never their values, timestamps in labelled UTC. Also records that "Users & Roles" and
"Security" are nav-gated on `settings.view` while their tables use `users.view`/`security.view`.
`pnpm check` (731 tests, up from 720), `pnpm build` (1 new real route), `pnpm db:test` N/A. Full detail
in `docs/DECISIONS.md` decision 242.

Decision 243, fifteenth increment (Settings, read-only): `/admin/settings` -- Entity profile, document
numbering (with an example number built exactly like `allocate_document_number`), approval rules and
stored key/value settings, each read directly under its own RLS policy, gated `settings.view`. Editing is a
separate, later increment. `pnpm check` (738 tests, up from 731), `pnpm build` (1 new real route), `pnpm
db:test` N/A. Full detail in `docs/DECISIONS.md` decision 243.

Decision 251: Money Reconciliation workspace (`/money/reconciliation/new`, `/money/reconciliation/[id]`):
start a session, paste statement lines, match/unmatch/exclude/include, complete (with an accepted reason
for a difference), reopen and discard, all through the P4 RPCs; the session header and history are a
direct RLS read of `reconciliation_sessions`. No migration. Full detail in `docs/DECISIONS.md` decision 251.

Decision 252: Documents Archive (`/documents/archive`), Sales/Purchase report (`/reports/sales-purchase`)
and Saved Reports (`/reports/saved`, plus "Simpan laporan ini" on report pages), each on a new RPC. Full
detail in `docs/DECISIONS.md` decision 252.

Decision 253: per-payment evidence on `/tax/filing` (filing or any confirmed payment as the target).
No migration. Full detail in `docs/DECISIONS.md` decision 253.

Decision 254: menu names in Indonesian and reveal submenus in the Sidebar (OWNER request). Full detail in
`docs/DECISIONS.md` decision 254.

Decision 255: `/cash-snapshot` gives Ringkasan > Saldo Kas & Bank its own page; opened menus stay open.
Full detail in `docs/DECISIONS.md` decision 255.

Decision 256: PPh 4(2) on rent of land/buildings and PPh 26 on payments to non-residents in the tax
engine (tax types `wht_pph4_2`, `wht_pph26`), and the PMK 81/2024 payment deadline (the 15th) for PPh 21
and PPh 23. Next slice: Create Bill / Create Invoice screens with tax fields, then marketplace PPh 22.
Full detail in `docs/DECISIONS.md` decision 256.

Decision 257: Create Invoice (`/sales/invoices/new`) and Record Bill (`/purchases/bills/new`) screens;
tax fields per line (withholding object, VAT charged, tax-invoice number, VAT treatment) in the shared
line editor, also on Record Expense. No migration. Full detail in `docs/DECISIONS.md` decision 257.

Decision 258: screens for existing commands -- Add Customer/Vendor, Add Account, Record Payment (invoice),
Pay Bill, contact tax facts, Tax Setup (profile + engine switch). No migration. The remaining unscreened
commands are listed in `docs/DECISIONS.md` decision 258.

Decision 259: Payment Confirmation queue (`/sales/claims`: confirm or reject a pending customer claim) and
"Cabut Tautan Publik" on Invoice Detail. No migration. Full detail in `docs/DECISIONS.md` decision 259.

Decision 260: marketplace stores and settlements (`/sales/marketplace`), PPh 22 marketplace rule, the
final-tax computation counts marketplace turnover and deducts the PPh 22 collected; output VAT while PKP.
Migration `20261002200000_p14_marketplace_settlements.sql`. Full detail in `docs/DECISIONS.md` decision 260.

Decision 261: edit a draft invoice or bill (`/sales/invoices/[id]/edit`, `/purchases/bills/[id]/edit`);
tax baseline re-checked against official sources. No migration. Full detail in `docs/DECISIONS.md`
decision 261.

Decision 262: tax preview and manual override on Bill/Invoice Detail; Categories screen with tax mapping
(`/accounting/categories`). No migration. Full detail in `docs/DECISIONS.md` decision 262.

Decision 263: refund a confirmed payment from Payment Detail (`create_refund`, confirmed at once). No
migration. Full detail in `docs/DECISIONS.md` decision 263.

Decision 264: the remaining write screens in one slice -- payroll, fixed assets, financing (loans,
obligations, equity), manual journal, fiscal-year close, draft expense edit and small actions. No
migration. Still open: Import Wizard, document attachments (file storage, P15), category-to-account
mapping (backend), a browser walkthrough of every new screen. Full detail in `docs/DECISIONS.md`
decision 264.

Decision 265: `set_category_account` and the account column on the Categories screen. Full detail in
`docs/DECISIONS.md` decision 265.

Decision 266: browser walkthrough of the write screens on the preview; fixed the server-action exports
that broke every form, numeric reads without a text cast, four pages that failed to load, and form width
and wording. Still open: the step-up actions (tax engine activation, override, fiscal-year close) need the
OWNER's code to be exercised; forms lose typed values after an error. Full detail in `docs/DECISIONS.md`
decision 266.

Decision 267: forms keep what was typed after an error (`usePreservingForm`), every form shows the
database's reason for a refused request (`describeAuthzError`), and the step-up actions were exercised.
Still open: database reasons are English. Full detail in `docs/DECISIONS.md` decision 267.

Decision 268: fiscal groups fill in the useful life and the form shows the monthly depreciation;
`/assets/opening` for assets owned before the app. Open for the OWNER: depreciation on a Personal ledger.
Full detail in `docs/DECISIONS.md` decision 268.

Decision 269: fiscal group suggested from the asset name; depreciation posts itself after month end;
payroll payment fixed (deferred trigger now SECURITY DEFINER). Open for the OWNER: keep the personal
business as a business-type Entity with taxpayer kind "Orang pribadi". Full detail in
`docs/DECISIONS.md` decision 269.

Decision 270: step-up window 30 minutes (OWNER override of Step 06 §8); personal business to be set up at
P15 as a business-type Entity with taxpayer kind "Orang pribadi". Full detail in `docs/DECISIONS.md`
decision 270.

Decision 271: the database's refusal reasons are shown in Indonesian (`translateReason`, 852 templates).
Full detail in `docs/DECISIONS.md` decision 271.

Decision 272 (P15 started): production migrations workflow, `docs/GO_LIVE.md`, and `update_entity_identity`
with its Settings form. Waiting on the OWNER: the two GitHub secrets and the production user. Full detail
in `docs/DECISIONS.md` decision 272.

Decision 273: production schema, Entities and first OWNER are in place; Entity labels are "PT" and
"Pribadi"; PP 20/2026 has no time limit for individuals and Perseroan Perorangan. Next: the OWNER enters
taxpayer profiles, accounts and opening balances. Full detail in `docs/DECISIONS.md` decision 273.

Decision 274: PPh Final UMKM rule versions from 1 July 2018 (PP 23/2018, UU 7/2021, PP 55/2022) so
earlier years compute; click and page-loading feedback in the app shell. Full detail in
`docs/DECISIONS.md` decision 274.

Decision 275: Import Wizard screen, file attachments on Bill/Expense/Invoice (private bucket, needs
`SUPABASE_SERVICE_ROLE_KEY` in Vercel Production), PPh Final reasons in Indonesian. Open: a screen to
add an Entity (OWNER to confirm the rule). Full detail in `docs/DECISIONS.md` decision 275.

Decision 276: `create_entity` and the "Tambah Entity" form on Settings (OWNER only, step-up, creator
becomes OWNER). Full detail in `docs/DECISIONS.md` decision 276.

Decision 277: BPJS Kesehatan and BPJS Ketenagakerjaan are owed and paid separately (payment kinds,
posting lines, run screen). Full detail in `docs/DECISIONS.md` decision 277.

Decision 278: separate ledger accounts 2220 (BPJS Ketenagakerjaan) and 2221 (BPJS Kesehatan). Full detail
in `docs/DECISIONS.md` decision 278.

Decision 280: "Kirim Invoice via Email" over Resend, kept alongside "Salin Tautan Publik". New optional
`RESEND_API_KEY`/`RESEND_FROM_EMAIL` env vars (absent means off, same shape as the Storage service-role
key); `src/services/email/resend.ts` (plain fetch, no new dependency) and `src/services/sales/
invoiceEmail.ts` reuse the existing public-link commands -- never a second kind of link. No migration, no
new RPC. `pnpm check` (835 tests, unchanged) and `pnpm build` pass. Full detail in `docs/DECISIONS.md`
decision 280.

Decision 279: Asset Movement/Disposal report, closing the one Step 12 report-catalogue item decision 178
left open. New read-only RPC `asset_movement_report` (gated by `assets.view` alone), a "Mutasi/Pelepasan
Aset" tab on `/reports`, and pgTAP coverage in `96_p8_assets.sql`. `pnpm db:test` passes (clean rebuild,
invariants, upgrade check); `pnpm check` (835 tests) and `pnpm build` pass. Full detail in
`docs/DECISIONS.md` decision 279.

Decision 281: Loan foreign-currency revaluation, the loans half of the OWNER's "Versi Sederhana" FX
confirmation (any selectable currency, IDR default, manual monthly rate entry, automatic FX gain/loss to
P&L) -- the fixed-asset half and interest accrual stay open. New migration adds `loan_fx_terms`/
`loan_fx_revaluations` and additively patches `app_private.loan_outstanding` (the one function every loan
reader already calls) and `public.loan_detail`; three new RPCs `loan_set_fx_terms`/`loan_revalue_fx`/
`loan_reverse_fx_revaluation` (currency locks after the first revaluation, 20% rate sanity guard, only the
latest revaluation is reversible). pgTAP coverage in `98_p8_loans.sql` section 13; full TS schema/service/
action/UI layer in the financing module. `pnpm db:test` passes (clean rebuild, invariants, upgrade check);
`pnpm check` (838 tests) and `pnpm build` pass. Full detail in `docs/DECISIONS.md` decision 281.

Decision 282: Fixed-asset foreign-currency memo, the fixed-asset half of the OWNER's "Versi Sederhana" FX
confirmation -- historical-rate only, no revaluation ("Hanya catat & tampilkan dalam mata uang asal");
interest accrual stays open. New migration adds nullable `fx_currency`/`fx_cost`/`fx_rate` to `fixed_assets`
(locked once an asset leaves draft, same as its cost and date). Captured automatically from a
foreign-currency bill/expense line at registration (`app_private.asset_register_line`); given explicitly
for opening assets (`asset_load_opening`, with the same 20% mistyped-rate guard the loans half of this
confirmation uses). `public.asset_detail` patched to surface it; pgTAP coverage in `96_p8_assets.sql`
section 11. `pnpm db:test` passes (clean rebuild, invariants, upgrade check); `pnpm check` (836 tests) and
`pnpm build` pass. Full detail in `docs/DECISIONS.md` decision 282.

Decision 283: Loan Restructure and Loan Set-Asset UI, closing the last two Part 3f action-form gaps found by
a code audit (the "Open items" bullet claiming every loan/obligation/equity action form was missing was
stale -- only these two were actually unbuilt). `restructureLoanAction`/`setLoanAssetAction` added to
`financingActions.ts`; two new `CommandForm`s ("Restrukturisasi Jadwal", "Tautkan ke Aset") added to
`LoanActionsPanel`; loan detail page now also loads the entity's fixed-asset list for the asset-link
dropdown. Pure wiring onto the already-built, already-tested `loan_restructure`/`loan_set_asset` RPCs -- no
schema, RPC or migration change. Automatic interest accrual was considered and explicitly declined this
round (decision 108, cash-basis, reconfirmed by the OWNER). `pnpm check` (839 tests, unchanged) and
`pnpm build` pass. Full detail in `docs/DECISIONS.md` decision 283.

Decision 284: AR Aging / AP Aging report screen, closing another "Open items" gap found by the same
code-audit method as decision 283 -- `ar_aging`/`ap_aging` (P5/P6) were already built, typed and tested but
only ever consumed by the Dashboard's KPI tiles. New "Umur Piutang"/"Umur Utang" tabs on `/reports`
(`ArAgingTable`/`ApAgingTable`), a shared `agingTotals` helper in `src/domain/reports/reports.ts`, each
gated by its own RPC's own permission (`invoices.view`/`bills.view`). Pure wiring -- no schema, RPC or
migration change. `pnpm check` (841 tests, up from 839: two new `agingTotals` unit tests) and `pnpm build`
pass. Full detail in `docs/DECISIONS.md` decision 284.

Decision 286: Split Aset screen, wiring up the one P8 asset command with no form (`asset_split`, found by a
direct code audit of every `src/services/**` export against its action/UI consumers, same method decision
283 used). New `splitAssetAction` + `SplitAssetForm` (a repeating name+cost row editor, 2-50 rows) on Asset
Detail, shown only for a draft asset from a purchase/expense line (not `opening`), matching `asset_split`'s
own guard. Pure wiring -- no schema, RPC or migration change. `pnpm check` (841 tests, unchanged) and
`pnpm build` pass. Full detail in `docs/DECISIONS.md` decision 286.

Decision 244 (OWNER answers 1a/2a/3a): "Users & Roles" and "Security" are now nav-gated on
`users.view` and `security.view`; `/reports/tax` forwards to `/tax/ledger`; `/reports/assets-loans`
forwards to the Kontrol Aset Tetap tab. `pnpm check` (740 tests, up from 738), `pnpm build` (2 new
real routes). Full detail in `docs/DECISIONS.md` decision 244.

Decision 250: Forecasts (OWNER answer to decision 139). `/planning/forecasts` shows, per category and
month, the 3-month average actual, replaced by a chosen budget's amount where the budget plans; the
Budget and Revenue Target reports now fill their Forecast column. Full detail in `docs/DECISIONS.md`
decision 250.

Decision 245, seventeenth increment: Products & Services (`/sales/products` list, create, detail and
edit), Direct Expenses (`/purchases/expenses` list, create, detail with submit, recall, reject, confirm,
cancel, reverse and correct) and Opening Balances (`/accounting/opening-balances` history, posting grid
and completion). No migration: the tables, RLS policies and RPCs already existed. Full detail in
`docs/DECISIONS.md` decision 245.

Decision 249: tax rule authoring on `/tax/rules` (OWNER answer to decision 239). New version prefilled
from a published rule, edit/publish/discard of drafts through the P7 RPCs, step-up and verified source
required to publish. No migration. Full detail in `docs/DECISIONS.md` decision 249.

Decision 246, eighteenth increment: Users & Roles (`/admin/users`, member detail with role change,
enable/disable and permission overrides through the step-up-gated P2 RPCs), Security Center
(`/admin/security`, read-only) and Recent Activity (`/activity`). No migration. Full detail in
`docs/DECISIONS.md` decision 246.

Decision 247, P14: Backup & Restore Center Part 2 -- restore into an empty Entity (OWNER decision)
with database-side validation, impact preview, step-up, typed Entity-code confirmation, one-transaction
write with integrity verification and restore history -- plus trusted-device revocation on
`/admin/security`. Fixes Part 1's export precision defect. The automated restore drill runs in
`pnpm db:test`. Full detail in `docs/DECISIONS.md` decision 247.

Decision 248, P14: OWNER answered decision 237. Tax periods follow the Entity's own timezone and fiscal
year (defaults WIB and January); the OWNER can change both in Settings (fiscal-year start only before any
accounting period exists). Test 9.5's month-end flake is fixed. Full detail in `docs/DECISIONS.md`
decision 248.

Still on the catch-all after these eighteen increments (tracked so nothing is silently dropped):
nothing: per-payment evidence on `/tax/filing` was built by decision 253, and `/documents/archive`,
`/reports/sales-purchase` and `/reports/saved` by decision 252. Every Step 09 nav item now has a screen.

`hikarich-finance-dev` brought current with the codebase (decision 227): OWNER approved applying the 46
pending migrations to this non-production Preview/dev project directly. Applied via the Supabase management
API in strict filename order, matched to the 15 already-applied migrations by name. `list_migrations`
independently re-verified: 61 migrations total, ending with `p14_backup_restore`, matching the repo exactly.
`hikarich-finance-prod` confirmed untouched. Security/performance advisors re-run and re-checked directly --
no new finding categories, everything observed matches this codebase's own established, intentional patterns
(SECURITY DEFINER RPCs with internal authorization checks; RLS-enabled-no-policy on RPC-only tables). Closes
the infrastructure gap decisions 222/223 flagged as OWNER-only. Unblocks both remaining Phase 14 items at
once: the Backup & Restore Center Part 2 restore drill now has a real non-production database to drill
against, and live browser/device E2E accessibility testing can now run against a real Vercel Preview
deployment instead of needing a local Docker-based Supabase stack. No repo files changed -- database-side
only; `pnpm db:test`'s fingerprint (a from-scratch local rebuild) is unaffected.

Live browser E2E smoke check against the now-current Preview deployment (decision 228): confirmed the
PR's own Vercel Preview build (backed by the now-current hikarich-finance-dev) renders /login correctly
end to end with zero console errors and correctly-labeled form fields. Going further requires signing in,
which this session's standing safety rules prohibit on any non-local host -- a hard stop, not a scope
choice. Authenticated E2E/accessibility testing stays open pending either the OWNER doing a signed-in
walkthrough with this session, or a dedicated non-production test login.

Security hotfix (decision 236): `pnpm audit --prod --audit-level=high` newly reported a critical RCE
advisory (GHSA-vcvr-r3jv-pc5j) affecting `next` `16.3.5` (vulnerable range `>=16.2.0 <16.3.6`), discovered
while verifying CI for decision 235's PR -- not caused by any code change here, the public advisory
database simply picked up a new disclosure. Bumped `next` and `eslint-config-next` to the latest patched
`16.3.8` (patch-only, no API change). Built as a standalone branch off `main` directly, not stacked on the
Tax family chain, so it can merge immediately -- every other open PR in the stack will start failing this
same audit check on its next CI re-run until this lands and each branch picks it up. Also investigated
decision 235's PR's own "Migration clean-rebuild and invariants" CI failure alongside this: reproduced
`pnpm db:test` locally against the identical migration set and it passed cleanly, so that failure is
treated as a transient CI-runner flake, not a real defect (decision 235 touches zero migrations). `pnpm
audit` now clean, `pnpm check` (673 tests, unchanged), `pnpm build` (no routes added/removed), `pnpm
db:test` not re-run (JS-only change), `npx prettier --check .` clean. Full detail in `docs/DECISIONS.md`
decision 236.

**OWNER QUESTION -- resolved by decision 248** (decision 237): the "Migration clean-rebuild and invariants" CI job
started failing on decisions 235/236's PRs (`95_p7_determination.sql` test 9.5), reproducibly on CI but
not locally. Traced to a real timezone-boundary defect in already-shipped P7 code, not anything in 235/236
(both touch zero P7 files): `tax_final_evaluate`'s "period is over" guard compares against
`entity_today()` (Entity's own timezone), while the test picks its period with plain `current_date`
(Postgres session's timezone) -- the two disagree during the hours, on the last day of any month, where
the Entity's timezone has already rolled into next month but the session's hasn't, letting evaluation fall
through the guard. Left unresolved: this is Step 05 §9 tax-computation logic and its own invariant test,
both locked spec, so a fix (either make the test entity-timezone-aware, or decide what "period over" means
across timezones) needs OWNER sign-off rather than a solo call. No repo behavior changed, documentation
only. Full root-cause trace in `docs/DECISIONS.md` decision 237.
