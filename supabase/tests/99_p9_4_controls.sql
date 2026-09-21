-- P9 gate, part 4 (Step 08 §13/§19, Step 12 §12, Step 16 §18): the payroll reads, reports and controls. Covers the run
-- list and summary, the liability report at two dates, the employee tax ledger and the annual reconciliation, the
-- payroll control against the General Ledger (its "other" column and its detective role), the period-close checks for
-- payroll, and the permission gating of every report. All data is synthetic; payroll months are fixed in 2025.
-- One rolled-back transaction.
begin;
set local client_min_messages = warning;

create table test_helpers.p9d (k text primary key, v uuid not null);
grant all on test_helpers.p9d to public;
create function test_helpers.put(p_k text, p_v uuid) returns uuid
language sql as $f$ insert into test_helpers.p9d values (p_k, p_v) on conflict (k) do update set v = excluded.v returning v $f$;
create function test_helpers.g(p_k text) returns uuid
language sql stable as $f$ select v from test_helpers.p9d where k = p_k $f$;
grant execute on function test_helpers.put(text, uuid), test_helpers.g(text) to public;

-- The payroll findings of a period close as "code:count" text, for readable assertions.
create function test_helpers.pblock(p_entity uuid, p_month date) returns text
language sql security definer set search_path = pg_catalog, public as $f$
  select coalesce(string_agg(b.code || ':' || b.item_count, ',' order by b.code), '')
  from public.accounting_periods p, lateral app_private.period_blockers(p.id) b
  where p.entity_id = p_entity and p.period_start = p_month and b.code like 'payroll%' $f$;
grant execute on function test_helpers.pblock(uuid, date) to public;

