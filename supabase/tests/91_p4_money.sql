-- P4 gate (Step 15 §8, Step 16 G4): internal transfers create no revenue or expense, money movements and the
-- General Ledger control accounts reconcile, and reconciliation never rewrites the books.
-- Covers financial accounts, opening movements, balance adjustments, transfers (fee, FX, approval, reversal),
-- the movement guard, statement reconciliation (match / exclude / complete / reopen) and period-close checks.
-- All data is synthetic. The whole file runs in one transaction that is rolled back.
begin;
set local client_min_messages = warning;

-- Test-only window on the ledger control rows that works whichever role the test currently acts as.
create function test_helpers.mc(p_entity uuid, p_as_of date default null)
returns table (financial_account_id uuid, name text, kind text, currency text, is_active boolean,
               movement_balance numeric, movement_base_balance numeric, ledger_balance numeric)
language sql security definer set search_path = pg_catalog, public as
$f$ select * from app_private.money_control_rows(p_entity, p_as_of) $f$;
grant execute on function test_helpers.mc(uuid, date) to anon, authenticated;

-- ================================================================ fixtures (superuser)
do $$
declare
  v_pt uuid;
  v_pe uuid;
begin
  insert into public.entities (entity_type, code, legal_name)
  values ('company', 'p4_pt', 'P4 PT (synthetic)') returning id into v_pt;
  perform app_private.provision_default_coa(v_pt);
  insert into public.entities (entity_type, code, legal_name)
  values ('personal', 'p4_pe', 'P4 PERSONAL (synthetic)') returning id into v_pe;
  perform app_private.provision_default_coa(v_pe);

  perform test_helpers.mk_user('b0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_user('b0000000-0000-0000-0000-000000000002', 'admin');
  perform test_helpers.mk_user('b0000000-0000-0000-0000-000000000003', 'approver');
  perform test_helpers.mk_user('b0000000-0000-0000-0000-000000000004', 'viewer');
  perform test_helpers.mk_user('b0000000-0000-0000-0000-000000000006', 'accountant');
  perform test_helpers.mk_user('b0000000-0000-0000-0000-000000000007', 'nobody');
  perform test_helpers.mk_user('b0000000-0000-0000-0000-000000000008', 'staff');
  perform test_helpers.mk_member(v_pt, 'b0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pe, 'b0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pt, 'b0000000-0000-0000-0000-000000000002', 'finance_admin');
  perform test_helpers.mk_member(v_pt, 'b0000000-0000-0000-0000-000000000003', 'approver');
  perform test_helpers.mk_member(v_pt, 'b0000000-0000-0000-0000-000000000004', 'viewer_auditor');
  perform test_helpers.mk_member(v_pt, 'b0000000-0000-0000-0000-000000000006', 'accountant');
  perform test_helpers.mk_member(v_pt, 'b0000000-0000-0000-0000-000000000008', 'finance_staff');
end
$$;

-- ================================================================ 1. financial accounts
do $$
declare
  pt uuid := test_helpers.entity('p4_pt');
  pe uuid := test_helpers.entity('p4_pe');
  v_owner uuid := 'b0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'b0000000-0000-0000-0000-000000000002';
  v_acct uuid := 'b0000000-0000-0000-0000-000000000006';
  v_staff uuid := 'b0000000-0000-0000-0000-000000000008';
  v_viewer uuid := 'b0000000-0000-0000-0000-000000000004';
  v_nobody uuid := 'b0000000-0000-0000-0000-000000000007';
  v_bca uuid;
  v_cash uuid;
  v_mandiri uuid;
  v_usd uuid;
  v_wallet uuid;
  v_cash2 uuid;
  v_other uuid;
  v_pe_bank uuid;
  v_pe_sav uuid;
  v_ver integer;
  v_ledger uuid;
begin
  perform test_helpers.login(v_owner);
  -- mapping the default cash/bank control accounts
  v_bca := public.create_financial_account(pt, 'key-fa-0001', 'bank', 'BCA Main', 'IDR', test_helpers.acct(pt, 'BANK_OPERATING'),
    'BCA', 'ACC-SECRET-777', 'PT Test');
  perform test_helpers.assert(public.create_financial_account(pt, 'key-fa-0001', 'bank', 'BCA Main', 'IDR', test_helpers.acct(pt, 'BANK_OPERATING'),
    'BCA', 'ACC-SECRET-777', 'PT Test') = v_bca, 'creating a financial account replays on the same key');
  perform test_helpers.expect_msg(format('select public.create_financial_account(%L, ''key-fa-0001'', ''bank'', ''Other name'', ''IDR'', %L)', pt, test_helpers.acct(pt, 'OTHER_CASH_ACCOUNT')),
    'INVALID', 'a key cannot be reused for another request');
  v_cash := public.create_financial_account(pt, 'key-fa-0002', 'cash', 'Petty Cash', 'IDR', test_helpers.acct(pt, 'CASH'));
  perform test_helpers.assert((select count(*) from public.financial_accounts where entity_id = pt) = 2, 'two financial accounts so far');

  -- the system creates and maps a child ledger account (Step 03 §7)
  v_mandiri := public.create_financial_account(pt, 'key-fa-0003', 'bank', 'Mandiri', 'IDR');
  select ledger_account_id into v_ledger from public.financial_accounts where id = v_mandiri;
  perform test_helpers.assert((select code from public.ledger_accounts where id = v_ledger) = '1121'
    and (select account_class from public.ledger_accounts where id = v_ledger) = 'asset'
    and (select is_control from public.ledger_accounts where id = v_ledger)
    and not (select allows_manual_posting from public.ledger_accounts where id = v_ledger)
    and (select parent_id from public.ledger_accounts where id = v_ledger) = (select parent_id from public.ledger_accounts where id = test_helpers.acct(pt, 'CASH')),
    'a bank account gets the next free 11xx child code under the cash group, as a protected control account');
  v_usd := public.create_financial_account(pt, 'key-fa-0004', 'bank', 'USD Account', 'USD');
  perform test_helpers.assert((select code from public.ledger_accounts a join public.financial_accounts f on f.ledger_account_id = a.id where f.id = v_usd) = '1122', 'next bank code');
  v_wallet := public.create_financial_account(pt, 'key-fa-0005', 'ewallet', 'GoPay', 'IDR');
  perform test_helpers.assert((select code from public.ledger_accounts a join public.financial_accounts f on f.ledger_account_id = a.id where f.id = v_wallet) = '1191', 'e-wallet range');
  v_cash2 := public.create_financial_account(pt, 'key-fa-0006', 'cash', 'Second Cash', 'IDR');
  perform test_helpers.assert((select code from public.ledger_accounts a join public.financial_accounts f on f.ledger_account_id = a.id where f.id = v_cash2) = '1111', 'cash range');

  -- Personal Entity: its own COA, its own accounts
  v_pe_bank := public.create_financial_account(pe, 'key-fa-0007', 'bank', 'Personal BCA', 'IDR', test_helpers.acct(pe, 'PERSONAL_BANK'));
  v_pe_sav := public.create_financial_account(pe, 'key-fa-0008', 'bank', 'Personal Savings', 'IDR');
  perform test_helpers.assert((select code from public.ledger_accounts a join public.financial_accounts f on f.ledger_account_id = a.id where f.id = v_pe_sav) = '1121', 'personal child account');

  -- validation
  perform test_helpers.expect_msg(format('select public.create_financial_account(%L, ''key-fa-0010'', ''savings'', ''X'', ''IDR'')', pt), 'INVALID', 'unknown kind');
  perform test_helpers.expect_msg(format('select public.create_financial_account(%L, ''key-fa-0011'', ''bank'', ''  '', ''IDR'')', pt), 'INVALID', 'a name is required');
  perform test_helpers.expect_msg(format('select public.create_financial_account(%L, ''key-fa-0012'', ''bank'', ''X'', ''ZZZ'')', pt), 'INVALID', 'unknown currency');
  perform test_helpers.expect_msg(format('select public.create_financial_account(%L, ''key-fa-0013'', ''bank'', ''X'', ''IDR'', %L)', pt, test_helpers.acct(pt, 'ACCOUNTS_RECEIVABLE')),
    'INVALID', 'a receivable account cannot back a bank account');
  perform test_helpers.expect_msg(format('select public.create_financial_account(%L, ''key-fa-0014'', ''bank'', ''X'', ''IDR'', %L)', pt, (select id from public.ledger_accounts where entity_id = pt and code = '1100')),
    'INVALID', 'the cash group itself cannot back a bank account');
  perform test_helpers.expect_msg(format('select public.create_financial_account(%L, ''key-fa-0015'', ''bank'', ''X'', ''IDR'', %L)', pt, test_helpers.acct(pt, 'BANK_OPERATING')),
    'CONFLICT', 'a ledger account backs one financial account only');
  perform test_helpers.expect_msg(format('select public.create_financial_account(%L, ''key-fa-0016'', ''bank'', ''X'', ''IDR'', %L)', pt, test_helpers.acct(pe, 'OTHER_CASH_ACCOUNT')),
    'INVALID', 'a ledger account of another Entity is refused');
  perform test_helpers.expect_msg(format('select public.create_financial_account(%L, ''key-fa-0017'', ''bank'', ''BCA Main'', ''IDR'')', pt), 'CONFLICT', 'names are unique per Entity');
  perform test_helpers.logout();

  -- capabilities: finance admin (money.edit, no coa.manage) can map an existing account, not create a ledger account
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.create_financial_account(%L, ''key-fa-0020'', ''bank'', ''Admin Bank'', ''IDR'')', pt), 'FORBIDDEN', 'creating a ledger account needs coa.manage');
  v_other := public.create_financial_account(pt, 'key-fa-0021', 'bank', 'Other Bank', 'IDR', test_helpers.acct(pt, 'OTHER_CASH_ACCOUNT'));
  perform test_helpers.assert(v_other is not null, 'a finance admin maps an existing control account');
  perform test_helpers.logout();
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.create_financial_account(%L, ''key-fa-0022'', ''bank'', ''X'', ''IDR'', %L)', pt, test_helpers.acct(pt, 'CASH')), 'FORBIDDEN', 'staff cannot manage financial accounts');
  perform test_helpers.logout();
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.set_financial_account_active(%L, false, ''not allowed here'')', v_cash2), 'FORBIDDEN', 'viewer cannot disable');
  perform test_helpers.logout();
  perform test_helpers.login(v_nobody);
  perform test_helpers.expect_msg(format('select public.create_financial_account(%L, ''key-fa-0023'', ''bank'', ''X'', ''IDR'')', pt), 'FORBIDDEN', 'a stranger cannot create accounts');
  perform test_helpers.expect_msg(format('select public.update_financial_account(%L, ''{"name":"Hacked"}'')', v_bca), 'FORBIDDEN', 'a stranger cannot edit accounts');
  perform test_helpers.logout();

  -- update: only descriptive fields, with a version check; the account number never enters the audit trail
  perform test_helpers.login(v_owner);
  select version into v_ver from public.financial_accounts where id = v_bca;
  perform test_helpers.assert(public.update_financial_account(v_bca, '{"institution_name":"Bank Central Asia","account_holder":"PT P4"}', v_ver) = v_ver + 1, 'update bumps the version');
  perform test_helpers.expect_msg(format('select public.update_financial_account(%L, ''{"institution_name":"Stale"}'', %s)', v_bca, v_ver), 'CONFLICT', 'stale version');
  perform test_helpers.expect_msg(format('select public.update_financial_account(%L, ''{"currency":"USD"}'')', v_bca), 'INVALID', 'currency cannot be changed');
  perform test_helpers.expect_msg(format('select public.update_financial_account(%L, ''{"ledger_account_id":null}'')', v_bca), 'INVALID', 'the mapping cannot be changed');
  perform test_helpers.expect_msg(format('select public.update_financial_account(%L, ''{}'')', v_bca), 'INVALID', 'empty patch');
  perform test_helpers.expect_msg(format('select public.update_financial_account(%L, ''{"name":"Mandiri"}'')', v_bca), 'CONFLICT', 'name collision');
  perform public.update_financial_account(v_bca, '{"account_number":"ACC-SECRET-778"}');
  perform test_helpers.assert(not exists (select 1 from public.audit_events where target_table = 'financial_accounts'
    and (before_state::text like '%ACC-SECRET%' or after_state::text like '%ACC-SECRET%')), 'account numbers are redacted from the audit trail');
  perform test_helpers.assert(public.reveal_sensitive('financial_account_number', v_bca) = 'ACC-SECRET-778', 'the number is still revealable through the audited RPC');

  -- browsers cannot write these tables directly
  perform test_helpers.expect_error(format('update public.financial_accounts set name = ''X'' where id = %L', v_bca), '42501', 'no direct write to financial accounts');
  perform test_helpers.expect_error('insert into public.money_movements (entity_id) values (gen_random_uuid())', '42501', 'no direct write to movements');

  -- disable: reason required; only an empty account; enabled again on request
  perform test_helpers.expect_msg(format('select public.set_financial_account_active(%L, false)', v_cash2), 'INVALID', 'disabling needs a reason');
  perform test_helpers.assert(public.set_financial_account_active(v_cash2, false, 'closed for good') = false, 'an empty account can be disabled');
  perform test_helpers.assert(public.set_financial_account_active(v_cash2, false, 'closed for good') = false, 'disabling twice is a no-op');
  perform test_helpers.assert(public.set_financial_account_active(v_cash2, true) = true, 're-enabled');
  perform test_helpers.assert(public.set_financial_account_active(v_wallet, false, 'wallet not used') = false, 'wallet disabled for later tests');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 2. opening balances create their movements
do $$
declare
  pt uuid := test_helpers.entity('p4_pt');
  v_owner uuid := 'b0000000-0000-0000-0000-000000000001';
  v_batch uuid;
  v_bca uuid := (select id from public.financial_accounts where name = 'BCA Main');
  v_cash uuid := (select id from public.financial_accounts where name = 'Petty Cash');
  v_mandiri uuid := (select id from public.financial_accounts where name = 'Mandiri');
  v_usd uuid := (select id from public.financial_accounts where name = 'USD Account');
  v_wallet uuid := (select id from public.financial_accounts where name = 'GoPay');
  v_lines jsonb;
begin
  perform test_helpers.login(v_owner);
  -- a foreign-currency account must state its original amount and rate
  perform test_helpers.expect_msg(format('select public.post_opening_balances(%L, ''key-p4-open-0'', date ''2026-09-01'', %L::jsonb)', pt,
    jsonb_build_array(jsonb_build_object('account_id', (select ledger_account_id from public.financial_accounts where id = v_usd), 'debit', 16000000))),
    'INVALID', 'opening line of a USD account needs the original amount');
  perform test_helpers.expect_msg(format('select public.post_opening_balances(%L, ''key-p4-open-0b'', date ''2026-09-01'', %L::jsonb)', pt,
    jsonb_build_array(jsonb_build_object('account_id', (select ledger_account_id from public.financial_accounts where id = v_wallet), 'debit', 100))),
    'INVALID', 'a disabled account cannot receive an opening balance');
  perform test_helpers.assert(not exists (select 1 from public.opening_balance_batches where entity_id = pt) and not exists (select 1 from public.money_movements where entity_id = pt),
    'refused openings leave nothing behind');

  v_lines := jsonb_build_array(
    jsonb_build_object('account_key', 'BANK_OPERATING', 'debit', 10000000),
    jsonb_build_object('account_key', 'CASH', 'debit', 500000),
    jsonb_build_object('account_id', (select ledger_account_id from public.financial_accounts where id = v_mandiri), 'debit', 2000000),
    jsonb_build_object('account_id', (select ledger_account_id from public.financial_accounts where id = v_usd), 'debit', 16000000,
                       'original_currency', 'USD', 'original_amount', 1000, 'exchange_rate', 16000),
    jsonb_build_object('account_key', 'OWNER_CAPITAL', 'credit', 28500000));
  v_batch := public.post_opening_balances(pt, 'key-p4-open-1', date '2026-09-01', v_lines, 'Opening balances');
  perform test_helpers.assert(public.post_opening_balances(pt, 'key-p4-open-1', date '2026-09-01', v_lines, 'Opening balances') = v_batch, 'the opening replays');
  perform test_helpers.assert((select count(*) from public.money_movements where entity_id = pt and source_type = 'opening_balance' and source_id = v_batch) = 4,
    'four opening movements, one per cash/bank line, none for the capital line');
  perform test_helpers.assert((select amount from public.money_movements where financial_account_id = v_usd) = 1000
    and (select currency from public.money_movements where financial_account_id = v_usd) = 'USD'
    and (select base_amount from public.money_movements where financial_account_id = v_usd) = 16000000
    and (select exchange_rate from public.money_movements where financial_account_id = v_usd) = 16000
    and (select component from public.money_movements where financial_account_id = v_usd) = 'opening', 'the USD opening keeps its own currency and rate');
  perform test_helpers.assert((select amount from public.money_movements where financial_account_id = v_bca) = 10000000
    and (select exchange_rate from public.money_movements where financial_account_id = v_bca) is null, 'the IDR opening carries no rate');
  perform test_helpers.assert(not exists (select 1 from public.money_control(pt) where difference::numeric <> 0), 'money and ledger agree after the opening');
  perform test_helpers.assert(public.complete_opening_balances(pt)::numeric = 0, 'migration completed');

  -- derived balances and the bank-ledger view
  perform test_helpers.assert((select movement_balance::numeric from public.money_control(pt) where financial_account_id = v_bca) = 10000000
    and (select movement_balance::numeric from public.money_control(pt) where financial_account_id = v_usd) = 1000
    and (select ledger_balance::numeric from public.money_control(pt) where financial_account_id = v_usd) = 16000000, 'balances are derived from movements');
  perform test_helpers.assert((select count(*) from public.account_activity(v_bca)) = 1
    and (select running_balance::numeric from public.account_activity(v_bca)) = 10000000
    and (select journal_number from public.account_activity(v_bca)) is not null, 'account activity shows the opening with its journal number');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 3. balance adjustments
do $$
declare
  pt uuid := test_helpers.entity('p4_pt');
  v_owner uuid := 'b0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'b0000000-0000-0000-0000-000000000002';
  v_acct uuid := 'b0000000-0000-0000-0000-000000000006';
  v_bca uuid := (select id from public.financial_accounts where name = 'BCA Main');
  v_usd uuid := (select id from public.financial_accounts where name = 'USD Account');
  v_interest uuid := test_helpers.acct(pt, 'INTEREST_INCOME');
  v_fee uuid := test_helpers.acct(pt, 'BANK_FEE_EXPENSE');
  v_adj uuid;
  v_before bigint;
begin
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.record_balance_adjustment(%L, ''key-p4-adj-0'', %L, ''in'', 100, null, date ''2026-09-30'', %L, ''Interest credited by the bank'')', pt, v_bca, v_interest),
    'FORBIDDEN', 'a finance admin cannot adjust balances');
  perform test_helpers.logout();

  perform test_helpers.login(v_acct);
  v_adj := public.record_balance_adjustment(pt, 'key-p4-adj-1', v_bca, 'in', 12500, null, date '2026-09-30', v_interest, 'Interest credited by the bank');
  perform test_helpers.assert((select amount from public.money_movements where id = v_adj) = 12500
    and (select component from public.money_movements where id = v_adj) = 'adjustment'
    and (select source_type from public.money_movements where id = v_adj) = 'money_adjustment', 'the adjustment is a movement of its own');
  perform test_helpers.assert(public.record_balance_adjustment(pt, 'key-p4-adj-1', v_bca, 'in', 12500, null, date '2026-09-30', v_interest, 'Interest credited by the bank') = v_adj, 'an adjustment replays on the same key');
  perform test_helpers.assert((select count(*) from public.money_movements where entity_id = pt and component = 'adjustment') = 1, 'the retry did not adjust twice');
  perform test_helpers.assert((select debit::numeric - credit::numeric from public.trial_balance(pt) where code = '7100') = -12500, 'the counter account carries the treatment: interest income');
  perform test_helpers.assert(not exists (select 1 from public.money_control(pt) where difference::numeric <> 0), 'an adjustment keeps money and ledger together');

  -- a foreign-currency adjustment keeps its original amount and rate
  perform public.record_balance_adjustment(pt, 'key-p4-adj-2', v_usd, 'out', 10.55, 16100, date '2026-09-30', v_fee, 'Wire fee charged in USD');
  perform test_helpers.assert((select amount from public.money_movements where financial_account_id = v_usd and component = 'adjustment') = 10.55
    and (select base_amount from public.money_movements where financial_account_id = v_usd and component = 'adjustment') = 169855, 'USD adjustment converted once with its rate');
  perform test_helpers.assert((select movement_balance::numeric from public.money_control(pt) where financial_account_id = v_usd) = 989.45, 'USD balance follows');

  -- validation
  perform test_helpers.expect_msg(format('select public.record_balance_adjustment(%L, ''key-p4-adj-3'', %L, ''in'', 100, null, date ''2026-09-30'', %L, ''short'')', pt, v_bca, v_interest), 'INVALID', 'a reason of 10 characters is required');
  perform test_helpers.expect_msg(format('select public.record_balance_adjustment(%L, ''key-p4-adj-4'', %L, ''sideways'', 100, null, date ''2026-09-30'', %L, ''A proper long reason'')', pt, v_bca, v_interest), 'INVALID', 'direction');
  perform test_helpers.expect_msg(format('select public.record_balance_adjustment(%L, ''key-p4-adj-5'', %L, ''in'', 0, null, date ''2026-09-30'', %L, ''A proper long reason'')', pt, v_bca, v_interest), 'INVALID', 'zero amount');
  perform test_helpers.expect_msg(format('select public.record_balance_adjustment(%L, ''key-p4-adj-6'', %L, ''in'', -5, null, date ''2026-09-30'', %L, ''A proper long reason'')', pt, v_bca, v_interest), 'INVALID', 'negative amount');
  perform test_helpers.expect_msg(format('select public.record_balance_adjustment(%L, ''key-p4-adj-7'', %L, ''in'', ''NaN''::numeric, null, date ''2026-09-30'', %L, ''A proper long reason'')', pt, v_bca, v_interest), 'INVALID', 'NaN amount');
  perform test_helpers.expect_msg(format('select public.record_balance_adjustment(%L, ''key-p4-adj-8'', %L, ''in'', 100.005, null, date ''2026-09-30'', %L, ''A proper long reason'')', pt, v_bca, v_interest), 'INVALID', 'too many decimals for IDR');
  perform test_helpers.expect_msg(format('select public.record_balance_adjustment(%L, ''key-p4-adj-9'', %L, ''in'', 100, 1.5, date ''2026-09-30'', %L, ''A proper long reason'')', pt, v_bca, v_interest), 'INVALID', 'a base-currency account takes no rate');
  perform test_helpers.expect_msg(format('select public.record_balance_adjustment(%L, ''key-p4-adj-10'', %L, ''in'', 100, null, date ''2026-09-30'', %L, ''A proper long reason'')', pt, v_usd, v_interest), 'INVALID', 'a USD account needs a rate');
  perform test_helpers.expect_msg(format('select public.record_balance_adjustment(%L, ''key-p4-adj-11'', %L, ''in'', 100, null, date ''2026-09-30'', %L, ''A proper long reason'')', pt, v_bca, test_helpers.acct(pt, 'CASH')), 'INVALID', 'the counter account cannot be a cash control account (that is a transfer)');
  perform test_helpers.expect_msg(format('select public.record_balance_adjustment(%L, ''key-p4-adj-12'', %L, ''in'', 100, null, date ''2026-09-30'', %L, ''A proper long reason'')', pt, v_bca, test_helpers.acct(pt, 'ACCOUNTS_RECEIVABLE')), 'INVALID', 'nor a receivable control account');
  perform test_helpers.expect_msg(format('select public.record_balance_adjustment(%L, ''key-p4-adj-13'', %L, ''in'', 100, null, date ''2026-09-30'', %L, ''A proper long reason'')', pt, v_bca, test_helpers.acct(pt, 'OPENING_BALANCE_CLEARING')), 'INVALID', 'nor the migration clearing account');
  perform test_helpers.expect_msg(format('select public.record_balance_adjustment(%L, ''key-p4-adj-15'', gen_random_uuid(), ''in'', 100, null, date ''2026-09-30'', %L, ''A proper long reason'')', pt, v_interest), 'INVALID', 'unknown account');
  perform test_helpers.expect_msg(format('select public.record_balance_adjustment(%L, ''key-p4-adj-16'', %L, ''in'', 100, null, date ''2999-01-01'', %L, ''A proper long reason'')', pt, v_bca, v_interest), 'INVALID', 'date out of range');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 4. transfers
