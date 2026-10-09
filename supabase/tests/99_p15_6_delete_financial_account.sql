-- P15: "Hapus Rekening" (delete_financial_account). An account with no history can be deleted; one with a movement,
-- a journal line or another record pointing at it cannot, and only roles that may manage accounts can try.
-- All data is synthetic. The whole file runs in one transaction that is rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  v_pt uuid;
begin
  insert into public.entities (entity_type, code, legal_name)
  values ('company', 'p156_pt', 'P15-6 PT (synthetic)') returning id into v_pt;
  perform app_private.provision_default_coa(v_pt);
  perform test_helpers.mk_user('b0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_user('b0000000-0000-0000-0000-000000000004', 'viewer');
  perform test_helpers.mk_user('b0000000-0000-0000-0000-000000000008', 'staff');
  perform test_helpers.mk_member(v_pt, 'b0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pt, 'b0000000-0000-0000-0000-000000000004', 'viewer_auditor');
  perform test_helpers.mk_member(v_pt, 'b0000000-0000-0000-0000-000000000008', 'finance_staff');
end
$$;

do $$
declare
  pt uuid := test_helpers.entity('p156_pt');
  v_owner uuid := 'b0000000-0000-0000-0000-000000000001';
  v_viewer uuid := 'b0000000-0000-0000-0000-000000000004';
  v_staff uuid := 'b0000000-0000-0000-0000-000000000008';
  v_empty uuid;
  v_used uuid;
  v_mapped uuid;
  v_ledger uuid;
begin
  perform test_helpers.login(v_owner);
  v_empty := public.create_financial_account(pt, 'key-del-0001', 'bank', 'Mandiri Salah Input', 'IDR');
  v_used := public.create_financial_account(pt, 'key-del-0002', 'bank', 'Bank Dipakai', 'IDR');
  v_mapped := public.create_financial_account(pt, 'key-del-0003', 'bank', 'Dipetakan Manual', 'IDR',
    test_helpers.acct(pt, 'BANK_OPERATING'));
  select ledger_account_id into v_ledger from public.financial_accounts where id = v_empty;
  perform test_helpers.logout();

  -- a stranger or a role without account management cannot delete
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.delete_financial_account(%L)', v_empty), 'FORBIDDEN', 'viewer cannot delete');
  perform test_helpers.logout();
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.delete_financial_account(%L)', v_empty), 'FORBIDDEN', 'staff cannot delete');
  perform test_helpers.logout();

  -- an account that has received a movement cannot be deleted
  perform test_helpers.login(v_owner);
  perform public.record_balance_adjustment(pt, 'key-del-adj-1', v_used, 'in', 1000, null, date '2026-09-30',
    test_helpers.acct(pt, 'BANK_FEE_EXPENSE'), 'Bunga bank uji hapus rekening');
  perform test_helpers.expect_msg(format('select public.delete_financial_account(%L)', v_used), 'CONFLICT', 'an account with movements cannot be deleted');
  perform test_helpers.assert(exists (select 1 from public.financial_accounts where id = v_used), 'the used account is still there');

  -- an empty account is deleted and its own ledger account is switched off
  perform test_helpers.assert(public.delete_financial_account(v_empty, 'salah input') = true, 'an empty account is deleted');
  perform test_helpers.assert(not exists (select 1 from public.financial_accounts where id = v_empty), 'the account row is gone');
  perform test_helpers.assert((select status from public.ledger_accounts where id = v_ledger) = 'inactive', 'its ledger account is inactive');
  perform test_helpers.expect_msg(format('select public.delete_financial_account(%L)', v_empty), 'FORBIDDEN', 'a deleted account cannot be deleted again');

  -- a default control account mapped by hand stays active after the delete
  perform test_helpers.assert(public.delete_financial_account(v_mapped) = true, 'a hand-mapped empty account is deleted');
  perform test_helpers.assert((select status from public.ledger_accounts where id = test_helpers.acct(pt, 'BANK_OPERATING')) = 'active', 'the default bank ledger account stays active');
  perform test_helpers.logout();
end
$$;

rollback;
