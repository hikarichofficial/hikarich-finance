-- Decision 326: the "Rekening Koran" monthly cash/bank statement (cash_statement). Hand-derived figures from a
-- small synthetic fixture; one transaction, rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  v_pt uuid;
  v_owner uuid := 'e3260000-0000-0000-0000-000000000001';
  v_staff uuid := 'e3260000-0000-0000-0000-000000000002';
  v_bank uuid;
  v_fa uuid;
  r jsonb;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p27_pt', 'P27 Statement PT (synthetic)') returning id into v_pt;
  perform app_private.provision_default_coa(v_pt);
  perform test_helpers.mk_user(v_owner, 'p27_owner');
  perform test_helpers.mk_user(v_staff, 'p27_staff');
  perform test_helpers.mk_member(v_pt, v_owner, 'owner');
  perform test_helpers.mk_member(v_pt, v_staff, 'viewer_auditor');
  v_bank := test_helpers.acct(v_pt, 'BANK_OPERATING');
  insert into public.financial_accounts (entity_id, kind, name, currency, ledger_account_id)
  values (v_pt, 'bank', 'Operating (synthetic)', 'IDR', v_bank) returning id into v_fa;

  -- September: +1,000,000 in. October: +5,000,000 in, 1,000,000 out, 250,000 out.
  perform test_helpers.simple_journal(v_pt, date '2026-09-10', v_bank, test_helpers.acct(v_pt, 'OWNER_CAPITAL'), 1000000);
  perform test_helpers.simple_journal(v_pt, date '2026-10-03', v_bank, test_helpers.acct(v_pt, 'OTHER_OPERATING_REVENUE'), 5000000);
  perform test_helpers.simple_journal(v_pt, date '2026-10-05', test_helpers.acct(v_pt, 'OFFICE_GENERAL_EXPENSE'), v_bank, 1000000);
  perform test_helpers.simple_journal(v_pt, date '2026-10-20', test_helpers.acct(v_pt, 'OFFICE_GENERAL_EXPENSE'), v_bank, 250000);

  perform test_helpers.login(v_owner);
  r := public.cash_statement(v_pt, null, date '2026-10-15', 25, 0);
  perform test_helpers.assert((r ->> 'opening')::numeric = 1000000, '1.1 the opening balance is everything before the month');
  perform test_helpers.assert((r ->> 'total_in')::numeric = 5000000 and (r ->> 'total_out')::numeric = 1250000, '1.2 the month''s money in and out');
  perform test_helpers.assert((r ->> 'closing')::numeric = 4750000, '1.3 closing = opening + in - out');
  perform test_helpers.assert((r ->> 'total_rows')::int = 3 and jsonb_array_length(r -> 'rows') = 3, '1.4 three lines in the month');
  perform test_helpers.assert(((r -> 'rows' -> 2) ->> 'saldo')::numeric = 4750000, '1.5 the running balance ends at the closing balance');
  perform test_helpers.assert(((r -> 'rows' -> 0) ->> 'saldo')::numeric = 6000000, '1.6 the first line starts from the opening balance');

  r := public.cash_statement(v_pt, v_fa, date '2026-10-01', 2, 2);
  perform test_helpers.assert(jsonb_array_length(r -> 'rows') = 1 and (r ->> 'total_rows')::int = 3, '2.1 paging returns only the requested slice but the full count');
  perform test_helpers.assert(((r -> 'rows' -> 0) ->> 'saldo')::numeric = 4750000, '2.2 a later page keeps the true running balance');

  r := public.cash_statement(v_pt, null, date '2026-09-01', 25, 0);
  perform test_helpers.assert((r ->> 'opening')::numeric = 0 and (r ->> 'closing')::numeric = 1000000, '3.1 an earlier month has its own balances');
  perform test_helpers.assert(jsonb_array_length(r -> 'months') = 12, '3.2 the overview always has 12 months');

  perform test_helpers.expect_msg(format('select public.cash_statement(%L, %L)', v_pt, gen_random_uuid()), 'NOT_FOUND', '4.1 an unknown account is refused');
  perform test_helpers.expect_msg(format('select public.cash_statement(%L, null, null, 500, 0)', v_pt), 'INVALID', '4.2 the page size is capped');
  perform test_helpers.logout();
end
$$;

rollback;