do $$
declare
  pt uuid := test_helpers.entity('p4_pt');
  v_owner uuid := 'b0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'b0000000-0000-0000-0000-000000000002';
  v_approver uuid := 'b0000000-0000-0000-0000-000000000003';
  v_bca uuid := (select id from public.financial_accounts where name = 'BCA Main');
  v_cash uuid := (select id from public.financial_accounts where name = 'Petty Cash');
  v_mandiri uuid := (select id from public.financial_accounts where name = 'Mandiri');
  v_t1 uuid;
  v_t2 uuid;
  v_j uuid;
  v_before numeric;
begin
  -- ---------------- a draft has no cash or accounting effect; confirmation needs the approver capability
  perform test_helpers.login(v_admin);
  v_t1 := public.create_transfer(pt, 'key-p4-tr-1', v_bca, v_mandiri, date '2026-09-10', 1000000, null, 6500, null, null, 'Move funds to Mandiri', 'REF-1');
  perform test_helpers.assert((select status from public.transfers where id = v_t1) = 'draft'
    and (select journal_id from public.transfers where id = v_t1) is null
    and (select transfer_number from public.transfers where id = v_t1) is null
    and (select base_out from public.transfers where id = v_t1) = 1000000
    and (select base_fee from public.transfers where id = v_t1) = 6500
    and (select amount_in from public.transfers where id = v_t1) = 1000000, 'a draft transfer is created with its figures and no posting');
  perform test_helpers.assert(not exists (select 1 from public.money_movements where source_type = 'transfer' and source_id = v_t1)
    and not exists (select 1 from public.journal_entries where source_type = 'transfer' and source_id = v_t1), 'a draft moves no money');
  perform test_helpers.assert(public.create_transfer(pt, 'key-p4-tr-1', v_bca, v_mandiri, date '2026-09-10', 1000000, null, 6500, null, null, 'Move funds to Mandiri', 'REF-1') = v_t1
    and (select count(*) from public.transfers where entity_id = pt) = 1, 'creating a transfer replays on the same key');
  perform test_helpers.expect_msg(format('select public.confirm_transfer(%L, ''key-p4-tr-2'')', v_t1), 'FORBIDDEN', 'a finance admin cannot confirm');
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-tr-3'', %L, %L, date ''2026-09-10'', 5, null, 0, null, null, null, null, true)', pt, v_bca, v_mandiri),
    'FORBIDDEN', 'nor create-and-confirm');
  perform test_helpers.logout();

  perform test_helpers.login(v_approver);
  perform test_helpers.assert(public.confirm_transfer(v_t1, 'key-p4-tr-4') = v_t1, 'the approver confirms');
  perform test_helpers.assert(public.confirm_transfer(v_t1, 'key-p4-tr-4') = v_t1, 'confirming replays on the same key');
  perform test_helpers.expect_msg(format('select public.confirm_transfer(%L, ''key-p4-tr-5'')', v_t1), 'CONFLICT', 'a transfer is confirmed once');
  perform test_helpers.logout();

  perform test_helpers.assert((select status from public.transfers where id = v_t1) = 'confirmed'
    and (select transfer_number from public.transfers where id = v_t1) = 'TRF-2026-0001'
    and (select confirmed_by from public.transfers where id = v_t1) = v_approver, 'confirmed with the next transfer number');
  select journal_id into v_j from public.transfers where id = v_t1;
  perform test_helpers.assert((select status from public.journal_entries where id = v_j) = 'posted'
    and (select source_type from public.journal_entries where id = v_j) = 'transfer'
    and (select posting_rule_version from public.journal_entries where id = v_j) = 'transfer.v1', 'one posted system journal with source linkage');
  perform test_helpers.assert((select count(*) from public.journal_lines where journal_id = v_j) = 4
    and (select sum(debit) from public.journal_lines where journal_id = v_j and ledger_account_id = (select ledger_account_id from public.financial_accounts where id = v_mandiri)) = 1000000
    and (select sum(credit) from public.journal_lines where journal_id = v_j and ledger_account_id = (select ledger_account_id from public.financial_accounts where id = v_bca)) = 1006500
    and (select sum(debit) from public.journal_lines where journal_id = v_j and ledger_account_id = test_helpers.acct(pt, 'BANK_FEE_EXPENSE')) = 6500, 'destination debited, source credited with principal + fee, fee expensed');
  perform test_helpers.assert(not exists (
    select 1 from public.journal_lines l join public.ledger_accounts a on a.id = l.ledger_account_id
    where l.journal_id = v_j and a.account_class in ('revenue', 'contra_revenue', 'other_income')), 'a transfer never creates revenue');
  perform test_helpers.assert((select count(*) from public.journal_lines l join public.ledger_accounts a on a.id = l.ledger_account_id
    where l.journal_id = v_j and a.account_class in ('expense', 'other_expense')) = 1
    and (select sum(l.debit) from public.journal_lines l join public.ledger_accounts a on a.id = l.ledger_account_id
         where l.journal_id = v_j and a.account_class in ('expense', 'other_expense')) = 6500, 'the only expense of a transfer is its explicit fee');
  perform test_helpers.assert((select count(*) from public.money_movements where source_type = 'transfer' and source_id = v_t1) = 3
    and (select count(*) from public.money_movements where source_id = v_t1 and financial_account_id = v_bca and direction = 'out') = 2
    and (select amount from public.money_movements where source_id = v_t1 and component = 'fee') = 6500
    and (select amount from public.money_movements where source_id = v_t1 and financial_account_id = v_mandiri and direction = 'in') = 1000000, 'paired movements plus the fee movement');
  perform test_helpers.assert((select movement_balance from test_helpers.mc(pt) where financial_account_id = v_bca) = 9006000
    and (select movement_balance from test_helpers.mc(pt) where financial_account_id = v_mandiri) = 3000000, 'balances moved');
  perform test_helpers.assert(not exists (select 1 from test_helpers.mc(pt) where ledger_balance <> movement_base_balance), 'money and ledger agree after the transfer');

  -- ---------------- owner: create and confirm in one step, a cash withdrawal without fee
  perform test_helpers.login(v_owner);
  v_t2 := public.create_transfer(pt, 'key-p4-tr-6', v_bca, v_cash, date '2026-09-12', 200000, null, 0, null, null, 'Cash withdrawal', null, true);
  perform test_helpers.assert((select status from public.transfers where id = v_t2) = 'confirmed'
    and (select transfer_number from public.transfers where id = v_t2) = 'TRF-2026-0002'
    and (select count(*) from public.money_movements where source_id = v_t2) = 2, 'the OWNER creates and confirms a withdrawal; no fee movement');
  perform test_helpers.logout();

  -- ---------------- validation and boundaries
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-tv-1'', %L, %L, date ''2026-09-12'', 100)', pt, v_bca, v_bca), 'INVALID', 'source and destination differ');
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-tv-2'', %L, gen_random_uuid(), date ''2026-09-12'', 100)', pt, v_bca), 'INVALID', 'unknown destination');
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-tv-3'', %L, %L, date ''2026-09-12'', 0)', pt, v_bca, v_cash), 'INVALID', 'zero amount');
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-tv-4'', %L, %L, date ''2026-09-12'', -5)', pt, v_bca, v_cash), 'INVALID', 'negative amount');
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-tv-5'', %L, %L, date ''2026-09-12'', 100, null, -1)', pt, v_bca, v_cash), 'INVALID', 'negative fee');
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-tv-6'', %L, %L, date ''2026-09-12'', 100.005)', pt, v_bca, v_cash), 'INVALID', 'too many decimals');
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-tv-7'', %L, %L, date ''2026-09-12'', ''NaN''::numeric)', pt, v_bca, v_cash), 'INVALID', 'NaN');
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-tv-8'', %L, %L, date ''2026-09-12'', 100, 99)', pt, v_bca, v_cash), 'INVALID', 'the same currency on both sides means equal amounts');
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-tv-9'', %L, %L, date ''2999-01-01'', 100)', pt, v_bca, v_cash), 'INVALID', 'date out of range');
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-tv-10'', %L, %L, date ''2026-09-12'', 100, null, 0, 1.5)', pt, v_bca, v_cash), 'INVALID', 'a base-currency source takes no rate');
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-tv-11'', %L, (select id from public.financial_accounts where name = ''GoPay''), date ''2026-09-12'', 100)', pt, v_bca), 'CONFLICT', 'a disabled account cannot be used');
  perform test_helpers.logout();

  -- PT <-> Personal is never a generic transfer (Step 03 §8)
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-tx-1'', %L, %L, date ''2026-09-12'', 100)', pt, v_bca,
    (select id from public.financial_accounts where name = 'Personal BCA')), 'INVALID', 'a Personal account cannot be the destination of a PT transfer');
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-tx-2'', %L, %L, date ''2026-09-12'', 100)', test_helpers.entity('p4_pe'), v_bca,
    (select id from public.financial_accounts where name = 'Personal BCA')), 'INVALID', 'nor can a PT account be the source of a Personal transfer');
  perform test_helpers.logout();
  perform test_helpers.expect_error(format('insert into public.transfers (entity_id, transfer_date, from_account_id, to_account_id, amount_out, amount_in, base_out, base_in) values (%L, date ''2026-09-12'', %L, %L, 1, 1, 1, 1)',
    pt, v_bca, (select id from public.financial_accounts where name = 'Personal BCA')), '23503', 'the database itself refuses a cross-Entity pair');
