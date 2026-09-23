-- P12 gate (Step 15 Phase 12, Step 12 §3-§5, §17, Table 9): canonical financial statement services
-- (20260930200100_p12_financial_statements.sql). Covers: `reports.view` permission gates and invalid date
-- ranges; Profit & Loss period movements; the Balance Sheet's Assets = Liabilities + Equity invariant,
-- including the live-computed (never posted) Current Year Earnings line; the Statement of Changes in
-- Equity's opening + movement = closing identity and its net-result row matching the Balance Sheet's
-- Current Year Earnings; the Cash Flow Statement's opening + operating + investing + financing = closing
-- identity and its source_type-driven classification; and the General Ledger drill-down's running balance.
-- Every figure below is hand-derived from the fixture and asserted exactly, not just structurally. All
-- data is synthetic; the whole file runs in one transaction that is rolled back.

begin;
set local client_min_messages = warning;

do $$
declare
  v_pt uuid;
  v_owner uuid := 'e0000000-0000-0000-0000-000000000011';
  v_staff uuid := 'e0000000-0000-0000-0000-000000000012';
  v_bank uuid;
  v_fa uuid;
  v_j1 uuid; v_j2 uuid; v_j3 uuid; v_j5 uuid; v_j6 uuid;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p12_stmt_pt', 'P12 Statements PT (synthetic)') returning id into v_pt;
  perform app_private.provision_default_coa(v_pt);
  perform test_helpers.mk_user(v_owner, 'p12_stmt_owner');
  perform test_helpers.mk_user(v_staff, 'p12_stmt_staff');
  perform test_helpers.mk_member(v_pt, v_owner, 'owner');
  perform test_helpers.mk_member(v_pt, v_staff, 'finance_staff'); -- no reports.view

  v_bank := test_helpers.acct(v_pt, 'BANK_OPERATING');
  insert into public.financial_accounts (entity_id, kind, name, currency, ledger_account_id)
  values (v_pt, 'bank', 'Operating (synthetic)', 'IDR', v_bank) returning id into v_fa;

  -- J1: 2024-01-01, BEFORE the CF report window: a small equity contribution -> this is what makes
  -- opening_cash nonzero for the window below.
  v_j1 := test_helpers.simple_journal(v_pt, date '2024-01-01', v_bank, test_helpers.acct(v_pt, 'OWNER_CAPITAL'), 1000000);
  insert into public.money_movements (entity_id, financial_account_id, currency, direction, amount, base_amount, movement_date, source_type, source_id, component, journal_id)
  values (v_pt, v_fa, 'IDR', 'in', 1000000, 1000000, date '2024-01-01', 'equity_event', gen_random_uuid(), 'principal', v_j1);

  -- J2: 2024-02-01, a loan disbursement (financing).
  v_j2 := test_helpers.simple_journal(v_pt, date '2024-02-01', v_bank, test_helpers.acct(v_pt, 'LOAN_LONG_TERM'), 4000000);
  insert into public.money_movements (entity_id, financial_account_id, currency, direction, amount, base_amount, movement_date, source_type, source_id, component, journal_id)
  values (v_pt, v_fa, 'IDR', 'in', 4000000, 4000000, date '2024-02-01', 'loan_payment', gen_random_uuid(), 'principal', v_j2);

  -- J3: 2024-03-10, revenue received in cash (operating).
  v_j3 := test_helpers.simple_journal(v_pt, date '2024-03-10', v_bank, test_helpers.acct(v_pt, 'OTHER_OPERATING_REVENUE'), 5000000);
  insert into public.money_movements (entity_id, financial_account_id, currency, direction, amount, base_amount, movement_date, source_type, source_id, component, journal_id)
  values (v_pt, v_fa, 'IDR', 'in', 5000000, 5000000, date '2024-03-10', 'payment', gen_random_uuid(), 'principal', v_j3);

  -- J4: 2024-04-01, an unpaid asset purchase (no cash movement at all): tests a real liability and a real
  -- non-cash asset balance in the same Balance Sheet.
  perform test_helpers.simple_journal(v_pt, date '2024-04-01', test_helpers.acct(v_pt, 'FIXED_ASSET_EQUIPMENT'), test_helpers.acct(v_pt, 'ACCOUNTS_PAYABLE'), 6000000);

  -- J5: 2024-04-05, an operating cash expense.
  v_j5 := test_helpers.simple_journal(v_pt, date '2024-04-05', test_helpers.acct(v_pt, 'OFFICE_GENERAL_EXPENSE'), v_bank, 1000000);
  insert into public.money_movements (entity_id, financial_account_id, currency, direction, amount, base_amount, movement_date, source_type, source_id, component, journal_id)
  values (v_pt, v_fa, 'IDR', 'out', 1000000, 1000000, date '2024-04-05', 'expense', gen_random_uuid(), 'principal', v_j5);

  -- J6: 2024-05-01, asset disposal proceeds (investing).
  v_j6 := test_helpers.simple_journal(v_pt, date '2024-05-01', v_bank, test_helpers.acct(v_pt, 'ASSET_DISPOSAL_GAIN_LOSS'), 2000000);
  insert into public.money_movements (entity_id, financial_account_id, currency, direction, amount, base_amount, movement_date, source_type, source_id, component, journal_id)
  values (v_pt, v_fa, 'IDR', 'in', 2000000, 2000000, date '2024-05-01', 'asset_disposal', gen_random_uuid(), 'principal', v_j6);

  -- 1. permission gate and input validation
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.profit_and_loss(%L, date ''2024-01-01'', date ''2024-12-31'')', v_pt),
    'FORBIDDEN', 'finance_staff has no reports.view for Profit & Loss');
  perform test_helpers.expect_msg(format('select public.balance_sheet(%L)', v_pt),
    'FORBIDDEN', 'finance_staff has no reports.view for Balance Sheet');
  perform test_helpers.expect_msg(format('select public.cash_flow_statement(%L, date ''2024-01-01'', date ''2024-12-31'')', v_pt),
    'FORBIDDEN', 'finance_staff has no reports.view for Cash Flow');
  perform test_helpers.expect_msg(format('select public.general_ledger(%L)', v_pt),
    'FORBIDDEN', 'finance_staff has no reports.view for the General Ledger');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.profit_and_loss(%L, date ''2024-12-31'', date ''2024-01-01'')', v_pt),
    'INVALID', 'end before start is refused');
  perform test_helpers.expect_msg(format('select public.general_ledger(%L, %L)', v_pt, gen_random_uuid()),
    'NOT_FOUND', 'an unknown account is refused');

  -- 2. Profit & Loss for the full year: revenue, expense and the "other" gain all show their natural,
  -- positive-reading debit/credit.
  perform test_helpers.assert(
    (select debit from public.profit_and_loss(v_pt, '2024-01-01', '2024-12-31') where code = '4190') = '0.0000'
    and (select credit from public.profit_and_loss(v_pt, '2024-01-01', '2024-12-31') where code = '4190') = '5000000.0000',
    'revenue shows a 5,000,000 credit for the year');
  perform test_helpers.assert(
    (select debit from public.profit_and_loss(v_pt, '2024-01-01', '2024-12-31') where code = '6500') = '1000000.0000',
    'the office expense shows a 1,000,000 debit for the year');
  perform test_helpers.assert(
    (select credit from public.profit_and_loss(v_pt, '2024-01-01', '2024-12-31') where code = '7400') = '2000000.0000',
    'the disposal gain shows a 2,000,000 credit for the year');
  perform test_helpers.assert(
    not exists (select 1 from public.profit_and_loss(v_pt, '2024-06-01', '2024-06-30') where code in ('4190', '6500', '7400')),
    'a P&L period with no activity returns none of these accounts (zero rows are not returned at all)');

  -- 3. Balance Sheet as of year end: Assets = Liabilities + Equity, generically, from the returned rows
  -- alone (never assuming which rows exist), plus the exact hand-derived figures.
  perform test_helpers.assert(
    (select coalesce(sum(case when account_class in ('asset') then debit::numeric - credit::numeric
                              when account_class = 'contra_asset' then debit::numeric - credit::numeric
                              else 0 end), 0)
     from public.balance_sheet(v_pt, '2024-12-31'))
    =
    (select coalesce(sum(case when account_class in ('liability', 'equity') then credit::numeric - debit::numeric else 0 end), 0)
     from public.balance_sheet(v_pt, '2024-12-31')),
    'Assets = Liabilities + Equity as of 2024-12-31');
  perform test_helpers.assert(
    (select debit::numeric - credit::numeric from public.balance_sheet(v_pt, '2024-12-31') where code = test_helpers.acct(v_pt, 'BANK_OPERATING')::text) is null,
    'sanity: code is the account CODE, not its id'); -- guards against a shape regression; the real check is by system_key below
  perform test_helpers.assert(
    (select debit::numeric - credit::numeric from public.balance_sheet(v_pt, '2024-12-31') ba
     join public.ledger_accounts la on la.id = ba.account_id where la.system_key = 'BANK_OPERATING') = 11000000,
    'BANK_OPERATING carries the full 11,000,000 cumulative debit balance');
  perform test_helpers.assert(
    (select debit::numeric from public.balance_sheet(v_pt, '2024-12-31') ba
     join public.ledger_accounts la on la.id = ba.account_id where la.system_key = 'FIXED_ASSET_EQUIPMENT') = 6000000,
    'the unpaid asset purchase still shows a real 6,000,000 asset balance');
  perform test_helpers.assert(
    (select credit::numeric from public.balance_sheet(v_pt, '2024-12-31') ba
     join public.ledger_accounts la on la.id = ba.account_id where la.system_key = 'ACCOUNTS_PAYABLE') = 6000000,
    'the matching 6,000,000 liability is real too');
  perform test_helpers.assert(
    (select credit::numeric from public.balance_sheet(v_pt, '2024-12-31') where account_class = 'equity' and name = 'Current Year Earnings') = 6000000,
    'Current Year Earnings computes to 6,000,000 (5,000,000 revenue - 1,000,000 expense + 2,000,000 gain), never a posted balance');
  perform test_helpers.assert(
    not exists (select 1 from public.journal_lines where ledger_account_id = test_helpers.acct(v_pt, 'CURRENT_YEAR_EARNINGS')),
    'nothing was ever actually posted to the CURRENT_YEAR_EARNINGS placeholder account');

  -- 4. Statement of Changes in Equity for the year: its net-result row matches Balance Sheet's Current
  -- Year Earnings exactly, and OWNER_CAPITAL's own opening/movement/closing reconciles.
  perform test_helpers.assert(
    (select period_credit::numeric from public.statement_of_changes_in_equity(v_pt, '2024-01-01', '2024-12-31') where name = 'Net result for the period') = 6000000,
    'the equity statement''s net result for the year matches the Balance Sheet''s Current Year Earnings');
  perform test_helpers.assert(
    (select opening_credit::numeric = 0 and period_credit::numeric = 1000000 and closing_credit::numeric = 1000000
     from public.statement_of_changes_in_equity(v_pt, '2024-01-01', '2024-12-31') sce
     join public.ledger_accounts la on la.id = sce.account_id where la.system_key = 'OWNER_CAPITAL'),
    'OWNER_CAPITAL opened at zero, moved by 1,000,000 and closed at 1,000,000');

  -- 5. Cash Flow Statement for Feb-May: opening + operating + investing + financing = closing (Table 9),
  -- and each bucket matches its hand-derived figure.
  perform test_helpers.assert(
    (select amount::numeric from public.cash_flow_statement(v_pt, '2024-02-01', '2024-05-31') where bucket = 'opening_cash') = 1000000,
    'opening cash is the 1,000,000 equity contribution from January');
  perform test_helpers.assert(
    (select amount::numeric from public.cash_flow_statement(v_pt, '2024-02-01', '2024-05-31') where bucket = 'operating') = 4000000,
    'operating nets the 5,000,000 revenue receipt against the 1,000,000 expense payment');
  perform test_helpers.assert(
    (select amount::numeric from public.cash_flow_statement(v_pt, '2024-02-01', '2024-05-31') where bucket = 'investing') = 2000000,
    'investing is the 2,000,000 disposal proceeds');
  perform test_helpers.assert(
    (select amount::numeric from public.cash_flow_statement(v_pt, '2024-02-01', '2024-05-31') where bucket = 'financing') = 4000000,
    'financing is the 4,000,000 loan disbursement');
  perform test_helpers.assert(
    (select amount::numeric from public.cash_flow_statement(v_pt, '2024-02-01', '2024-05-31') where bucket = 'opening_cash')
    + coalesce((select amount::numeric from public.cash_flow_statement(v_pt, '2024-02-01', '2024-05-31') where bucket = 'operating'), 0)
    + coalesce((select amount::numeric from public.cash_flow_statement(v_pt, '2024-02-01', '2024-05-31') where bucket = 'investing'), 0)
    + coalesce((select amount::numeric from public.cash_flow_statement(v_pt, '2024-02-01', '2024-05-31') where bucket = 'financing'), 0)
    = (select amount::numeric from public.cash_flow_statement(v_pt, '2024-02-01', '2024-05-31') where bucket = 'closing_cash'),
    'opening cash + net movement = closing cash (Step 12 Table 9)');

  -- 6. General Ledger drill-down on BANK_OPERATING: every posted line that touched it, in order, with a
  -- running balance that ends at the same 11,000,000 the Balance Sheet reported.
  perform test_helpers.assert(
    (select count(*) from public.general_ledger(v_pt, v_bank, '2024-01-01', '2024-12-31')) = 5,
    'all five journals that touched BANK_OPERATING are returned');
  perform test_helpers.assert(
    (select running_balance::numeric from public.general_ledger(v_pt, v_bank, '2024-01-01', '2024-12-31') order by entry_date desc limit 1) = 11000000,
    'the running balance ends at the same 11,000,000 the Balance Sheet shows');
  perform test_helpers.assert(
    (select source_type from public.general_ledger(v_pt, v_bank, '2024-01-01', '2024-12-31') where journal_id = v_j3) = 'test'
    and (select entry_type from public.general_ledger(v_pt, v_bank, '2024-01-01', '2024-12-31') where journal_id = v_j3) = 'system',
    'test_helpers.simple_journal stamps entry_type=system, source_type=test (test_helpers.draft_journal''s own fixture marker), carried through by the General Ledger drill-down unchanged');
  perform test_helpers.logout();
end
$$;

rollback;
