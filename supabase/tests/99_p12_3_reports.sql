-- P12 gate (Step 15 Phase 12, Step 12 §15/§19): Custom Report Builder and Consolidated Analysis
-- (20260930200200_p12_consolidated_and_custom_reports.sql). Covers: the reports.view gate shared by every
-- dataset, the per-dataset required_permission gate (a caller with reports.view but not the dataset's own
-- permission is still refused), the NOT_FOUND for an unknown dataset key, correct grouping/summation for
-- each of the three curated datasets with a date-range filter and a still-draft/unconfirmed document
-- excluded, and consolidated_cash_position's per-Entity reports.cross_entity gate -- fails closed on the
-- whole call when any one requested Entity is unauthorized, rather than silently dropping it, and sums
-- the '1100' cash group correctly across a company and a personal Entity. All data is synthetic; the whole
-- file runs in one transaction that is rolled back.

begin;
set local client_min_messages = warning;

do $$
declare
  v_pt uuid;
  v_pt2 uuid;
  v_pe uuid;
  v_owner uuid := 'f0000000-0000-0000-0000-000000000001';
  v_limited uuid := 'f0000000-0000-0000-0000-000000000002';
  v_no_reports uuid := 'f0000000-0000-0000-0000-000000000003';
  v_no_dataset uuid := 'f0000000-0000-0000-0000-000000000004';
  v_cust_a uuid;
  v_cust_b uuid;
  v_vendor_a uuid;
  v_vendor_b uuid;
  v_payee_a uuid;
  v_cat uuid;
  v_office_acct uuid;
  v_cash uuid;
  v_fa_cash uuid;
  v_bank uuid;
  v_inv1 uuid;
  v_inv2 uuid;
  v_inv3 uuid;
  v_bill1 uuid;
  v_bill2 uuid;
  v_bill3 uuid;
  v_bill4 uuid;
  v_exp1 uuid;
  v_exp2 uuid;
  v_today date;
  v_mship_pt uuid;
  v_mship_pt2 uuid;