end
$$;

do $$
declare
  pt uuid := test_helpers.entity('p4_pt');
  v_owner uuid := 'b0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'b0000000-0000-0000-0000-000000000002';
  v_approver uuid := 'b0000000-0000-0000-0000-000000000003';
  v_staff uuid := 'b0000000-0000-0000-0000-000000000008';
  v_viewer uuid := 'b0000000-0000-0000-0000-000000000004';
  v_nobody uuid := 'b0000000-0000-0000-0000-000000000007';
  v_bca uuid := (select id from public.financial_accounts where name = 'BCA Main');
  v_cash uuid := (select id from public.financial_accounts where name = 'Petty Cash');
  v_mandiri uuid := (select id from public.financial_accounts where name = 'Mandiri');
  v_usd uuid := (select id from public.financial_accounts where name = 'USD Account');
  v_t uuid;
  v_t3 uuid;
  v_j uuid;
begin
  -- ---------------- FX and cross-currency transfers (Step 04 §5, §14)
  perform test_helpers.login(v_owner);
  -- no difference: 1,600,000 IDR buys 100 USD at 16,000
  v_t := public.create_transfer(pt, 'key-p4-fx-1', v_mandiri, v_usd, date '2026-09-14', 1600000, 100, 0, null, 16000, 'Buy USD', null, true);
  perform test_helpers.assert((select fx_difference from public.transfers where id = v_t) = 0 and (select base_in from public.transfers where id = v_t) = 1600000
    and (select count(*) from public.journal_lines where journal_id = (select journal_id from public.transfers where id = v_t)) = 2, 'no FX line when the base values agree');
  perform test_helpers.assert((select amount from public.money_movements where source_id = v_t and financial_account_id = v_usd) = 100
    and (select currency from public.money_movements where source_id = v_t and financial_account_id = v_usd) = 'USD'
    and (select exchange_rate from public.money_movements where source_id = v_t and financial_account_id = v_usd) = 16000, 'the USD leg is recorded in USD with its rate snapshot');
  -- a gain: the USD received is worth 5,000 more than the IDR given
  v_t := public.create_transfer(pt, 'key-p4-fx-2', v_mandiri, v_usd, date '2026-09-14', 1600000, 100, 0, null, 16050, 'Buy USD at a better rate', null, true);
  select journal_id into v_j from public.transfers where id = v_t;
  perform test_helpers.assert((select fx_difference from public.transfers where id = v_t) = 5000
    and (select credit from public.journal_lines where journal_id = v_j and ledger_account_id = test_helpers.acct(pt, 'FX_GAIN_LOSS')) = 5000, 'an FX gain is a separate credit to FX gain/loss');
  -- a loss with a fee in the source currency: 50 USD (16,100) arrive as 800,000 IDR, fee 1.10 USD
  v_t3 := public.create_transfer(pt, 'key-p4-fx-3', v_usd, v_bca, date '2026-09-15', 50, 800000, 1.10, 16100, null, 'Sell USD', null, true);
  select journal_id into v_j from public.transfers where id = v_t3;
  perform test_helpers.assert((select fx_difference from public.transfers where id = v_t3) = -5000 and (select base_out from public.transfers where id = v_t3) = 805000
    and (select base_fee from public.transfers where id = v_t3) = 17710
    and (select debit from public.journal_lines where journal_id = v_j and ledger_account_id = test_helpers.acct(pt, 'FX_GAIN_LOSS')) = 5000
    and (select sum(debit) from public.journal_lines where journal_id = v_j) = (select sum(credit) from public.journal_lines where journal_id = v_j), 'an FX loss is a separate debit; the journal balances');
  perform test_helpers.assert((select sum(l.original_amount) from public.journal_lines l where l.journal_id = v_j and l.credit > 0 and l.original_currency = 'USD') = 51.10, 'the journal lines keep the USD amounts of the source leg');
  perform test_helpers.assert((select count(*) from public.money_movements where source_id = v_t3 and financial_account_id = v_usd and direction = 'out') = 2
    and (select amount from public.money_movements where source_id = v_t3 and component = 'fee') = 1.10, 'principal and fee leave the USD account as two movements');
  perform test_helpers.assert((select movement_balance from test_helpers.mc(pt) where financial_account_id = v_usd) = 989.45 + 100 + 100 - 50 - 1.10, 'USD balance derived from movements');
  perform test_helpers.assert(not exists (select 1 from test_helpers.mc(pt) where ledger_balance <> movement_base_balance), 'money and ledger agree after FX transfers');

  -- rate and amount rules
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-fv-1'', %L, %L, date ''2026-09-14'', 1600000, 100)', pt, v_mandiri, v_usd), 'INVALID', 'a USD destination needs its rate');
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-fv-2'', %L, %L, date ''2026-09-14'', 1600000, null, 0, null, 16000)', pt, v_mandiri, v_usd), 'INVALID', 'the amount received is required across currencies');
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-fv-3'', %L, %L, date ''2026-09-14'', 1600000, 100, 0, 1, 16000)', pt, v_mandiri, v_usd), 'INVALID', 'an IDR source takes no rate');
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-fv-4'', %L, %L, date ''2026-09-14'', 1600000, 100, 0, null, 20000)', pt, v_mandiri, v_usd), 'INVALID', 'a rate that makes the FX difference exceed 20% is refused');
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-fv-5'', %L, %L, date ''2026-09-14'', 1600000, 100, 0, null, 16000.12345678901)', pt, v_mandiri, v_usd), 'INVALID', 'rates allow ten decimals');
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-fv-6'', %L, %L, date ''2026-09-14'', 10.005, 800000, 0, 16100)', pt, v_usd, v_bca), 'INVALID', 'USD allows two decimals');
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-fv-7'', %L, %L, date ''2026-09-14'', 10, 160000, 0, 0)', pt, v_usd, v_bca), 'INVALID', 'a zero rate is not a rate');
  perform test_helpers.logout();

  -- ---------------- who can do what
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-pm-1'', %L, %L, date ''2026-09-12'', 100)', pt, v_bca, v_cash), 'FORBIDDEN', 'finance staff cannot transfer');
  perform test_helpers.logout();
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-pm-2'', %L, %L, date ''2026-09-12'', 100)', pt, v_bca, v_cash), 'FORBIDDEN', 'a viewer cannot transfer');
  perform test_helpers.assert((select count(*) from public.transfers) >= 5 and (select count(*) from public.money_movements) > 10, 'but a viewer reads transfers and movements');
  perform test_helpers.expect_error(format('update public.transfers set status = ''cancelled'' where id = %L', v_t), '42501', 'no direct writes for anyone');
  perform test_helpers.logout();
  perform test_helpers.login(v_nobody);
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-pm-3'', %L, %L, date ''2026-09-12'', 100)', pt, v_bca, v_cash), 'FORBIDDEN', 'a stranger cannot transfer');
  perform test_helpers.expect_msg(format('select public.confirm_transfer(%L, ''key-p4-pm-4'')', v_t), 'FORBIDDEN', 'nor confirm');
  perform test_helpers.expect_msg('select public.confirm_transfer(gen_random_uuid(), ''key-p4-pm-5'')', 'FORBIDDEN', 'an unknown transfer reads as forbidden');
  perform test_helpers.assert(test_helpers.rows('select 1 from public.transfers') = 0 and test_helpers.rows('select 1 from public.money_movements') = 0
    and test_helpers.rows('select 1 from public.financial_accounts') = 0, 'a stranger reads nothing');
  perform test_helpers.logout();

  -- ---------------- drafts can be cancelled, confirmed ones cannot
  perform test_helpers.login(v_admin);
  v_t := public.create_transfer(pt, 'key-p4-cx-1', v_bca, v_cash, date '2026-09-16', 1000, null, 0, null, null, 'To be cancelled');
  perform test_helpers.assert(public.cancel_transfer(v_t, 'Entered twice') = 'cancelled', 'a draft is cancelled');
  perform test_helpers.assert((select status from public.transfers where id = v_t) = 'cancelled', 'and recorded as cancelled');
  perform test_helpers.expect_msg(format('select public.cancel_transfer(%L)', v_t), 'CONFLICT', 'a cancelled transfer cannot be cancelled again');
  perform test_helpers.expect_msg(format('select public.cancel_transfer(%L)', (select id from public.transfers where transfer_number = 'TRF-2026-0001')), 'CONFLICT', 'a confirmed transfer cannot be cancelled');
  perform test_helpers.logout();
  perform test_helpers.login(v_approver);
  perform test_helpers.expect_msg(format('select public.confirm_transfer(%L, ''key-p4-cx-2'')', v_t), 'CONFLICT', 'a cancelled transfer cannot be confirmed');
  perform test_helpers.logout();

  -- ---------------- the record itself is protected
  perform test_helpers.expect_error(format('update public.transfers set amount_out = 5 where id = %L', (select id from public.transfers where transfer_number = 'TRF-2026-0001')), '23000', 'the amount of a transfer is frozen');
  perform test_helpers.expect_error(format('update public.transfers set status = ''draft'' where id = %L', (select id from public.transfers where transfer_number = 'TRF-2026-0001')), '23000', 'a confirmed transfer cannot go back to draft');
  perform test_helpers.expect_error(format('update public.transfers set description = ''x'' where id = %L', v_t), '23000', 'a cancelled transfer is final');
  perform test_helpers.expect_error(format('delete from public.transfers where id = %L', v_t), '23000', 'transfers are never deleted');
  perform test_helpers.expect_error('update public.money_movements set amount = amount + 1', '23000', 'movements are immutable');
  perform test_helpers.expect_error('delete from public.money_movements', '23000', 'movements are never deleted');
  perform test_helpers.expect_error('truncate public.money_movements cascade', '23000', 'movements are never truncated');
  perform test_helpers.assert((select count(*) from public.numbering_sequences where entity_id = pt and scope = 'transfer') = 1, 'transfers have their own numbering sequence');
end
$$;

