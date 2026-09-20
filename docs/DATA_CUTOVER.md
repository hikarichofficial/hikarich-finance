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