begin
  -- --------------------------------------------------------------------- fixture: entities, people, masters
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p12_rep_pt', 'P12 Reports PT (synthetic)') returning id into v_pt;
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p12_rep_pt2', 'P12 Reports PT2 (synthetic)') returning id into v_pt2;
  insert into public.entities (entity_type, code, legal_name) values ('personal', 'p12_rep_pe', 'P12 Reports Personal (synthetic)') returning id into v_pe;
  perform app_private.provision_default_coa(v_pt);
  perform app_private.provision_default_coa(v_pt2);
  perform app_private.provision_default_coa(v_pe);
  perform test_helpers.mk_user(v_owner, 'p12_rep_owner');
  perform test_helpers.mk_user(v_limited, 'p12_rep_limited');
  perform test_helpers.mk_user(v_no_reports, 'p12_rep_no_reports');
  perform test_helpers.mk_user(v_no_dataset, 'p12_rep_no_dataset');
  perform test_helpers.mk_member(v_pt, v_owner, 'owner');
  perform test_helpers.mk_member(v_pt2, v_owner, 'owner');
  perform test_helpers.mk_member(v_pe, v_owner, 'owner');
  v_mship_pt := test_helpers.mk_member(v_pt, v_limited, 'accountant');
  v_mship_pt2 := test_helpers.mk_member(v_pt2, v_limited, 'accountant');
  -- v_limited holds reports.cross_entity only on v_pt (an explicit, audited per-membership grant, since no
  -- role template grants it by default) -- the fixture for the fail-closed consolidated_cash_position case.
  insert into public.membership_permission_overrides (membership_id, permission_key, effect, reason)
  values (v_mship_pt, 'reports.cross_entity', 'grant', 'p12 test: cross-entity analytics on PT only');
  -- finance_staff has invoices.view/bills.view but not reports.view: the top-level gate.
  perform test_helpers.mk_member(v_pt, v_no_reports, 'finance_staff');
  -- payroll has neither reports.view nor invoices.view/bills.view; granted only reports.view here, to
  -- isolate the per-dataset required_permission check from the top-level reports.view check.
  perform test_helpers.mk_member(v_pt, v_no_dataset, 'payroll');
  insert into public.membership_permission_overrides (membership_id, permission_key, effect, reason)
  select id, 'reports.view', 'grant', 'p12 test: reports.view only, no dataset permission'
  from public.entity_memberships where entity_id = v_pt and user_id = v_no_dataset;

  -- Category and its sales-context account mapping: master-data screens are P1/P2 scope, seeded here as
  -- superuser exactly like the P5 test fixture does (92_p5_sales.sql).
  insert into public.categories (entity_id, name, kind) values (v_pt, 'P12 Sales', 'revenue') returning id into v_cat;
  insert into public.category_account_mappings (entity_id, category_id, context, credit_ledger_account_id, effective_from)
  values (v_pt, v_cat, 'sales', test_helpers.acct(v_pt, 'OTHER_OPERATING_REVENUE'), date '2000-01-01');

  v_office_acct := test_helpers.acct(v_pt, 'OFFICE_GENERAL_EXPENSE');
  v_cash := test_helpers.acct(v_pt, 'CASH');
  v_bank := test_helpers.acct(v_pt, 'BANK_OPERATING');

  perform test_helpers.login(v_owner);
  v_today := test_helpers.today(v_pt);
  v_cust_a := public.create_contact(v_pt, 'key-p12-c-01', 'customer', 'Customer Alfa');
  v_cust_b := public.create_contact(v_pt, 'key-p12-c-02', 'customer', 'Customer Beta');
  v_vendor_a := public.create_contact(v_pt, 'key-p12-c-03', 'vendor', 'Vendor Satu');
  v_vendor_b := public.create_contact(v_pt, 'key-p12-c-04', 'vendor', 'Vendor Dua');
  v_payee_a := public.create_contact(v_pt, 'key-p12-c-05', 'vendor', 'Payee Toko');
  -- create_expense_draft's p_account is a financial_accounts.id, not a ledger_accounts.id.
  v_fa_cash := public.create_financial_account(v_pt, 'key-p12-fa-01', 'cash', 'Petty Cash (synthetic)', 'IDR', v_cash);

  -- --------------------------------------------------------------------- invoices_by_customer fixture
  -- Alfa: two issued invoices dated -20 and -5 days (300,000 + 200,000 = 500,000). Beta: one issued
  -- invoice dated -15 days (150,000). A fourth, still-draft invoice for Alfa is never issued.
  v_inv1 := public.create_invoice_draft(v_pt, 'key-p12-inv-01', v_cust_a, v_today - 20, v_today + 10,
    jsonb_build_array(jsonb_build_object('description', 'Service A', 'unit_price', 300000, 'category_id', v_cat)));
  perform public.issue_invoice(v_inv1, 'key-p12-inv-01-issue');
  v_inv2 := public.create_invoice_draft(v_pt, 'key-p12-inv-02', v_cust_a, v_today - 5, v_today + 25,
    jsonb_build_array(jsonb_build_object('description', 'Service B', 'unit_price', 200000, 'category_id', v_cat)));
  perform public.issue_invoice(v_inv2, 'key-p12-inv-02-issue');
  v_inv3 := public.create_invoice_draft(v_pt, 'key-p12-inv-03', v_cust_b, v_today - 15, v_today + 15,
    jsonb_build_array(jsonb_build_object('description', 'Service C', 'unit_price', 150000, 'category_id', v_cat)));
  perform public.issue_invoice(v_inv3, 'key-p12-inv-03-issue');
  perform public.create_invoice_draft(v_pt, 'key-p12-inv-04', v_cust_a, v_today - 1, v_today + 29,
    jsonb_build_array(jsonb_build_object('description', 'Never issued', 'unit_price', 999999, 'category_id', v_cat)));

  -- --------------------------------------------------------------------- bills_by_vendor fixture
  -- Satu: two approved bills (120,000 + 80,000 = 200,000). Dua: one approved bill (60,000) and one bill
  -- that is only submitted, never approved -- excluded.
  v_bill1 := public.create_bill_draft(v_pt, 'key-p12-b-01', v_vendor_a, v_today - 20, v_today + 10,
    jsonb_build_array(jsonb_build_object('description', 'Supplies', 'unit_price', 120000, 'account_id', v_office_acct)));
  perform public.submit_bill(v_bill1, 'key-p12-b-01-submit');
  perform public.approve_bill(v_bill1, 'key-p12-b-01-approve');
  v_bill2 := public.create_bill_draft(v_pt, 'key-p12-b-02', v_vendor_a, v_today - 8, v_today + 22,
    jsonb_build_array(jsonb_build_object('description', 'More supplies', 'unit_price', 80000, 'account_id', v_office_acct)));
  perform public.submit_bill(v_bill2, 'key-p12-b-02-submit');
  perform public.approve_bill(v_bill2, 'key-p12-b-02-approve');
  v_bill3 := public.create_bill_draft(v_pt, 'key-p12-b-03', v_vendor_b, v_today - 12, v_today + 18,
    jsonb_build_array(jsonb_build_object('description', 'Dua order', 'unit_price', 60000, 'account_id', v_office_acct)));
  perform public.submit_bill(v_bill3, 'key-p12-b-03-submit');
  perform public.approve_bill(v_bill3, 'key-p12-b-03-approve');
  v_bill4 := public.create_bill_draft(v_pt, 'key-p12-b-04', v_vendor_b, v_today - 3, v_today + 27,
    jsonb_build_array(jsonb_build_object('description', 'Still submitted, not approved', 'unit_price', 999999, 'account_id', v_office_acct)));
  perform public.submit_bill(v_bill4, 'key-p12-b-04-submit');

  -- --------------------------------------------------------------------- expenses_by_payee fixture
  -- Toko: one confirmed expense (45,000). A second, merely submitted expense must not appear.
  v_exp1 := public.create_expense_draft(v_pt, 'key-p12-e-01', v_fa_cash, v_today - 6,
    jsonb_build_array(jsonb_build_object('description', 'Office snacks', 'unit_price', 45000, 'account_id', v_office_acct)),
    v_payee_a);
  perform public.confirm_expense(v_exp1, 'key-p12-e-01-confirm');
  v_exp2 := public.create_expense_draft(v_pt, 'key-p12-e-02', v_fa_cash, v_today - 2,
    jsonb_build_array(jsonb_build_object('description', 'Not yet confirmed', 'unit_price', 77000, 'account_id', v_office_acct)),
    v_payee_a);
  perform public.submit_expense(v_exp2, 'key-p12-e-02-submit');

  -- --------------------------------------------------------------------- consolidated_cash_position fixture
  -- test_helpers.simple_journal posts directly (bypassing the RPC layer) as the test-runner superuser, so it
  -- must run outside any login() session, exactly like the fixture journals at the top of this file's peers.
  perform test_helpers.logout();
  -- v_pt: BANK_OPERATING debited 1,000,000; CASH already carries a 45,000 credit from the confirmed expense
  -- above -> 1100 group total = 1,000,000 - 45,000 = 955,000.
  perform test_helpers.simple_journal(v_pt, v_today, v_bank, test_helpers.acct(v_pt, 'OTHER_OPERATING_REVENUE'), 1000000);
  -- v_pt2: BANK_OPERATING debited 250,000 -> 1100 group total = 250,000.
  perform test_helpers.simple_journal(v_pt2, v_today, test_helpers.acct(v_pt2, 'BANK_OPERATING'),
    test_helpers.acct(v_pt2, 'OTHER_OPERATING_REVENUE'), 250000);
  -- v_pe (personal): PERSONAL_BANK debited 400,000 -> 1100 group total = 400,000.
  perform test_helpers.simple_journal(v_pe, v_today, test_helpers.acct(v_pe, 'PERSONAL_BANK'),
    test_helpers.acct(v_pe, 'OTHER_PERSONAL_INCOME'), 400000);
  perform test_helpers.logout();

  -- ============================================================ 1. run_custom_report: permission gates
  perform test_helpers.login(v_no_reports);
  perform test_helpers.expect_msg(format('select * from public.run_custom_report(%L, ''invoices_by_customer'')', v_pt),
    'FORBIDDEN: missing reports.view', 'finance_staff has invoices.view but not reports.view: refused before the dataset is even looked up');
  perform test_helpers.logout();

  perform test_helpers.login(v_no_dataset);
  perform test_helpers.expect_msg(format('select * from public.run_custom_report(%L, ''invoices_by_customer'')', v_pt),
    'FORBIDDEN: missing invoices.view', 'payroll granted only reports.view still lacks the dataset''s own invoices.view');
  perform test_helpers.expect_msg(format('select * from public.run_custom_report(%L, ''bills_by_vendor'')', v_pt),
    'FORBIDDEN: missing bills.view', 'and lacks bills.view for the vendor dataset');
  perform test_helpers.expect_msg(format('select * from public.run_custom_report(%L, ''expenses_by_payee'')', v_pt),
    'FORBIDDEN: missing bills.view', 'the payee dataset is gated by bills.view too (Step 12 Table 4)');
  perform test_helpers.logout();

  -- ============================================================ 2. run_custom_report: NOT_FOUND
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select * from public.run_custom_report(%L, ''not_a_real_dataset'')', v_pt),
    'NOT_FOUND: unknown report dataset', 'an unknown dataset key is refused, not silently run as an empty result');

  -- ============================================================ 3. invoices_by_customer: grouping, sums, date range
  perform test_helpers.assert(
    (select row_count from public.run_custom_report(v_pt, 'invoices_by_customer') where dimension = 'Customer Alfa') = 2
    and (select total_amount from public.run_custom_report(v_pt, 'invoices_by_customer') where dimension = 'Customer Alfa') = '500000.0000',
    'Alfa: 2 issued invoices totalling 500,000; the still-draft fourth invoice never counted');
  perform test_helpers.assert(
    (select row_count from public.run_custom_report(v_pt, 'invoices_by_customer') where dimension = 'Customer Beta') = 1
    and (select total_amount from public.run_custom_report(v_pt, 'invoices_by_customer') where dimension = 'Customer Beta') = '150000.0000',
    'Beta: 1 issued invoice totalling 150,000');
  perform test_helpers.assert(
    (select count(*) from public.run_custom_report(v_pt, 'invoices_by_customer')) = 2,
    'exactly two customers have issued-invoice activity (the draft-only customer contributes nothing)');
  perform test_helpers.assert(
    (select total_amount from public.run_custom_report(v_pt, 'invoices_by_customer', v_today - 10, v_today) where dimension = 'Customer Alfa') = '200000.0000',
    'a date range of the last 10 days excludes Alfa''s first invoice (issued 20 days ago), leaving only the 200,000 one');
  perform test_helpers.assert(
    not exists (select 1 from public.run_custom_report(v_pt, 'invoices_by_customer', v_today - 10, v_today) where dimension = 'Customer Beta'),
    'the same range excludes Beta entirely (her invoice was issued 15 days ago)');

  -- ============================================================ 4. bills_by_vendor: grouping, sums
  perform test_helpers.assert(
    (select row_count from public.run_custom_report(v_pt, 'bills_by_vendor') where dimension = 'Vendor Satu') = 2
    and (select total_amount from public.run_custom_report(v_pt, 'bills_by_vendor') where dimension = 'Vendor Satu') = '200000.0000',
    'Satu: 2 approved bills totalling 200,000');
  perform test_helpers.assert(
    (select row_count from public.run_custom_report(v_pt, 'bills_by_vendor') where dimension = 'Vendor Dua') = 1
    and (select total_amount from public.run_custom_report(v_pt, 'bills_by_vendor') where dimension = 'Vendor Dua') = '60000.0000',
    'Dua: 1 approved bill totalling 60,000; the still-submitted-only bill never counted');

  -- ============================================================ 5. expenses_by_payee: grouping, sums
  perform test_helpers.assert(
    (select row_count from public.run_custom_report(v_pt, 'expenses_by_payee') where dimension = 'Payee Toko') = 1
    and (select total_amount from public.run_custom_report(v_pt, 'expenses_by_payee') where dimension = 'Payee Toko') = '45000.0000',
    'Toko: 1 confirmed expense totalling 45,000; the still-submitted-only expense never counted');
  perform test_helpers.logout();

  -- ============================================================ 6. consolidated_cash_position: gates and aggregation
  perform test_helpers.login(v_no_reports);
  perform test_helpers.expect_msg(format('select * from public.consolidated_cash_position(array[%L]::uuid[])', v_pt),
    'FORBIDDEN', 'finance_staff has no reports.cross_entity grant at all');
  perform test_helpers.logout();

  perform test_helpers.login(v_limited);
  perform test_helpers.assert(
    (select cash_balance from public.consolidated_cash_position(array[v_pt]::uuid[])) = '955000.0000',
    'v_limited is authorized on v_pt alone: 1,000,000 bank less the 45,000 expense = 955,000');
  perform test_helpers.expect_msg(format('select * from public.consolidated_cash_position(array[%L, %L]::uuid[])', v_pt, v_pt2),
    'FORBIDDEN', 'v_limited lacks reports.cross_entity on v_pt2: the whole call fails closed, not just that Entity dropped');
  perform test_helpers.expect_msg('select * from public.consolidated_cash_position(null)', 'INVALID', 'at least one Entity is required');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  perform test_helpers.assert(
    (select count(*) from public.consolidated_cash_position(array[v_pt, v_pt2, v_pe]::uuid[])) = 3,
    'the owner (bypass) sees all three requested Entities');
  perform test_helpers.assert(
    (select cash_balance from public.consolidated_cash_position(array[v_pt, v_pt2, v_pe]::uuid[]) where entity_id = v_pt) = '955000.0000'
    and (select cash_balance from public.consolidated_cash_position(array[v_pt, v_pt2, v_pe]::uuid[]) where entity_id = v_pt2) = '250000.0000'
    and (select cash_balance from public.consolidated_cash_position(array[v_pt, v_pt2, v_pe]::uuid[]) where entity_id = v_pe) = '400000.0000',
    'each Entity''s 1100 cash group is summed independently -- company and personal books are never merged (Step 12 §15)');
  perform test_helpers.assert(
    (select entity_type from public.consolidated_cash_position(array[v_pe]::uuid[])) = 'personal',
    'entity_type is carried through for the personal book');
  perform test_helpers.logout();
end
$$;

rollback;