-- ---------------- approval rules (maker-checker, Step 06 §7), negative-balance policy, closed periods, reversal
do $$
declare
  pt uuid := test_helpers.entity('p4_pt');
  v_owner uuid := 'b0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'b0000000-0000-0000-0000-000000000002';
  v_approver uuid := 'b0000000-0000-0000-0000-000000000003';
  v_acct uuid := 'b0000000-0000-0000-0000-000000000006';
  v_bca uuid := (select id from public.financial_accounts where name = 'BCA Main');
  v_cash uuid := (select id from public.financial_accounts where name = 'Petty Cash');
  v_cash2 uuid := (select id from public.financial_accounts where name = 'Second Cash');
  v_mandiri uuid := (select id from public.financial_accounts where name = 'Mandiri');
  v_admin_m uuid := (select id from public.entity_memberships where entity_id = pt and user_id = 'b0000000-0000-0000-0000-000000000002');
  v_t uuid;
  v_t1 uuid := (select id from public.transfers where transfer_number = 'TRF-2026-0001');
  v_rev uuid;
  v_period uuid;
  v_bca_before numeric;
  v_man_before numeric;
  v_cash_before numeric;
begin
  -- the admin may also approve here (explicit grant), but a rule forbids approving one's own transfer
  insert into public.membership_permission_overrides (membership_id, permission_key, effect) values (v_admin_m, 'money.transfer_approve', 'grant');
  insert into public.approval_rules (entity_id, module, action, min_amount, requires_approval, allow_self_approval, effective_from)
  values (pt, 'money', 'transfer', 0, true, false, date '2026-01-01');
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-ar-1'', %L, %L, date ''2026-09-17'', 1000, null, 0, null, null, null, null, true)', pt, v_bca, v_cash),
    'FORBIDDEN', 'maker-checker: one person cannot create and confirm');
  v_t := public.create_transfer(pt, 'key-p4-ar-2', v_bca, v_cash, date '2026-09-17', 1000, null, 0, null, null, 'Needs a second person');
  perform test_helpers.expect_msg(format('select public.confirm_transfer(%L, ''key-p4-ar-3'')', v_t), 'FORBIDDEN', 'nor confirm their own draft');
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.transfers where id = v_t) = 'draft', 'the refused confirmations left the draft alone');
  perform test_helpers.login(v_approver);
  perform test_helpers.assert(public.confirm_transfer(v_t, 'key-p4-ar-4') = v_t, 'a different person confirms');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  v_t := public.create_transfer(pt, 'key-p4-ar-5', v_bca, v_cash, date '2026-09-17', 1000, null, 0, null, null, 'Owner approves own', null, true);
  perform test_helpers.assert((select status from public.transfers where id = v_t) = 'confirmed', 'the OWNER may approve their own event');
  perform test_helpers.logout();
  -- a rule that starts above the amount does not apply
  update public.approval_rules set min_amount = 5000000 where entity_id = pt and module = 'money';
  perform test_helpers.login(v_admin);
  v_t := public.create_transfer(pt, 'key-p4-ar-6', v_bca, v_cash, date '2026-09-17', 1000, null, 0, null, null, 'Below the rule threshold', null, true);
  perform test_helpers.assert((select status from public.transfers where id = v_t) = 'confirmed', 'a rule above the amount does not apply');
  perform test_helpers.logout();
  delete from public.approval_rules where entity_id = pt;
  delete from public.membership_permission_overrides where membership_id = v_admin_m;

  -- negative-balance policy: the Entity may block cash accounts from going below zero (Step 08 §9)
  insert into public.entity_settings (entity_id, setting_key, setting_value) values (pt, 'money.block_negative_balance', '["cash"]'::jsonb);
  select movement_balance into v_cash_before from test_helpers.mc(pt) where financial_account_id = v_cash;
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-ng-1'', %L, %L, date ''2026-09-18'', 100000000, null, 0, null, null, null, null, true)', pt, v_cash, v_bca),
    'CONFLICT', 'a cash account cannot be overdrawn when blocked');
  perform test_helpers.assert((select movement_balance from test_helpers.mc(pt) where financial_account_id = v_cash) = v_cash_before, 'the refused transfer left the balance alone');
  v_t := public.create_transfer(pt, 'key-p4-ng-2', v_cash, v_cash2, date '2026-09-18', 300000, null, 0, null, null, null, null, true);
  perform test_helpers.assert((select status from public.transfers where id = v_t) = 'confirmed', 'within the balance it goes through');
  perform test_helpers.logout();
  delete from public.entity_settings where entity_id = pt and setting_key = 'money.block_negative_balance';
  -- without the block a negative balance is allowed but surfaced as a warning (Step 08 §9, Step 04 §12)
  perform test_helpers.login(v_owner);
  perform public.create_transfer(pt, 'key-p4-ng-3', v_cash2, v_cash, date '2026-09-19', 1000000, null, 0, null, null, 'Overdraw the second cash box', null, true);
  perform test_helpers.assert((select movement_balance < 0 from test_helpers.mc(pt) where financial_account_id = v_cash2), 'the negative balance is flagged');
  perform test_helpers.logout();
  select id into v_period from public.accounting_periods where entity_id = pt and period_start = date '2026-09-01';
  perform test_helpers.login(v_acct);
  perform test_helpers.assert(exists (select 1 from public.period_close_checks(v_period) where code = 'negative_cash_balance' and severity = 'warning'), 'closing review warns about the negative balance');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform public.create_transfer(pt, 'key-p4-ng-4', v_cash, v_cash2, date '2026-09-19', 1000000, null, 0, null, null, 'Put it back', null, true);
  perform test_helpers.logout();

  -- ---------------- a closed period blocks confirmation
  perform app_private.ensure_accounting_period(pt, date '2026-07-15');
  select id into v_period from public.accounting_periods where entity_id = pt and period_start = date '2026-07-01';
  perform test_helpers.login(v_acct);
  perform public.begin_period_close(v_period);
  perform test_helpers.assert(public.close_period(v_period) = 'closed', 'July is closed');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-p4-cp-1'', %L, %L, date ''2026-07-20'', 1000, null, 0, null, null, null, null, true)', pt, v_bca, v_cash),
    'CONFLICT', 'a transfer cannot be confirmed into a closed period');
  v_t := public.create_transfer(pt, 'key-p4-cp-2', v_bca, v_cash, date '2026-07-20', 1000);
  perform test_helpers.expect_msg(format('select public.confirm_transfer(%L, ''key-p4-cp-3'')', v_t), 'CONFLICT', 'nor a draft dated in it');
  perform test_helpers.assert((select status from public.transfers where id = v_t) = 'draft' and not exists (select 1 from public.money_movements where source_id = v_t), 'nothing was booked');
  perform public.cancel_transfer(v_t);
  perform test_helpers.logout();

  -- ---------------- reversal is the only correction (Step 04 §11)
  select movement_balance into v_bca_before from test_helpers.mc(pt) where financial_account_id = v_bca;
  select movement_balance into v_man_before from test_helpers.mc(pt) where financial_account_id = v_mandiri;
  perform test_helpers.login(v_admin);
  v_t := public.create_transfer(pt, 'key-p4-rv-d', v_bca, v_cash, date '2026-09-20', 500, null, 0, null, null, 'A draft that stays a draft');
  perform test_helpers.expect_msg(format('select public.reverse_transfer(%L, ''key-p4-rv-0'', date ''2026-09-25'', ''Wrong destination'')', v_t1), 'FORBIDDEN', 'a finance admin cannot reverse');
  perform test_helpers.logout();
  perform test_helpers.login(v_approver);
  perform test_helpers.expect_msg(format('select public.reverse_transfer(%L, ''key-p4-rv-1'', date ''2026-09-25'', ''oops'')', v_t1), 'INVALID', 'a reason is required');
  perform test_helpers.expect_msg(format('select public.reverse_transfer(%L, ''key-p4-rv-2'', date ''2026-09-01'', ''Wrong destination account'')', v_t1), 'INVALID', 'not before the original date');
  perform test_helpers.expect_msg(format('select public.reverse_transfer(%L, ''key-p4-rv-3'', date ''2026-09-25'', ''Wrong destination account'')', v_t), 'CONFLICT', 'a draft cannot be reversed');
  v_rev := public.reverse_transfer(v_t1, 'key-p4-rv-4', date '2026-09-25', 'Wrong destination account');
  perform test_helpers.assert(public.reverse_transfer(v_t1, 'key-p4-rv-4', date '2026-09-25', 'Wrong destination account') = v_rev, 'reversal replays on the same key');
  perform test_helpers.expect_msg(format('select public.reverse_transfer(%L, ''key-p4-rv-5'', date ''2026-09-26'', ''Wrong destination account'')', v_t1), 'CONFLICT', 'a transfer is reversed once');
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.transfers where id = v_t1) = 'reversed' and (select reversal_journal_id from public.transfers where id = v_t1) = v_rev
    and (select transfer_number from public.transfers where id = v_t1) = 'TRF-2026-0001' and (select reverse_reason from public.transfers where id = v_t1) = 'Wrong destination account', 'the transfer is marked reversed and keeps its number');
  perform test_helpers.assert((select entry_type from public.journal_entries where id = v_rev) = 'reversal'
    and (select reverses_journal_id from public.journal_entries where id = v_rev) = (select journal_id from public.transfers where id = v_t1), 'the reversal journal mirrors the original');
  perform test_helpers.assert((select count(*) from public.money_movements where source_id = v_t1 and reverses_movement_id is not null) = 3
    and (select count(*) from public.money_movements where source_id = v_t1) = 6, 'every original movement has its mirror; the originals stay');
  perform test_helpers.assert((select movement_balance from test_helpers.mc(pt) where financial_account_id = v_bca) = v_bca_before + 1006500
    and (select movement_balance from test_helpers.mc(pt) where financial_account_id = v_mandiri) = v_man_before - 1000000, 'balances are back');
  perform test_helpers.assert((select coalesce(sum(l.debit - l.credit), 0) from public.journal_lines l
    where l.journal_id in ((select journal_id from public.transfers where id = v_t1), v_rev) and l.ledger_account_id = test_helpers.acct(pt, 'BANK_FEE_EXPENSE')) = 0, 'the fee expense nets to zero');
  perform test_helpers.assert(not exists (select 1 from test_helpers.mc(pt) where ledger_balance <> movement_base_balance), 'money and ledger agree after the reversal');
  perform test_helpers.expect_error(format('update public.transfers set status = ''confirmed'' where id = %L', v_t1), '23000', 'a reversed transfer is final');
end
$$;

-- ================================================================ 5. the movement guard and the money/ledger control
do $$
declare
  pt uuid := test_helpers.entity('p4_pt');
  pe uuid := test_helpers.entity('p4_pe');
  v_acct uuid := 'b0000000-0000-0000-0000-000000000006';
  v_bca uuid := (select id from public.financial_accounts where name = 'BCA Main');
  v_pe_bank uuid := (select id from public.financial_accounts where name = 'Personal BCA');
  v_src uuid := gen_random_uuid();
  v_j uuid;
  v_draft uuid;
  v_pe_j uuid;
  v_period uuid;
  v_orig uuid;
  v_mov uuid;
begin
  -- A raw system journal that touches the bank ledger account WITHOUT its money movement (what a broken or
  -- future workflow could do): the control must see it, and Close must refuse it.
  v_j := app_private.post_system_journal(pt, 'raw_event', v_src, 'raw.rule', 'v1', date '2026-09-21', 'Raw posting on the bank account',
    jsonb_build_array(jsonb_build_object('account_key', 'BANK_OPERATING', 'debit', 100), jsonb_build_object('account_key', 'OTHER_OPERATING_REVENUE', 'credit', 100)));
  perform test_helpers.assert((select ledger_balance - movement_base_balance from test_helpers.mc(pt) where financial_account_id = v_bca) = 100, 'the control shows the gap between ledger and movements');
  select id into v_period from public.accounting_periods where entity_id = pt and period_start = date '2026-09-01';
  perform test_helpers.login(v_acct);
  perform test_helpers.assert(exists (select 1 from public.period_close_checks(v_period) where code = 'money_ledger_mismatch' and severity = 'blocker' and item_count = 1), 'Close is blocked by the mismatch');
  perform public.begin_period_close(v_period);
  perform test_helpers.expect_msg(format('select public.close_period(%L)', v_period), 'CONFLICT', 'the period cannot close while money and ledger disagree');
  perform public.cancel_period_close(v_period);
  perform test_helpers.logout();

  -- the movement guard: a movement must be exactly what a posted journal of the same Entity and date booked
  perform test_helpers.expect_msg(format('select app_private.record_movement(%L, %L, ''in'', 200, 200, null, date ''2026-09-21'', ''raw_event'', %L, ''principal'', %L)', pt, v_bca, v_src, v_j),
    'INVALID', 'more than the journal booked');
  perform test_helpers.expect_msg(format('select app_private.record_movement(%L, %L, ''out'', 100, 100, null, date ''2026-09-21'', ''raw_event'', %L, ''principal'', %L)', pt, v_bca, v_src, v_j),
    'INVALID', 'the journal did not credit the account');
  perform test_helpers.expect_msg(format('select app_private.record_movement(%L, %L, ''in'', 100, 100, null, date ''2026-09-22'', ''raw_event'', %L, ''principal'', %L)', pt, v_bca, v_src, v_j),
    'INVALID', 'the date must equal the journal date');
  perform test_helpers.expect_msg(format('select app_private.record_movement(%L, %L, ''in'', 100, 150, null, date ''2026-09-21'', ''raw_event'', %L, ''principal'', %L)', pt, v_bca, v_src, v_j),
    'INVALID', 'a base-currency movement has equal amounts');
  perform test_helpers.expect_msg(format('select app_private.record_movement(%L, %L, ''in'', 100, 100, 1.5, date ''2026-09-21'', ''raw_event'', %L, ''principal'', %L)', pt, v_bca, v_src, v_j),
    'INVALID', 'a base-currency movement has no rate');
  perform test_helpers.expect_msg(format('select app_private.record_movement(%L, %L, ''in'', 100.001, 100.001, null, date ''2026-09-21'', ''raw_event'', %L, ''principal'', %L)', pt, v_bca, v_src, v_j),
    'INVALID', 'decimals beyond the currency');
  perform test_helpers.expect_msg(format('select app_private.record_movement(%L, %L, ''in'', 0, 0, null, date ''2026-09-21'', ''raw_event'', %L, ''principal'', %L)', pt, v_bca, v_src, v_j),
    'INVALID', 'a movement has an amount');
  perform test_helpers.expect_msg(format('select app_private.record_movement(%L, gen_random_uuid(), ''in'', 100, 100, null, date ''2026-09-21'', ''raw_event'', %L, ''principal'', %L)', pt, v_src, v_j),
    'INVALID', 'unknown account');
  v_draft := test_helpers.draft_journal(pt, date '2026-09-21', 'system');
  perform test_helpers.add_line(v_draft, test_helpers.acct(pt, 'BANK_OPERATING'), 100, 0);
  perform test_helpers.add_line(v_draft, test_helpers.acct(pt, 'OTHER_OPERATING_REVENUE'), 0, 100);
  perform test_helpers.expect_msg(format('select app_private.record_movement(%L, %L, ''in'', 100, 100, null, date ''2026-09-21'', ''raw_event'', %L, ''principal'', %L)', pt, v_bca, v_src, v_draft),
    'INVALID', 'a draft journal is not evidence');
  delete from public.journal_lines where journal_id = v_draft;
  delete from public.journal_entries where id = v_draft;
  v_pe_j := app_private.post_system_journal(pe, 'raw_event', gen_random_uuid(), 'raw.rule', 'v1', date '2026-09-21', 'Personal raw posting',
    jsonb_build_array(jsonb_build_object('account_key', 'PERSONAL_BANK', 'debit', 100), jsonb_build_object('account_key', 'OTHER_PERSONAL_INCOME', 'credit', 100)));
  perform test_helpers.expect_msg(format('select app_private.record_movement(%L, %L, ''in'', 100, 100, null, date ''2026-09-21'', ''raw_event'', %L, ''principal'', %L)', pt, v_bca, v_src, v_pe_j),
    'INVALID', 'a journal of another Entity is not evidence');
  perform test_helpers.expect_msg(format('select app_private.record_movement(%L, %L, ''in'', 100, 100, null, date ''2026-09-21'', ''raw_event'', %L, ''principal'', %L)', pt, v_pe_bank, v_src, v_j),
    'INVALID', 'an account of another Entity is refused');
  perform test_helpers.expect_error(format('insert into public.money_movements (entity_id, financial_account_id, currency, direction, amount, base_amount, exchange_rate, movement_date, source_type, source_id, journal_id) values (%L, %L, ''USD'', ''in'', 100, 100, 1, date ''2026-09-21'', ''raw_event'', %L, %L)', pt, v_bca, v_src, v_j),
    '23503', 'a movement cannot carry another currency than its account');

  -- the matching movement closes the gap; a second one for the same booking is refused
  v_mov := app_private.record_movement(pt, v_bca, 'in', 100, 100, null, date '2026-09-21', 'raw_event', v_src, 'principal', v_j, 'Raw posting');
  perform test_helpers.assert(not exists (select 1 from test_helpers.mc(pt) where ledger_balance <> movement_base_balance), 'ledger and movements agree again');
  perform test_helpers.expect_msg(format('select app_private.record_movement(%L, %L, ''in'', 100, 100, null, date ''2026-09-21'', ''raw_event'', %L, ''principal'', %L)', pt, v_bca, v_src, v_j),
    'INVALID', 'the same booking cannot be counted twice');
  perform test_helpers.login(v_acct);
  perform test_helpers.assert(not exists (select 1 from public.period_close_checks(v_period) where code = 'money_ledger_mismatch'), 'the blocker is gone');
  perform test_helpers.logout();

  -- reversal movements mirror the original exactly and belong to the reversal journal
  perform test_helpers.expect_msg(format('select app_private.record_movement(%L, %L, ''out'', 100, 100, null, date ''2026-09-21'', ''raw_event'', %L, ''principal'', %L, null, %L)', pt, v_bca, v_src, v_j, v_mov),
    'INVALID', 'a reversal must sit on the reversal journal of the original');
  perform test_helpers.expect_msg(format('select app_private.record_movement(%L, %L, ''in'', 100, 100, null, date ''2026-09-21'', ''raw_event'', %L, ''principal'', %L, null, %L)', pt, v_bca, v_src, v_j, v_mov),
    'INVALID', 'a reversal goes the other way');
