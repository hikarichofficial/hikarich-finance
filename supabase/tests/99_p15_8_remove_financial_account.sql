-- P15: "Hapus Rekening" for an account with transactions (remove_financial_account): an account with history is
-- archived (hidden from the list, ledger and movements untouched, same name reusable); one without is erased.
-- All data is synthetic. The whole file runs in one transaction that is rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  v_pt uuid;
begin
  insert into public.entities (entity_type, code, legal_name)
  values ('company', 'p158_pt', 'P15-8 PT (synthetic)') returning id into v_pt;
  perform app_private.provision_default_coa(v_pt);
  perform test_helpers.mk_user('b0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_user('b0000000-0000-0000-0000-000000000008', 'staff');
  perform test_helpers.mk_member(v_pt, 'b0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pt, 'b0000000-0000-0000-0000-000000000008', 'finance_staff');
end
$$;

do $$
declare
  pt uuid := test_helpers.entity('p158_pt');
  v_owner uuid := 'b0000000-0000-0000-0000-000000000001';
  v_staff uuid := 'b0000000-0000-0000-0000-000000000008';
  v_empty uuid;
  v_used uuid;
  v_new uuid;
  v_ledger uuid;
  v_moves integer;
  v_lines integer;
begin
  perform test_helpers.login(v_owner);
  v_empty := public.create_financial_account(pt, 'key-rm-0001', 'bank', 'Rekening Kosong', 'IDR');
  v_used := public.create_financial_account(pt, 'key-rm-0002', 'bank', 'BCA Uji', 'IDR');
  select ledger_account_id into v_ledger from public.financial_accounts where id = v_used;
  perform public.record_balance_adjustment(pt, 'key-rm-adj-1', v_used, 'in', 5000, null, date '2026-09-30',
    test_helpers.acct(pt, 'BANK_FEE_EXPENSE'), 'Saldo uji hapus rekening');
  select count(*) into v_moves from public.money_movements where financial_account_id = v_used;
  select count(*) into v_lines from public.journal_lines where ledger_account_id = v_ledger;
  perform test_helpers.logout();

  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.remove_financial_account(%L)', v_used), 'FORBIDDEN', 'staff cannot remove');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  -- no history: really erased
  perform test_helpers.assert(public.remove_financial_account(v_empty, 'salah input') = 'deleted', 'an empty account is deleted');
  perform test_helpers.logout();
  perform test_helpers.assert(not exists (select 1 from public.financial_accounts where id = v_empty), 'the empty account row is gone');
  perform test_helpers.login(v_owner);

  -- with history (and a balance): archived, not erased
  perform test_helpers.assert(public.remove_financial_account(v_used, 'rekening ditutup') = 'archived', 'an account with history is archived');
  perform test_helpers.logout();
  perform test_helpers.assert(exists (select 1 from public.financial_accounts where id = v_used and deleted_at is not null and not is_active), 'the row stays, marked deleted and inactive');
  perform test_helpers.login(v_owner);
  perform test_helpers.logout();
  perform test_helpers.assert((select count(*) from public.money_movements where financial_account_id = v_used) = v_moves, 'money movements are untouched');
  perform test_helpers.login(v_owner);
  perform test_helpers.logout();
  perform test_helpers.assert((select count(*) from public.journal_lines where ledger_account_id = v_ledger) = v_lines, 'journal lines are untouched');
  perform test_helpers.login(v_owner);
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.ledger_accounts where id = v_ledger) = 'active', 'its ledger account stays active');
  perform test_helpers.login(v_owner);
  perform test_helpers.assert(not exists (select 1 from public.money_control(pt) where financial_account_id = v_used), 'it no longer shows in the account list');
  perform test_helpers.logout();
  perform test_helpers.assert(exists (select 1 from app_private.money_control_rows(pt) where financial_account_id = v_used), 'period close still sees it');
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.remove_financial_account(%L)', v_used), 'FORBIDDEN', 'it cannot be removed twice');

  -- the same name can be used again
  v_new := public.create_financial_account(pt, 'key-rm-0003', 'bank', 'BCA Uji', 'IDR');
  perform test_helpers.assert(v_new is not null, 'the name can be reused');
  perform test_helpers.logout();
end
$$;

rollback;
