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

## Sales and receivables tests (P5)

`92_p5_sales.sql` covers, in order: customers, products and accounts (duplicate-aware
customers, canonical phone numbers, sensitive fields); draft invoices with server-side
arithmetic and validation; issuing (numbering, snapshots, journal, public link); payments
(partial, exact, several invoices, foreign currency with exchange differences, overpayment kept
as a customer advance); "Saya Sudah Bayar" claims and the anonymous token surface (limits,
control characters, unknown and revoked tokens, no table readable by `anon`); the approval
rule with maker-checker and reversals of payments and credit applications; cancel, void,
correct and link regeneration; refunds from an allocation and from the advance, in a foreign
currency; positions, aging and the receivables control over time; period closing and closed
periods; authorization, Entity isolation and privileges; the receivables control catching a
broken book; the hardening cases found by the independent review (base-currency thresholds,
due-date bound, exact small percentage discount, link token permission, public receipt scope,
refund and void date bounds, correcting an invoice whose product was retired); and exact
proration on near-ties against rational-arithmetic references. Every case ends with the
sales/money/ledger controls.

`db-test.sh` adds `sales_concurrency_test`: six sessions race to pay one invoice, retry one
request, confirm and reject one claim, reverse and refund one payment, void and pay one invoice,
refund one payment repeatedly, and confirm a claim while its invoice is voided (which must not
deadlock). Every item takes effect exactly once and the layers still agree at the end. The suite
was checked against deliberately broken code (16 mutants in the first pass: 14 killed, 2
equivalent; plus the review fixes: base-currency threshold, percentage discount, due-date bound,
refund date bound, receipt scope, exact proration, retired-product correction, link permission,
void date bound and the claim/invoice lock order, each killed). The independent review's findings
were fixed or documented as accepted (DECISIONS 76) with a regression check.

## Purchases and payables tests (P6)

`93_p6_purchases.sql` covers, in order: vendors, categories and accounts; draft bills with
server-side arithmetic and validation (three line treatments, foreign currency, limits);
submit, recall, reject and approve (numbering, vendor snapshot, journal); payments in the base
currency (partial, exact, several bills at once); foreign-currency bills and payments with
exchange gains and losses; reversing a payment, including the sub-ledger against the ledger on
every day; due-date change, cancel, void and correct; duplicate detection on vendor references;
direct expenses (duplicates, dates, cancel, reverse, correct); evidence documents and links;
period closing and closed periods; maker-checker thresholds in the base currency; the review
hardening cases (a payment cannot be dated before a reversal on the same bill, the person who
edited or submitted a document is a preparer too, direct writes cannot break allocations or void
a bill with money on it, explicit input limits, a payee snapshot that survives a contact rename);
and the Personal Entity, isolation between Entities and privileges. Every case ends with the
purchase/money/ledger controls.

`db-test.sh` adds `purchases_concurrency_test`: six sessions race to pay one bill, retry one
request, approve two bills with the same vendor invoice number, void and pay one bill, reverse a
payment and void its bill, confirm and cancel one expense, confirm two expenses with the same
receipt, and pay and reverse on one account at once (which must not deadlock). Every item takes
effect exactly once and the layers still agree at the end. The suite was checked against
deliberately broken code (the first pass and the review fixes, dozens of mutants in total: every
one killed except a few behaviour-neutral redundant defences). The independent review's findings
were fixed or documented as accepted (DECISIONS 85-87) with a regression check.

## Tax tests (P7)

`94_p7_tax.sql` covers the rule master (drafts, step-up, publishing, effective dates, repeals, immutability), the taxpayer
and counterparty facts, aggregation facts and the engine switch. `95_p7_determination.sql` covers, in order: fixtures;
the evaluators with their effective-date boundaries and NEEDS_REVIEW cases (output VAT, input VAT, PPh 23, a payee
without NPWP, an individual payee, a non-resident payee); invoices with VAT (totals, receivable, revenue at the price, a zero
determination before PKP status, a document that needs review is not issued, a line confirmed by a tax reviewer, a
discount booked through the contra-revenue account with VAT on the price after the discount); bills and expenses (creditable
input VAT to Tax Asset, withholding to Tax Payable, the payable net of withholding, payment capacity); OWNER overrides
(who may, step-up, limits, replay, withdrawal) and confirmation; void, correction and reversal of recognised documents with
the tax ledger reversed; tax payments (part, exact, over the outstanding, offset against input VAT, offset beyond the input
VAT available, penalty, reversal, dates, base-currency account); filings and amendments; evidence; reconciliation (stale,
differences with notes, unpaid, overpaid, nothing to reconcile); the tax control against the General Ledger; PPh Final UMKM
(review cases, the exempt band, the annual ceiling, recomputation posting only the difference, an excluded taxpayer);
the calendar and overview; the period-close checks; exact decimal text in the lists; and authorization (roles, strangers, the
other Entity, anonymous, no direct writes, frozen history). Every scenario ends with the tax and money controls.

The tax layer was checked against deliberately broken code (mutation checks over the determination, integration, payments,
filings and final-tax code: dozens of mutants; every one killed except two behaviour-neutral redundant defences, DECISIONS 100).

## Assets, loans and equity tests (P8)

`96_p8_assets.sql` covers the register from approved purchase lines (draft assets, splitting, the link status of the
line, release on void), activation and the depreciation plan (straight-line, declining balance, undepreciated, residual,
fiscal class), the month-end posting run and its reversal, re-planning, disposal (sale for cash, sale on credit,
scrapping, reversal, the gain or loss), opening assets, the register and reports, and authorization. `97_p8_obligations.sql`
covers other receivables and payables: recognition by cash and by offset, part settlement with interest and fee, write-off,
reversal, void, the related-entity tag and Personal Entities. `98_p8_loans.sql` covers the schedule arithmetic (annuity,
flat, interest-only, manual, month-end due dates), drafts, activation for both directions, allocation of payments (arrears
first, prepayment, interest and fee), closing and reopening, write-off, restructuring with preserved history, cancellation,
the asset link, opening loans with the opening balance batch, Personal loans and authorization. `99_p8_equity.sql` covers
contributions, capital returns (guarded by the equity balance), dividends in parts and beyond the profit available,
Personal investment and distribution events, `equity.approve`, step-up and the summary. `99_p8_period_controls.sql` covers
the period-close checks (unposted depreciation, the asset and financing controls with rolled-back probes, pending asset
lines, unpaid installments, tax reviews), the financing control report, the tax-review queue and command, and the shape
check of the fiscal depreciation groups. Every scenario ends with the money and sub-ledger controls.

The TypeScript layer checks that the schedule and depreciation previews (`src/domain/financing`, `src/domain/assets`)
give the same figures as the database functions, and that the schemas accept what the database returns (they were
checked against real payloads of every report and detail function) and refuse malformed input.