end
$$;

-- ================================================================ 6. statement reconciliation
create function test_helpers.mv(p_source uuid, p_account uuid, p_component text default 'principal') returns uuid
language sql security definer set search_path = pg_catalog, public as
$f$ select id from public.money_movements
    where source_id = p_source and financial_account_id = p_account and component = p_component and reverses_movement_id is null $f$;
create function test_helpers.ln(p_session uuid, p_desc text) returns uuid
language sql security definer set search_path = pg_catalog, public as
$f$ select id from public.statement_lines where session_id = p_session and description = p_desc $f$;
grant execute on function test_helpers.mv(uuid, uuid, text), test_helpers.ln(uuid, text) to anon, authenticated;

do $$
declare
  pt uuid := test_helpers.entity('p4_pt');
  v_owner uuid := 'b0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'b0000000-0000-0000-0000-000000000002';
  v_approver uuid := 'b0000000-0000-0000-0000-000000000003';
  v_viewer uuid := 'b0000000-0000-0000-0000-000000000004';
  v_acct uuid := 'b0000000-0000-0000-0000-000000000006';
  v_nobody uuid := 'b0000000-0000-0000-0000-000000000007';
  v_staff uuid := 'b0000000-0000-0000-0000-000000000008';
  v_bca uuid := (select id from public.financial_accounts where name = 'BCA Main');
  v_rb uuid;
  v_db uuid;
  v_t1 uuid; v_t2 uuid; v_t3 uuid; v_t4 uuid; v_t5 uuid; v_t6 uuid; v_t7 uuid; v_t8 uuid; v_td uuid;
  v_s uuid;
  v_s2 uuid;
  v_ds uuid;
  v_ds2 uuid;
  v_l1 uuid; v_l2 uuid; v_l3 uuid; v_l4 uuid; v_l5 uuid; v_l6 uuid; v_l7 uuid; v_dup uuid;
  v_res jsonb;
  v_period uuid;
  v_jn bigint;
  v_mn bigint;
  v_adj uuid;
  v_short numeric;
  v_diff text;
  r record;
