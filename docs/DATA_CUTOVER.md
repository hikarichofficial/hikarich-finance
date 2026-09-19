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
