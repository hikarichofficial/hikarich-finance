-- Accounting periods (Step 07 §17) and ledger account protection (Step 03 §1/§5/§10).
begin;
set local client_min_messages = warning;

do $$
declare
  pt uuid := test_helpers.entity('demo_pt');
  v_p uuid;
  v_p2 uuid;
  a_exp uuid := test_helpers.acct(pt, 'OFFICE_GENERAL_EXPENSE');
  a_rev uuid := test_helpers.acct(pt, 'OTHER_OPERATING_REVENUE');
  a_custom uuid;
  a_child uuid;
  v_grp uuid;
begin
  -- ---- periods
  v_p := app_private.ensure_accounting_period(pt, date '2027-03-20');
  perform test_helpers.assert(app_private.ensure_accounting_period(pt, date '2027-03-01') = v_p, 'ensure_accounting_period is idempotent per month');
  perform test_helpers.assert((select period_start from public.accounting_periods where id = v_p) = date '2027-03-01'
    and (select period_end from public.accounting_periods where id = v_p) = date '2027-03-31', 'monthly boundaries');
  perform test_helpers.assert((select fiscal_year from public.accounting_periods where id = v_p) = 2027, 'fiscal year label');
  perform test_helpers.expect_error(
    format('insert into public.accounting_periods (entity_id, fiscal_year, period_start, period_end) values (%L,2027,%L,%L)',
           pt, date '2027-03-15', date '2027-04-15'), '23P01', 'overlapping periods');
  perform test_helpers.expect_error(
    format('insert into public.accounting_periods (entity_id, fiscal_year, period_start, period_end, status) values (%L,2028,%L,%L,%L)',
           pt, date '2028-01-01', date '2028-01-31', 'closed'), '23000', 'new period must be open');
  perform test_helpers.expect_error(
    format('insert into public.accounting_periods (entity_id, fiscal_year, period_start, period_end) values (%L,2028,%L,%L)',
           pt, date '2028-02-10', date '2028-02-01'), '23514', 'period end before start');

  -- Status machine: open -> closing_review -> closed -> reopened -> closed.
  perform test_helpers.expect_error(format('update public.accounting_periods set status = %L where id = %L', 'closed', v_p), '23000', 'open -> closed is not allowed');
  perform test_helpers.expect_error(format('update public.accounting_periods set status = %L, reopen_reason = %L where id = %L', 'reopened', 'x', v_p), '23000', 'open -> reopened is not allowed');
  update public.accounting_periods set status = 'closing_review' where id = v_p;
  update public.accounting_periods set status = 'open' where id = v_p;
  update public.accounting_periods set status = 'closing_review' where id = v_p;
  update public.accounting_periods set status = 'closed' where id = v_p;
  perform test_helpers.assert((select closed_at from public.accounting_periods where id = v_p) is not null, 'closed_at recorded');
  perform test_helpers.expect_error(format('update public.accounting_periods set status = %L where id = %L', 'open', v_p), '23000', 'closed -> open is not allowed');
  update public.accounting_periods set status = 'reopened', reopen_reason = 'Adjustment (test)' where id = v_p;
  perform test_helpers.assert((select reopened_at from public.accounting_periods where id = v_p) is not null, 'reopened_at recorded');
  update public.accounting_periods set status = 'closed' where id = v_p;

  -- Boundaries are frozen once journals exist.
  v_p2 := app_private.ensure_accounting_period(pt, date '2027-04-10');
  perform test_helpers.simple_journal(pt, date '2027-04-10', a_exp, a_rev, 10, 'manual', false);
  perform test_helpers.expect_error(
    format('update public.accounting_periods set period_end = %L where id = %L', date '2027-04-29', v_p2), '23000', 'period boundaries frozen after journals');

  -- ---- ledger accounts
  perform test_helpers.expect_error(
    format('delete from public.ledger_accounts where id = %L', test_helpers.acct(pt, 'BANK_OPERATING')), '23000', 'protected account delete');
  perform test_helpers.expect_error(
    format('update public.ledger_accounts set system_key = %L where id = %L', 'OTHER_KEY', a_exp), '23000', 'system key is stable');
  perform test_helpers.expect_error(
    format('update public.ledger_accounts set status = %L where id = %L', 'inactive', a_exp), '23000', 'system account cannot be deactivated');
  perform test_helpers.expect_error(
    format('insert into public.ledger_accounts (entity_id, code, name, account_class, normal_balance) values (%L,%L,%L,%L,%L)', pt, '6500', 'Dup', 'expense', 'debit'),
    '23505', 'duplicate account code in Entity');
  perform test_helpers.expect_error(
    format('insert into public.ledger_accounts (entity_id, code, name, account_class, normal_balance) values (%L,%L,%L,%L,%L)', pt, '65', 'Short', 'expense', 'debit'),
    '23514', 'account code format');
  perform test_helpers.expect_error(
    format('insert into public.ledger_accounts (entity_id, code, name, account_class, normal_balance, is_group, allows_manual_posting) values (%L,%L,%L,%L,%L,true,true)',
           pt, '6991', 'Group manual', 'expense', 'debit'), '23514', 'group accounts do not take manual posting');
  perform test_helpers.expect_error(
    format('insert into public.ledger_accounts (entity_id, code, name, account_class, normal_balance) values (%L,%L,%L,%L,%L)', pt, '6992', 'Bad class', 'gadget', 'debit'),
    '23514', 'account class domain');
  perform test_helpers.expect_error(
    format('insert into public.ledger_accounts (entity_id, code, name, account_class, normal_balance, system_key) values (%L,%L,%L,%L,%L,%L)',
           pt, '6993', 'Dup key', 'expense', 'debit', 'OFFICE_GENERAL_EXPENSE'), '23505', 'system key unique per Entity');

  -- Ordinary (non-system) accounts: deactivate, delete, hierarchy.
  insert into public.ledger_accounts (entity_id, code, name, account_class, normal_balance, allows_manual_posting)
  values (pt, '6994', 'Custom expense', 'expense', 'debit', true) returning id into a_custom;
  update public.ledger_accounts set status = 'inactive' where id = a_custom;
  update public.ledger_accounts set status = 'active' where id = a_custom;
  insert into public.ledger_accounts (entity_id, code, name, account_class, normal_balance, parent_id)
  values (pt, '6995', 'Child', 'expense', 'debit', a_custom) returning id into a_child;
  perform test_helpers.expect_error(
    format('update public.ledger_accounts set parent_id = %L where id = %L', a_child, a_custom), '23000', 'account hierarchy cycle');
  perform test_helpers.expect_error(
    format('update public.ledger_accounts set parent_id = id where id = %L', a_custom), '23000', 'account cannot be its own parent');
  perform test_helpers.expect_error(
    format('delete from public.ledger_accounts where id = %L', a_custom), '23503', 'account with children cannot be deleted');
  delete from public.ledger_accounts where id = a_child;
  -- History freezes accounting meaning.
  perform test_helpers.simple_journal(pt, date '2027-04-11', a_custom, a_rev, 10, 'manual', true);
  perform test_helpers.expect_error(
    format('update public.ledger_accounts set account_class = %L, normal_balance = %L where id = %L', 'revenue', 'credit', a_custom),
    '23000', 'class frozen after postings');
  perform test_helpers.expect_error(
    format('delete from public.ledger_accounts where id = %L', a_custom), '23503', 'account with postings cannot be deleted');
end
$$;

rollback;
