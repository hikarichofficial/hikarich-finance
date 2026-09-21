-- P9 gate, part 3 (Step 04 §8, Step 05 §9, Step 07 §14, Step 08 §13, Step 16 §18): posting a payroll run, its payslips
-- and tax consequence, paying it (net pay in parts, BPJS, PPh 21 through the tax payment), reversing payments, closing
-- and reopening, and the correction path (a reversal, a new revision, the latest-month rule). Every expected figure is
-- worked out by hand. All data is synthetic; payroll months are fixed in 2025. One rolled-back transaction.
begin;
set local client_min_messages = warning;

create table test_helpers.p9c (k text primary key, v uuid not null);
grant all on test_helpers.p9c to public;
create function test_helpers.put(p_k text, p_v uuid) returns uuid
language sql as $f$ insert into test_helpers.p9c values (p_k, p_v) on conflict (k) do update set v = excluded.v returning v $f$;
create function test_helpers.g(p_k text) returns uuid
language sql stable as $f$ select v from test_helpers.p9c where k = p_k $f$;
grant execute on function test_helpers.put(text, uuid), test_helpers.g(text) to public;

create function test_helpers.jd(p_journal uuid, p_key text) returns numeric
language sql security definer set search_path = pg_catalog, public as $f$
  select coalesce(sum(l.debit), 0) from public.journal_lines l
  join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
  where l.journal_id = p_journal and a.system_key = p_key $f$;
create function test_helpers.jc(p_journal uuid, p_key text) returns numeric
language sql security definer set search_path = pg_catalog, public as $f$
  select coalesce(sum(l.credit), 0) from public.journal_lines l
  join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
  where l.journal_id = p_journal and a.system_key = p_key $f$;
-- Debit minus credit of an account over the posted journals.
create function test_helpers.bal(p_entity uuid, p_key text) returns numeric
language sql security definer set search_path = pg_catalog, public as $f$
  select coalesce(sum(l.debit - l.credit), 0)
  from public.journal_lines l
  join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id and j.status = 'posted'
  join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
  where l.entity_id = p_entity and a.system_key = p_key $f$;
grant execute on function test_helpers.jd(uuid, text), test_helpers.jc(uuid, text), test_helpers.bal(uuid, text) to public;