begin
  -- ---------------- fixtures: two accounts funded by real transfers (movements with source 'transfer')
  perform test_helpers.login(v_owner);
  v_rb := public.create_financial_account(pt, 'key-p4-rc-a1', 'bank', 'Recon Bank', 'IDR');
  v_db := public.create_financial_account(pt, 'key-p4-rc-a2', 'bank', 'Diff Bank', 'IDR');
  perform test_helpers.logout();
  select greatest(0, 4700000 - movement_balance) into v_short from test_helpers.mc(pt) where financial_account_id = v_bca;
  if v_short > 0 then
    perform test_helpers.login(v_acct);
    perform public.record_balance_adjustment(pt, 'key-p4-rc-top', v_bca, 'in', v_short, null, date '2026-09-01', test_helpers.acct(pt, 'INTEREST_INCOME'), 'Top up the test account balance');
    perform test_helpers.logout();
  end if;
  perform test_helpers.login(v_owner);
  v_t1 := public.create_transfer(pt, 'key-p4-rc-t1', v_bca, v_rb, date '2026-09-03', 1000000, null, 0, null, null, 'Funding 1', 'RC-1', true);
  v_t2 := public.create_transfer(pt, 'key-p4-rc-t2', v_bca, v_rb, date '2026-09-05', 2000000, null, 0, null, null, 'Funding 2', 'RC-2', true);
  v_t8 := public.create_transfer(pt, 'key-p4-rc-t8', v_bca, v_rb, date '2026-09-02', 50000, null, 0, null, null, 'Funding late credit', 'RC-8', true);
  v_t3 := public.create_transfer(pt, 'key-p4-rc-t3', v_rb, v_bca, date '2026-09-10', 500000, null, 2500, null, null, 'Return with bank fee', 'RC-3', true);
  v_t4 := public.create_transfer(pt, 'key-p4-rc-t4', v_rb, v_bca, date '2026-09-15', 150000, null, 0, null, null, 'Return 2', 'RC-4', true);
  v_t5 := public.create_transfer(pt, 'key-p4-rc-t5', v_bca, v_rb, date '2026-09-22', 300000, null, 0, null, null, 'Batch part 1', 'RC-5', true);
  v_t6 := public.create_transfer(pt, 'key-p4-rc-t6', v_bca, v_rb, date '2026-09-22', 700000, null, 0, null, null, 'Batch part 2', 'RC-6', true);
  v_t7 := public.create_transfer(pt, 'key-p4-rc-t7', v_bca, v_rb, date '2026-09-28', 400000, null, 0, null, null, 'Deposit in transit', 'RC-7', true);
  v_td := public.create_transfer(pt, 'key-p4-rc-td', v_bca, v_db, date '2026-09-05', 100000, null, 0, null, null, 'Funding Diff Bank', 'RC-D', true);
  perform test_helpers.logout();
  perform test_helpers.assert((select movement_balance from test_helpers.mc(pt) where financial_account_id = v_rb) = 3797500, 'Recon Bank holds the funded balance');
  v_jn := (select count(*) from public.journal_entries where entity_id = pt);
  v_mn := (select count(*) from public.money_movements where entity_id = pt);

  -- ---------------- who may reconcile
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.create_reconciliation_session(%L, ''key-p4-rs-x'', %L, date ''2026-09-01'', date ''2026-09-30'', 0, 100)', pt, v_rb), 'FORBIDDEN', 'staff cannot reconcile');
  perform test_helpers.logout();
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.create_reconciliation_session(%L, ''key-p4-rs-x'', %L, date ''2026-09-01'', date ''2026-09-30'', 0, 100)', pt, v_rb), 'FORBIDDEN', 'a viewer cannot reconcile');
  perform test_helpers.logout();
  perform test_helpers.login(v_approver);
  perform test_helpers.expect_msg(format('select public.create_reconciliation_session(%L, ''key-p4-rs-x'', %L, date ''2026-09-01'', date ''2026-09-30'', 0, 100)', pt, v_rb), 'FORBIDDEN', 'an approver cannot reconcile');
  perform test_helpers.logout();
  perform test_helpers.login(v_nobody);
  perform test_helpers.expect_msg(format('select public.create_reconciliation_session(%L, ''key-p4-rs-x'', %L, date ''2026-09-01'', date ''2026-09-30'', 0, 100)', pt, v_rb), 'FORBIDDEN', 'a stranger cannot reconcile');
  perform test_helpers.logout();

  -- ---------------- open a session (September) with validation
  perform test_helpers.login(v_acct);
  perform test_helpers.expect_msg(format('select public.create_reconciliation_session(%L, ''key-p4-rs-v1'', %L, date ''2026-09-30'', date ''2026-09-01'', 0, 100)', pt, v_rb), 'INVALID', 'the period ends before it starts');
  perform test_helpers.expect_msg(format('select public.create_reconciliation_session(%L, ''key-p4-rs-v2'', %L, date ''2026-09-01'', date ''2026-09-30'', null, 100)', pt, v_rb), 'INVALID', 'balances are required');
  perform test_helpers.expect_msg(format('select public.create_reconciliation_session(%L, ''key-p4-rs-v3'', %L, date ''2026-09-01'', date ''2026-09-30'', 0, 100.555)', pt, v_rb), 'INVALID', 'too many decimals for IDR');
  perform test_helpers.expect_msg(format('select public.create_reconciliation_session(%L, ''key-p4-rs-v4'', gen_random_uuid(), date ''2026-09-01'', date ''2026-09-30'', 0, 100)', pt), 'INVALID', 'unknown account');
  v_s := public.create_reconciliation_session(pt, 'key-p4-rs-1', v_rb, date '2026-09-01', date '2026-09-30', 0, 3397500, 'September statement');
  perform test_helpers.assert(public.create_reconciliation_session(pt, 'key-p4-rs-1', v_rb, date '2026-09-01', date '2026-09-30', 0, 3397500, 'September statement') = v_s, 'a session replays on the same key');
  perform test_helpers.expect_msg(format('select public.create_reconciliation_session(%L, ''key-p4-rs-2'', %L, date ''2026-09-01'', date ''2026-09-30'', 0, 3397500)', pt, v_rb), 'CONFLICT', 'one session at a time per account');
  perform test_helpers.assert((select status from public.reconciliation_sessions where id = v_s) = 'open', 'the session is open');

  -- ---------------- statement lines: validation, staging, idempotent re-upload
  perform test_helpers.expect_msg(format('select public.add_statement_lines(%L, ''{"date":"2026-09-03"}''::jsonb)', v_s), 'INVALID', 'lines are an array');
  perform test_helpers.expect_msg(format('select public.add_statement_lines(%L, ''[]''::jsonb)', v_s), 'INVALID', 'at least one line');
  perform test_helpers.expect_msg(format('select public.add_statement_lines(%L, ''[{"date":"2026-10-03","amount":"100"}]''::jsonb)', v_s), 'INVALID', 'a line outside the period');
  perform test_helpers.expect_msg(format('select public.add_statement_lines(%L, ''[{"date":"2026-09-03","amount":"0"}]''::jsonb)', v_s), 'INVALID', 'a zero line');
  perform test_helpers.expect_msg(format('select public.add_statement_lines(%L, ''[{"date":"2026-09-03","amount":"12.555"}]''::jsonb)', v_s), 'INVALID', 'decimals beyond IDR');
  perform test_helpers.expect_msg(format('select public.add_statement_lines(%L, ''[{"date":"2026-09-03","amount":"abc"}]''::jsonb)', v_s), 'INVALID', 'unreadable amount');
  perform test_helpers.expect_msg(format('select public.add_statement_lines(%L, ''[{"date":"not a date","amount":"5"}]''::jsonb)', v_s), 'INVALID', 'unreadable date');
  perform test_helpers.assert((select count(*) from public.statement_lines where session_id = v_s) = 0, 'a refused upload stages nothing');
  v_res := public.add_statement_lines(v_s, '[
    {"date":"2026-09-03","amount":"1000000","description":"CR TRANSFER IN","reference":"R1"},
    {"date":"2026-09-06","amount":"2000000","description":"CR TRANSFER IN 2"},
    {"date":"2026-09-10","amount":"-500000","description":"DR TRANSFER OUT"},
    {"date":"2026-09-10","amount":"-2500","description":"DR TRANSFER FEE"},
    {"date":"2026-09-16","amount":"-150000","description":"DR TRANSFER OUT 2"},
    {"date":"2026-09-23","amount":"1000000","description":"CR BATCH DEPOSIT"},
    {"date":"2026-09-25","amount":"50000","description":"CR LATE CREDIT"},
    {"date":"2026-09-03","amount":"1000000","description":"CR DUPLICATE SHOWN TWICE"}]'::jsonb);
  perform test_helpers.assert((v_res ->> 'added')::int = 8 and (v_res ->> 'skipped')::int = 0, 'eight lines staged');
  v_res := public.add_statement_lines(v_s, '[
    {"date":"2026-09-03","amount":"1000000","description":"CR TRANSFER IN","reference":"R1"},
    {"date":"2026-09-06","amount":"2000000","description":"CR TRANSFER IN 2"}]'::jsonb);
  perform test_helpers.assert((v_res ->> 'added')::int = 0 and (v_res ->> 'skipped')::int = 2, 'uploading the same statement twice adds nothing');
  v_res := public.add_statement_lines(v_s, '[
    {"date":"2026-09-11","amount":"-1000","description":"SAME FEE"},
    {"date":"2026-09-11","amount":"-1000","description":"SAME FEE"}]'::jsonb);
  perform test_helpers.assert((v_res ->> 'added')::int = 2, 'two identical lines of one upload stay distinct');
  v_res := public.add_statement_lines(v_s, '[
    {"date":"2026-09-11","amount":"-1000","description":"SAME FEE"},
    {"date":"2026-09-11","amount":"-1000","description":"SAME FEE"}]'::jsonb);
  perform test_helpers.assert((v_res ->> 'added')::int = 0 and (v_res ->> 'skipped')::int = 2, 'and re-uploading them is still idempotent');
  -- the two test-only lines are not part of the September story: drop them by discarding nothing - they are excluded below
  v_l1 := test_helpers.ln(v_s, 'CR TRANSFER IN');
  v_l2 := test_helpers.ln(v_s, 'CR TRANSFER IN 2');
  v_l3 := test_helpers.ln(v_s, 'DR TRANSFER OUT');
  v_l4 := test_helpers.ln(v_s, 'DR TRANSFER FEE');
  v_l5 := test_helpers.ln(v_s, 'DR TRANSFER OUT 2');
  v_l6 := test_helpers.ln(v_s, 'CR BATCH DEPOSIT');
  v_l7 := test_helpers.ln(v_s, 'CR LATE CREDIT');
  v_dup := test_helpers.ln(v_s, 'CR DUPLICATE SHOWN TWICE');
  perform test_helpers.expect_error(format('update public.statement_lines set amount = 5 where id = %L', v_l1), '42501', 'a browser cannot edit lines directly');
  perform test_helpers.logout();
  perform test_helpers.expect_error(format('update public.statement_lines set amount = 5 where id = %L', v_l1), '23000', 'a statement line is immutable evidence');
  perform test_helpers.login(v_acct);
  -- the same-fee lines are removed from the story with a reason
  perform public.exclude_statement_line((select id from public.statement_lines where session_id = v_s and description = 'SAME FEE' order by fingerprint limit 1), 'Test noise line one');
  perform public.exclude_statement_line((select id from public.statement_lines where session_id = v_s and description = 'SAME FEE' and not is_excluded), 'Test noise line two');

  -- ---------------- nothing is complete yet; the workspace shows what can be matched
  perform test_helpers.expect_msg(format('select public.complete_reconciliation(%L)', v_s), 'CONFLICT', 'unresolved lines block completion');
  perform test_helpers.assert(exists (select 1 from public.period_close_checks((select id from public.accounting_periods where entity_id = pt and period_start = date '2026-09-01'))
    where code = 'unresolved_statement_lines' and severity = 'warning' and item_count = 8), 'Close warns about unresolved statement lines');
  perform test_helpers.assert((select count(*) from public.reconciliation_workspace(v_s) where display_status = 'possible_match') = 6
    and (select count(*) from public.reconciliation_workspace(v_s) where display_status = 'unmatched') = 2
    and (select count(*) from public.reconciliation_workspace(v_s) where display_status = 'excluded') = 2, 'the workspace derives possible / unmatched / excluded');
  perform test_helpers.assert((select count(*) from public.reconciliation_candidates(v_l1)) = 1
    and (select movement_id from public.reconciliation_candidates(v_l1)) = test_helpers.mv(v_t1, v_rb)
    and (select day_difference from public.reconciliation_candidates(v_l2)) = 1, 'candidates: exact signed amount within the tolerance');
  perform test_helpers.assert((select count(*) from public.reconciliation_candidates(v_l7)) = 0, 'no candidate outside the tolerance');
  perform test_helpers.assert((select count(*) from public.unreconciled_movements(v_rb)) = 9, 'nine movements are not matched yet (the opening batch has none)');

  -- ---------------- matching rules
  perform test_helpers.expect_msg(format('select public.match_statement_line(%L, array[%L]::uuid[])', v_l1, test_helpers.mv(v_t2, v_rb)), 'INVALID', 'the amounts must be equal exactly');
  perform test_helpers.expect_msg(format('select public.match_statement_line(%L, array[%L]::uuid[])', v_l1, test_helpers.mv(v_t1, v_bca)), 'INVALID', 'a movement of another account cannot be matched');
  perform test_helpers.expect_msg(format('select public.match_statement_line(%L, array[]::uuid[])', v_l1), 'INVALID', 'a match needs a movement');
  perform test_helpers.expect_msg(format('select public.match_statement_line(%L, array[%L, %L]::uuid[])', v_l1, test_helpers.mv(v_t1, v_rb), test_helpers.mv(v_t1, v_rb)), 'INVALID', 'the same movement twice is refused');
  perform test_helpers.expect_msg(format('select public.match_statement_line(%L, array[%L]::uuid[])', gen_random_uuid(), test_helpers.mv(v_t1, v_rb)), 'FORBIDDEN', 'an unknown line looks like a forbidden one');
  perform test_helpers.assert(public.match_statement_line(v_l1, array[test_helpers.mv(v_t1, v_rb)]) = 1, 'one-to-one match');
  perform test_helpers.expect_msg(format('select public.match_statement_line(%L, array[%L]::uuid[])', v_l1, test_helpers.mv(v_t1, v_rb)), 'CONFLICT', 'a matched line cannot be matched again');
  perform test_helpers.expect_msg(format('select public.match_statement_line(%L, array[%L]::uuid[])', v_dup, test_helpers.mv(v_t1, v_rb)), 'CONFLICT', 'a movement clears against one line only');
  perform test_helpers.assert((select display_status from public.reconciliation_workspace(v_s) where line_id = v_l1) = 'matched'
    and (select count(*) from public.unreconciled_movements(v_rb)) = 8, 'the matched movement leaves the outstanding list');
  perform test_helpers.assert(public.match_statement_line(v_l2, array[test_helpers.mv(v_t2, v_rb)]) = 1, 'a movement one day away is inside the tolerance');
  perform test_helpers.assert(public.match_statement_line(v_l3, array[test_helpers.mv(v_t3, v_rb)]) = 1
    and public.match_statement_line(v_l4, array[test_helpers.mv(v_t3, v_rb, 'fee')]) = 1
    and public.match_statement_line(v_l5, array[test_helpers.mv(v_t4, v_rb)]) = 1, 'principal and fee match their own bank lines');
  perform test_helpers.assert(public.match_statement_line(v_l6, array[test_helpers.mv(v_t5, v_rb), test_helpers.mv(v_t6, v_rb)]) = 2, 'many movements to one bank line (batched deposit)');
  -- outside the date tolerance: only with a written manual reason
  perform test_helpers.expect_msg(format('select public.match_statement_line(%L, array[%L]::uuid[])', v_l7, test_helpers.mv(v_t8, v_rb)), 'INVALID', 'outside the tolerance needs a reason');
  perform test_helpers.expect_msg(format('select public.match_statement_line(%L, array[%L]::uuid[], ''x'')', v_l7, test_helpers.mv(v_t8, v_rb)), 'INVALID', 'a one-letter reason is not a reason');
  perform test_helpers.assert(public.match_statement_line(v_l7, array[test_helpers.mv(v_t8, v_rb)], 'Bank posted the credit late') = 1, 'a manual match with a reason');
  perform test_helpers.assert((select manual_reason from public.reconciliation_matches where statement_line_id = v_l7) = 'Bank posted the credit late', 'a manual match keeps its reason');
  perform test_helpers.assert((select count(*) from public.reconciliation_matches where statement_line_id = v_l6 and manual_reason is null) = 2, 'automatic matches carry no manual reason');

  -- exclusions
  perform test_helpers.expect_msg(format('select public.exclude_statement_line(%L, ''dup'')', v_dup), 'INVALID', 'an exclusion needs a reason');
  perform test_helpers.expect_msg(format('select public.exclude_statement_line(%L, ''Should not work'')', v_l1), 'CONFLICT', 'a matched line cannot be excluded');
  perform public.exclude_statement_line(v_dup, 'The bank listed the credit twice');
  perform test_helpers.assert((select is_excluded from public.statement_lines where id = v_dup) and (select exclusion_reason from public.statement_lines where id = v_dup) = 'The bank listed the credit twice', 'excluded with its reason');
  perform test_helpers.expect_msg(format('select public.match_statement_line(%L, array[%L]::uuid[])', v_dup, test_helpers.mv(v_t1, v_rb)), 'CONFLICT', 'an excluded line cannot be matched');
  perform public.include_statement_line(v_dup);
  perform test_helpers.assert(not (select is_excluded from public.statement_lines where id = v_dup) and (select exclusion_reason from public.statement_lines where id = v_dup) is null, 'included again');
  perform test_helpers.expect_msg(format('select public.complete_reconciliation(%L)', v_s), 'CONFLICT', 'the included duplicate blocks completion again');
  perform public.exclude_statement_line(v_dup, 'The bank listed the credit twice');

  -- unmatch and re-match
  perform test_helpers.expect_msg(format('select public.unmatch_statement_line(%L, ''no'')', v_l1), 'INVALID', 'unmatching needs a reason');
  perform test_helpers.expect_msg(format('select public.unmatch_statement_line(%L, ''Matched by mistake'')', v_dup), 'CONFLICT', 'nothing to unmatch');
  perform test_helpers.assert(public.unmatch_statement_line(v_l1, 'Matched by mistake') = 1, 'unmatch');
  perform test_helpers.expect_msg(format('select public.complete_reconciliation(%L)', v_s), 'CONFLICT', 'an unmatched line blocks completion');
  perform test_helpers.assert(public.match_statement_line(v_l1, array[test_helpers.mv(v_t1, v_rb)]) = 1, 're-match');

  -- ---------------- a matched movement is locked against reversal
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.reverse_transfer(%L, ''key-p4-rc-rv'', date ''2026-09-29'', ''Reverse a cleared transfer'')', v_t1), 'CONFLICT', 'a cleared transfer cannot be reversed');
  perform test_helpers.logout();
  perform test_helpers.login(v_acct);

  -- ---------------- what reconciliation may never do: change the books
  perform test_helpers.assert((select count(*) from public.journal_entries where entity_id = pt) = v_jn
    and (select count(*) from public.money_movements where entity_id = pt) = v_mn, 'matching neither posts nor moves money');
  perform test_helpers.assert((select count(*) from public.unreconciled_movements(v_rb)) = 1
    and (select movement_id from public.unreconciled_movements(v_rb)) = test_helpers.mv(v_t7, v_rb), 'only the deposit in transit is outstanding');

  -- ---------------- complete, evidence, reopen, complete again
  v_diff := public.complete_reconciliation(v_s);
  perform test_helpers.assert(v_diff::numeric = 0, 'no difference');
  select * into r from public.reconciliation_sessions where id = v_s;
  perform test_helpers.assert(r.status = 'reconciled' and r.system_book_balance = 3797500 and r.system_cleared_balance = 3397500
    and r.outstanding_balance = 400000 and r.difference = 0 and r.excluded_lines = 3 and r.outstanding_items = 1
    and r.accepted_difference_reason is null and r.reconciled_by = v_acct and r.reconciled_at is not null, 'the session stores its evidence');
  perform test_helpers.expect_msg(format('select public.complete_reconciliation(%L)', v_s), 'CONFLICT', 'a completed session cannot be completed again');
  perform test_helpers.expect_msg(format('select public.add_statement_lines(%L, ''[{"date":"2026-09-04","amount":"5"}]''::jsonb)', v_s), 'CONFLICT', 'no new lines after completion');
  perform test_helpers.expect_msg(format('select public.unmatch_statement_line(%L, ''Change after completion'')', v_l1), 'CONFLICT', 'no unmatching after completion');
  perform test_helpers.expect_msg(format('select public.discard_reconciliation_session(%L)', v_s), 'CONFLICT', 'a completed session cannot be discarded');
  perform test_helpers.expect_error(format('delete from public.reconciliation_sessions where id = %L', v_s), '42501', 'no direct delete');
  perform test_helpers.expect_msg(format('select public.reopen_reconciliation(%L, ''too short'')', v_s), 'INVALID', 'a reopen reason of ten characters');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  perform test_helpers.assert(public.reopen_reconciliation(v_s, 'A late bank line was found') = 'reopened', 'a finance admin can reopen with a reason');
  perform test_helpers.logout();
  perform test_helpers.login(v_acct);
  select * into r from public.reconciliation_sessions where id = v_s;
  perform test_helpers.assert(r.status = 'reopened' and r.reopen_reason = 'A late bank line was found' and r.difference is null and r.reconciled_at is null, 'reopening clears the completion evidence and keeps the reason');
  perform test_helpers.expect_msg(format('select public.reopen_reconciliation(%L, ''Reopening twice over'')', v_s), 'CONFLICT', 'only a completed session can be reopened');
  perform test_helpers.logout();
  perform test_helpers.assert(exists (select 1 from public.audit_events where entity_id = pt and target_table = 'reconciliation_sessions' and target_id = v_s and reason = 'A late bank line was found'), 'the reopening is audited with its reason');
  perform test_helpers.login(v_acct);
  perform test_helpers.assert(public.complete_reconciliation(v_s)::numeric = 0, 'completed again');
  perform test_helpers.assert((select count(*) from public.journal_entries where entity_id = pt) = v_jn
    and (select count(*) from public.money_movements where entity_id = pt) = v_mn, 'the books never moved during reconciliation');

  -- ---------------- next session: continuity, overlap, an explicit adjustment for a bank-only fee
  perform test_helpers.expect_msg(format('select public.create_reconciliation_session(%L, ''key-p4-rs-3'', %L, date ''2026-10-01'', date ''2026-10-31'', 3000000, 3391000)', pt, v_rb), 'INVALID', 'a session opens at the previous closing balance');
  perform test_helpers.expect_msg(format('select public.create_reconciliation_session(%L, ''key-p4-rs-4'', %L, date ''2026-09-15'', date ''2026-10-15'', 3397500, 3791000)', pt, v_rb), 'CONFLICT', 'periods of one account never overlap');
  v_s2 := public.create_reconciliation_session(pt, 'key-p4-rs-5', v_rb, date '2026-10-01', date '2026-10-31', 3397500, 3791000, 'October statement');
  perform public.add_statement_lines(v_s2, '[
    {"date":"2026-10-02","amount":"400000","description":"CR TRANSFER IN 3"},
    {"date":"2026-10-31","amount":"-6500","description":"DR ADMIN FEE"}]'::jsonb);
  perform test_helpers.expect_msg(format('select public.reopen_reconciliation(%L, ''Try to reopen an old month'')', v_s), 'CONFLICT', 'an earlier session cannot be reopened once a later one exists');
  perform test_helpers.assert(public.match_statement_line(test_helpers.ln(v_s2, 'CR TRANSFER IN 3'), array[test_helpers.mv(v_t7, v_rb)]) = 1, 'the deposit in transit clears in the next statement');
  perform test_helpers.assert((select count(*) from public.reconciliation_candidates(test_helpers.ln(v_s2, 'DR ADMIN FEE'))) = 0, 'a bank fee has no movement yet');
  v_adj := public.record_balance_adjustment(pt, 'key-p4-rc-adj', v_rb, 'out', 6500, null, date '2026-10-31', test_helpers.acct(pt, 'BANK_FEE_EXPENSE'), 'Monthly bank admin fee per statement');
  perform test_helpers.assert((select movement_id from public.reconciliation_candidates(test_helpers.ln(v_s2, 'DR ADMIN FEE'))) = v_adj, 'the explicit adjustment becomes the candidate');
  perform test_helpers.assert(public.match_statement_line(test_helpers.ln(v_s2, 'DR ADMIN FEE'), array[v_adj]) = 1, 'and clears the fee');
  perform test_helpers.assert(public.complete_reconciliation(v_s2)::numeric = 0, 'October completes without difference');
  select * into r from public.reconciliation_sessions where id = v_s2;
  perform test_helpers.assert(r.system_cleared_balance = 3791000 and r.system_book_balance = 3791000 and r.outstanding_items = 0, 'October evidence');

  -- ---------------- a difference is never absorbed silently
  v_ds := public.create_reconciliation_session(pt, 'key-p4-rs-d1', v_db, date '2026-09-01', date '2026-09-30', 0, 555555);
  perform public.add_statement_lines(v_ds, '[{"date":"2026-09-05","amount":"100000","description":"CR FUNDING"}]'::jsonb);
  perform public.match_statement_line(test_helpers.ln(v_ds, 'CR FUNDING'), array[test_helpers.mv(v_td, v_db)]);
  perform test_helpers.expect_msg(format('select public.complete_reconciliation(%L)', v_ds), 'CONFLICT', 'lines that do not explain the statement movement block completion');
  perform public.discard_reconciliation_session(v_ds);
  perform test_helpers.assert(not exists (select 1 from public.statement_lines where session_id = v_ds)
    and not exists (select 1 from public.reconciliation_matches where session_id = v_ds), 'discarding removes the lines and matches');
  perform test_helpers.assert(exists (select 1 from public.money_movements where id = test_helpers.mv(v_td, v_db)) and (select count(*) from public.unreconciled_movements(v_db)) = 1, 'the movement is untouched and outstanding again');
  v_ds2 := public.create_reconciliation_session(pt, 'key-p4-rs-d2', v_db, date '2026-09-01', date '2026-09-30', 1000, 101000);
  perform public.add_statement_lines(v_ds2, '[{"date":"2026-09-05","amount":"100000","description":"CR FUNDING"}]'::jsonb);
  perform public.match_statement_line(test_helpers.ln(v_ds2, 'CR FUNDING'), array[test_helpers.mv(v_td, v_db)]);
  perform test_helpers.expect_msg(format('select public.complete_reconciliation(%L)', v_ds2), 'INVALID', 'a difference needs an explicit decision');
  perform test_helpers.expect_msg(format('select public.complete_reconciliation(%L, ''too short'')', v_ds2), 'INVALID', 'and a reason of ten characters');
  perform test_helpers.assert(public.complete_reconciliation(v_ds2, 'Statement opening balance predates the system')::numeric = 1000, 'accepted with a reason');
  select * into r from public.reconciliation_sessions where id = v_ds2;
  perform test_helpers.assert(r.difference = 1000 and r.accepted_difference_reason = 'Statement opening balance predates the system'
    and r.system_cleared_balance = 100000 and r.status = 'reconciled', 'the accepted difference and its reason are stored');
  perform test_helpers.assert(not exists (select 1 from test_helpers.mc(pt) where ledger_balance <> movement_base_balance), 'accepting a difference leaves ledger and money layer untouched');
  perform test_helpers.logout();

  -- ---------------- status report and Close checks
  perform test_helpers.login(v_viewer);
  select * into r from public.reconciliation_status(pt) where name = 'Recon Bank';
  perform test_helpers.assert(r.last_reconciled_until = date '2026-10-31' and r.last_statement_closing::numeric = 3791000 and not r.session_in_progress
    and r.unresolved_lines = 0 and r.outstanding_movements = 0 and r.last_difference::numeric = 0, 'status of the reconciled account');
  select * into r from public.reconciliation_status(pt) where name = 'Diff Bank';
  perform test_helpers.assert(r.last_difference::numeric = 1000 and r.last_reconciled_until = date '2026-09-30', 'status shows the accepted difference');
  select * into r from public.reconciliation_status(pt) where name = 'BCA Main';
  perform test_helpers.assert(r.last_reconciled_until is null and r.outstanding_movements > 0, 'an account never reconciled says so');
  perform test_helpers.assert(exists (select 1 from public.period_close_checks((select id from public.accounting_periods where entity_id = pt and period_start = date '2026-09-01'))
    where code = 'account_not_reconciled' and severity = 'warning' and item_count >= 1), 'Close warns about accounts that are not reconciled');
  perform test_helpers.assert(not exists (select 1 from public.period_close_checks((select id from public.accounting_periods where entity_id = pt and period_start = date '2026-09-01'))
    where code in ('unresolved_statement_lines', 'money_ledger_mismatch')), 'no unresolved lines and no mismatch remain');
  -- visibility follows money.view
  perform test_helpers.assert((select count(*) from public.reconciliation_sessions where entity_id = pt) = 3
    and (select count(*) from public.statement_lines where entity_id = pt) > 0
    and (select count(*) from public.reconciliation_matches where entity_id = pt) > 0, 'a viewer can read the reconciliation records');
  perform test_helpers.expect_msg(format('select public.match_statement_line(%L, array[%L]::uuid[])', v_l1, test_helpers.mv(v_t1, v_rb)), 'FORBIDDEN', 'a viewer cannot match');
  perform test_helpers.expect_msg(format('select public.add_statement_lines(%L, ''[{"date":"2026-10-04","amount":"5"}]''::jsonb)', v_s2), 'FORBIDDEN', 'a viewer cannot stage lines');
  perform test_helpers.expect_error(format('insert into public.reconciliation_matches (entity_id, session_id, statement_line_id, movement_id) values (%L, %L, %L, %L)', pt, v_s, v_l1, test_helpers.mv(v_t2, v_rb)), '42501', 'no direct writes to matches');
  perform test_helpers.logout();
  perform test_helpers.login(v_nobody);
  perform test_helpers.assert((select count(*) from public.reconciliation_sessions where entity_id = pt) = 0
    and (select count(*) from public.statement_lines where entity_id = pt) = 0
    and (select count(*) from public.reconciliation_matches where entity_id = pt) = 0, 'a stranger sees nothing');
  perform test_helpers.expect_msg(format('select * from public.reconciliation_workspace(%L)', v_s), 'FORBIDDEN', 'a stranger has no workspace');
  perform test_helpers.expect_msg(format('select * from public.reconciliation_status(%L)', pt), 'FORBIDDEN', 'a stranger has no status');
  perform test_helpers.logout();

  -- the audit trail records every step of a session, never the statement's bank account number
  perform test_helpers.assert((select count(*) from public.audit_events where target_table = 'reconciliation_matches' and entity_id = pt and action = 'reconciliation_matches.delete') >= 1
    and (select count(*) from public.audit_events where target_table = 'statement_lines' and entity_id = pt and action = 'statement_lines.update') >= 4, 'matches, unmatches and exclusions are audited');
