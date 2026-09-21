# Data Cutover (opening balances, imports, go-live)

Status: **procedure to be completed in P15**, using Steps 01, 04, 08, 14 and 16. No production
data exists yet and none may be loaded before the gates below pass.

## Preconditions before any real data enters production

1. P14 gates pass, including a backup export and a restore drill on a non-production project.
2. OWNER approves the cutover date and the opening-balance source (Step 17 §21: a destructive
   real-data migration/cutover choice needs OWNER approval).
3. Taxpayer facts are confirmed by the OWNER (status, NPWP, PKP) — never guessed.
4. Preview and Development contain test data only; real evidence is never copied there.

## Outline (details fixed in P15)

1. Freeze the opening date per Entity (PT and Personal remain separate ledgers).
2. Load opening balances through the accounting engine as balanced, posted journals — never by
   direct table inserts.
3. Import master data and open documents through the import staging flow with batch/row lineage.
4. Reconcile: trial balance equality, sub-ledger to control account, counts and totals recorded
   as evidence.
5. OWNER sign-off, then production go-live.

## First OWNER (P2, decision 33)

Access to production starts with one OWNER. Sequence at release: the OWNER creates their own user
in Supabase Auth (they type the password), a database administrator runs
`select app_private.bootstrap_owner('<auth user id>', '<display name>')` once, and the OWNER then
signs in and enrols an authenticator (mandatory for OWNER). Further users are added through
`assign_membership`; no credentials pass through code, chat or Git.

## Opening balances (P3, decisions 43-44)

The mechanism exists and is tested; it is used only at release, by the OWNER, per Entity:

1. `post_opening_balances(entity, key, cutover date, lines, note)` posts one opening journal.
   Only balance-sheet accounts are accepted. Anything the lines do not balance is held in
   8900 Opening Balance / Migration Clearing, so an incomplete migration is visible.
2. Further batches may be added until the migration is completed (for example one batch per
   source: bank balances, then payables).
3. `complete_opening_balances(entity, note)` succeeds only when 8900 is zero, or when a written
   migration adjustment note documents the residual. It ends the opening window for that Entity.
4. The period that contains the cutover date cannot be closed before step 3.
5. Sub-ledger detail behind control accounts (open invoices and bills, loans, assets) is loaded
   by the P5-P8 modules and reconciled to the control account (decision 44).
6. Cash, bank and e-wallet balances (P4, decisions 51-53): create every financial account first
   (`create_financial_account`, without postings on its ledger account), then post the opening
   balance line on that account's ledger account. The same command creates the opening movement, so
   the money layer equals the ledger from the first day. Foreign-currency accounts state the
   original amount and rate on the line. The first bank reconciliation of each account starts from
   the statement's opening balance; a difference to the system is accepted only with a written reason.
7. Customer invoices still open at the cutover (P5): P5 has no loader for them. Two ways exist and
   only one may be used per Entity: (a) issue them as normal invoices dated at their original
   issue date (the numbers then come from the Entity's own invoice family; the customer receives
   the original document elsewhere), which posts revenue and must therefore be excluded from the
   opening balance; or (b) post the receivable in the opening balance and keep the invoices
   outside the system until P11 defines the import. Doing both would count the receivable twice:
   the receivables control (decision 74) shows the opening balance separately as `other_ledger`
   so a double count is visible, not silent.
8. Vendor bills and expenses still open at the cutover (P6): P6 has no loader for them either, and
   the same two ways exist with the same rule of one way per Entity: (a) approve them as normal
   bills dated at their original bill date, which posts the expense and must therefore be excluded
   from the opening balance; or (b) post the payable in the opening balance and keep the bills
   outside the system until P11 defines the import. The payables control (decision 80) shows the
   opening balance separately as `other_ledger`, so a double count is visible, not silent. Payments
   made before the cutover are not entered. Original invoices and receipts stay with the OWNER;
   evidence is registered by hash only (decision 83).
9. Tax at the cutover (P7): documents dated before the Entity's tax-engine start date carry no tax and
   are never re-evaluated, so the engine start date is the cutover line: set it to the first day from
   which tax should be recognised by the system. Opening balances of Tax Payable and Tax Asset are
   posted as opening balances and appear in the tax control as `ledger_other`, never as a difference;
   tax already paid or filed for earlier periods is not entered. Turnover earned outside this system in
   the tax year counts toward the annual ceiling only when recorded as an aggregation fact, and an
   individual whose year predates the engine start is a review case for the final tax (decision 97).
   The taxpayer's NPWP, PKP status and regime are entered as facts with an evidence note, never copied
   from documents into Git (decision 90).
10. Fixed assets at the cutover (P8): load each asset with `asset_load_opening` (cost, accumulated depreciation to the
    cut-over date, in-service date, method and life); nothing is posted by the loader. The cost and the accumulated
    depreciation of the same assets are posted by the opening balance batch on the fixed-asset and Accumulated
    Depreciation accounts, and the asset control (`asset_control_report`) must show no difference before the first period
    is closed (decision 115). Depreciation continues from the month after the cut-over. Assets bought after the cut-over
    come from bills and expenses with treatment `asset`.
11. Loans at the cutover (P8): load each loan with `loan_load_opening` (outstanding principal, terms and the schedule
    still to run; the original principal may be given); nothing is posted by the loader. The outstanding principal is posted
    by the opening balance batch on the loan account the loan uses (short-term, long-term, Personal loan, or Other
    Receivable for a loan given), and the financing control must show no difference. Interest and fees already paid before
    the cut-over are not entered (decision 108).
12. Other receivables and payables at the cutover (P8): record each open item as an obligation with the `offset` method
    against an account chosen by the accountant, dated at the cut-over, and do NOT include Other Receivable, Other Payable
    or Dividend Payable in the opening balance batch (the same rule of one way per Entity as items 7 and 8); a control
    difference shows a double count. Declared but unpaid dividends are entered as a dividend event confirmed on its date
    and paid in parts as usual. The tax treatment of anything paid before the cut-over is not entered (decision 106).

13. Payroll at the cutover (P9): create each employee with the join date of the real employment, then record the
    compensation, tax facts (tax-number status, PTKP status, who bears the tax) and BPJS enrolment from the date they
    apply. For a tax year that was payrolled before the cut-over, record per employee with `employee_set_tax_opening` the
    taxable gross, the pension contributions and the PPh 21 withheld from January through the last month paid (up to
    November); without it the annual computation of the last tax month flags `ytd_incomplete` and the run cannot be
    submitted. Payroll unpaid at the cut-over is in the opening balance batch on Payroll Liabilities and BPJS Liabilities
    and shows as "other" in the payroll control until it is paid; do not also create a run for that month (decision 130).
    The first run is for the first month after the cut-over. Real payroll figures and tax numbers are entered only in
    the application, never in files in Git.