-- The reconciliation invariants of payroll, checked after every major step.
create function test_helpers.pcontrols(p_entity uuid, p_label text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $f$
declare
  c record;
  r record;
begin
  if exists (select 1 from app_private.money_control_rows(p_entity) m where m.ledger_balance <> m.movement_base_balance) then
    raise exception 'TEST FAIL [%]: money movements differ from the ledger', p_label;
  end if;
  for c in select * from app_private.payroll_control(p_entity) loop
    if c.sub_ledger <> c.ledger_workflow or c.ledger_other <> 0 then
      raise exception 'TEST FAIL [%]: payroll control % differs: sub-ledger %, ledger %, other %', p_label, c.account_key,
        c.sub_ledger, c.ledger_workflow, c.ledger_other;
    end if;
  end loop;
  for r in select id, run_number, revision from public.payroll_runs where entity_id = p_entity and journal_id is not null loop
    if jsonb_array_length(app_private.payroll_run_differences(r.id)) > 0 then
      raise exception 'TEST FAIL [%]: run % rev % does not reconcile: %', p_label, r.run_number, r.revision,
        app_private.payroll_run_differences(r.id);
    end if;
  end loop;
  if -test_helpers.bal(p_entity, 'PAYROLL_LIABILITY') <> (select coalesce(sum(x.sub_ledger), 0) from app_private.payroll_control(p_entity) x where x.account_key = 'PAYROLL_LIABILITY') then
    raise exception 'TEST FAIL [%]: the net pay liability differs from the ledger', p_label;
  end if;
end
$f$;
grant execute on function test_helpers.pcontrols(uuid, text) to public;

-- ================================================================ fixtures (superuser)
do $$
declare
  v_pt uuid;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p9c_pt', 'P9C PT (synthetic)') returning id into v_pt;
  perform app_private.provision_default_coa(v_pt);
  perform test_helpers.mk_user('a1000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_user('a1000000-0000-0000-0000-000000000002', 'payroll');
  perform test_helpers.mk_user('a1000000-0000-0000-0000-000000000003', 'payroll two');
  perform test_helpers.mk_user('a1000000-0000-0000-0000-000000000004', 'accountant');
  perform test_helpers.mk_user('a1000000-0000-0000-0000-000000000005', 'tax');
  perform test_helpers.mk_member(v_pt, 'a1000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pt, 'a1000000-0000-0000-0000-000000000002', 'payroll');
  perform test_helpers.mk_member(v_pt, 'a1000000-0000-0000-0000-000000000003', 'payroll');
  perform test_helpers.mk_member(v_pt, 'a1000000-0000-0000-0000-000000000004', 'accountant');
  perform test_helpers.mk_member(v_pt, 'a1000000-0000-0000-0000-000000000005', 'tax');
end
$$;

-- ================================================================ 1. employees and the run of July 2025
do $$
declare
  pt uuid := test_helpers.entity('p9c_pt');
  v_owner uuid := 'a1000000-0000-0000-0000-000000000001';
  v_pay uuid := 'a1000000-0000-0000-0000-000000000002';
  e uuid;
begin
  perform test_helpers.login(v_owner);
  perform test_helpers.put('bank', public.create_financial_account(pt, 'key-p9c-fa-1', 'bank', 'BCA Payroll', 'IDR', test_helpers.acct(pt, 'BANK_OPERATING'), 'BCA', 'ACC-P9C-1', 'PT P9C'));
  perform test_helpers.put('usd', public.create_financial_account(pt, 'key-p9c-fa-2', 'bank', 'USD Account', 'USD'));
  perform test_helpers.logout();

  perform test_helpers.login(v_pay);
  e := test_helpers.put('A', public.employee_create(pt, 'key-p9c-A', 'Employee A', '2025-03-01', 'permanent', 'Staff'));
  perform public.employee_set_compensation(e, 'key-p9c-A-c', '2025-03-01', jsonb_build_array(
    jsonb_build_object('component', 'basic', 'kind', 'earning', 'label', 'Gaji pokok', 'amount', '5000000', 'bpjs_base', true),
    jsonb_build_object('component', 'meal', 'kind', 'earning', 'label', 'Uang makan', 'amount', '600000'),
    jsonb_build_object('component', 'transport', 'kind', 'earning', 'label', 'Transport', 'amount', '300000', 'taxable', false)));
  perform public.employee_set_tax_profile(e, 'key-p9c-A-t', '2025-03-01', 'has_tax_id', '3200000000000001', 'TK/0');
  perform public.employee_set_bpjs(e, 'key-p9c-A-b', '2025-03-01', '[
    {"component":"bpjs_kes","enrolled":true},{"component":"bpjs_jht","enrolled":true},{"component":"bpjs_jp","enrolled":true},
    {"component":"bpjs_jkk","enrolled":true,"rate_key":"grade_1"},{"component":"bpjs_jkm","enrolled":true}]'::jsonb);
  e := test_helpers.put('C', public.employee_create(pt, 'key-p9c-C', 'Employee C', '2025-06-01', 'permanent', 'Director'));
  perform public.employee_set_compensation(e, 'key-p9c-C-c', '2025-06-01', jsonb_build_array(
    jsonb_build_object('component', 'basic', 'kind', 'earning', 'label', 'Gaji pokok', 'amount', '10000000')));
  perform public.employee_set_tax_profile(e, 'key-p9c-C-t', '2025-06-01', 'has_tax_id', '3200000000000003', 'TK/0', 'gross_up');
  e := test_helpers.put('D', public.employee_create(pt, 'key-p9c-D', 'Employee D', '2025-04-01', 'permanent', 'Clerk'));
  perform public.employee_set_compensation(e, 'key-p9c-D-c', '2025-04-01', jsonb_build_array(
    jsonb_build_object('component', 'basic', 'kind', 'earning', 'label', 'Gaji pokok', 'amount', '6000000')));
  perform public.employee_set_tax_profile(e, 'key-p9c-D-t', '2025-04-01', 'no_tax_id', null, 'TK/0');
  -- Expected July 2025 (worked out by hand; see the engine test for the working):
  --   A gross 5,900,000, employee BPJS 200,000, employer BPJS 512,000, PPh 21 29,135, net 5,670,865
  --   C gross 10,000,000, PPh 21 230,179 borne by the employer (allowance), net 10,000,000
  --   D gross 6,000,000, PPh 21 54,000 (no tax number: 120%), net 5,946,000
  --   run: gross 21,900,000, PPh 21 313,314 (allowance 230,179), employee BPJS 200,000, employer BPJS 512,000, net 21,616,865
  perform test_helpers.put('jul', public.payroll_run_create(pt, 'key-p9c-r1', '2025-07-01', '2025-07-25', 'July payroll (synthetic)'));
  perform public.payroll_run_calculate(test_helpers.g('jul'));
  perform test_helpers.assert((public.payroll_run_get(test_helpers.g('jul')) ->> 'net_pay_total')::numeric = 21616865
    and (public.payroll_run_get(test_helpers.g('jul')) ->> 'pph21_total')::numeric = 313314, 'the July run adds up as worked out by hand');
  perform public.payroll_run_submit(test_helpers.g('jul'), 'key-p9c-s1');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 2. approval and posting
do $$
declare
  pt uuid := test_helpers.entity('p9c_pt');
  v_owner uuid := 'a1000000-0000-0000-0000-000000000001';
  v_pay uuid := 'a1000000-0000-0000-0000-000000000002';
  v_pay2 uuid := 'a1000000-0000-0000-0000-000000000003';
  v_acc uuid := 'a1000000-0000-0000-0000-000000000004';
  v_run uuid := test_helpers.g('jul');
  v_j uuid;
  v_j2 uuid;
  j jsonb;
begin
  perform test_helpers.login(v_pay2);
  perform public.payroll_run_approve(v_run, 'key-p9c-ap1');
  perform test_helpers.logout();

  perform test_helpers.login(v_acc);
  perform test_helpers.expect_msg(format('select public.payroll_run_post(%L, ''key-p9c-po0'')', v_run), 'FORBIDDEN', 'an accountant cannot post payroll');
  perform test_helpers.logout();

  -- PPh 21 must reach the tax ledger: without a running tax engine payroll is not posted
  perform test_helpers.login(v_pay2);
  perform test_helpers.expect_msg(format('select public.payroll_run_post(%L, ''key-p9c-po1'')', v_run), 'INVALID: activate the tax engine', 'payroll needs the tax engine');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform public.tax_record_entity_profile(pt, 'key-p9c-ep-1', date '2025-01-01', 'company', 'resident', 'general', 'none', 'none', 'pkp', 'yes', null, 'synthetic');
  perform public.tax_engine_activate(pt, 'key-p9c-ea-1', date '2025-01-01');
  perform test_helpers.logout();

  perform test_helpers.login(v_pay2);
  v_j := public.payroll_run_post(v_run, 'key-p9c-po2');
  v_j2 := public.payroll_run_post(v_run, 'key-p9c-po2');
  perform test_helpers.assert(v_j = v_j2, 'a repeated request returns the same journal');
  perform test_helpers.put('jul_j', v_j);
  perform test_helpers.expect_msg(format('select public.payroll_run_post(%L, ''key-p9c-po3'')', v_run), 'CONFLICT', 'a run is posted once');
  perform test_helpers.expect_msg(format('select public.payroll_run_calculate(%L)', v_run), 'CONFLICT', 'a posted run is not recalculated');
  perform test_helpers.expect_msg(format('select public.payroll_run_discard(%L, ''Not wanted any more'')', v_run), 'CONFLICT', 'a posted run is not discarded');
  perform test_helpers.expect_msg(format('select public.payroll_run_return(%L, ''Send it back please'')', v_run), 'CONFLICT', 'nor returned');
  perform test_helpers.expect_msg(format('select public.payroll_adjustment_add(%L, ''key-p9c-ad1'', %L, ''earning'', ''Bonus'', ''1'')', v_run, test_helpers.g('A')), 'CONFLICT', 'nor adjusted');
  j := public.payroll_run_get(v_run);
  perform test_helpers.assert(j ->> 'status' = 'posted' and j ->> 'posting_date' = '2025-07-31' and (j ->> 'journal_id')::uuid = v_j, 'posted at the end of the payroll month');
  perform test_helpers.assert(j -> 'differences' = '[]'::jsonb, 'the run reconciles');
  perform test_helpers.logout();

  -- the journal, by hand: Dr salary 22,130,179 (gross + allowance) and employer BPJS 512,000; Cr net pay 21,616,865, PPh 21 313,314, BPJS 712,000
  perform test_helpers.assert(test_helpers.jd(v_j, 'SALARY_EXPENSE') = 22130179 and test_helpers.jd(v_j, 'EMPLOYER_BENEFIT_EXPENSE') = 512000, 'debits: salary expense and employer BPJS');
  perform test_helpers.assert(test_helpers.jc(v_j, 'PAYROLL_LIABILITY') = 21616865 and test_helpers.jc(v_j, 'TAX_PAYABLE') = 313314
    and test_helpers.jc(v_j, 'BPJS_LIABILITY') = 712000, 'credits: net pay, PPh 21 and BPJS liabilities');
  perform test_helpers.assert((select sum(debit) - sum(credit) from public.journal_lines where journal_id = v_j) = 0, 'the journal balances');
  perform test_helpers.assert((select source_type || '/' || entry_date from public.journal_entries where id = v_j) = 'payroll_run/2025-07-31', 'the journal is a payroll journal dated at the month end');
  -- the tax layer: one determination for the run (the total only), one ledger accrual in the payroll month
  perform test_helpers.assert((select count(*) from public.tax_determinations where source_type = 'payroll_run' and source_id = v_run and superseded_at is null) = 1, 'one live determination');
  perform test_helpers.assert((select tax_type = 'wht_pph21' and tax_amount = 313314 and direction = 'payable' from public.tax_determinations where source_id = v_run), 'PPh 21 total is the determination');
  perform test_helpers.assert(not exists (select 1 from public.tax_determinations d where d.source_id = v_run and (d.facts::text ~ 'Employee|3200000000' or d.trace::text ~ 'Employee|3200000000')), 'no employee detail leaks into the tax layer');
  perform test_helpers.assert((select sum(amount) from public.tax_ledger_entries where entity_id = pt and tax_type = 'wht_pph21' and tax_period = '2025-07-01') = 313314, 'the PPh 21 ledger accrues the total in the payroll month');
  perform test_helpers.assert(-test_helpers.bal(pt, 'TAX_PAYABLE') = 313314, 'Tax Payables carry PPh 21');
  -- payslips: one per employee, immutable snapshots
  perform test_helpers.assert((select count(*) from public.payroll_payslips where run_id = v_run and status = 'issued') = 3, 'three payslips are issued');
  perform test_helpers.assert((select bool_and(payslip_number like 'PSL-%') from public.payroll_payslips where run_id = v_run), 'payslip numbers come from their family');
  perform test_helpers.assert((select (snapshot ->> 'net_pay')::numeric from public.payroll_payslips where employee_id = test_helpers.g('A') and run_id = v_run) = 5670865, 'the payslip carries the net pay');
  perform test_helpers.assert((select (snapshot #>> '{tax,pph21}')::numeric from public.payroll_payslips where employee_id = test_helpers.g('C') and run_id = v_run) = 230179
    and (select (snapshot #>> '{tax,withheld_from_employee}')::numeric from public.payroll_payslips where employee_id = test_helpers.g('C') and run_id = v_run) = 0, 'C: the payslip shows the tax the employer bore');
  perform test_helpers.expect_error(format('update public.payroll_payslips set snapshot = ''{}'' where run_id = %L', v_run), '23000', 'a payslip cannot be edited');
  perform test_helpers.expect_error(format('delete from public.payroll_payslips where run_id = %L', v_run), null, 'a payslip cannot be deleted');
  perform test_helpers.expect_error(format('update public.payroll_runs set gross_pay_total = 1 where id = %L', v_run), '23000', 'a posted run cannot change');
  perform test_helpers.expect_error(format('delete from public.payroll_run_lines where run_id = %L', v_run), '23000', 'its lines are frozen');
  perform test_helpers.expect_error(format('insert into public.payroll_adjustments (entity_id, run_id, employee_id, kind, label, amount) values (%L, %L, %L, ''earning'', ''x'', 1)', pt, v_run, test_helpers.g('A')), '23000', 'and takes no adjustment');
  perform test_helpers.pcontrols(pt, 'after posting');

  -- after posting, employees and tax facts of that month are protected
  perform test_helpers.login(v_pay);
  perform test_helpers.expect_msg(format('select public.employee_update(%L, ''Employee A'', ''2025-03-15'')', test_helpers.g('A')), 'CONFLICT', 'the join date of a counted employee cannot change');
  perform test_helpers.expect_msg(format('select public.employee_end(%L, ''key-p9c-x1'', ''2025-06-30'', ''Resigned'')', test_helpers.g('A')), 'CONFLICT', 'an employee cannot leave before a posted payroll month');
  perform test_helpers.expect_msg(format('select public.employee_set_tax_opening(%L, ''key-p9c-o1'', 2025, 5, ''1000000'', ''0'', ''0'')', test_helpers.g('A')), 'CONFLICT', 'opening figures cannot change once the year has posted payroll');
  perform test_helpers.expect_msg(format('select public.payroll_run_create(%L, ''key-p9c-r2'', ''2025-07-01'', ''2025-07-26'')', pt), 'CONFLICT', 'no second live run for July');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 3. payslip visibility
do $$
declare
  pt uuid := test_helpers.entity('p9c_pt');
  v_pay uuid := 'a1000000-0000-0000-0000-000000000002';
  v_acc uuid := 'a1000000-0000-0000-0000-000000000004';
  v_run uuid := test_helpers.g('jul');
  v_slip uuid;
  v_role uuid;
  s jsonb;
begin
  perform test_helpers.login(v_acc);
  perform test_helpers.expect_msg(format('select * from public.payroll_payslip_list(%L)', pt), 'FORBIDDEN', 'an accountant cannot list payslips');
  perform test_helpers.logout();
  perform test_helpers.login(v_pay);
  perform test_helpers.assert((select count(*) from public.payroll_payslip_list(pt, v_run)) = 3, 'the payroll user lists three payslips');
  perform test_helpers.assert((select count(*) from public.payroll_payslip_list(pt, v_run, test_helpers.g('A'))) = 1, 'and can filter by employee');
  select payslip_id into v_slip from public.payroll_payslip_list(pt, v_run, test_helpers.g('A'));
  s := public.payroll_payslip_get(v_slip);
  perform test_helpers.assert(s ->> 'status' = 'issued' and (s ->> 'net_pay')::numeric = 5670865 and (s #>> '{tax,pph21}')::numeric = 29135, 'payslip with the tax section');
  perform test_helpers.assert(s #>> '{employee,name}' = 'Employee A' and (s #>> '{bpjs_employer,kes}')::numeric = 200000, 'employee and BPJS sections');
  perform test_helpers.logout();
  -- without payroll.tax_view the tax section is removed
  insert into public.roles (role_key, name) values ('p9c_prep', 'P9C preparer') returning id into v_role;
  insert into public.role_permissions (role_id, permission_key) select v_role, k from unnest(array['payroll.compensation_view', 'payroll.run']) k;
  perform test_helpers.mk_user('a1000000-0000-0000-0000-000000000006', 'preparer');
  perform test_helpers.mk_member(pt, 'a1000000-0000-0000-0000-000000000006', 'p9c_prep');
  perform test_helpers.login('a1000000-0000-0000-0000-000000000006');
  s := public.payroll_payslip_get(v_slip);
  perform test_helpers.assert((s ->> 'net_pay')::numeric = 5670865 and not (s ? 'tax'), 'the preparer sees the payslip without the tax section');
  perform test_helpers.expect_msg(format('select * from public.payroll_employee_tax_ledger(%L, 2025)', pt), 'FORBIDDEN', 'the employee tax ledger needs the tax right');
  perform test_helpers.expect_msg(format('select * from public.payroll_annual_reconciliation(%L, 2025)', pt), 'FORBIDDEN', 'so does the annual reconciliation');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 4. paying net pay, BPJS and PPh 21
do $$
declare
  pt uuid := test_helpers.entity('p9c_pt');
  v_owner uuid := 'a1000000-0000-0000-0000-000000000001';
  v_pay uuid := 'a1000000-0000-0000-0000-000000000002';
  v_pay2 uuid := 'a1000000-0000-0000-0000-000000000003';
  v_acc uuid := 'a1000000-0000-0000-0000-000000000004';
  v_tax uuid := 'a1000000-0000-0000-0000-000000000005';
  v_run uuid := test_helpers.g('jul');
  v_bank uuid := test_helpers.g('bank');
  v_usd uuid := test_helpers.g('usd');
  v_p1 uuid;
  v_p2 uuid;
  v_p3 uuid;
  v_salary numeric;
begin
  v_salary := test_helpers.bal(pt, 'SALARY_EXPENSE');
  perform test_helpers.login(v_acc);
  perform test_helpers.expect_msg(format('select public.payroll_record_payment(%L, ''key-p9c-pm0'', ''net_pay'', ''2025-08-01'', %L)', v_run, v_bank), 'FORBIDDEN', 'an accountant cannot pay payroll');
  perform test_helpers.logout();

  perform test_helpers.login(v_pay, 'aal2', interval '3 hours');
  perform test_helpers.expect_msg(format('select public.payroll_record_payment(%L, ''key-p9c-pm1'', ''net_pay'', ''2025-08-01'', %L)', v_run, v_bank), 'STEP_UP_REQUIRED', 'a payment needs a recent step-up');
  perform test_helpers.logout();

  perform test_helpers.login(v_pay);
  perform test_helpers.expect_msg(format('select public.payroll_record_payment(%L, ''key-p9c-pm2'', ''severance'', ''2025-08-01'', %L)', v_run, v_bank), 'INVALID', 'a known payment kind');
  perform test_helpers.expect_msg(format('select public.payroll_record_payment(%L, ''key-p9c-pm3'', ''net_pay'', ''2025-07-30'', %L)', v_run, v_bank), 'INVALID', 'not before the payroll was posted');
  perform test_helpers.expect_msg(format('select public.payroll_record_payment(%L, ''key-p9c-pm4'', ''net_pay'', %L, %L)', v_run, test_helpers.today(pt) + 1, v_bank), 'INVALID', 'not in the future');
  perform test_helpers.expect_msg(format('select public.payroll_record_payment(%L, ''key-p9c-pm5'', ''net_pay'', ''2025-08-01'', %L)', v_run, v_usd), 'INVALID', 'from a base-currency account');
  perform test_helpers.expect_msg(format('select public.payroll_record_payment(%L, ''key-p9c-pm6'', ''net_pay'', ''2025-08-01'', %L)', v_run, gen_random_uuid()), 'INVALID', 'from a known account');
  perform test_helpers.expect_msg(format($q$select public.payroll_record_payment(%L, 'key-p9c-pm7', 'net_pay', '2025-08-01', %L, null, jsonb_build_array(jsonb_build_object('employee', %L, 'amount', '5670866')))$q$, v_run, v_bank, test_helpers.g('A')), 'INVALID', 'not more than the employee is owed');
  perform test_helpers.expect_msg(format($q$select public.payroll_record_payment(%L, 'key-p9c-pm8', 'net_pay', '2025-08-01', %L, null, jsonb_build_array(jsonb_build_object('employee', %L, 'amount', '1000'), jsonb_build_object('employee', %L, 'amount', '1000')))$q$, v_run, v_bank, test_helpers.g('A'), test_helpers.g('A')), 'INVALID', 'an employee only once per payment');
  perform test_helpers.expect_msg(format($q$select public.payroll_record_payment(%L, 'key-p9c-pm9', 'net_pay', '2025-08-01', %L, null, jsonb_build_array(jsonb_build_object('employee', %L, 'amount', '1000')))$q$, v_run, v_bank, gen_random_uuid()), 'INVALID', 'an employee of the run');
  perform test_helpers.expect_msg(format($q$select public.payroll_record_payment(%L, 'key-p9c-pm10', 'net_pay', '2025-08-01', %L, null, jsonb_build_array(jsonb_build_object('employee', %L, 'amount', '0')))$q$, v_run, v_bank, test_helpers.g('A')), 'INVALID', 'a positive amount');
  perform test_helpers.assert((select count(*) from public.payroll_payments_list(v_run)) = 0, 'refused payments change nothing');

  -- a part payment to A only
  v_p1 := public.payroll_record_payment(v_run, 'key-p9c-pm11', 'net_pay', '2025-08-01', v_bank, null,
    jsonb_build_array(jsonb_build_object('employee', test_helpers.g('A'), 'amount', '3000000')), 'TRF-001', 'first transfer');
  perform test_helpers.assert(v_p1 = public.payroll_record_payment(v_run, 'key-p9c-pm11', 'net_pay', '2025-08-01', v_bank, null,
    jsonb_build_array(jsonb_build_object('employee', test_helpers.g('A'), 'amount', '3000000')), 'TRF-001', 'first transfer'), 'the same key replays the same payment');
  perform test_helpers.assert(public.payroll_run_get(v_run) ->> 'status' = 'partially_paid' and (public.payroll_run_get(v_run) ->> 'net_paid')::numeric = 3000000, 'partially paid');
  perform test_helpers.assert((select net_paid::numeric from public.payroll_run_lines(v_run) where employee_id = test_helpers.g('A')) = 3000000, 'A has been paid 3,000,000');
  perform test_helpers.assert(test_helpers.bal(pt, 'PAYROLL_LIABILITY') = -21616865 + 3000000, 'the liability falls by the payment');
  perform test_helpers.assert(test_helpers.bal(pt, 'SALARY_EXPENSE') = v_salary, 'a payment books no second salary expense');
  perform test_helpers.expect_msg(format($q$select public.payroll_record_payment(%L, 'key-p9c-pm12', 'net_pay', '2025-08-02', %L, null, jsonb_build_array(jsonb_build_object('employee', %L, 'amount', '2670866')))$q$, v_run, v_bank, test_helpers.g('A')), 'INVALID', 'A is owed 2,670,865 only');
  perform test_helpers.pcontrols(pt, 'after the first payment');

  -- the rest of A and everyone else, in one payment
  v_p2 := public.payroll_record_payment(v_run, 'key-p9c-pm13', 'net_pay', '2025-08-02', v_bank);
  perform test_helpers.assert((select amount::numeric from public.payroll_payments_list(v_run) where payment_id = v_p2) = 18616865, 'the second payment is everything still owed');
  perform test_helpers.assert(public.payroll_run_get(v_run) ->> 'status' = 'paid', 'the run is paid');
  perform test_helpers.expect_msg(format('select public.payroll_record_payment(%L, ''key-p9c-pm14'', ''net_pay'', ''2025-08-03'', %L)', v_run, v_bank), 'INVALID', 'nothing is owed any more');
  perform test_helpers.assert(test_helpers.bal(pt, 'PAYROLL_LIABILITY') = 0, 'the net pay liability is cleared');
  perform test_helpers.assert(test_helpers.bal(pt, 'SALARY_EXPENSE') = v_salary, 'still no second salary expense');
  perform test_helpers.pcontrols(pt, 'after full payment');

  -- BPJS: a part, an excess, the rest
  v_p3 := public.payroll_record_payment(v_run, 'key-p9c-pm15', 'bpjs', '2025-08-05', v_bank, '300000');
  perform test_helpers.expect_msg(format('select public.payroll_record_payment(%L, ''key-p9c-pm16'', ''bpjs'', ''2025-08-06'', %L, ''500000'')', v_run, v_bank), 'INVALID', 'BPJS beyond its liability');
  perform test_helpers.expect_msg(format($q$select public.payroll_record_payment(%L, 'key-p9c-pm17', 'bpjs', '2025-08-06', %L, '100', jsonb_build_array(jsonb_build_object('employee', %L, 'amount', '100')))$q$, v_run, v_bank, test_helpers.g('A')), 'INVALID', 'BPJS is paid in one amount, not per employee');
  perform public.payroll_record_payment(v_run, 'key-p9c-pm18', 'bpjs', '2025-08-06', v_bank);
  perform test_helpers.assert(test_helpers.bal(pt, 'BPJS_LIABILITY') = 0, 'the BPJS liability is cleared');
  perform test_helpers.assert((public.payroll_run_get(v_run) ->> 'bpjs_paid')::numeric = 712000, 'BPJS paid in two parts');
  perform test_helpers.pcontrols(pt, 'after BPJS');
  perform test_helpers.logout();

  -- PPh 21 goes through the tax payment of the tax layer
  perform test_helpers.login(v_tax);
  perform test_helpers.expect_msg(format('select public.tax_record_payment(%L, ''key-p9c-tp-0'', ''wht_pph21'', ''2025-07-01'', ''2025-08-10'', %L, ''400000'')', pt, v_bank), 'INVALID', 'PPh 21 beyond what is outstanding');
  perform public.tax_record_payment(pt, 'key-p9c-tp-1', 'wht_pph21', '2025-07-01', '2025-08-10', v_bank, '313314', '0', '0', 'NTPN-P9C-1', 'PPh 21 July (synthetic)');
  perform test_helpers.logout();
  perform test_helpers.assert(test_helpers.bal(pt, 'TAX_PAYABLE') = 0, 'the PPh 21 liability is cleared');
  perform test_helpers.pcontrols(pt, 'after the PPh 21 payment');
  -- the cash side: every rupiah left the bank exactly once: net pay 21,616,865 + BPJS 712,000 + PPh 21 313,314
  perform test_helpers.assert(test_helpers.bal(pt, 'BANK_OPERATING') = -(21616865 + 712000 + 313314), 'the bank paid out the three liabilities');
end
$$;

-- ================================================================ 5. reversing payments, closing, reopening
do $$
declare
  pt uuid := test_helpers.entity('p9c_pt');
  v_pay uuid := 'a1000000-0000-0000-0000-000000000002';
  v_pay2 uuid := 'a1000000-0000-0000-0000-000000000003';
  v_run uuid := test_helpers.g('jul');
  v_bank uuid := test_helpers.g('bank');
  v_first uuid;
  v_rev uuid;
begin
  perform test_helpers.login(v_pay);
  select payment_id into v_first from public.payroll_payments_list(v_run) where kind = 'net_pay' order by payment_date, payment_number limit 1;
  perform test_helpers.expect_msg(format('select public.payroll_reverse_payment(%L, ''key-p9c-rv0'', ''2025-08-03'', ''no'')', v_first), 'INVALID', 'a reversal needs a reason');
  perform test_helpers.expect_msg(format('select public.payroll_reverse_payment(%L, ''key-p9c-rv1'', ''2025-07-31'', ''Wrong account used'')', v_first), 'INVALID', 'not before the payment');
  v_rev := public.payroll_reverse_payment(v_first, 'key-p9c-rv2', '2025-08-03', 'Transfer was rejected by the bank');
  perform test_helpers.assert(v_rev = public.payroll_reverse_payment(v_first, 'key-p9c-rv2', '2025-08-03', 'Transfer was rejected by the bank'), 'a reversal replays');
  perform test_helpers.expect_msg(format('select public.payroll_reverse_payment(%L, ''key-p9c-rv3'', ''2025-08-04'', ''Reversed twice by error'')', v_first), 'CONFLICT', 'a payment is reversed once');
  perform test_helpers.assert(public.payroll_run_get(v_run) ->> 'status' = 'partially_paid', 'the run is partly paid again');
  perform test_helpers.assert((select net_paid::numeric from public.payroll_run_lines(v_run) where employee_id = test_helpers.g('A')) = 2670865, 'A: only the later payment stands');
  perform test_helpers.assert(test_helpers.bal(pt, 'PAYROLL_LIABILITY') = -3000000, 'the liability is back by the reversed 3,000,000');
  perform test_helpers.assert((select status from public.payroll_payments_list(v_run) where payment_id = v_first) = 'reversed', 'the payment shows as reversed');
  perform test_helpers.pcontrols(pt, 'after reversing a payment');
  -- pay it again, exactly the 3,000,000 that came back
  perform public.payroll_record_payment(v_run, 'key-p9c-pm19', 'net_pay', '2025-08-04', v_bank);
  perform test_helpers.assert(public.payroll_run_get(v_run) ->> 'status' = 'paid', 'paid again');
  perform test_helpers.logout();
  perform test_helpers.expect_error(format('update public.payroll_payments set amount = 1 where id = %L', v_first), '23000', 'a payment is history');
  perform test_helpers.expect_error(format('delete from public.payroll_payments where id = %L', v_first), null, 'a payment is not deleted');

  -- closing and reopening
  perform test_helpers.login(v_pay2);
  perform public.payroll_run_close(v_run, 'key-p9c-cl1');
  perform public.payroll_run_close(v_run, 'key-p9c-cl1');
  perform test_helpers.assert(public.payroll_run_get(v_run) ->> 'status' = 'closed', 'closed (a replay is a no-op)');
  perform test_helpers.expect_msg(format('select public.payroll_run_close(%L, ''key-p9c-cl2'')', v_run), 'CONFLICT', 'closed once');
  perform test_helpers.expect_msg(format('select public.payroll_record_payment(%L, ''key-p9c-pm20'', ''bpjs'', ''2025-08-06'', %L, ''1'')', v_run, v_bank), 'CONFLICT', 'a closed run takes no payment');
  perform test_helpers.expect_msg(format('select public.payroll_run_correct(%L, ''key-p9c-cr0'', ''2025-08-10'', ''Closed run cannot be corrected'')', v_run), 'CONFLICT', 'a closed run is reopened before it is corrected');
  perform test_helpers.logout();
  perform test_helpers.login(v_pay2, 'aal2', interval '3 hours');
  perform test_helpers.expect_msg(format('select public.payroll_run_reopen(%L, ''key-p9c-ro0'', ''Fixing a bank error'')', v_run), 'STEP_UP_REQUIRED', 'reopening needs a recent step-up');
  perform test_helpers.logout();
  perform test_helpers.login(v_pay2);
  perform test_helpers.expect_msg(format('select public.payroll_run_reopen(%L, ''key-p9c-ro1'', ''no'')', v_run), 'INVALID', 'reopening needs a reason');
  perform public.payroll_run_reopen(v_run, 'key-p9c-ro2', 'Fixing a bank error');
  perform test_helpers.assert(public.payroll_run_get(v_run) ->> 'status' = 'paid', 'reopened to paid');
  perform test_helpers.expect_msg(format('select public.payroll_run_reopen(%L, ''key-p9c-ro3'', ''Reopened twice by mistake'')', v_run), 'CONFLICT', 'only a closed run reopens');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 6. August, the latest-month rule and the correction of July
do $$
declare
  pt uuid := test_helpers.entity('p9c_pt');
  v_pay uuid := 'a1000000-0000-0000-0000-000000000002';
  v_pay2 uuid := 'a1000000-0000-0000-0000-000000000003';
  v_jul uuid := test_helpers.g('jul');
  v_aug uuid;
  v_new uuid;
  v_new2 uuid;
  v_pmt record;
begin
  perform test_helpers.login(v_pay);
  v_aug := test_helpers.put('aug', public.payroll_run_create(pt, 'key-p9c-r3', '2025-08-01', '2025-08-25'));
  perform public.payroll_run_calculate(v_aug);
  perform public.payroll_run_submit(v_aug, 'key-p9c-s2');
  perform test_helpers.logout();
  perform test_helpers.login(v_pay2);
  perform public.payroll_run_approve(v_aug, 'key-p9c-ap2');
  perform public.payroll_run_post(v_aug, 'key-p9c-po4');
  perform test_helpers.assert(public.payroll_run_get(v_aug) ->> 'status' = 'posted', 'August is posted');
  perform test_helpers.pcontrols(pt, 'after August');

  -- July has payments and a later posted month: both block the correction
  perform test_helpers.expect_msg(format('select public.payroll_run_correct(%L, ''key-p9c-cr1'', ''2025-09-05'', ''Bonus was forgotten in July'')', v_jul), 'CONFLICT: reverse the payments', 'payments are reversed first');
  perform test_helpers.logout();
  perform test_helpers.login(v_pay2);
  for v_pmt in select payment_id from public.payroll_payments_list(v_jul) where status = 'confirmed' order by payment_date desc, payment_number desc loop
    perform public.payroll_reverse_payment(v_pmt.payment_id, 'key-p9c-rv-' || substr(v_pmt.payment_id::text, 1, 8), '2025-09-04', 'Payroll of July is being corrected');
  end loop;
  perform test_helpers.assert(public.payroll_run_get(v_jul) ->> 'status' = 'posted', 'July is posted again once every payment is reversed');
  perform test_helpers.pcontrols(pt, 'after reversing all July payments');
  perform test_helpers.expect_msg(format('select public.payroll_run_correct(%L, ''key-p9c-cr2'', ''2025-09-05'', ''Bonus was forgotten in July'')', v_jul), 'CONFLICT: a later month', 'the latest month is corrected first');
  perform test_helpers.logout();

  -- correct August first (no payments), then July
  perform test_helpers.login(v_pay2, 'aal2', interval '3 hours');
  perform test_helpers.expect_msg(format('select public.payroll_run_correct(%L, ''key-p9c-cr3'', ''2025-09-05'', ''August was posted by mistake'')', v_aug), 'STEP_UP_REQUIRED', 'a correction needs a recent step-up');
  perform test_helpers.logout();
  perform test_helpers.login(v_pay2);
  perform test_helpers.expect_msg(format('select public.payroll_run_correct(%L, ''key-p9c-cr4'', ''2025-09-05'', ''bad'')', v_aug), 'INVALID', 'a correction needs a reason');
  perform test_helpers.expect_msg(format('select public.payroll_run_correct(%L, ''key-p9c-cr5'', %L, ''August was posted by mistake'')', v_aug, test_helpers.today(pt) + 1), 'INVALID', 'not in the future');
  v_new2 := public.payroll_run_correct(v_aug, 'key-p9c-cr6', '2025-09-05', 'August was posted by mistake');
  perform test_helpers.assert(v_new2 = public.payroll_run_correct(v_aug, 'key-p9c-cr6', '2025-09-05', 'August was posted by mistake'), 'a correction replays');
  perform test_helpers.assert(public.payroll_run_get(v_aug) ->> 'status' = 'corrected' and public.payroll_run_get(v_new2) ->> 'status' = 'draft', 'August is corrected; a draft revision opens');
  v_new := public.payroll_run_correct(v_jul, 'key-p9c-cr7', '2025-09-05', 'Bonus was forgotten in July');
  perform test_helpers.put('jul2', v_new);
  perform test_helpers.assert(public.payroll_run_get(v_jul) ->> 'status' = 'corrected' and public.payroll_run_get(v_new) ->> 'status' = 'draft', 'July is corrected; a draft revision opens');
  perform test_helpers.assert((public.payroll_run_get(v_new) ->> 'corrects_run_id')::uuid = v_jul, 'the revision points at the run it corrects');
  perform test_helpers.assert((select revision from public.payroll_run_list(pt) where run_id = v_new) = 2
    and (select run_number from public.payroll_run_list(pt) where run_id = v_new) = (select run_number from public.payroll_run_list(pt) where run_id = v_jul), 'revision 2 of the same run number');
  perform test_helpers.logout();

  -- the reversal: journal, tax ledger, payslips
  perform test_helpers.assert((select count(*) from public.payroll_payslips where run_id = v_jul and status = 'voided') = 3
    and (select count(*) from public.payroll_payslips where run_id = v_jul and status = 'issued') = 0, 'the July payslips are voided, not deleted');
  perform test_helpers.assert((select reversal_journal_id from public.payroll_runs where id = v_jul) is not null
    and test_helpers.jc((select reversal_journal_id from public.payroll_runs where id = v_jul), 'SALARY_EXPENSE') = 22130179, 'the reversal journal credits salary expense');
  perform test_helpers.assert(test_helpers.bal(pt, 'SALARY_EXPENSE') = 0 and test_helpers.bal(pt, 'PAYROLL_LIABILITY') = 0 and test_helpers.bal(pt, 'BPJS_LIABILITY') = 0
    and test_helpers.bal(pt, 'EMPLOYER_BENEFIT_EXPENSE') = 0, 'both months are fully reversed in the ledger');
  perform test_helpers.assert((select coalesce(sum(amount), 0) from public.tax_ledger_entries where entity_id = pt and tax_type = 'wht_pph21' and entry_kind = 'reversal') < 0, 'the tax ledger holds the reversals');
  perform test_helpers.assert((select count(*) from public.tax_determinations where source_type = 'payroll_run' and source_id in (v_jul, v_aug) and superseded_at is null) = 0, 'no live determination of the corrected runs');
  perform test_helpers.pcontrols(pt, 'after the corrections');

  -- July is calculated, approved and posted again as revision 2, the same taxes accrue again
  perform test_helpers.login(v_pay);
  perform test_helpers.put('jul_bonus', public.payroll_adjustment_add(v_new, 'key-p9c-ad2', test_helpers.g('A'), 'earning', 'Bonus', '1000000'));
  perform public.payroll_run_calculate(v_new);
  perform public.payroll_run_submit(v_new, 'key-p9c-s3');
  perform test_helpers.logout();
  perform test_helpers.login(v_pay2);
  perform public.payroll_run_approve(v_new, 'key-p9c-ap3');
  perform public.payroll_run_post(v_new, 'key-p9c-po5');
  -- A with the bonus, by hand: taxable 6,827,000 -> TER A 1.25% = 85,337; gross 6,900,000; net 6,900,000 - 200,000 - 85,337 = 6,614,663
  perform test_helpers.assert((select net_pay::numeric from public.payroll_run_lines(v_new) where employee_id = test_helpers.g('A')) = 6614663
    and (select pph21::numeric from public.payroll_run_lines(v_new) where employee_id = test_helpers.g('A')) = 85337, 'revision 2 carries the bonus');
  perform test_helpers.assert((public.payroll_run_get(v_new) ->> 'pph21_total')::numeric = 313314 - 29135 + 85337, 'and the new PPh 21 total');
  perform test_helpers.assert((select count(*) from public.payroll_payslip_list(pt, v_new) where status = 'issued') = 3, 'three new payslips');
  perform test_helpers.assert((select count(*) from public.payroll_payslip_list(pt, null, test_helpers.g('A')) where status = 'issued') = 1, 'one live payslip per employee and month');
  perform test_helpers.pcontrols(pt, 'after revision 2');
  perform test_helpers.logout();
  -- Tax Payables, by hand: July 313,314 paid 313,314; August 313,314; both reversed; July revision 2 owes 369,516:
  -- 369,516 owed less the 313,314 that was paid against the reversed accrual = 56,202 still payable
  perform test_helpers.assert(-test_helpers.bal(pt, 'TAX_PAYABLE') = 56202, 'Tax Payables carry what revision 2 owes beyond what was paid');
end
$$;

rollback;
