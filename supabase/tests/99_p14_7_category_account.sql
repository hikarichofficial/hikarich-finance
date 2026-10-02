-- P14 decision 265: mapping a category to the ledger account it posts to. Covers authorization, the kind
-- and account-class rules, effective dating (the past is never rewritten) and ending a mapping.
-- Synthetic data; the whole file runs in one transaction that is rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  e1 uuid;
  v_owner uuid := 'e2650000-0000-0000-0000-000000000001';
  v_viewer uuid := 'e2650000-0000-0000-0000-000000000002';
  v_rev uuid;
  v_exp uuid;
  v_asset uuid;
  v_a_rev uuid;
  v_a_rev2 uuid;
  v_a_exp uuid;
  v_m1 uuid;
  v_m2 uuid;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p14_cm1', 'P14 Mapping (synthetic)')
  returning id into e1;
  perform test_helpers.mk_user(v_owner, 'p265-owner');
  perform test_helpers.mk_user(v_viewer, 'p265-viewer');
  perform test_helpers.mk_member(e1, v_owner, 'owner');
  perform test_helpers.mk_member(e1, v_viewer, 'viewer_auditor');
  insert into public.categories (entity_id, name, kind) values (e1, 'Jasa', 'revenue') returning id into v_rev;
  insert into public.categories (entity_id, name, kind) values (e1, 'Sewa', 'expense') returning id into v_exp;
  insert into public.categories (entity_id, name, kind) values (e1, 'Peralatan', 'asset') returning id into v_asset;
  insert into public.ledger_accounts (entity_id, code, name, account_class, normal_balance)
  values (e1, '4901', 'Pendapatan Jasa (synthetic)', 'revenue', 'credit') returning id into v_a_rev;
  insert into public.ledger_accounts (entity_id, code, name, account_class, normal_balance)
  values (e1, '4902', 'Pendapatan Lain (synthetic)', 'revenue', 'credit') returning id into v_a_rev2;
  insert into public.ledger_accounts (entity_id, code, name, account_class, normal_balance)
  values (e1, '6901', 'Beban Sewa (synthetic)', 'expense', 'debit') returning id into v_a_exp;

  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.set_category_account(%L, %L, %L, %L)', e1, v_rev, v_a_rev, date '2026-01-01'),
    'FORBIDDEN', '1.1 a viewer cannot map a category');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.set_category_account(%L, %L, %L, %L)', e1, v_rev, v_a_exp, date '2026-01-01'),
    'INVALID', '1.2 a revenue category does not map to an expense account');
  perform test_helpers.expect_msg(format('select public.set_category_account(%L, %L, %L, %L)', e1, v_exp, v_a_rev, date '2026-01-01'),
    'INVALID', '1.3 an expense category does not map to a revenue account');
  perform test_helpers.expect_msg(format('select public.set_category_account(%L, %L, %L, %L)', e1, v_asset, v_a_exp, date '2026-01-01'),
    'INVALID', '1.4 other kinds are not mapped here');

  v_m1 := public.set_category_account(e1, v_rev, v_a_rev, date '2026-01-01');
  perform test_helpers.assert(app_private.resolve_revenue_account(e1, v_rev, date '2026-03-01') = v_a_rev,
    '1.5 invoices of the category post to the mapped revenue account');
  v_m2 := public.set_category_account(e1, v_rev, v_a_rev2, date '2026-06-01');
  perform test_helpers.assert(v_m2 <> v_m1
    and (select effective_to from public.category_account_mappings where id = v_m1) = date '2026-05-31'
    and app_private.resolve_revenue_account(e1, v_rev, date '2026-03-01') = v_a_rev
    and app_private.resolve_revenue_account(e1, v_rev, date '2026-07-01') = v_a_rev2,
    '1.6 a change starts on its date; earlier dates keep the account they had');
  perform test_helpers.expect_msg(format('select public.set_category_account(%L, %L, %L, %L)', e1, v_rev, v_a_rev, date '2026-02-01'),
    'CONFLICT', '1.7 a mapping cannot be inserted before a later one');
  perform test_helpers.assert(public.set_category_account(e1, v_rev, v_a_rev, date '2026-06-01') = v_m2
    and app_private.resolve_revenue_account(e1, v_rev, date '2026-07-01') = v_a_rev,
    '1.8 the same start date corrects the mapping in place');

  perform public.set_category_account(e1, v_exp, v_a_exp, date '2026-01-01');
  perform test_helpers.assert(app_private.resolve_purchase_account(e1, v_exp, 'expense', null, date '2026-02-01') = v_a_exp,
    '1.9 bills and expenses of the category post to the mapped expense account');
  perform public.set_category_account(e1, v_exp, null, date '2026-09-01');
  perform test_helpers.assert((select effective_to from public.category_account_mappings
      where category_id = v_exp and context = 'purchases') = date '2026-08-31'
    and app_private.resolve_purchase_account(e1, v_exp, 'expense', null, date '2026-02-01') = v_a_exp,
    '1.10 ending a mapping keeps its history');
  perform test_helpers.logout();
end
$$;

rollback;
