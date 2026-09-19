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