end
$$;

-- ================================================================ 7. gate property test (Step 16 G4)
-- A seeded random mix of same-currency and cross-currency transfers with fees, and reversals. After every run
-- the money layer equals the ledger, the books balance, transfers created no revenue, the profit and loss moved
-- by exactly the fees and FX differences of the transfers still in force, and the numbers have no gaps.
do $$
declare
  v_owner uuid := 'b0000000-0000-0000-0000-000000000001';
  v_acct uuid := 'b0000000-0000-0000-0000-000000000006';
  g uuid;
  v_a uuid; v_b uuid; v_c uuid;
  v_i integer;
  v_r double precision;
  v_from uuid; v_to uuid;
  v_amt numeric; v_in numeric; v_fee numeric; v_rout numeric; v_rin numeric;
  v_date date;
  v_t uuid;
  v_pl_before numeric;
  v_pl_after numeric;
  v_expected numeric;
  v_created integer := 0;
  v_reversed integer := 0;
  v_idr_usd integer := 0;
  v_usd_idr integer := 0;
  v_exp_a numeric; v_exp_b numeric; v_exp_c numeric;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p4_gate', 'P4 GATE (synthetic)') returning id into g;
  perform app_private.provision_default_coa(g);
  perform test_helpers.mk_member(g, v_owner, 'owner');
  perform test_helpers.mk_member(g, v_acct, 'accountant');

  perform test_helpers.login(v_owner);
  v_a := public.create_financial_account(g, 'key-gate-a', 'bank', 'Gate A', 'IDR');
  v_b := public.create_financial_account(g, 'key-gate-b', 'bank', 'Gate B', 'IDR');
  v_c := public.create_financial_account(g, 'key-gate-c', 'bank', 'Gate C', 'USD');
  perform test_helpers.logout();
  perform test_helpers.login(v_acct);
  perform public.record_balance_adjustment(g, 'key-gate-f1', v_a, 'in', 2000000000, null, date '2026-11-01', test_helpers.acct(g, 'INTEREST_INCOME'), 'Synthetic starting funds A');
  perform public.record_balance_adjustment(g, 'key-gate-f2', v_b, 'in', 1000000000, null, date '2026-11-01', test_helpers.acct(g, 'INTEREST_INCOME'), 'Synthetic starting funds B');
  perform public.record_balance_adjustment(g, 'key-gate-f3', v_c, 'in', 50000, 16000, date '2026-11-01', test_helpers.acct(g, 'INTEREST_INCOME'), 'Synthetic starting funds C');
  perform test_helpers.logout();

  select coalesce(sum(l.credit - l.debit), 0) into v_pl_before
  from public.journal_lines l join public.journal_entries j on j.id = l.journal_id and j.status = 'posted'
  join public.ledger_accounts a on a.id = l.ledger_account_id
  where j.entity_id = g and a.account_class not in ('asset', 'liability', 'equity');

  perform setseed(0.271828);
  perform test_helpers.login(v_owner);
  for v_i in 1 .. 90 loop
    v_r := random();
    if v_r < 0.2 and exists (select 1 from public.transfers where entity_id = g and status = 'confirmed') then
      select id into v_t from public.transfers where entity_id = g and status = 'confirmed' order by md5(id::text || v_i::text) limit 1;
      perform public.reverse_transfer(v_t, 'key-gate-r-' || v_i, date '2026-11-30', 'Randomised reversal in the gate test');
      v_reversed := v_reversed + 1;
      continue;
    end if;
    v_date := date '2026-11-01' + floor(random() * 28)::integer;
    v_fee := 0; v_rout := null; v_rin := null; v_in := null;
    if v_r < 0.6 then
      -- same currency
      if random() < 0.5 then v_from := v_a; v_to := v_b; else v_from := v_b; v_to := v_a; end if;
      v_amt := 1 + floor(random() * 5000000);
      v_fee := floor(random() * 3) * 2500;
    elsif v_r < 0.8 then
      -- IDR -> USD
      v_from := case when random() < 0.5 then v_a else v_b end; v_to := v_c;
      v_amt := 1000000 + floor(random() * 49000000);
      v_in := round(v_amt / 16000, 2);
      v_rin := round((16000 * (0.97 + random() * 0.06))::numeric, 4);
      v_fee := floor(random() * 3) * 2500;
      v_idr_usd := v_idr_usd + 1;
    else
      -- USD -> IDR
      v_from := v_c; v_to := case when random() < 0.5 then v_a else v_b end;
      v_amt := round((10 + random() * 490)::numeric, 2);
      v_rout := round((16000 * (0.97 + random() * 0.06))::numeric, 4);
      v_in := round(v_amt * 16000, 0);
      v_fee := case when random() < 0.5 then 0 else 1.5 end;
      v_usd_idr := v_usd_idr + 1;
    end if;
    perform public.create_transfer(g, 'key-gate-t-' || v_i, v_from, v_to, v_date, v_amt, v_in, v_fee, v_rout, v_rin, 'Randomised transfer ' || v_i, null, true);
    v_created := v_created + 1;
  end loop;
  perform test_helpers.logout();

  perform test_helpers.assert(v_created >= 40 and v_reversed >= 8 and v_idr_usd >= 5 and v_usd_idr >= 5, 'the random run exercised every kind of transfer and reversals');

  -- 1. the money layer equals the General Ledger for every account
  perform test_helpers.assert(not exists (select 1 from test_helpers.mc(g) where ledger_balance <> movement_base_balance), 'gate: money movements equal the ledger control accounts');
  -- 2. the books balance
  perform test_helpers.assert((select coalesce(sum(l.debit), 0) - coalesce(sum(l.credit), 0)
                               from public.journal_lines l join public.journal_entries j on j.id = l.journal_id where j.entity_id = g and j.status = 'posted') = 0, 'gate: the trial balance balances');
  -- 3. balances follow the transfers exactly (independent recomputation from the transfer records)
  select 2000000000 + coalesce(sum(case when t.to_account_id = v_a then t.amount_in else 0 end - case when t.from_account_id = v_a then t.amount_out + t.fee_amount else 0 end), 0)
    into v_exp_a from public.transfers t where t.entity_id = g and t.status = 'confirmed';
  select 1000000000 + coalesce(sum(case when t.to_account_id = v_b then t.amount_in else 0 end - case when t.from_account_id = v_b then t.amount_out + t.fee_amount else 0 end), 0)
    into v_exp_b from public.transfers t where t.entity_id = g and t.status = 'confirmed';
  select 50000 + coalesce(sum(case when t.to_account_id = v_c then t.amount_in else 0 end - case when t.from_account_id = v_c then t.amount_out + t.fee_amount else 0 end), 0)
    into v_exp_c from public.transfers t where t.entity_id = g and t.status = 'confirmed';
  perform test_helpers.assert((select movement_balance from test_helpers.mc(g) where financial_account_id = v_a) = v_exp_a
    and (select movement_balance from test_helpers.mc(g) where financial_account_id = v_b) = v_exp_b
    and (select movement_balance from test_helpers.mc(g) where financial_account_id = v_c) = v_exp_c, 'gate: every balance equals funding plus the transfers still in force');
  -- 4. transfers created no revenue and no expense except fees and FX differences
  perform test_helpers.assert(not exists (
    select 1 from public.journal_lines l join public.journal_entries j on j.id = l.journal_id
    join public.ledger_accounts a on a.id = l.ledger_account_id
    where j.entity_id = g and j.source_type = 'transfer'
      and a.system_key is distinct from 'BANK_FEE_EXPENSE' and a.system_key is distinct from 'FX_GAIN_LOSS'
      and not exists (select 1 from public.financial_accounts f where f.ledger_account_id = a.id)), 'gate: a transfer journal touches only cash accounts, the fee expense and the FX account');
  perform test_helpers.assert(not exists (
    select 1 from public.journal_lines l join public.journal_entries j on j.id = l.journal_id
    join public.ledger_accounts a on a.id = l.ledger_account_id
    where j.entity_id = g and j.source_type = 'transfer' and a.account_class in ('revenue', 'other_income')), 'gate: no revenue is ever recognised by a transfer');
  -- 5. the profit and loss moved by exactly the fees and FX differences of the transfers still in force
  select coalesce(sum(l.credit - l.debit), 0) into v_pl_after
  from public.journal_lines l join public.journal_entries j on j.id = l.journal_id and j.status = 'posted'
  join public.ledger_accounts a on a.id = l.ledger_account_id
  where j.entity_id = g and a.account_class not in ('asset', 'liability', 'equity');
  select coalesce(sum(t.fx_difference - t.base_fee), 0) into v_expected from public.transfers t where t.entity_id = g and t.status = 'confirmed';
  perform test_helpers.assert(v_pl_after - v_pl_before = v_expected, 'gate: net profit changed by fees and FX differences only');
  -- 6. every original movement of a reversed transfer has exactly one mirror, and its nets are zero
  perform test_helpers.assert(not exists (
    select 1 from public.money_movements m where m.entity_id = g and m.reverses_movement_id is null
      and exists (select 1 from public.transfers t where t.id = m.source_id and t.status = 'reversed')
      and (select count(*) from public.money_movements x where x.reverses_movement_id = m.id) <> 1), 'gate: reversed transfers are mirrored exactly once');
  perform test_helpers.assert((select count(*) from public.money_movements m where m.entity_id = g and m.reverses_movement_id is null and m.source_type = 'transfer'
      and exists (select 1 from public.transfers t where t.id = m.source_id and t.status = 'confirmed')
      and exists (select 1 from public.money_movements x where x.reverses_movement_id = m.id)) = 0, 'gate: a confirmed transfer has no mirror');
  -- 7. transfer numbers are unique and gapless
  perform test_helpers.assert((select count(*) from public.transfers where entity_id = g and transfer_number is not null) = v_created
    and (select count(distinct transfer_number) from public.transfers where entity_id = g and transfer_number is not null) = v_created
    and (select max(right(transfer_number, 4)::integer) from public.transfers where entity_id = g) = v_created
    and (select min(right(transfer_number, 4)::integer) from public.transfers where entity_id = g) = 1, 'gate: transfer numbers are gapless');
  -- 8. reversal journals reverse their originals line by line
  perform test_helpers.assert(not exists (
    select 1 from public.transfers t
    where t.entity_id = g and t.status = 'reversed'
      and (select coalesce(sum(l.debit - l.credit), 0) from public.journal_lines l where l.journal_id in (t.journal_id, t.reversal_journal_id)) <> 0), 'gate: original plus reversal nets to zero');
