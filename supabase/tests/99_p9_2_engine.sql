-- P9 gate, part 2 (Step 05 §9, Step 07 §14, Step 08 §13, Step 15 §13): the payroll run and its calculation. Every
-- expected number below is worked out by hand from the published rule data (PMK 168/2023 TER table, the BPJS rates and
-- caps, Pasal 17 with PTKP), not read back from the engine. Covers the run lifecycle up to approval (create, calculate,
-- adjustments, review flags, submit, return, approve, discard, one live run per month, stale inputs), BPJS shares and
-- caps, TER, the gross-up allowance, the no-tax-number surcharge, the annual computation of December with opening
-- figures and over-withholding, and the payroll permission boundary of the reads. Posting and payments follow in the
-- next files. All data is synthetic; payroll months are fixed in 2025. The file runs in one rolled-back transaction.
begin;
set local client_min_messages = warning;

create table test_helpers.p9b (k text primary key, v uuid not null);
grant all on test_helpers.p9b to public;
create function test_helpers.put(p_k text, p_v uuid) returns uuid
language sql as $f$ insert into test_helpers.p9b values (p_k, p_v) on conflict (k) do update set v = excluded.v returning v $f$;
create function test_helpers.g(p_k text) returns uuid
language sql stable as $f$ select v from test_helpers.p9b where k = p_k $f$;
grant execute on function test_helpers.put(text, uuid), test_helpers.g(text) to public;

-- One line of a run as the payroll clerk sees it, by employee key.
create function test_helpers.ln(p_run uuid, p_emp text) returns record
language sql stable as $f$
  select l.* from public.payroll_run_lines(p_run) l where l.employee_id = test_helpers.g(p_emp)
$f$;
grant execute on function test_helpers.ln(uuid, text) to public;