-- ================================================================ fixtures (superuser)
do $$
declare
  v_pt uuid;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p9d_pt', 'P9D PT (synthetic)') returning id into v_pt;
  perform app_private.provision_default_coa(v_pt);
  perform test_helpers.mk_user('b2000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_user('b2000000-0000-0000-0000-000000000002', 'payroll');
  perform test_helpers.mk_user('b2000000-0000-0000-0000-000000000003', 'payroll two');
  perform test_helpers.mk_user('b2000000-0000-0000-0000-000000000004', 'accountant');
  perform test_helpers.mk_user('b2000000-0000-0000-0000-000000000005', 'tax');
  perform test_helpers.mk_member(v_pt, 'b2000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pt, 'b2000000-0000-0000-0000-000000000002', 'payroll');
  perform test_helpers.mk_member(v_pt, 'b2000000-0000-0000-0000-000000000003', 'payroll');
  perform test_helpers.mk_member(v_pt, 'b2000000-0000-0000-0000-000000000004', 'accountant');
  perform test_helpers.mk_member(v_pt, 'b2000000-0000-0000-0000-000000000005', 'tax');
end
$$;

-- ================================================================ 1. a posted July, partly paid
do $$
declare
  pt uuid := test_helpers.entity('p9d_pt');
  v_owner uuid := 'b2000000-0000-0000-0000-000000000001';
  v_pay uuid := 'b2000000-0000-0000-0000-000000000002';
  v_pay2 uuid := 'b2000000-0000-0000-0000-000000000003';
  v_tax uuid := 'b2000000-0000-0000-0000-000000000005';
  e uuid;
  v_run uuid;
  v_bank uuid;
begin
  perform test_helpers.login(v_owner);
  v_bank := test_helpers.put('bank', public.create_financial_account(pt, 'key-p9d-fa-1', 'bank', 'BCA Payroll', 'IDR', test_helpers.acct(pt, 'BANK_OPERATING')));
  perform public.tax_record_entity_profile(pt, 'key-p9d-ep-1', date '2025-01-01', 'company', 'resident', 'general', 'none', 'none', 'pkp', 'yes', null, 'synthetic');
  perform public.tax_engine_activate(pt, 'key-p9d-ea-1', date '2025-01-01');
  perform test_helpers.logout();

  perform test_helpers.login(v_pay);
  e := test_helpers.put('A', public.employee_create(pt, 'key-p9d-A', 'Employee A', '2025-03-01', 'permanent', 'Staff'));
  perform public.employee_set_compensation(e, 'key-p9d-A-c', '2025-03-01', jsonb_build_array(
    jsonb_build_object('component', 'basic', 'kind', 'earning', 'label', 'Gaji pokok', 'amount', '5000000', 'bpjs_base', true),
    jsonb_build_object('component', 'meal', 'kind', 'earning', 'label', 'Uang makan', 'amount', '600000'),
    jsonb_build_object('component', 'transport', 'kind', 'earning', 'label', 'Transport', 'amount', '300000', 'taxable', false)));
  perform public.employee_set_tax_profile(e, 'key-p9d-A-t', '2025-03-01', 'has_tax_id', '3200000000000001', 'TK/0');
  perform public.employee_set_bpjs(e, 'key-p9d-A-b', '2025-03-01', '[
    {"component":"bpjs_kes","enrolled":true},{"component":"bpjs_jht","enrolled":true},{"component":"bpjs_jp","enrolled":true},
    {"component":"bpjs_jkk","enrolled":true,"rate_key":"grade_1"},{"component":"bpjs_jkm","enrolled":true}]'::jsonb);
  e := test_helpers.put('C', public.employee_create(pt, 'key-p9d-C', 'Employee C', '2025-06-01', 'permanent', 'Director'));
  perform public.employee_set_compensation(e, 'key-p9d-C-c', '2025-06-01', jsonb_build_array(
    jsonb_build_object('component', 'basic', 'kind', 'earning', 'label', 'Gaji pokok', 'amount', '10000000')));
  perform public.employee_set_tax_profile(e, 'key-p9d-C-t', '2025-06-01', 'has_tax_id', '3200000000000003', 'TK/0', 'gross_up');
  e := test_helpers.put('D', public.employee_create(pt, 'key-p9d-D', 'Employee D', '2025-04-01', 'permanent', 'Clerk'));
  perform public.employee_set_compensation(e, 'key-p9d-D-c', '2025-04-01', jsonb_build_array(
    jsonb_build_object('component', 'basic', 'kind', 'earning', 'label', 'Gaji pokok', 'amount', '6000000')));
  perform public.employee_set_tax_profile(e, 'key-p9d-D-t', '2025-04-01', 'no_tax_id', null, 'TK/0');
  -- E joins after July with unknown tax facts: absent from July, "incomplete" in the annual reconciliation
  e := test_helpers.put('E', public.employee_create(pt, 'key-p9d-E', 'Employee E', '2025-08-01', 'permanent', 'Clerk'));
  perform public.employee_set_tax_profile(e, 'key-p9d-E-t', '2025-08-01', 'unknown', null, 'unknown');
  v_run := test_helpers.put('jul', public.payroll_run_create(pt, 'key-p9d-r1', '2025-07-01', '2025-07-25'));
  perform public.payroll_run_calculate(v_run);
  perform public.payroll_run_submit(v_run, 'key-p9d-s1');
  perform test_helpers.logout();
  perform test_helpers.login(v_pay2);
  perform public.payroll_run_approve(v_run, 'key-p9d-ap1');
  perform public.payroll_run_post(v_run, 'key-p9d-po1');
  -- part payments: 3,000,000 net pay to A, 300,000 of BPJS
  perform public.payroll_record_payment(v_run, 'key-p9d-pm1', 'net_pay', '2025-08-01', v_bank, null,
    jsonb_build_array(jsonb_build_object('employee', test_helpers.g('A'), 'amount', '3000000')));
  perform public.payroll_record_payment(v_run, 'key-p9d-pm2', 'bpjs', '2025-08-05', v_bank, '300000');
  perform test_helpers.logout();
  perform test_helpers.login(v_tax);
  perform public.tax_record_payment(pt, 'key-p9d-tp-1', 'wht_pph21', '2025-07-01', '2025-08-10', v_bank, '100000', '0', '0', 'NTPN-P9D-1', 'part payment (synthetic)');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 2. run reads, summary and liability report
do $$
declare
  pt uuid := test_helpers.entity('p9d_pt');
  v_pay uuid := 'b2000000-0000-0000-0000-000000000002';
  v_run uuid := test_helpers.g('jul');
  r record;
  n integer;
begin
  perform test_helpers.login(v_pay);
  select * into r from public.payroll_run_list(pt) where run_id = v_run;
  perform test_helpers.assert(r.status = 'partially_paid' and r.employee_count = 3 and r.review_count = 0, 'the list shows a partly paid run of three employees');
  perform test_helpers.assert(r.net_pay_total::numeric = 21616865 and r.net_paid::numeric = 3000000 and r.bpjs_paid::numeric = 300000
    and r.pph21_total::numeric = 313314 and r.journal_id is not null, 'the list carries totals and what was paid');
  perform test_helpers.assert((select count(*) from public.payroll_run_list(pt, 'posted')) = 0 and (select count(*) from public.payroll_run_list(pt, 'partially_paid')) = 1, 'the status filter works');
  perform test_helpers.assert((select count(*) from public.payroll_payments_list(v_run)) = 2 and (select count(*) from public.payroll_run_lines(v_run)) = 3, 'payments and lines are listed');

  -- payroll summary
  select * into r from public.payroll_summary_report(pt) where run_id = v_run;
  perform test_helpers.assert(r.gross_pay::numeric = 21900000 and r.net_pay::numeric = 21616865 and r.net_unpaid::numeric = 18616865, 'summary: gross, net and net unpaid');
  perform test_helpers.assert(r.bpjs_unpaid::numeric = 412000 and r.pph21::numeric = 313314 and r.pph21_period_outstanding::numeric = 213314, 'summary: BPJS unpaid and PPh 21 outstanding for the period');
  perform test_helpers.assert((select count(*) from public.payroll_summary_report(pt, '2025-08-01', '2025-12-31')) = 0, 'the summary filters by month');

  -- liabilities: today and at the end of July (before any payment)
  perform test_helpers.assert((select outstanding::numeric from public.payroll_liability_report(pt) where liability = 'net_pay') = 18616865
    and (select paid::numeric from public.payroll_liability_report(pt) where liability = 'net_pay') = 3000000, 'liability: net pay owed and paid today');
  perform test_helpers.assert((select outstanding::numeric from public.payroll_liability_report(pt) where liability = 'bpjs') = 412000, 'liability: BPJS outstanding today');
  perform test_helpers.assert((select outstanding::numeric from public.payroll_liability_report(pt) where liability = 'pph21' and period_start = '2025-07-01') = 213314, 'liability: PPh 21 outstanding for July');
  perform test_helpers.assert((select paid::numeric from public.payroll_liability_report(pt, '2025-07-31') where liability = 'net_pay') = 0
    and (select outstanding::numeric from public.payroll_liability_report(pt, '2025-07-31') where liability = 'net_pay') = 21616865, 'liability at the end of July: nothing paid yet');
  perform test_helpers.assert((select count(*) from public.payroll_liability_report(pt, '2025-06-30')) = 0, 'and none before the posting');

  -- employee tax ledger of the year
  perform test_helpers.assert((select count(*) from public.payroll_employee_tax_ledger(pt, 2025)) = 3, 'the tax ledger has one row per employee and payrolled month');
  select * into r from public.payroll_employee_tax_ledger(pt, 2025, test_helpers.g('A'));
  perform test_helpers.assert(r.source = 'run' and r.tax_period = '2025-07-01' and r.tax_base::numeric = 5827000 and r.pph21::numeric = 29135
    and r.pension_deduction::numeric = 150000 and r.tax_mode = 'ter', 'the employee tax ledger row of A');
  perform test_helpers.assert((select tax_allowance::numeric from public.payroll_employee_tax_ledger(pt, 2025, test_helpers.g('C'))) = 230179, 'C: the allowance is on the ledger');
  perform test_helpers.expect_msg(format('select * from public.payroll_employee_tax_ledger(%L, 1999)', pt), 'INVALID', 'a plausible tax year');

  -- annual reconciliation, by hand for A (10 months, March to December): gross 5,827,000 - 5% cost 291,350 - pension 150,000 = 5,385,650 < PTKP 45,000,000
  -- so the annual tax is 0 against 29,135 withheld
  select * into r from public.payroll_annual_reconciliation(pt, 2025) where employee_id = test_helpers.g('A');
  perform test_helpers.assert(r.months_worked = 10 and r.gross_income::numeric = 5827000 and r.annual_tax::numeric = 0 and r.withheld::numeric = 29135
    and r.difference::numeric = -29135 and r.status = 'over_withheld', 'reconciliation: A is over-withheld');
  perform test_helpers.assert((select status from public.payroll_annual_reconciliation(pt, 2025) where employee_id = test_helpers.g('E')) = 'incomplete', 'reconciliation: unknown tax facts are incomplete, not guessed');
  perform test_helpers.assert((select status from public.payroll_annual_reconciliation(pt, 2025) where employee_id = test_helpers.g('C')) in ('over_withheld', 'under_withheld', 'reconciled'), 'reconciliation: C has a status');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 3. the payroll control and the period checks
do $$
declare
  pt uuid := test_helpers.entity('p9d_pt');
  v_owner uuid := 'b2000000-0000-0000-0000-000000000001';
  v_pay uuid := 'b2000000-0000-0000-0000-000000000002';
  v_pay2 uuid := 'b2000000-0000-0000-0000-000000000003';
  v_acc uuid := 'b2000000-0000-0000-0000-000000000004';
  v_run uuid := test_helpers.g('jul');
  v_new uuid;
  r record;
  v_j uuid;
begin
  -- the control needs accounting.view as well as the payroll right: the owner has both, the payroll role has no accounting right
  perform test_helpers.login(v_pay);
  perform test_helpers.expect_msg(format('select * from public.payroll_control_report(%L)', pt), 'FORBIDDEN', 'the payroll role has no accounting right for the control');
  perform test_helpers.logout();
  perform test_helpers.login(v_acc);
  perform test_helpers.expect_msg(format('select * from public.payroll_control_report(%L)', pt), 'FORBIDDEN', 'the accountant has no payroll right for it');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  select * into r from public.payroll_control_report(pt) where account_key = 'PAYROLL_LIABILITY';
  perform test_helpers.assert(r.sub_ledger::numeric = 18616865 and r.ledger_workflow::numeric = 18616865 and r.ledger_other::numeric = 0 and r.difference::numeric = 0, 'control: net pay liability agrees with the ledger');
  select * into r from public.payroll_control_report(pt) where account_key = 'BPJS_LIABILITY';
  perform test_helpers.assert(r.sub_ledger::numeric = 412000 and r.ledger_total::numeric = 412000 and r.difference::numeric = 0, 'control: BPJS liability agrees with the ledger');
  perform test_helpers.assert((select ledger_total::numeric from public.payroll_control_report(pt, '2025-07-31') where account_key = 'PAYROLL_LIABILITY') = 21616865, 'control at a date');
  perform test_helpers.logout();

  -- an opening balance or a system journal without payroll source on the payroll account shows in the "other" column, never inside the control
  perform test_helpers.simple_journal(pt, date '2025-07-15', test_helpers.acct(pt, 'SALARY_EXPENSE'), test_helpers.acct(pt, 'PAYROLL_LIABILITY'), 1000000, 'system');
  perform test_helpers.login(v_owner);
  select * into r from public.payroll_control_report(pt) where account_key = 'PAYROLL_LIABILITY';
  perform test_helpers.assert(r.ledger_other::numeric = 1000000 and r.difference::numeric = 0 and r.ledger_total::numeric = 19616865, 'control: a foreign journal is visible as "other"');
  perform test_helpers.logout();

  -- the period checks: nothing to report for a reconciled posted month
  perform test_helpers.assert(test_helpers.pblock(pt, date '2025-07-01') = '', 'no payroll finding for a reconciled month');

  -- a payroll journal without its run breaks the control: the period close is blocked
  v_j := app_private.post_system_journal(pt, 'payroll_payment', gen_random_uuid(), 'payroll.pay', 'payroll.v1', date '2025-07-20', 'Orphan payroll payment (synthetic)',
    jsonb_build_array(jsonb_build_object('account_key', 'PAYROLL_LIABILITY', 'debit', 500, 'credit', 0),
                      jsonb_build_object('account_key', 'BANK_OPERATING', 'debit', 0, 'credit', 500)));
  perform test_helpers.assert(test_helpers.pblock(pt, date '2025-07-01') like 'payroll_ledger_mismatch:%', 'an orphan payroll journal blocks the period');
  perform test_helpers.login(v_owner);
  perform test_helpers.assert((select difference::numeric from public.payroll_control_report(pt) where account_key = 'PAYROLL_LIABILITY') <> 0, 'and the control report shows the difference');
  perform test_helpers.logout();
  perform app_private.reverse_journal_core(v_j, date '2025-07-21', 'Remove the orphan (test)');
  perform test_helpers.assert(test_helpers.pblock(pt, date '2025-07-01') = '', 'reversing it clears the finding');

  -- a corrected run leaves a draft revision in the period: a warning; approved but not posted: a blocker; posted: clear
  perform test_helpers.login(v_pay2);
  for r in select payment_id from public.payroll_payments_list(v_run) where status = 'confirmed' loop
    perform public.payroll_reverse_payment(r.payment_id, 'key-p9d-rv-' || substr(r.payment_id::text, 1, 8), '2025-08-06', 'Payroll of July is being corrected');
  end loop;
  v_new := public.payroll_run_correct(v_run, 'key-p9d-cr1', '2025-08-07', 'Correcting July payroll (synthetic)');
  perform test_helpers.logout();
  perform test_helpers.assert(test_helpers.pblock(pt, date '2025-07-01') = 'payroll_not_posted:1', 'a draft revision in the period is a warning');
  perform test_helpers.login(v_pay);
  perform public.payroll_run_calculate(v_new);
  perform public.payroll_run_submit(v_new, 'key-p9d-s2');
  perform test_helpers.logout();
  perform test_helpers.assert(test_helpers.pblock(pt, date '2025-07-01') = 'payroll_not_posted:1', 'submitted is still only a warning');
  perform test_helpers.login(v_pay2);
  perform public.payroll_run_approve(v_new, 'key-p9d-ap2');
  perform test_helpers.logout();
  perform test_helpers.assert(test_helpers.pblock(pt, date '2025-07-01') = 'payroll_approved_not_posted:1', 'an approved run that is not posted blocks the period');
  perform test_helpers.login(v_pay2);
  perform public.payroll_run_post(v_new, 'key-p9d-po2');
  perform test_helpers.logout();
  perform test_helpers.assert(test_helpers.pblock(pt, date '2025-07-01') = '', 'posted: no payroll finding');
end
$$;

-- ================================================================ 4. the permission gating of every read
do $$
declare
  pt uuid := test_helpers.entity('p9d_pt');
  v_pay uuid := 'b2000000-0000-0000-0000-000000000002';
  v_acc uuid := 'b2000000-0000-0000-0000-000000000004';
  v_tax uuid := 'b2000000-0000-0000-0000-000000000005';
  v_run uuid := test_helpers.g('jul');
  v_slip uuid;
  v_pay_id uuid;
begin
  select id into v_slip from public.payroll_payslips where entity_id = pt limit 1;
  select id into v_pay_id from public.payroll_payments where entity_id = pt limit 1;
  -- the accountant and the tax role hold accounting / tax rights, not payroll rights: every payroll read is refused
  perform test_helpers.login(v_acc);
  perform test_helpers.expect_msg(format('select * from public.payroll_run_list(%L)', pt), 'FORBIDDEN', 'accountant: run list');
  perform test_helpers.expect_msg(format('select public.payroll_run_get(%L)', v_run), 'FORBIDDEN', 'accountant: run');
  perform test_helpers.expect_msg(format('select * from public.payroll_adjustments_list(%L)', v_run), 'FORBIDDEN', 'accountant: adjustments');
  perform test_helpers.expect_msg(format('select * from public.payroll_payments_list(%L)', v_run), 'FORBIDDEN', 'accountant: payments');
  perform test_helpers.expect_msg(format('select public.payroll_payslip_get(%L)', v_slip), 'FORBIDDEN', 'accountant: payslip');
  perform test_helpers.expect_msg(format('select * from public.payroll_summary_report(%L)', pt), 'FORBIDDEN', 'accountant: summary');
  perform test_helpers.expect_msg(format('select * from public.payroll_liability_report(%L)', pt), 'FORBIDDEN', 'accountant: liabilities');
  perform test_helpers.expect_msg(format('select * from public.payroll_employee_tax_ledger(%L, 2025)', pt), 'FORBIDDEN', 'accountant: employee tax ledger');
  perform test_helpers.expect_msg(format('select * from public.payroll_annual_reconciliation(%L, 2025)', pt), 'FORBIDDEN', 'accountant: annual reconciliation');
  perform test_helpers.expect_msg(format('select * from public.employee_list(%L)', pt), 'FORBIDDEN', 'accountant: employee list');
  perform test_helpers.expect_error('select * from public.payroll_payslips', '42501', 'accountant: payslip table is closed');
  perform test_helpers.expect_error('select * from public.payroll_payments', '42501', 'accountant: payment table is closed');
  perform test_helpers.logout();
  perform test_helpers.login(v_tax);
  perform test_helpers.expect_msg(format('select * from public.payroll_run_list(%L)', pt), 'FORBIDDEN', 'tax role: run list');
  perform test_helpers.expect_msg(format('select * from public.payroll_annual_reconciliation(%L, 2025)', pt), 'FORBIDDEN', 'tax role: annual reconciliation');
  perform test_helpers.logout();
  -- the payroll role sees its reports; an unauthenticated caller sees nothing
  perform test_helpers.login(v_pay);
  perform test_helpers.assert((select count(*) from public.payroll_summary_report(pt)) >= 1, 'payroll role: summary');
  perform test_helpers.logout();
  perform test_helpers.as_anon();
  perform test_helpers.expect_error(format('select * from public.payroll_run_list(%L)', pt), '42501', 'anon: no access to the run list');
  perform test_helpers.expect_error(format('select public.employee_create(%L, ''key-p9d-anon'', ''X Y'', ''2025-01-01'', ''permanent'', ''Staff'')', pt), '42501', 'anon: no access to employee creation');
  perform test_helpers.logout();
end
$$;

rollback;
