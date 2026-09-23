-- P12 gate (Step 15 Phase 12, Step 12 §4/§31): year-end closing entries
-- (20260930200000_p12_year_end_closing.sql). Covers: the periods.close/periods.reopen permission gates,
-- the "every period of the fiscal year must be closed" guard, the actual closing math (P&L-class accounts
-- net to zero, retained earnings receives the net result, entry_type = 'closing'), idempotent replay, the
-- already-closed conflict, the STEP_UP_REQUIRED/reason gates on reversal, and that a reversed fiscal year
-- can be closed again with a brand new journal. The "close/reverse fiscal years in order across multiple
-- years" guards are exercised only by inspection of 20260930200000_p12_year_end_closing.sql, not by a
-- second fiscal year here, to keep this fixture focused. All data is synthetic; the whole file runs in one
-- transaction that is rolled back.

begin;
set local client_min_messages = warning;

do $$
declare
  v_pt uuid;
  v_owner uuid := 'e0000000-0000-0000-0000-000000000001';
  v_accountant uuid := 'e0000000-0000-0000-0000-000000000002';
  v_viewer uuid := 'e0000000-0000-0000-0000-000000000003';
  v_jan uuid;
  v_jun uuid;
  v_journal uuid;
  v_replay uuid;
  v_reversal uuid;
  v_retained uuid;
  v_cye uuid;
  v_revenue uuid;
  v_expense uuid;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p12_close_pt', 'P12 Closing PT (synthetic)') returning id into v_pt;
  perform app_private.provision_default_coa(v_pt);
  perform test_helpers.mk_user(v_owner, 'p12_owner');
  perform test_helpers.mk_user(v_accountant, 'p12_accountant');
  perform test_helpers.mk_user(v_viewer, 'p12_viewer');
  perform test_helpers.mk_member(v_pt, v_owner, 'owner');
  perform test_helpers.mk_member(v_pt, v_accountant, 'accountant');
  perform test_helpers.mk_member(v_pt, v_viewer, 'viewer_auditor');

  v_revenue := test_helpers.acct(v_pt, 'OTHER_OPERATING_REVENUE');
  v_expense := test_helpers.acct(v_pt, 'OFFICE_GENERAL_EXPENSE');
  v_retained := test_helpers.acct(v_pt, 'RETAINED_EARNINGS');
  v_cye := test_helpers.acct(v_pt, 'CURRENT_YEAR_EARNINGS');

  -- FY2024 (calendar year, fiscal_year_start_month defaults to 1): 10,000,000 revenue in January,
  -- 3,000,000 expense in June -> net result 7,000,000 profit. Only these two periods ever exist.
  perform test_helpers.simple_journal(v_pt, date '2024-01-15', test_helpers.acct(v_pt, 'BANK_OPERATING'), v_revenue, 10000000);
  perform test_helpers.simple_journal(v_pt, date '2024-06-15', v_expense, test_helpers.acct(v_pt, 'BANK_OPERATING'), 3000000);
  select id into v_jan from public.accounting_periods where entity_id = v_pt and fiscal_year = 2024 and extract(month from period_start) = 1;
  select id into v_jun from public.accounting_periods where entity_id = v_pt and fiscal_year = 2024 and extract(month from period_start) = 6;

  -- 1. cannot close before every period of the fiscal year is closed
  perform test_helpers.login(v_accountant);
  perform test_helpers.expect_msg(format('select public.close_fiscal_year(%L, 2023, ''p12-close-2023'')', v_pt),
    'NOT_FOUND', 'FY2023 never had any periods (the two journals above are both dated in 2024)');
  perform test_helpers.expect_msg(format('select public.close_fiscal_year(%L, 2024, ''p12-close-early'')', v_pt),
    'CONFLICT', 'FY2024''s two periods exist (auto-created by the journals above) but neither is closed yet');
  perform test_helpers.logout();

  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.close_fiscal_year(%L, 2024, ''p12-close-a'')', v_pt),
    'FORBIDDEN', 'a viewer (no periods.close) cannot close a fiscal year');
  perform test_helpers.logout();

  perform test_helpers.login(v_accountant);
  perform test_helpers.expect_msg(format('select public.close_fiscal_year(%L, 2024, ''p12-close-b'')', v_pt),
    'CONFLICT', 'January is not closed yet');
  perform public.begin_period_close(v_jan);
  perform public.close_period(v_jan);
  perform test_helpers.expect_msg(format('select public.close_fiscal_year(%L, 2024, ''p12-close-c'')', v_pt),
    'CONFLICT', 'June is still open even though January is closed');
  perform public.begin_period_close(v_jun);
  perform public.close_period(v_jun);

  -- 2. closing books the net result to retained earnings and zeroes the year's P&L accounts
  v_journal := public.close_fiscal_year(v_pt, 2024, 'p12-close-d');
  perform test_helpers.assert(v_journal is not null, 'closing returns a journal id');
  perform test_helpers.assert((select entry_type from public.journal_entries where id = v_journal) = 'closing',
    'the closing journal carries entry_type = closing');
  perform test_helpers.assert((select entry_date from public.journal_entries where id = v_journal) = date '2024-07-01',
    'dated the day after the fiscal year''s last existing period (June), landing in a fresh open period');
  perform test_helpers.assert(
    (select coalesce(sum(debit), 0) from public.journal_lines where journal_id = v_journal)
    = (select coalesce(sum(credit), 0) from public.journal_lines where journal_id = v_journal),
    'the closing journal balances');
  perform test_helpers.assert(
    (select coalesce(sum(l.debit), 0) - coalesce(sum(l.credit), 0)
     from public.journal_lines l join public.journal_entries j on j.id = l.journal_id
     where l.ledger_account_id = v_revenue and j.status = 'posted') = 0,
    'the revenue account nets to zero across all posted activity (including the closing line)');
  perform test_helpers.assert(
    (select coalesce(sum(l.debit), 0) - coalesce(sum(l.credit), 0)
     from public.journal_lines l join public.journal_entries j on j.id = l.journal_id
     where l.ledger_account_id = v_expense and j.status = 'posted') = 0,
    'the expense account nets to zero across all posted activity (including the closing line)');
  perform test_helpers.assert(
    (select coalesce(sum(l.credit), 0) - coalesce(sum(l.debit), 0)
     from public.journal_lines l join public.journal_entries j on j.id = l.journal_id
     where l.ledger_account_id = v_retained and j.status = 'posted') = 7000000,
    'retained earnings received the 7,000,000 net result');
  perform test_helpers.assert(
    not exists (select 1 from public.journal_lines where journal_id = v_journal and ledger_account_id = v_cye),
    'nothing is ever posted to the CURRENT_YEAR_EARNINGS placeholder account itself');
  perform test_helpers.assert(
    (select count(*) from public.fiscal_year_closures where entity_id = v_pt and fiscal_year = 2024 and reversed_at is null) = 1,
    'one active closure row is recorded');

  -- 3. idempotent replay and the already-closed conflict
  v_replay := public.close_fiscal_year(v_pt, 2024, 'p12-close-d');
  perform test_helpers.assert(v_replay = v_journal, 'the same key replays the same closing journal');
  perform test_helpers.expect_msg(format('select public.close_fiscal_year(%L, 2024, ''p12-close-e'')', v_pt),
    'CONFLICT', 'a different key for an already-closed year is refused');
  perform test_helpers.logout();

  -- 4. reversal gates: permission, step-up, reason length
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.reverse_fiscal_year_closing(%L, 2024, ''undo the FY2024 close for testing'')', v_pt),
    'FORBIDDEN', 'a viewer (no periods.reopen) cannot reverse a closing');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner, 'aal2', interval '20 minutes');
  perform test_helpers.expect_msg(format('select public.reverse_fiscal_year_closing(%L, 2024, ''undo the FY2024 close for testing'')', v_pt),
    'STEP_UP_REQUIRED', 'a stale authentication cannot reverse a closing');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.reverse_fiscal_year_closing(%L, 2024, ''short'')', v_pt),
    'INVALID', 'a reason under 10 characters is refused');
  perform test_helpers.expect_msg(format('select public.reverse_fiscal_year_closing(%L, 2023, ''undo a year that was never closed'')', v_pt),
    'NOT_FOUND', 'FY2023 has no active closure to reverse');

  v_reversal := public.reverse_fiscal_year_closing(v_pt, 2024, 'undo the FY2024 close for testing');
  perform test_helpers.assert(v_reversal is not null, 'reversal returns a journal id');
  perform test_helpers.assert(
    (select coalesce(sum(l.credit), 0) - coalesce(sum(l.debit), 0)
     from public.journal_lines l join public.journal_entries j on j.id = l.journal_id
     where l.ledger_account_id = v_retained and j.status = 'posted') = 0,
    'retained earnings is back to zero after the reversal');
  perform test_helpers.assert(
    (select reversed_at is not null and reversal_journal_id = v_reversal from public.fiscal_year_closures
     where entity_id = v_pt and fiscal_year = 2024 and closing_journal_id = v_journal),
    'the closure row records its own reversal');
  perform test_helpers.expect_msg(format('select public.reverse_fiscal_year_closing(%L, 2024, ''cannot reverse the same closing twice'')', v_pt),
    'NOT_FOUND', 'the same fiscal year has no active closure left to reverse a second time');

  -- 5. a reversed fiscal year can be closed again (a fresh closing journal, not a replay of the reversed one)
  perform test_helpers.assert(public.close_fiscal_year(v_pt, 2024, 'p12-close-f') <> v_journal,
    're-closing FY2024 posts a brand new closing journal, distinct from the reversed one');
  perform test_helpers.assert(
    (select coalesce(sum(l.credit), 0) - coalesce(sum(l.debit), 0)
     from public.journal_lines l join public.journal_entries j on j.id = l.journal_id
     where l.ledger_account_id = v_retained and j.status = 'posted') = 7000000,
    'retained earnings carries the net result again after re-closing');
  perform test_helpers.logout();
end
$$;

rollback;