-- ================================================================ fixtures (superuser)
do $$
declare
  v_pt uuid;
  v_pe uuid;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p9b_pt', 'P9B PT (synthetic)') returning id into v_pt;
  perform app_private.provision_default_coa(v_pt);
  insert into public.entities (entity_type, code, legal_name) values ('personal', 'p9b_pe', 'P9B PERSONAL (synthetic)') returning id into v_pe;
  perform app_private.provision_default_coa(v_pe);
  perform test_helpers.mk_user('f0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_user('f0000000-0000-0000-0000-000000000002', 'payroll');
  perform test_helpers.mk_user('f0000000-0000-0000-0000-000000000003', 'payroll two');
  perform test_helpers.mk_user('f0000000-0000-0000-0000-000000000004', 'accountant');
  perform test_helpers.mk_member(v_pt, 'f0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pe, 'f0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pt, 'f0000000-0000-0000-0000-000000000002', 'payroll');
  perform test_helpers.mk_member(v_pt, 'f0000000-0000-0000-0000-000000000003', 'payroll');
  perform test_helpers.mk_member(v_pt, 'f0000000-0000-0000-0000-000000000004', 'accountant');
end
$$;

-- ================================================================ 1. the employees of the June 2025 payroll
do $$
declare
  pt uuid := test_helpers.entity('p9b_pt');
  v_pay uuid := 'f0000000-0000-0000-0000-000000000002';
  e uuid;
begin
  perform test_helpers.login(v_pay);
  -- A: three earnings (one not taxable), full BPJS with JKK grade 1
  e := test_helpers.put('A', public.employee_create(pt, 'key-p9b-A', 'Employee A', '2025-03-01', 'permanent', 'Staff'));
  perform public.employee_set_compensation(e, 'key-p9b-A-c', '2025-03-01', jsonb_build_array(
    jsonb_build_object('component', 'basic', 'kind', 'earning', 'label', 'Gaji pokok', 'amount', '5000000', 'bpjs_base', true),
    jsonb_build_object('component', 'meal', 'kind', 'earning', 'label', 'Uang makan', 'amount', '600000'),
    jsonb_build_object('component', 'transport', 'kind', 'earning', 'label', 'Transport', 'amount', '300000', 'taxable', false)));
  perform public.employee_set_tax_profile(e, 'key-p9b-A-t', '2025-03-01', 'has_tax_id', '3200000000000001', 'TK/0');
  perform public.employee_set_bpjs(e, 'key-p9b-A-b', '2025-03-01', '[
    {"component":"bpjs_kes","enrolled":true},{"component":"bpjs_jht","enrolled":true},{"component":"bpjs_jp","enrolled":true},
    {"component":"bpjs_jkk","enrolled":true,"rate_key":"grade_1"},{"component":"bpjs_jkm","enrolled":true}]'::jsonb);
  -- B: a high earner above the Kes and JP wage caps, category B
  e := test_helpers.put('B', public.employee_create(pt, 'key-p9b-B', 'Employee B', '2025-06-01', 'contract', 'Manager'));
  perform public.employee_set_compensation(e, 'key-p9b-B-c', '2025-06-01', jsonb_build_array(
    jsonb_build_object('component', 'basic', 'kind', 'earning', 'label', 'Gaji pokok', 'amount', '15000000', 'bpjs_base', true)));
  perform public.employee_set_tax_profile(e, 'key-p9b-B-t', '2025-06-01', 'has_tax_id', '3200000000000002', 'TK/2');
  perform public.employee_set_bpjs(e, 'key-p9b-B-b', '2025-06-01', '[
    {"component":"bpjs_kes","enrolled":true},{"component":"bpjs_jht","enrolled":true},{"component":"bpjs_jp","enrolled":true}]'::jsonb);
  -- C: the employer bears the tax (gross-up); joins in the middle of the month
  e := test_helpers.put('C', public.employee_create(pt, 'key-p9b-C', 'Employee C', '2025-06-10', 'permanent', 'Director'));
  perform public.employee_set_compensation(e, 'key-p9b-C-c', '2025-06-10', jsonb_build_array(
    jsonb_build_object('component', 'basic', 'kind', 'earning', 'label', 'Gaji pokok', 'amount', '10000000')));
  perform public.employee_set_tax_profile(e, 'key-p9b-C-t', '2025-06-10', 'has_tax_id', '3200000000000003', 'TK/0', 'gross_up');
  -- D: no tax number: the withholding is 20% higher
  e := test_helpers.put('D', public.employee_create(pt, 'key-p9b-D', 'Employee D', '2025-04-01', 'permanent', 'Clerk'));
  perform public.employee_set_compensation(e, 'key-p9b-D-c', '2025-04-01', jsonb_build_array(
    jsonb_build_object('component', 'basic', 'kind', 'earning', 'label', 'Gaji pokok', 'amount', '6000000')));
  perform public.employee_set_tax_profile(e, 'key-p9b-D-t', '2025-04-01', 'no_tax_id', null, 'TK/0');
  -- E: tax facts unknown; F: no compensation; G: JKK enrolled without a risk grade
  e := test_helpers.put('E', public.employee_create(pt, 'key-p9b-E', 'Employee E', '2025-05-01', 'permanent', 'Clerk'));
  perform public.employee_set_compensation(e, 'key-p9b-E-c', '2025-05-01', jsonb_build_array(
    jsonb_build_object('component', 'basic', 'kind', 'earning', 'label', 'Gaji pokok', 'amount', '5000000')));
  perform public.employee_set_tax_profile(e, 'key-p9b-E-t', '2025-05-01', 'unknown', null, 'unknown');
  e := test_helpers.put('F', public.employee_create(pt, 'key-p9b-F', 'Employee F', '2025-05-01', 'permanent', 'Clerk'));
  perform public.employee_set_tax_profile(e, 'key-p9b-F-t', '2025-05-01', 'has_tax_id', '3200000000000006', 'TK/0');
  e := test_helpers.put('G', public.employee_create(pt, 'key-p9b-G', 'Employee G', '2025-05-01', 'permanent', 'Clerk'));
  perform public.employee_set_compensation(e, 'key-p9b-G-c', '2025-05-01', jsonb_build_array(
    jsonb_build_object('component', 'basic', 'kind', 'earning', 'label', 'Gaji pokok', 'amount', '5000000', 'bpjs_base', true)));
  perform public.employee_set_tax_profile(e, 'key-p9b-G-t', '2025-05-01', 'has_tax_id', '3200000000000007', 'TK/0');
  perform public.employee_set_bpjs(e, 'key-p9b-G-b', '2025-05-01', '[{"component":"bpjs_jkk","enrolled":true}]'::jsonb);
  perform test_helpers.logout();
end
$$;

-- ================================================================ 2. creating a run
do $$
declare
  pt uuid := test_helpers.entity('p9b_pt');
  pe uuid := test_helpers.entity('p9b_pe');
  v_pay uuid := 'f0000000-0000-0000-0000-000000000002';
  v_acc uuid := 'f0000000-0000-0000-0000-000000000004';
  v_owner uuid := 'f0000000-0000-0000-0000-000000000001';
  v_run uuid;
  v_again uuid;
begin
  perform test_helpers.login(v_acc);
  perform test_helpers.expect_msg(format('select public.payroll_run_create(%L, ''key-p9b-r0'', ''2025-06-01'', ''2025-06-28'')', pt), 'FORBIDDEN', 'an accountant cannot create a run');
  perform test_helpers.expect_msg(format('select * from public.payroll_run_list(%L)', pt), 'FORBIDDEN', 'an accountant cannot list runs');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.payroll_run_create(%L, ''key-p9b-r0a'', ''2025-06-01'', ''2025-06-28'')', pe), 'INVALID', 'a Personal Entity has no payroll');
  perform test_helpers.logout();

  perform test_helpers.login(v_pay);
  perform test_helpers.expect_msg(format('select public.payroll_run_create(%L, ''key-p9b-r1'', null, ''2025-06-28'')', pt), 'INVALID', 'a payroll month');
  perform test_helpers.expect_msg(format('select public.payroll_run_create(%L, ''key-p9b-r2'', ''2025-06-01'', null)', pt), 'INVALID', 'a pay date');
  perform test_helpers.expect_msg(format('select public.payroll_run_create(%L, ''key-p9b-r3'', ''2025-06-01'', ''2025-05-31'')', pt), 'INVALID', 'the pay date is not before the month');
  perform test_helpers.expect_msg(format('select public.payroll_run_create(%L, ''key-p9b-r4'', %L, %L)', pt, test_helpers.today(pt) + 40, test_helpers.today(pt) + 45), 'INVALID', 'not a month that has not started');
  v_run := public.payroll_run_create(pt, 'key-p9b-r5', '2025-06-17', '2025-06-28', 'June payroll (synthetic)');
  v_again := public.payroll_run_create(pt, 'key-p9b-r5', '2025-06-17', '2025-06-28', 'June payroll (synthetic)');
  perform test_helpers.assert(v_run = v_again, 'the same key replays the same run');
  perform test_helpers.put('jun', v_run);
  perform test_helpers.assert((select r.status || '/' || r.period_start || '/' || r.period_end || '/' || r.revision
                               from public.payroll_run_list(pt) r where r.run_id = v_run) = 'draft/2025-06-01/2025-06-30/1', 'a draft run for the whole month');
  perform test_helpers.assert((select run_number from public.payroll_run_list(pt) where run_id = v_run) like 'PR-%', 'the run number comes from its numbering family');
  perform test_helpers.expect_msg(format('select public.payroll_run_create(%L, ''key-p9b-r6'', ''2025-06-01'', ''2025-06-29'')', pt), 'CONFLICT', 'one live run per payroll month');
  perform test_helpers.expect_msg(format('select public.payroll_run_submit(%L, ''key-p9b-s0'')', v_run), 'CONFLICT', 'a draft run cannot be submitted before it is calculated');
  perform test_helpers.expect_msg(format('select public.payroll_run_approve(%L, ''key-p9b-ap0'')', v_run), 'CONFLICT', 'nor approved');
  perform test_helpers.expect_msg(format('select public.payroll_run_post(%L, ''key-p9b-po0'')', v_run), 'CONFLICT', 'nor posted');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 3. the first calculation: what needs review
do $$
declare
  v_pay uuid := 'f0000000-0000-0000-0000-000000000002';
  v_run uuid := test_helpers.g('jun');
  r record;
  j jsonb;
begin
  perform test_helpers.login(v_pay);
  perform public.payroll_run_calculate(v_run);
  j := public.payroll_run_get(v_run);
  perform test_helpers.assert(j ->> 'status' = 'calculated' and (j ->> 'employee_count')::int = 7, 'calculated: seven employees are part of the month');
  perform test_helpers.assert((j ->> 'review_count')::int = 3, 'three lines need review: E, F and G');
  perform test_helpers.assert((select review_flags from public.payroll_run_lines(v_run) where employee_id = test_helpers.g('E')) = array['tax_facts_missing'], 'E: unknown tax facts');
  perform test_helpers.assert((select review_flags from public.payroll_run_lines(v_run) where employee_id = test_helpers.g('F')) = array['no_compensation'], 'F: no compensation');
  perform test_helpers.assert((select review_flags from public.payroll_run_lines(v_run) where employee_id = test_helpers.g('G')) = array['bpjs_rate_option_missing:bpjs_jkk'], 'G: JKK needs its risk grade');
  perform test_helpers.assert((select info_flags from public.payroll_run_lines(v_run) where employee_id = test_helpers.g('C')) = array['joined_during_month'], 'C: joined during the month (information only)');
  perform test_helpers.assert(exists (select 1 from public.payroll_run_lines(v_run) where employee_id = test_helpers.g('A') and review_flags = '{}' and info_flags = '{}'), 'A is clean');
  perform test_helpers.assert(j -> 'rules' is not null and jsonb_array_length(j -> 'rules') > 0, 'the rule versions used are recorded on the run');
  perform test_helpers.expect_msg(format('select public.payroll_run_submit(%L, ''key-p9b-s1'')', v_run), 'INVALID', 'a run with lines to review cannot be submitted');

  -- A, by hand: BPJS on 5,000,000 (basic only): Kes 1% 50,000 / 4% 200,000; JHT 2% 100,000 / 3.7% 185,000; JP 1% 50,000 / 2% 100,000;
  -- JKK 0.24% 12,000; JKM 0.3% 15,000. Taxable = 5,600,000 + employer Kes/JKK/JKM 227,000 = 5,827,000; TER A 0.5% -> 29,135.
  select * into r from public.payroll_run_lines(v_run) where employee_id = test_helpers.g('A');
  perform test_helpers.assert(r.gross_pay::numeric = 5900000 and r.bpjs_wage_base::numeric = 5000000, 'A: gross and BPJS wage base');
  perform test_helpers.assert(r.bpjs_employee::numeric = 200000 and r.bpjs_employer::numeric = 512000, 'A: BPJS shares');
  perform test_helpers.assert(r.tax_base::numeric = 5827000 and r.tax_mode = 'ter' and r.pph21::numeric = 29135 and r.tax_allowance::numeric = 0, 'A: TER on taxable income including employer Kes/JKK/JKM');
  perform test_helpers.assert(r.net_pay::numeric = 5670865, 'A: net pay = 5,900,000 - 200,000 - 29,135');
  perform test_helpers.assert(r.tax_calc ->> 'category' = 'A' and r.tax_calc ->> 'rate' = '0.005', 'A: the working shows category and rate');

  -- B, by hand: caps: Kes 12,000,000 x 1% / 4% = 120,000 / 480,000; JHT on 15,000,000: 300,000 / 555,000; JP on 10,547,400: 105,474 / 210,948.
  -- Taxable = 15,000,000 + 480,000 = 15,480,000; category B (TK/2) 6% -> 928,800.
  select * into r from public.payroll_run_lines(v_run) where employee_id = test_helpers.g('B');
  perform test_helpers.assert(r.bpjs_employee::numeric = 525474 and r.bpjs_employer::numeric = 1245948, 'B: BPJS with the Kes and JP wage caps');
  perform test_helpers.assert(r.tax_base::numeric = 15480000 and r.pph21::numeric = 928800 and r.tax_calc ->> 'category' = 'B', 'B: category B at 6%');
  perform test_helpers.assert(r.net_pay::numeric = 13545726, 'B: net pay');

  -- C, by hand: the allowance a solves a = floor(2.25% x (10,000,000 + a)) = 230,178; net pay is the gross (the employer pays the tax).
  select * into r from public.payroll_run_lines(v_run) where employee_id = test_helpers.g('C');
  perform test_helpers.assert(r.tax_method = 'gross_up' and r.pph21::numeric = 230179 and r.tax_allowance::numeric = 230179, 'C: gross-up allowance');
  perform test_helpers.assert(r.tax_base::numeric = 10000000 and r.net_pay::numeric = 10000000, 'C: the employee receives the full salary');
  perform test_helpers.assert(r.tax_calc ->> 'base' = '10230179', 'C: the taxed base includes the allowance');

  -- D, by hand: 6,000,000 x 0.75% x 1.2 = 54,000
  select * into r from public.payroll_run_lines(v_run) where employee_id = test_helpers.g('D');
  perform test_helpers.assert(r.pph21::numeric = 54000 and r.net_pay::numeric = 5946000 and (r.tax_calc ->> 'no_tax_id')::boolean, 'D: no tax number = 120% of the TER tax');

  -- a flagged line carries no guessed tax
  select * into r from public.payroll_run_lines(v_run) where employee_id = test_helpers.g('E');
  perform test_helpers.assert(r.pph21::numeric = 0 and r.tax_mode is null, 'E: no tax is guessed for unknown facts');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 4. resolving the flags, the totals, adjustments
do $$
declare
  pt uuid := test_helpers.entity('p9b_pt');
  v_pay uuid := 'f0000000-0000-0000-0000-000000000002';
  v_run uuid := test_helpers.g('jun');
  r record;
  j jsonb;
  v_adj uuid;
  v_adj2 uuid;
begin
  perform test_helpers.login(v_pay);
  perform public.employee_set_tax_profile(test_helpers.g('E'), 'key-p9b-E-t2', '2025-06-01', 'has_tax_id', '3200000000000005', 'TK/1');
  perform public.employee_set_compensation(test_helpers.g('F'), 'key-p9b-F-c', '2025-06-01', jsonb_build_array(
    jsonb_build_object('component', 'basic', 'kind', 'earning', 'label', 'Gaji pokok', 'amount', '4000000')));
  perform public.employee_set_bpjs(test_helpers.g('G'), 'key-p9b-G-b2', '2025-06-01', '[{"component":"bpjs_jkk","enrolled":true,"rate_key":"grade_2"}]'::jsonb);
  perform test_helpers.assert((public.payroll_run_get(v_run) ->> 'stale')::boolean, 'a calculated run whose inputs changed is stale');
  perform public.payroll_run_calculate(v_run);
  j := public.payroll_run_get(v_run);
  perform test_helpers.assert((j ->> 'review_count')::int = 0, 'nothing left to review');
  -- G, by hand: JKK grade 2 = 0.54% x 5,000,000 = 27,000 (taxable benefit): taxable 5,027,000 -> TER 0%
  select * into r from public.payroll_run_lines(v_run) where employee_id = test_helpers.g('G');
  perform test_helpers.assert(r.bpjs_employer::numeric = 27000 and r.tax_base::numeric = 5027000 and r.pph21::numeric = 0, 'G: JKK grade 2');
  perform test_helpers.assert((select pph21::numeric from public.payroll_run_lines(v_run) where employee_id = test_helpers.g('E')) = 0
    and (select net_pay::numeric from public.payroll_run_lines(v_run) where employee_id = test_helpers.g('F')) = 4000000, 'E and F are computed');
  -- totals, by hand
  perform test_helpers.assert((j ->> 'gross_pay_total')::numeric = 50900000, 'total gross');
  perform test_helpers.assert((j ->> 'employee_bpjs_total')::numeric = 725474 and (j ->> 'employer_bpjs_total')::numeric = 1784948, 'BPJS totals');
  perform test_helpers.assert((j ->> 'pph21_total')::numeric = 1242114 and (j ->> 'tax_allowance_total')::numeric = 230179, 'PPh 21 total and allowance');
  perform test_helpers.assert((j ->> 'net_pay_total')::numeric = 49162591, 'total net pay');
  perform test_helpers.assert((j ->> 'tax_base_total')::numeric = 51334000, 'total tax base');

  -- adjustments: a bonus and an unpaid-leave deduction for A change its tax by the TER of the new taxable income
  perform test_helpers.expect_msg(format('select public.payroll_adjustment_add(%L, ''key-p9b-ad0'', %L, ''earning'', ''Bonus'', ''-5'')', v_run, test_helpers.g('A')), 'INVALID', 'a positive amount');
  perform test_helpers.expect_msg(format('select public.payroll_adjustment_add(%L, ''key-p9b-ad1'', %L, ''gift'', ''Bonus'', ''100'')', v_run, test_helpers.g('A')), 'INVALID', 'a known kind');
  perform test_helpers.expect_msg(format('select public.payroll_adjustment_add(%L, ''key-p9b-ad2'', %L, ''earning'', '' '', ''100'')', v_run, test_helpers.g('A')), 'INVALID', 'a label');
  perform test_helpers.expect_msg(format('select public.payroll_adjustment_add(%L, ''key-p9b-ad3'', %L, ''earning'', ''Bonus'', ''100.555'')', v_run, test_helpers.g('A')), 'INVALID', 'no more decimals than the currency');
  perform test_helpers.expect_msg(format('select public.payroll_adjustment_add(%L, ''key-p9b-ad4'', %L, ''earning'', ''Bonus'', ''100'')', v_run, gen_random_uuid()), 'INVALID', 'an employee of this payroll month');
  v_adj := public.payroll_adjustment_add(v_run, 'key-p9b-ad5', test_helpers.g('A'), 'earning', 'Bonus', '1000000');
  perform test_helpers.assert(v_adj = public.payroll_adjustment_add(v_run, 'key-p9b-ad5', test_helpers.g('A'), 'earning', 'Bonus', '1000000'), 'the same key replays the same adjustment');
  v_adj2 := public.payroll_adjustment_add(v_run, 'key-p9b-ad6', test_helpers.g('A'), 'deduction', 'Potongan absen', '200000');
  perform test_helpers.assert((select count(*) from public.payroll_adjustments_list(v_run)) = 2, 'two adjustments listed');
  perform test_helpers.assert((public.payroll_run_get(v_run) ->> 'status') = 'draft', 'an adjustment returns the run to draft');
  perform public.payroll_run_calculate(v_run);
  -- taxable = 5,600,000 + 1,000,000 - 200,000 + 227,000 = 6,627,000 -> TER A 1% -> 66,270; gross 6,700,000; net 6,700,000 - 200,000 - 66,270
  select * into r from public.payroll_run_lines(v_run) where employee_id = test_helpers.g('A');
  perform test_helpers.assert(r.adjustment_earnings::numeric = 1000000 and r.adjustment_deductions::numeric = 200000 and r.gross_pay::numeric = 6700000, 'A: gross with adjustments');
  perform test_helpers.assert(r.tax_base::numeric = 6627000 and r.pph21::numeric = 66270 and r.net_pay::numeric = 6433730, 'A: tax and net pay with adjustments');
  perform public.payroll_adjustment_remove(v_adj2);
  perform public.payroll_run_calculate(v_run);
  -- taxable = 6,600,000 + 227,000 = 6,827,000 -> TER A 1.25% -> floor(85,337.5) = 85,337
  select * into r from public.payroll_run_lines(v_run) where employee_id = test_helpers.g('A');
  perform test_helpers.assert(r.tax_base::numeric = 6827000 and r.pph21::numeric = 85337, 'A: only the bonus remains; the tax is rounded down');
  perform public.payroll_adjustment_remove(v_adj);
  perform public.payroll_run_calculate(v_run);
  perform test_helpers.assert((select pph21::numeric from public.payroll_run_lines(v_run) where employee_id = test_helpers.g('A')) = 29135, 'back to the plain month');
  perform test_helpers.assert((public.payroll_run_get(v_run) ->> 'net_pay_total')::numeric = 49162591, 'and to the plain totals');
  perform test_helpers.assert((select count(*) from public.payroll_adjustments_list(v_run)) = 0, 'no adjustments left');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 5. submit, return, stale inputs, approval rule
do $$
declare
  pt uuid := test_helpers.entity('p9b_pt');
  v_pay uuid := 'f0000000-0000-0000-0000-000000000002';
  v_pay2 uuid := 'f0000000-0000-0000-0000-000000000003';
  v_owner uuid := 'f0000000-0000-0000-0000-000000000001';
  v_acc uuid := 'f0000000-0000-0000-0000-000000000004';
  v_run uuid := test_helpers.g('jun');
begin
  perform test_helpers.login(v_acc);
  perform test_helpers.expect_msg(format('select public.payroll_run_submit(%L, ''key-p9b-s2'')', v_run), 'FORBIDDEN', 'an accountant cannot submit');
  perform test_helpers.expect_msg(format('select public.payroll_run_get(%L)', v_run), 'FORBIDDEN', 'nor read the run');
  perform test_helpers.expect_msg(format('select * from public.payroll_run_lines(%L)', v_run), 'FORBIDDEN', 'nor its lines');
  perform test_helpers.logout();

  perform test_helpers.login(v_pay);
  perform public.payroll_run_submit(v_run, 'key-p9b-s3');
  perform public.payroll_run_submit(v_run, 'key-p9b-s3');
  perform test_helpers.assert((public.payroll_run_get(v_run) ->> 'status') = 'submitted', 'submitted (a replay is a no-op)');
  perform test_helpers.expect_msg(format('select public.payroll_run_submit(%L, ''key-p9b-s4'')', v_run), 'CONFLICT', 'submitted once');
  perform test_helpers.expect_msg(format('select public.payroll_adjustment_add(%L, ''key-p9b-ad7'', %L, ''earning'', ''Bonus'', ''1'')', v_run, test_helpers.g('A')), 'CONFLICT', 'a submitted run takes no adjustments');
  perform test_helpers.expect_msg(format('select public.payroll_run_calculate(%L)', v_run), 'CONFLICT', 'and is not recalculated');
  perform test_helpers.expect_msg(format('select public.payroll_run_return(%L, ''no'')', v_run), 'INVALID', 'a return needs a reason');
  perform public.payroll_run_return(v_run, 'Check the June bonus');
  perform test_helpers.assert((public.payroll_run_get(v_run) ->> 'status') = 'draft', 'returned to draft');
  perform test_helpers.expect_msg(format('select public.payroll_run_submit(%L, ''key-p9b-s5'')', v_run), 'CONFLICT', 'a returned run is calculated again before it is submitted');
  perform public.payroll_run_calculate(v_run);
  perform public.payroll_run_submit(v_run, 'key-p9b-s6');
  perform test_helpers.logout();

  -- the same person may not approve their own submission when an approval rule says so (the owner is exempt)
  insert into public.approval_rules (entity_id, module, action, effective_from, requires_approval, allow_self_approval)
  values (pt, 'payroll', 'approve', '2025-01-01', true, false);
  perform test_helpers.login(v_pay);
  perform test_helpers.expect_msg(format('select public.payroll_run_approve(%L, ''key-p9b-ap1'')', v_run), 'FORBIDDEN', 'a different person approves');
  perform test_helpers.logout();

  -- a change of the inputs after the calculation makes the run stale: approval refuses it
  perform test_helpers.login(v_pay2);
  perform public.employee_set_compensation(test_helpers.g('A'), 'key-p9b-A-c2', '2025-06-01', jsonb_build_array(
    jsonb_build_object('component', 'meal', 'kind', 'earning', 'label', 'Uang makan', 'amount', '700000')));
  perform test_helpers.assert((public.payroll_run_get(v_run) ->> 'stale')::boolean, 'the run shows that it is stale');
  perform test_helpers.expect_msg(format('select public.payroll_run_approve(%L, ''key-p9b-ap2'')', v_run), 'CONFLICT', 'a stale run cannot be approved');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 6. return, recalculate, approve, discard, the next revision slot
do $$
declare
  pt uuid := test_helpers.entity('p9b_pt');
  v_pay uuid := 'f0000000-0000-0000-0000-000000000002';
  v_pay2 uuid := 'f0000000-0000-0000-0000-000000000003';
  v_run uuid := test_helpers.g('jun');
  r record;
  v_new uuid;
begin
  perform test_helpers.login(v_pay);
  perform public.payroll_run_return(v_run, 'Meal allowance changed');
  perform public.payroll_run_calculate(v_run);
  -- A now has meal 700,000: taxable 5,700,000 + 227,000 = 5,927,000 -> TER A 0.5% -> 29,635; gross 6,000,000
  select * into r from public.payroll_run_lines(v_run) where employee_id = test_helpers.g('A');
  perform test_helpers.assert(r.gross_pay::numeric = 6000000 and r.tax_base::numeric = 5927000 and r.pph21::numeric = 29635, 'A: the new meal allowance');
  perform public.payroll_run_submit(v_run, 'key-p9b-s7');
  perform test_helpers.logout();

  perform test_helpers.login(v_pay2);
  perform public.payroll_run_approve(v_run, 'key-p9b-ap3');
  perform public.payroll_run_approve(v_run, 'key-p9b-ap3');
  perform test_helpers.assert((public.payroll_run_get(v_run) ->> 'status') = 'approved', 'approved by a second person (a replay is a no-op)');
  perform test_helpers.expect_msg(format('select public.payroll_run_approve(%L, ''key-p9b-ap4'')', v_run), 'CONFLICT', 'approved once');
  perform test_helpers.logout();

  -- an approved run whose inputs change again is not postable
  perform test_helpers.login(v_pay);
  perform public.employee_set_bpjs(test_helpers.g('A'), 'key-p9b-A-b2', '2025-06-01', '[{"component":"bpjs_jkm","enrolled":false}]'::jsonb);
  perform test_helpers.expect_msg(format('select public.payroll_run_post(%L, ''key-p9b-po1'')', v_run), 'CONFLICT', 'an approved run with changed inputs is not posted');
  perform public.payroll_run_return(v_run, 'JKM opt-out recorded');
  perform test_helpers.assert((public.payroll_run_get(v_run) ->> 'status') = 'draft', 'an approved run can be returned');
  -- A without JKM: employer JKM 0; taxable 5,700,000 + 200,000 + 12,000 = 5,912,000 -> TER 0.5% = 29,560
  perform public.payroll_run_calculate(v_run);
  select * into r from public.payroll_run_lines(v_run) where employee_id = test_helpers.g('A');
  perform test_helpers.assert(r.bpjs_employer::numeric = 497000 and r.tax_base::numeric = 5912000 and r.pph21::numeric = 29560, 'A: no JKM from June');
  -- discarding a run frees the month
  perform test_helpers.expect_msg(format('select public.payroll_run_discard(%L, ''x'')', v_run), 'INVALID', 'a discard needs a reason');
  perform public.payroll_run_discard(v_run, 'Prepared by mistake');
  perform test_helpers.assert((public.payroll_run_get(v_run) ->> 'status') = 'discarded', 'discarded');
  perform test_helpers.expect_msg(format('select public.payroll_run_calculate(%L)', v_run), 'CONFLICT', 'a discarded run is final');
  v_new := public.payroll_run_create(pt, 'key-p9b-r7', '2025-06-01', '2025-06-28');
  perform test_helpers.assert(v_new <> v_run, 'a new run for the same month after a discard');
  perform test_helpers.assert((select run_number from public.payroll_run_list(pt) where run_id = v_new)
    = (select run_number from public.payroll_run_list(pt) where run_id = v_run)
    and (select revision from public.payroll_run_list(pt) where run_id = v_new) = 2, 'the new run continues the number as revision 2');
  perform test_helpers.put('jun2', v_new);
  perform test_helpers.logout();
  -- the lines and adjustments of a run that is not a draft cannot be changed even by the table owner's SQL
  perform test_helpers.expect_error(format('delete from public.payroll_run_lines where run_id = %L', v_run), '23000', 'lines of a discarded run are frozen');
  perform test_helpers.expect_error(format('update public.payroll_runs set status = ''posted'' where id = %L', v_run), null, 'a discarded run cannot move on');
  perform test_helpers.expect_error(format('delete from public.payroll_runs where id = %L', v_run), null, 'a run is never deleted');
end
$$;

-- ================================================================ 7. December: the annual computation, opening figures, over-withholding
do $$
declare
  pt uuid := test_helpers.entity('p9b_pt');
  v_pay uuid := 'f0000000-0000-0000-0000-000000000002';
  e uuid;
  v_nov uuid;
  v_dec uuid;
  r record;
  j jsonb;
begin
  perform test_helpers.login(v_pay);
  perform public.payroll_run_discard(test_helpers.g('jun2'), 'Not needed for this test');
  -- H: joined in January, paid 55,000,000 taxable up to November with 5,000,000 withheld (far too much)
  e := test_helpers.put('H', public.employee_create(pt, 'key-p9b-H', 'Employee H', '2025-01-01', 'permanent', 'Clerk'));
  perform public.employee_set_compensation(e, 'key-p9b-H-c', '2025-01-01', jsonb_build_array(
    jsonb_build_object('component', 'basic', 'kind', 'earning', 'label', 'Gaji pokok', 'amount', '5000000')));
  perform public.employee_set_tax_profile(e, 'key-p9b-H-t', '2025-01-01', 'has_tax_id', '3200000000000008', 'TK/0');
  -- I: joined in January with no history at all
  e := test_helpers.put('I', public.employee_create(pt, 'key-p9b-I', 'Employee I', '2025-01-01', 'permanent', 'Clerk'));
  perform public.employee_set_compensation(e, 'key-p9b-I-c', '2025-01-01', jsonb_build_array(
    jsonb_build_object('component', 'basic', 'kind', 'earning', 'label', 'Gaji pokok', 'amount', '5000000')));
  perform public.employee_set_tax_profile(e, 'key-p9b-I-t', '2025-01-01', 'has_tax_id', '3200000000000009', 'TK/0');
  perform test_helpers.expect_msg(format('select public.employee_set_tax_opening(%L, ''key-p9b-o0'', 2025, 12, ''1'', ''0'', ''0'')', test_helpers.g('H')), 'INVALID', 'opening figures stop at month 11');
  perform test_helpers.expect_msg(format('select public.employee_set_tax_opening(%L, ''key-p9b-o1'', 2025, 11, ''-1'', ''0'', ''0'')', test_helpers.g('H')), 'INVALID', 'no negative opening figure');
  perform test_helpers.expect_msg(format('select public.employee_set_tax_opening(%L, ''key-p9b-o2'', 2024, 11, ''1'', ''0'', ''0'')', test_helpers.g('H')), 'INVALID', 'not before the employee joined');
  perform public.employee_set_tax_opening(test_helpers.g('H'), 'key-p9b-o3', 2025, 11, '55000000', '0', '5000000', 'Synthetic cut-over');
  -- A: March to November, 9 months of the plain June figures (taxable 5,827,000, pension 150,000, tax 29,135)
  perform public.employee_set_tax_opening(test_helpers.g('A'), 'key-p9b-o4', 2025, 11, '52443000', '1350000', '262215', 'Synthetic cut-over');
  perform test_helpers.logout();

  -- (meal is 700,000 and JKM ended in the June scenario: December is computed from the recorded terms, so we use
  -- A's December inputs as they are: taxable 5,700,000 + Kes 200,000 + JKK 12,000 = 5,912,000; pension 150,000)
  -- an unposted November run blocks the December reconciliation
  perform test_helpers.login(v_pay);
  v_nov := public.payroll_run_create(pt, 'key-p9b-r8', '2025-11-05', '2025-11-28');
  v_dec := test_helpers.put('dec', public.payroll_run_create(pt, 'key-p9b-r9', '2025-12-01', '2025-12-28'));
  perform public.payroll_run_calculate(v_dec);
  perform test_helpers.assert((select review_flags from public.payroll_run_lines(v_dec) where employee_id = test_helpers.g('A')) = array['earlier_run_not_posted'],
    'A: an unposted earlier run of the year blocks the annual computation');
  perform test_helpers.assert((select review_flags from public.payroll_run_lines(v_dec) where employee_id = test_helpers.g('I')) @> array['ytd_incomplete'],
    'I: months without history or opening figures block the annual computation');
  perform public.payroll_run_discard(v_nov, 'Not needed for this test');
  perform public.payroll_run_calculate(v_dec);
  perform test_helpers.assert((select review_flags from public.payroll_run_lines(v_dec) where employee_id = test_helpers.g('A')) = '{}', 'A: clean once the earlier run is gone');
  perform test_helpers.assert((select review_flags from public.payroll_run_lines(v_dec) where employee_id = test_helpers.g('I')) = array['ytd_incomplete'], 'I: still incomplete');
  -- A, by hand (10 months: March to December): gross 52,443,000 + 5,912,000 = 58,355,000; pension 1,350,000 + 150,000 = 1,500,000;
  -- occupational cost min(5% x 58,355,000 = 2,917,750; 500,000 x 10) = 2,917,750; PTKP 54,000,000 x 10/12 = 45,000,000;
  -- PKP = floor((58,355,000 - 2,917,750 - 1,500,000 - 45,000,000)/1000) x 1000 = 8,937,000; tax 5% = 446,850; less 262,215 = 184,635.
  select * into r from public.payroll_run_lines(v_dec) where employee_id = test_helpers.g('A');
  perform test_helpers.assert(r.tax_mode = 'annual' and r.tax_base::numeric = 5912000, 'A: the last tax month is computed annually');
  perform test_helpers.assert((r.tax_calc ->> 'months')::int = 10 and (r.tax_calc ->> 'ptkp')::numeric = 45000000, 'A: PTKP is prorated to the months worked');
  perform test_helpers.assert((r.tax_calc ->> 'occupational_cost')::numeric = 2917750 and (r.tax_calc ->> 'pkp')::numeric = 8937000, 'A: occupational cost and PKP (rounded down to 1,000)');
  perform test_helpers.assert((r.tax_calc ->> 'annual_tax')::numeric = 446850 and (r.tax_calc ->> 'withheld_before')::numeric = 262215, 'A: annual tax and what was withheld before');
  perform test_helpers.assert(r.pph21::numeric = 184635, 'A: December tax = annual tax - withheld before');
  -- H, by hand (12 months): gross 55,000,000 + 5,000,000 = 60,000,000; cost min(3,000,000; 6,000,000) = 3,000,000; PTKP 54,000,000;
  -- PKP 3,000,000; tax 150,000 - 5,000,000 withheld = -4,850,000: no tax this month, over-withholding reported, no refund.
  select * into r from public.payroll_run_lines(v_dec) where employee_id = test_helpers.g('H');
  perform test_helpers.assert(r.pph21::numeric = 0 and r.info_flags = array['tax_overwithheld:4850000'], 'H: over-withholding is reported, not refunded through payroll');
  perform test_helpers.assert((r.tax_calc ->> 'annual_tax')::numeric = 150000 and (r.tax_calc ->> 'due')::numeric = -4850000, 'H: the working shows the negative balance');
  perform test_helpers.assert(r.net_pay::numeric = 5000000, 'H: net pay is not reduced');

  -- the opening figures are a record: a later revision replaces the earlier one
  perform public.employee_set_tax_opening(test_helpers.g('H'), 'key-p9b-o5', 2025, 11, '55000000', '0', '150000', 'Corrected withholding');
  perform public.payroll_run_calculate(v_dec);
  select * into r from public.payroll_run_lines(v_dec) where employee_id = test_helpers.g('H');
  perform test_helpers.assert(r.pph21::numeric = 0 and r.info_flags = '{}' and (r.tax_calc ->> 'due')::numeric = 0, 'H: with the corrected opening the December balance is nil');

  perform test_helpers.logout();
  perform test_helpers.assert((select count(*) from public.audit_events a where a.target_table = 'employee_tax_openings' and a.entity_id = pt) >= 3
    and not exists (select 1 from public.audit_events a where a.target_table = 'employee_tax_openings' and a.after_state::text ~ '55000000|5000000|150000'),
    'opening figures are audited without their amounts');
end
$$;

-- ================================================================ 8. the sensitive boundary of the reads
do $$
declare
  pt uuid := test_helpers.entity('p9b_pt');
  v_pay uuid := 'f0000000-0000-0000-0000-000000000002';
  v_none uuid := 'f0000000-0000-0000-0000-000000000004';
  v_dec uuid := test_helpers.g('dec');
  v_role uuid;
  v_ops uuid := 'f0000000-0000-0000-0000-000000000005';
  r record;
begin
  -- a preparer who may run payroll and see amounts but not tax facts
  insert into public.roles (role_key, name) values ('p9b_prep', 'P9B preparer') returning id into v_role;
  insert into public.role_permissions (role_id, permission_key)
  select v_role, k from unnest(array['payroll.employee_view', 'payroll.compensation_view', 'payroll.run']) k;
  perform test_helpers.mk_user(v_ops, 'preparer');
  perform test_helpers.mk_member(pt, v_ops, 'p9b_prep');
  perform test_helpers.login(v_ops);
  select * into r from public.payroll_run_lines(v_dec) where employee_id = test_helpers.g('A');
  perform test_helpers.assert(r.net_pay is not null and r.gross_pay is not null, 'the preparer sees pay');
  perform test_helpers.assert(r.pph21 is null and r.tax_base is null and r.tax_calc is null and r.tax_allowance is null, 'but no tax fields');
  perform test_helpers.assert(public.payroll_run_get(v_dec) ->> 'pph21_total' is null and public.payroll_run_get(v_dec) ->> 'gross_pay_total' is not null, 'the run header hides the tax total');
  perform test_helpers.assert((select pph21_total from public.payroll_run_list(pt) limit 1) is null, 'and so does the list');
  perform test_helpers.expect_msg(format('select public.payroll_run_approve(%L, ''key-p9b-x1'')', v_dec), 'FORBIDDEN', 'a preparer cannot approve');
  perform test_helpers.expect_msg(format('select public.payroll_record_payment(%L, ''key-p9b-x2'', ''net_pay'', ''2025-12-29'', %L)', v_dec, gen_random_uuid()), 'FORBIDDEN', 'nor pay');
  perform test_helpers.logout();
  -- amounts are closed to a clerk who has a payroll right but no compensation right
  insert into public.roles (role_key, name) values ('p9b_blind', 'P9B without amounts') returning id into v_role;
  insert into public.role_permissions (role_id, permission_key) select v_role, k from unnest(array['payroll.employee_view', 'payroll.run']) k;
  perform test_helpers.mk_user('f0000000-0000-0000-0000-000000000006', 'blind');
  perform test_helpers.mk_member(pt, 'f0000000-0000-0000-0000-000000000006', 'p9b_blind');
  perform test_helpers.login('f0000000-0000-0000-0000-000000000006');
  perform test_helpers.expect_msg(format('select * from public.payroll_run_lines(%L)', v_dec), 'FORBIDDEN', 'no amounts without the compensation right');
  perform test_helpers.expect_msg(format('select public.payroll_run_calculate(%L)', v_dec), 'FORBIDDEN', 'no calculation either');
  perform test_helpers.expect_error('select * from public.payroll_runs', '42501', 'the run table is closed');
  perform test_helpers.expect_error('select * from public.payroll_run_lines', '42501', 'the line table is closed');
  perform test_helpers.expect_error('select * from public.payroll_adjustments', '42501', 'the adjustment table is closed');
  perform test_helpers.expect_error('select * from public.employee_tax_openings', '42501', 'the opening figures are closed');
  perform test_helpers.logout();
end
$$;

rollback;
