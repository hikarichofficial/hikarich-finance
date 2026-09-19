-- Journal / posting hard invariants (Step 04 §1/§11, Step 08 §6/§14, Step 17 §13), enforced by the database.
begin;
set local client_min_messages = warning;

do $$
declare
  pt uuid := test_helpers.entity('demo_pt');
  pe uuid := test_helpers.entity('demo_personal');
  a_exp uuid := test_helpers.acct(pt, 'OFFICE_GENERAL_EXPENSE');
  a_rev uuid := test_helpers.acct(pt, 'OTHER_OPERATING_REVENUE');
  a_bank uuid := test_helpers.acct(pt, 'BANK_OPERATING');
  a_grp uuid;
  a_off uuid;
  j uuid;
  j2 uuid;
  rev uuid;
  v_period uuid;
  v_rec record;
begin
  select id into a_grp from public.ledger_accounts where entity_id = pt and code = '1100';
  insert into public.ledger_accounts (entity_id, code, name, account_class, normal_balance, allows_manual_posting, status)
  values (pt, '6990', 'Retired expense', 'expense', 'debit', true, 'inactive') returning id into a_off;

  -- ---- happy path, exact decimals (0.1 + 0.2 = 0.3)
  j := test_helpers.draft_journal(pt, date '2026-09-10');
  perform test_helpers.add_line(j, a_exp, 0.1, 0);
  perform test_helpers.add_line(j, a_exp, 0.2, 0);
  perform test_helpers.add_line(j, a_rev, 0, 0.3);
  perform test_helpers.post(j);
  select * into v_rec from public.journal_entries where id = j;
  perform test_helpers.assert(v_rec.status = 'posted' and v_rec.posted_at is not null, 'journal posted with timestamp');

  -- ---- immutability of posted journals and their lines
  perform test_helpers.expect_error(format('update public.journal_entries set description = %L where id = %L', 'edit', j), '23000', 'posted journal update');
  perform test_helpers.expect_error(format('delete from public.journal_entries where id = %L', j), '23000', 'posted journal delete');
  perform test_helpers.expect_error(format('update public.journal_lines set debit = 5 where journal_id = %L and line_no = 1', j), '23000', 'posted line update');
  perform test_helpers.expect_error(format('delete from public.journal_lines where journal_id = %L', j), '23000', 'posted line delete');
  perform test_helpers.expect_error(
    format('insert into public.journal_lines (entity_id, journal_id, line_no, ledger_account_id, debit) values (%L,%L,9,%L,1)', pt, j, a_exp),
    '23000', 'line added to posted journal');
  perform test_helpers.expect_error('truncate public.journal_lines', '23000', 'truncate lines');
  perform test_helpers.expect_error('truncate public.journal_entries cascade', '23000', 'truncate journals');
  perform test_helpers.expect_error(
    format('update public.journal_entries set status = %L where id = %L', 'draft', j), '23000', 'posted cannot go back to draft');

  -- ---- balance / line-count rules
  j := test_helpers.draft_journal(pt, date '2026-09-10');
  perform test_helpers.add_line(j, a_exp, 100, 0);
  perform test_helpers.add_line(j, a_rev, 0, 99.9999);
  perform test_helpers.expect_error(format('select test_helpers.post(%L)', j), '23514', 'unbalanced journal');
  j := test_helpers.draft_journal(pt, date '2026-09-10');
  perform test_helpers.expect_error(format('select test_helpers.post(%L)', j), '23514', 'journal without lines');
  perform test_helpers.add_line(j, a_exp, 10, 0);
  perform test_helpers.expect_error(format('select test_helpers.post(%L)', j), '23514', 'single-line journal');

  -- ---- line shape
  perform test_helpers.expect_error(format('select test_helpers.add_line(%L,%L,5,5)', j, a_exp), '23514', 'line with both sides');
  perform test_helpers.expect_error(format('select test_helpers.add_line(%L,%L,0,0)', j, a_exp), '23514', 'zero line');
  perform test_helpers.expect_error(format('select test_helpers.add_line(%L,%L,-5,0)', j, a_exp), '23514', 'negative debit');
  perform test_helpers.expect_error(format('select test_helpers.add_line(%L,%L,%L::numeric,0)', j, a_exp, 'NaN'), '23514', 'NaN amount');
  perform test_helpers.expect_error(
    format('insert into public.journal_lines (entity_id, journal_id, line_no, ledger_account_id, debit, original_currency) values (%L,%L,7,%L,1,%L)',
           pt, j, a_exp, 'USD'), '23514', 'partial FX snapshot');
  perform test_helpers.expect_error(
    format('insert into public.journal_lines (entity_id, journal_id, line_no, ledger_account_id, debit, original_currency, original_amount, exchange_rate) values (%L,%L,7,%L,1,%L,1,0)',
           pt, j, a_exp, 'USD'), '23514', 'zero FX rate');
  insert into public.journal_lines (entity_id, journal_id, line_no, ledger_account_id, credit, original_currency, original_amount, exchange_rate)
  values (pt, j, 8, a_rev, 10, 'USD', 0.0006, 16000);
  perform test_helpers.assert(true, 'complete FX snapshot accepted');
  perform test_helpers.expect_error(
    format('insert into public.journal_lines (entity_id, journal_id, line_no, ledger_account_id, debit) values (%L,%L,8,%L,1)', pt, j, a_exp),
    '23505', 'duplicate line number');

  -- ---- account rules
  j := test_helpers.draft_journal(pt, date '2026-09-10');
  perform test_helpers.add_line(j, a_off, 10, 0);
  perform test_helpers.add_line(j, a_rev, 0, 10);
  perform test_helpers.expect_error(format('select test_helpers.post(%L)', j), '23514', 'inactive account');
  j := test_helpers.draft_journal(pt, date '2026-09-10', 'system');
  perform test_helpers.add_line(j, a_grp, 10, 0);
  perform test_helpers.add_line(j, a_rev, 0, 10);
  perform test_helpers.expect_error(format('select test_helpers.post(%L)', j), '23514', 'group account');

  -- ---- protected accounts: manual journals need an authorized override reason
  j := test_helpers.simple_journal(pt, date '2026-09-10', a_bank, a_rev, 50, 'manual', false);
  perform test_helpers.expect_error(format('select test_helpers.post(%L)', j), '23514', 'manual journal on protected account');
  perform test_helpers.expect_error(
    format('update public.journal_entries set control_override_reason = %L where id = %L', '   ', j), '23514', 'blank override reason');
  update public.journal_entries set control_override_reason = 'Authorized correction (test)' where id = j;
  perform test_helpers.post(j);
  perform test_helpers.assert((select status from public.journal_entries where id = j) = 'posted', 'override allows protected manual posting');
  -- System journals do not need the override.
  perform test_helpers.simple_journal(pt, date '2026-09-10', a_bank, a_rev, 75, 'system', true);

  -- ---- source linkage and identity
  perform test_helpers.expect_error(
    format('insert into public.journal_entries (entity_id, entry_date, period_id, entry_type, description) values (%L,%L,%L,%L,%L)',
           pt, date '2026-09-10', app_private.ensure_accounting_period(pt, date '2026-09-10'), 'system', 'no source'),
    '23514', 'system journal without source');
  perform test_helpers.expect_error(
    format('insert into public.journal_entries (entity_id, entry_date, period_id, entry_type, description, status, posted_at) values (%L,%L,%L,%L,%L,%L,now())',
           pt, date '2026-09-10', app_private.ensure_accounting_period(pt, date '2026-09-10'), 'manual', 'born posted', 'posted'),
    '23000', 'journal created directly as posted');
  j := test_helpers.draft_journal(pt, date '2026-09-10', 'system');
  update public.journal_entries set posting_key = 'evt:duplicate' where id = j;
  perform test_helpers.expect_error(
    format('update public.journal_entries set posting_key = %L where id = %L', 'evt:duplicate', test_helpers.draft_journal(pt, date '2026-09-10', 'system')),
    '23505', 'duplicate posting key in one Entity');
  -- The same key is fine in another Entity (keys are Entity-scoped).
  j2 := test_helpers.draft_journal(pe, date '2026-09-10', 'system');
  update public.journal_entries set posting_key = 'evt:duplicate' where id = j2;
  perform test_helpers.assert(true, 'same posting key allowed in another Entity');

  -- ---- draft journals can be deleted (lines cascade); posted ones cannot
  j := test_helpers.simple_journal(pt, date '2026-09-10', a_exp, a_rev, 5, 'manual', false);
  delete from public.journal_entries where id = j;
  perform test_helpers.assert(not exists (select 1 from public.journal_lines where journal_id = j), 'draft delete cascades to lines');
  j := test_helpers.simple_journal(pt, date '2026-09-10', a_exp, a_rev, 5, 'manual', false);
  perform test_helpers.expect_error(
    format('update public.journal_lines set journal_id = %L where journal_id = %L and line_no = 1', test_helpers.draft_journal(pt, date '2026-09-10'), j),
    '23000', 'line cannot move between journals');

  -- ---- reversals
  j := test_helpers.simple_journal(pt, date '2026-09-11', a_exp, a_rev, 200, 'system', true);
  rev := test_helpers.draft_journal(pt, date '2026-09-12', 'reversal', j);
  perform test_helpers.add_line(rev, a_exp, 0, 150);
  perform test_helpers.add_line(rev, a_rev, 150, 0);
  perform test_helpers.expect_error(format('select test_helpers.post(%L)', rev), '23514', 'partial reversal is rejected');
  perform test_helpers.add_line(rev, a_exp, 0, 50);
  perform test_helpers.add_line(rev, a_rev, 50, 0);
  perform test_helpers.post(rev);
  perform test_helpers.assert((select status from public.journal_entries where id = rev) = 'posted', 'exact mirror reversal posts');
  perform test_helpers.expect_error(
    format('select test_helpers.draft_journal(%L, %L, %L, %L)', pt, date '2026-09-13', 'reversal', j), '23505', 'second reversal of the same journal');
  perform test_helpers.expect_error(
    format('select test_helpers.draft_journal(%L, %L, %L, %L)', pe, date '2026-09-13', 'reversal',
           test_helpers.simple_journal(pt, date '2026-09-11', a_exp, a_rev, 7, 'system', true)),
    '23503', 'reversal of another Entity journal');
  -- Reversal of a still-draft journal.
  j2 := test_helpers.simple_journal(pt, date '2026-09-11', a_exp, a_rev, 10, 'system', false);
  rev := test_helpers.draft_journal(pt, date '2026-09-12', 'reversal', j2);
  perform test_helpers.add_line(rev, a_exp, 0, 10);
  perform test_helpers.add_line(rev, a_rev, 10, 0);
  perform test_helpers.expect_error(format('select test_helpers.post(%L)', rev), '23514', 'reversal of an unposted journal');
  perform test_helpers.expect_error(
    format('update public.journal_entries set entry_type = %L where id = %L', 'system', rev), '23514', 'reversal link is mandatory for reversal type only');

  -- ---- periods and dates
  j := test_helpers.simple_journal(pt, date '2026-09-10', a_exp, a_rev, 5, 'manual', false);
  select id into v_period from public.accounting_periods where entity_id = pt and period_start = date '2026-08-01';
  update public.journal_entries set period_id = v_period where id = j;
  perform test_helpers.expect_error(format('select test_helpers.post(%L)', j), '23514', 'entry date outside its period');

  j := test_helpers.simple_journal(pt, date '2026-06-10', a_exp, a_rev, 5, 'manual', false);
  v_period := app_private.ensure_accounting_period(pt, date '2026-06-10');
  update public.accounting_periods set status = 'closing_review' where id = v_period;
  update public.accounting_periods set status = 'closed' where id = v_period;
  perform test_helpers.expect_error(format('select test_helpers.post(%L)', j), '23514', 'posting into a closed period');
  perform test_helpers.expect_error(
    format('update public.accounting_periods set status = %L where id = %L', 'reopened', v_period), '23514', 'reopen needs a reason');
  update public.accounting_periods set status = 'reopened', reopen_reason = 'Late vendor bill (test)' where id = v_period;
  perform test_helpers.post(j);
  perform test_helpers.assert((select status from public.journal_entries where id = j) = 'posted', 'posting into a reopened period');
end
$$;

rollback;