end
$$;

-- ================================================================ 8. independent-review regressions
-- Each block reproduces a defect found by the independent review of this phase and proves it stays fixed.
do $$
declare
  v_owner uuid := 'b0000000-0000-0000-0000-000000000001';
  v_acct uuid := 'b0000000-0000-0000-0000-000000000006';
  e uuid;
  v_e1 uuid; v_e2 uuid; v_u1 uuid; v_u2 uuid;
  v_period uuid;
  v_t uuid;
  v_tf uuid;
  v_adj_out uuid; v_adj_in uuid; v_adj1 uuid; v_adj_oct uuid;
  v_s1 uuid; v_s2 uuid; v_s3 uuid; v_sx uuid;
  v_j uuid;
  r record;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p4_edge', 'P4 EDGE (synthetic)') returning id into e;
  perform app_private.provision_default_coa(e);
  perform test_helpers.mk_member(e, v_owner, 'owner');
  perform test_helpers.mk_member(e, v_acct, 'accountant');

  -- (1) a ledger account that already carries postings cannot be adopted by the money layer
  v_j := app_private.post_system_journal(e, 'raw_event', gen_random_uuid(), 'raw.rule', 'v1', date '2026-09-21', 'Posting before the money layer',
    jsonb_build_array(jsonb_build_object('account_key', 'BANK_OPERATING', 'debit', 5000), jsonb_build_object('account_key', 'OTHER_OPERATING_REVENUE', 'credit', 5000)));
  select id into v_period from public.accounting_periods where entity_id = e and period_start = date '2026-09-01';
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.create_financial_account(%L, ''key-edge-map-1'', ''bank'', ''Adopt'', ''IDR'', %L)', e, test_helpers.acct(e, 'BANK_OPERATING')),
    'CONFLICT', 'a ledger account with postings cannot be mapped');
  perform test_helpers.logout();
  perform test_helpers.login(v_acct);
  perform test_helpers.assert(exists (select 1 from public.period_close_checks(v_period) where code = 'unmapped_cash_account' and severity = 'warning' and item_count = 1),
    'Close warns about a cash ledger account the money layer cannot see');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  v_e1 := public.create_financial_account(e, 'key-edge-a-1', 'bank', 'Edge One', 'IDR');
  v_e2 := public.create_financial_account(e, 'key-edge-a-2', 'bank', 'Edge Two', 'IDR');
  v_u1 := public.create_financial_account(e, 'key-edge-a-3', 'bank', 'Edge USD One', 'USD');
  v_u2 := public.create_financial_account(e, 'key-edge-a-4', 'bank', 'Edge USD Two', 'USD');
  perform test_helpers.logout();
  perform test_helpers.login(v_acct);
  v_adj1 := public.record_balance_adjustment(e, 'key-edge-f-1', v_e1, 'in', 1000000, null, date '2026-09-05', test_helpers.acct(e, 'INTEREST_INCOME'), 'Synthetic starting funds');
  perform test_helpers.logout();

  -- (2) the hard negative-balance block also stops a reversal that would overdraw the account
  insert into public.entity_settings (entity_id, setting_key, setting_value) values (e, 'money.block_negative_balance', '["bank"]'::jsonb);
  perform test_helpers.login(v_owner);
  v_t := public.create_transfer(e, 'key-edge-t-1', v_e1, v_e2, date '2026-09-06', 1000000, null, 0, null, null, 'Move to Edge Two', null, true);
  perform test_helpers.logout();
  perform test_helpers.login(v_acct);
  v_adj_out := public.record_balance_adjustment(e, 'key-edge-f-2', v_e2, 'out', 900000, null, date '2026-09-07', test_helpers.acct(e, 'BANK_FEE_EXPENSE'), 'Synthetic spending from Edge Two');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.reverse_transfer(%L, ''key-edge-r-1'', date ''2026-09-08'', ''Reverse the funding'')', v_t), 'CONFLICT', 'a reversal cannot overdraw a blocked account');
  perform test_helpers.logout();
  perform test_helpers.login(v_acct);
  v_adj_in := public.record_balance_adjustment(e, 'key-edge-f-3', v_e2, 'in', 900000, null, date '2026-09-09', test_helpers.acct(e, 'INTEREST_INCOME'), 'Synthetic top-up of Edge Two');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform public.reverse_transfer(v_t, 'key-edge-r-2', date '2026-09-10', 'Reverse the funding');
  perform test_helpers.logout();
  delete from public.entity_settings where entity_id = e and setting_key = 'money.block_negative_balance';
  perform test_helpers.assert((select movement_balance from test_helpers.mc(e) where financial_account_id = v_e1) = 1000000
    and (select movement_balance from test_helpers.mc(e) where financial_account_id = v_e2) = 0, 'the reversal went through once the money was there');

  -- (3) one exchange rate for a transfer between two accounts of the same foreign currency
  perform test_helpers.login(v_acct);
  perform public.record_balance_adjustment(e, 'key-edge-f-4', v_u1, 'in', 1000, 16000, date '2026-09-11', test_helpers.acct(e, 'INTEREST_INCOME'), 'Synthetic USD funds');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-edge-t-2'', %L, %L, date ''2026-09-12'', 100, null, 0, 16000, 19000, ''USD move'', null, true)', e, v_u1, v_u2),
    'INVALID', 'two rates for one foreign currency would invent an exchange gain');
  v_tf := public.create_transfer(e, 'key-edge-t-3', v_u1, v_u2, date '2026-09-12', 100, null, 0, 16000, 16000, 'USD move', null, true);
  perform test_helpers.logout();
  perform test_helpers.assert((select fx_difference from public.transfers where id = v_tf) = 0
    and not exists (select 1 from public.journal_lines l where l.journal_id = (select journal_id from public.transfers where id = v_tf) and l.ledger_account_id = test_helpers.acct(e, 'FX_GAIN_LOSS')),
    'the same rate on both sides books no exchange difference');

  -- (4) a reversed movement and its mirror never appear on a bank statement or in the outstanding list
  perform test_helpers.login(v_acct);
  perform test_helpers.assert((select count(*) from public.unreconciled_movements(v_e2)) = 2, 'only the two real movements are outstanding; the reversed pair is not');
  v_s1 := public.create_reconciliation_session(e, 'key-edge-s-1', v_e2, date '2026-09-01', date '2026-09-30', 0, 0);
  perform public.add_statement_lines(v_s1, '[
    {"date":"2026-09-07","amount":"-900000","description":"EDGE OUT"},
    {"date":"2026-09-09","amount":"900000","description":"EDGE IN"}]'::jsonb);
  perform test_helpers.expect_msg(format('select public.match_statement_line(%L, array[%L]::uuid[])', test_helpers.ln(v_s1, 'EDGE IN'), test_helpers.mv(v_t, v_e2)),
    'INVALID', 'the reversed original cannot be matched');
  perform test_helpers.expect_msg(format('select public.match_statement_line(%L, array[%L]::uuid[])', test_helpers.ln(v_s1, 'EDGE OUT'), (select id from public.money_movements where reverses_movement_id = test_helpers.mv(v_t, v_e2))),
    'INVALID', 'the reversal itself cannot be matched');
  perform test_helpers.assert(public.match_statement_line(test_helpers.ln(v_s1, 'EDGE OUT'), array[v_adj_out]) = 1
    and public.match_statement_line(test_helpers.ln(v_s1, 'EDGE IN'), array[v_adj_in]) = 1, 'the real movements match');
  perform test_helpers.assert(public.complete_reconciliation(v_s1)::numeric = 0, 'and the session completes');
  select * into r from public.reconciliation_sessions where id = v_s1;
  perform test_helpers.assert(r.outstanding_items = 0 and r.system_book_balance = 0 and r.system_cleared_balance = 0, 'the reversed pair is not an outstanding item');

  -- (5) a later completed session locks the earlier one; discarding the reopened later one unlocks it
  v_s2 := public.create_reconciliation_session(e, 'key-edge-s-2', v_e2, date '2026-10-01', date '2026-10-31', 0, 0);
  perform test_helpers.assert(public.complete_reconciliation(v_s2)::numeric = 0, 'an October session with no lines and no movement completes');
  perform test_helpers.expect_msg(format('select public.reopen_reconciliation(%L, ''Fix a wrong September match'')', v_s1), 'CONFLICT', 'a later completed session blocks the reopening');
  perform public.reopen_reconciliation(v_s2, 'Unlock September for a fix');
  perform test_helpers.expect_msg(format('select public.reopen_reconciliation(%L, ''Fix a wrong September match'')', v_s1), 'CONFLICT', 'only one session is in progress at a time');
  perform public.discard_reconciliation_session(v_s2);
  perform test_helpers.assert(not exists (select 1 from public.reconciliation_sessions where id = v_s2), 'the reopened later session is discarded');
  perform public.reopen_reconciliation(v_s1, 'Fix a wrong September match');
  perform test_helpers.assert(public.unmatch_statement_line(test_helpers.ln(v_s1, 'EDGE IN'), 'Matched to the wrong movement') = 1, 'the earlier session can be corrected now');
  perform public.match_statement_line(test_helpers.ln(v_s1, 'EDGE IN'), array[v_adj_in]);
  perform test_helpers.assert(public.complete_reconciliation(v_s1)::numeric = 0, 'and completed again');
  -- a discarded session's key does not silently hand back a dead id
  perform test_helpers.expect_msg(format('select public.create_reconciliation_session(%L, ''key-edge-s-2'', %L, date ''2026-10-01'', date ''2026-10-31'', 0, 0)', e, v_e2), 'CONFLICT', 'a discarded session is not replayed');

  -- (6) a movement booked a few days after the statement's period still clears a line inside it
  v_adj_oct := public.record_balance_adjustment(e, 'key-edge-f-5', v_e1, 'in', 500000, null, date '2026-10-02', test_helpers.acct(e, 'INTEREST_INCOME'), 'Synthetic late booking');
  v_s3 := public.create_reconciliation_session(e, 'key-edge-s-3', v_e1, date '2026-09-01', date '2026-09-30', 0, 1500000);
  perform public.add_statement_lines(v_s3, '[
    {"date":"2026-09-05","amount":"1000000","description":"EDGE FUNDS"},
    {"date":"2026-09-30","amount":"500000","description":"EDGE LATE"}]'::jsonb);
  perform public.match_statement_line(test_helpers.ln(v_s3, 'EDGE FUNDS'), array[v_adj1]);
  perform public.match_statement_line(test_helpers.ln(v_s3, 'EDGE LATE'), array[v_adj_oct]);
  perform test_helpers.assert(public.complete_reconciliation(v_s3)::numeric = 0, 'no false difference for a movement dated after the period end');
  select * into r from public.reconciliation_sessions where id = v_s3;
  perform test_helpers.assert(r.system_cleared_balance = 1500000 and r.system_book_balance = 1000000 and r.outstanding_balance = -500000, 'the evidence shows the bank ahead of the books');

  -- (7) something booked inside a reconciled window afterwards makes its evidence stale
  perform test_helpers.assert(not exists (select 1 from public.period_close_checks(v_period) where code = 'reconciliation_stale'), 'nothing is stale yet');
  perform public.record_balance_adjustment(e, 'key-edge-f-6', v_e1, 'in', 100000, null, date '2026-09-15', test_helpers.acct(e, 'INTEREST_INCOME'), 'Synthetic backdated booking');
  perform test_helpers.assert(exists (select 1 from public.period_close_checks(v_period) where code = 'reconciliation_stale' and severity = 'warning' and item_count = 1), 'Close warns that a completed reconciliation is stale');
  perform test_helpers.logout();
end
$$;

rollback;
