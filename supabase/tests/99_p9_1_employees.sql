-- P9 gate, part 1 (Step 15 §13, Step 01 #24-#25, Step 02 "People & Payroll", Step 06 §4/§6): the employee master and
-- the sensitive payroll boundary. Covers creation and validation, the payroll-only permission set, closed tables,
-- effective-dated employment / compensation / tax facts / BPJS enrolment, the masked tax identifier and its step-up,
-- the redacted audit trail, immutability, and the company-only rule. All data is synthetic; dates are fixed in 2025 so
-- the file does not depend on the day it runs. The whole file runs in one transaction that is rolled back.
begin;
set local client_min_messages = warning;

create table test_helpers.p9a (k text primary key, v uuid not null);
grant all on test_helpers.p9a to public;
create function test_helpers.put(p_k text, p_v uuid) returns uuid
language sql as $f$ insert into test_helpers.p9a values (p_k, p_v) on conflict (k) do update set v = excluded.v returning v $f$;
create function test_helpers.g(p_k text) returns uuid
language sql stable as $f$ select v from test_helpers.p9a where k = p_k $f$;
grant execute on function test_helpers.put(text, uuid), test_helpers.g(text) to public;

-- ================================================================ fixtures (superuser)
do $$
declare
  v_pt uuid;
  v_pe uuid;
  v_role uuid;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p9a_pt', 'P9A PT (synthetic)') returning id into v_pt;
  perform app_private.provision_default_coa(v_pt);
  insert into public.entities (entity_type, code, legal_name) values ('personal', 'p9a_pe', 'P9A PERSONAL (synthetic)') returning id into v_pe;
  perform app_private.provision_default_coa(v_pe);
  perform test_helpers.mk_user('e0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_user('e0000000-0000-0000-0000-000000000002', 'payroll');
  perform test_helpers.mk_user('e0000000-0000-0000-0000-000000000003', 'accountant');
  perform test_helpers.mk_user('e0000000-0000-0000-0000-000000000004', 'viewer');
  perform test_helpers.mk_user('e0000000-0000-0000-0000-000000000005', 'nobody');
  perform test_helpers.mk_user('e0000000-0000-0000-0000-000000000006', 'ops');
  perform test_helpers.mk_member(v_pt, 'e0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pe, 'e0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pt, 'e0000000-0000-0000-0000-000000000002', 'payroll');
  perform test_helpers.mk_member(v_pe, 'e0000000-0000-0000-0000-000000000002', 'payroll');
  perform test_helpers.mk_member(v_pt, 'e0000000-0000-0000-0000-000000000003', 'accountant');
  perform test_helpers.mk_member(v_pt, 'e0000000-0000-0000-0000-000000000004', 'viewer_auditor');
  -- A payroll clerk who maintains the employee list and pay terms but may not see tax facts.
  insert into public.roles (role_key, name) values ('p9a_ops', 'P9A payroll operations') returning id into v_role;
  insert into public.role_permissions (role_id, permission_key)
  select v_role, k from unnest(array['payroll.employee_view', 'payroll.employee_edit', 'payroll.compensation_view',
                                     'payroll.compensation_edit']) k;
  perform test_helpers.mk_member(v_pt, 'e0000000-0000-0000-0000-000000000006', 'p9a_ops');
end
$$;

-- ================================================================ 1. the boundary and validation
do $$
declare
  pt uuid := test_helpers.entity('p9a_pt');
  pe uuid := test_helpers.entity('p9a_pe');
  v_owner uuid := 'e0000000-0000-0000-0000-000000000001';
  v_pay uuid := 'e0000000-0000-0000-0000-000000000002';
  v_acc uuid := 'e0000000-0000-0000-0000-000000000003';
  v_view uuid := 'e0000000-0000-0000-0000-000000000004';
  v_none uuid := 'e0000000-0000-0000-0000-000000000005';
  u uuid;
  v_emp uuid;
  v_again uuid;
  v_code text;
begin
  perform test_helpers.assert(exists (select 1 from public.permissions where key = 'payroll.tax_view'), 'the tax-view right is in the catalog');
  perform test_helpers.assert(not exists (select 1 from public.role_permissions rp join public.roles r on r.id = rp.role_id
    where rp.permission_key like 'payroll.%' and r.role_key not in ('payroll', 'p9a_ops')), 'only the payroll role holds payroll rights (the owner holds all by definition)');

  -- nobody but payroll people (and the owner) can create or list employees
  foreach u in array array[v_acc, v_view, v_none] loop
    perform test_helpers.login(u);
    perform test_helpers.expect_msg(format('select public.employee_create(%L, ''k-p9a-x'', ''Tester Satu'', ''2025-01-01'', ''permanent'', ''Staff'')', pt), 'FORBIDDEN', 'a non-payroll user cannot create an employee');
    perform test_helpers.expect_msg(format('select * from public.employee_list(%L)', pt), 'FORBIDDEN', 'a non-payroll user cannot list employees');
    perform test_helpers.logout();
  end loop;

  perform test_helpers.login(v_pay);
  perform test_helpers.expect_msg(format('select public.employee_create(%L, ''k-p9a-pe'', ''Tester Satu'', ''2025-01-01'', ''permanent'', ''Staff'')', pe), 'INVALID', 'a Personal Entity has no employees');
  perform test_helpers.expect_msg(format('select public.employee_create(%L, ''k-p9a-v1'', ''T'', ''2025-01-01'', ''permanent'', ''Staff'')', pt), 'INVALID', 'a name of at least two characters');
  perform test_helpers.expect_msg(format('select public.employee_create(%L, ''k-p9a-v2'', ''Tester Satu'', null, ''permanent'', ''Staff'')', pt), 'INVALID', 'a join date');
  perform test_helpers.expect_msg(format('select public.employee_create(%L, ''k-p9a-v3'', ''Tester Satu'', ''2025-01-01'', ''freelance'', ''Staff'')', pt), 'INVALID', 'a known employment type');
  perform test_helpers.expect_msg(format('select public.employee_create(%L, ''k-p9a-v4'', ''Tester Satu'', ''2025-01-01'', ''permanent'', '' '')', pt), 'INVALID', 'a position');
  perform test_helpers.expect_msg(format('select public.employee_create(%L, ''k-p9a-v5'', ''Tester Satu'', ''1990-01-01'', ''permanent'', ''Staff'')', pt), 'INVALID', 'a plausible join date');
  perform test_helpers.assert((select count(*) from public.employee_list(pt)) = 0, 'refused creations change nothing');

  v_emp := public.employee_create(pt, 'k-p9a-e1', '  Tester Satu ', '2025-01-01', 'permanent', 'Staff Admin', 'Umum');
  v_again := public.employee_create(pt, 'k-p9a-e1', '  Tester Satu ', '2025-01-01', 'permanent', 'Staff Admin', 'Umum');
  perform test_helpers.assert(v_emp = v_again, 'the same key and payload replays the same employee');
  perform test_helpers.expect_msg(format('select public.employee_create(%L, ''k-p9a-e1'', ''Tester Lain'', ''2025-01-01'', ''permanent'', ''Staff Admin'')', pt), 'INVALID: idempotency', 'the same key with another payload is refused');
  perform test_helpers.assert((select count(*) from public.employee_list(pt)) = 1, 'the replay created no second employee');
  perform test_helpers.put('e1', v_emp);
  perform test_helpers.put('e2', public.employee_create(pt, 'k-p9a-e2', 'Tester Dua', '2025-02-01', 'contract', 'Staff Gudang'));
  select employee_code into v_code from public.employee_list(pt) where id = v_emp;
  perform test_helpers.assert(v_code like 'EMP-%', 'the employee code comes from the numbering family');
  perform test_helpers.assert((select full_name from public.employee_list(pt) where id = v_emp) = 'Tester Satu', 'the name is trimmed');
  perform test_helpers.assert((select position_title || '/' || department from public.employee_list(pt) where id = v_emp) = 'Staff Admin/Umum', 'the list shows the current position');
  perform test_helpers.assert((select count(*) from public.employee_list(pt)) = 2, 'both employees are listed');
  perform test_helpers.logout();

  -- the list never carries money or tax facts (its columns are operational)
  perform test_helpers.assert((select array_agg(column_name::text order by ordinal_position) from information_schema.columns
    where table_schema = 'public' and table_name = 'employees') @> array['id', 'full_name']
    and not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'employees'
                    and column_name ~ 'salary|amount|tax|npwp|nik'), 'the identity table has no money or tax columns');

  -- the owner may do it too; the second Entity type is refused for the owner as well
  perform test_helpers.login(v_owner);
  perform test_helpers.assert((select count(*) from public.employee_list(pt)) = 2, 'the owner sees the list');
  perform test_helpers.expect_msg(format('select * from public.employee_list(%L)', pe), 'INVALID', 'the owner has no payroll on a Personal Entity either');
  perform test_helpers.logout();

  -- the payroll tables are closed to the browser roles
  perform test_helpers.login(v_pay);
  perform test_helpers.expect_error('select * from public.employees', '42501', 'the employee table is closed');
  perform test_helpers.expect_error('select * from public.employee_compensation', '42501', 'compensation is closed');
  perform test_helpers.expect_error('select * from public.employee_tax_profiles', '42501', 'tax facts are closed');
  perform test_helpers.expect_error('select * from public.employee_bpjs_enrollments', '42501', 'BPJS enrolment is closed');
  perform test_helpers.expect_error('select * from public.employee_employments', '42501', 'employment records are closed');
  perform test_helpers.expect_error(format('update public.employees set full_name = ''Hacked'' where id = %L', v_emp), '42501', 'no direct update');
  perform test_helpers.logout();
  perform test_helpers.login(v_none);
  perform test_helpers.expect_error('select * from public.employees', '42501', 'closed for everyone');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 2. employment records, effective dated
do $$
declare
  v_pay uuid := 'e0000000-0000-0000-0000-000000000002';
  v_acc uuid := 'e0000000-0000-0000-0000-000000000003';
  e1 uuid := test_helpers.g('e1');
begin
  perform test_helpers.login(v_acc);
  perform test_helpers.expect_msg(format('select public.employee_record_employment(%L, ''2025-06-01'', ''permanent'', ''Supervisor'')', e1), 'FORBIDDEN', 'an accountant cannot record an employment change');
  perform test_helpers.expect_msg(format('select * from public.employee_employment_history(%L)', e1), 'FORBIDDEN', 'an accountant cannot read the history');
  perform test_helpers.logout();

  perform test_helpers.login(v_pay);
  perform test_helpers.expect_msg(format('select public.employee_record_employment(%L, ''2024-12-31'', ''permanent'', ''Supervisor'')', e1), 'INVALID', 'not before the join date');
  perform test_helpers.expect_msg(format('select public.employee_record_employment(%L, ''2025-06-01'', ''intern'', ''Supervisor'')', e1), 'INVALID', 'a known type');
  perform test_helpers.expect_msg(format('select public.employee_record_employment(%L, ''2025-06-01'', ''permanent'', '''')', e1), 'INVALID', 'a position');
  perform public.employee_record_employment(e1, '2025-06-01', 'permanent', 'Supervisor', 'Umum', 'Promoted');
  perform test_helpers.expect_msg(format('select public.employee_record_employment(%L, ''2025-06-01'', ''permanent'', ''Manager'')', e1), 'CONFLICT', 'one record per date');
  perform test_helpers.assert((select count(*) from public.employee_employment_history(e1)) = 2, 'two employment records');
  perform test_helpers.assert((select position_title from public.employee_employment_history(e1) order by effective_from desc limit 1) = 'Supervisor', 'newest first');
  perform test_helpers.assert((select position_title from public.employee_employment_history(e1) order by effective_from limit 1) = 'Staff Admin', 'the original terms are preserved');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 3. compensation, effective dated
do $$
declare
  v_pay uuid := 'e0000000-0000-0000-0000-000000000002';
  v_acc uuid := 'e0000000-0000-0000-0000-000000000003';
  v_ops uuid := 'e0000000-0000-0000-0000-000000000006';
  e1 uuid := test_helpers.g('e1');
  e2 uuid := test_helpers.g('e2');
  j jsonb;
begin
  perform test_helpers.login(v_acc);
  perform test_helpers.expect_msg(format('select public.employee_set_compensation(%L, ''k-p9a-c0'', ''2025-01-01'', ''[{"component":"basic","kind":"earning","label":"Gaji pokok","amount":"5000000"}]'')', e1), 'FORBIDDEN', 'an accountant cannot set compensation');
  perform test_helpers.expect_msg(format('select public.employee_compensation_get(%L)', e1), 'FORBIDDEN', 'an accountant cannot read compensation');
  perform test_helpers.logout();

  perform test_helpers.login(v_pay);
  perform test_helpers.expect_msg(format('select public.employee_set_compensation(%L, ''k-p9a-c1'', ''2024-12-01'', ''[{"component":"basic","kind":"earning","label":"Gaji pokok","amount":"5000000"}]'')', e1), 'INVALID', 'not before the join date');
  perform test_helpers.expect_msg(format('select public.employee_set_compensation(%L, ''k-p9a-c2'', ''2025-01-01'', ''[]'')', e1), 'INVALID', 'at least one component');
  perform test_helpers.expect_msg(format('select public.employee_set_compensation(%L, ''k-p9a-c3'', ''2025-01-01'', ''{"a":1}'')', e1), 'INVALID', 'an array of components');
  perform test_helpers.expect_msg(format('select public.employee_set_compensation(%L, ''k-p9a-c4'', ''2025-01-01'', ''[{"component":"Basic Pay","kind":"earning","label":"x","amount":"1"}]'')', e1), 'INVALID', 'a component code shape');
  perform test_helpers.expect_msg(format('select public.employee_set_compensation(%L, ''k-p9a-c5'', ''2025-01-01'', ''[{"component":"basic","kind":"bonus","label":"x","amount":"1"}]'')', e1), 'INVALID', 'a known kind');
  perform test_helpers.expect_msg(format('select public.employee_set_compensation(%L, ''k-p9a-c6'', ''2025-01-01'', ''[{"component":"basic","kind":"earning","label":"x","amount":"-5"}]'')', e1), 'INVALID', 'no negative amount');
  perform test_helpers.expect_msg(format('select public.employee_set_compensation(%L, ''k-p9a-c7'', ''2025-01-01'', ''[{"component":"basic","kind":"earning","label":"x","amount":"10.555"}]'')', e1), 'INVALID', 'more decimals than the currency allows');
  perform test_helpers.expect_msg(format('select public.employee_set_compensation(%L, ''k-p9a-c8'', ''2025-01-01'', ''[{"component":"loan","kind":"deduction","label":"x","amount":"100000","bpjs_base":true}]'')', e1), 'INVALID', 'only an earning counts for BPJS');
  perform test_helpers.assert(public.employee_compensation_get(e1, '2025-12-31') ->> 'earnings_total' = '0', 'refused terms change nothing');

  perform test_helpers.assert(public.employee_set_compensation(e1, 'k-p9a-c9', '2025-01-01', jsonb_build_array(
      jsonb_build_object('component', 'basic', 'kind', 'earning', 'label', 'Gaji pokok', 'amount', '5000000', 'bpjs_base', true),
      jsonb_build_object('component', 'meal', 'kind', 'earning', 'label', 'Uang makan', 'amount', '600000', 'taxable', true),
      jsonb_build_object('component', 'transport', 'kind', 'earning', 'label', 'Transport', 'amount', '300000', 'taxable', false),
      jsonb_build_object('component', 'loan', 'kind', 'deduction', 'label', 'Cicilan pinjaman', 'amount', '200000'))) = 4, 'four components recorded');
  perform test_helpers.assert(public.employee_set_compensation(e1, 'k-p9a-c9', '2025-01-01', jsonb_build_array(
      jsonb_build_object('component', 'basic', 'kind', 'earning', 'label', 'Gaji pokok', 'amount', '5000000', 'bpjs_base', true),
      jsonb_build_object('component', 'meal', 'kind', 'earning', 'label', 'Uang makan', 'amount', '600000', 'taxable', true),
      jsonb_build_object('component', 'transport', 'kind', 'earning', 'label', 'Transport', 'amount', '300000', 'taxable', false),
      jsonb_build_object('component', 'loan', 'kind', 'deduction', 'label', 'Cicilan pinjaman', 'amount', '200000'))) = 4, 'an identical replay reports the same result');
  perform test_helpers.assert(jsonb_array_length(public.employee_compensation_get(e1, '2025-03-01') -> 'components') = 4, 'the replay wrote nothing twice');
  j := public.employee_compensation_get(e1, '2025-03-01');
  perform test_helpers.assert(j ->> 'earnings_total' = '5900000' and j ->> 'deductions_total' = '200000', 'totals at a date');
  perform test_helpers.assert((j -> 'components' -> 0 ->> 'kind') = 'earning', 'earnings are listed first');
  perform test_helpers.assert((select bool_and(c ->> 'taxable' = 'false') from jsonb_array_elements(j -> 'components') c where c ->> 'component' = 'transport'), 'the taxable flag is kept');
  perform test_helpers.expect_msg(format('select public.employee_set_compensation(%L, ''k-p9a-c10'', ''2025-01-01'', ''[{"component":"basic","kind":"earning","label":"x","amount":"6000000"}]'')', e1), 'CONFLICT', 'a component cannot be rewritten for a date already recorded');

  -- a raise from a later date leaves the past untouched; a zero amount ends a component
  perform public.employee_set_compensation(e1, 'k-p9a-c11', '2025-07-01', jsonb_build_array(
    jsonb_build_object('component', 'basic', 'kind', 'earning', 'label', 'Gaji pokok', 'amount', '6000000', 'bpjs_base', true),
    jsonb_build_object('component', 'loan', 'kind', 'deduction', 'label', 'Cicilan pinjaman', 'amount', '0')));
  j := public.employee_compensation_get(e1, '2025-06-30');
  perform test_helpers.assert(j ->> 'earnings_total' = '5900000' and j ->> 'deductions_total' = '200000', 'June is unchanged by the July raise');
  j := public.employee_compensation_get(e1, '2025-07-01');
  perform test_helpers.assert(j ->> 'earnings_total' = '6900000' and j ->> 'deductions_total' = '0', 'July has the raise and the ended deduction');
  perform test_helpers.assert(jsonb_array_length(j -> 'components') = 3, 'the ended component is left out');
  perform test_helpers.assert(public.employee_compensation_get(e1, '2024-12-31') ->> 'earnings_total' = '0', 'nothing before the first record');
  perform test_helpers.logout();

  -- the operations clerk holds the compensation rights but not the tax right
  perform test_helpers.login(v_ops);
  perform test_helpers.assert(public.employee_compensation_get(e1, '2025-07-01') ->> 'earnings_total' = '6900000', 'compensation is visible with its right');
  perform test_helpers.expect_msg(format('select public.employee_tax_profile_get(%L)', e1), 'FORBIDDEN', 'the tax profile needs payroll.tax_view');
  perform test_helpers.expect_msg(format('select public.employee_tax_identifier(%L)', e1), 'FORBIDDEN', 'the identifier needs payroll.tax_view');
  perform test_helpers.expect_msg(format('select public.employee_set_tax_profile(%L, ''k-p9a-ops'', ''2025-01-01'', ''unknown'', null, ''unknown'')', e1), 'FORBIDDEN', 'recording tax facts needs payroll.tax_view');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 4. tax facts, the masked identifier and the step-up
do $$
declare
  v_pay uuid := 'e0000000-0000-0000-0000-000000000002';
  v_acc uuid := 'e0000000-0000-0000-0000-000000000003';
  e1 uuid := test_helpers.g('e1');
  e2 uuid := test_helpers.g('e2');
  j jsonb;
  v_id uuid;
  v_id2 uuid;
begin
  perform test_helpers.login(v_acc);
  perform test_helpers.expect_msg(format('select public.employee_tax_profile_get(%L)', e1), 'FORBIDDEN', 'an accountant cannot read tax facts');
  perform test_helpers.logout();

  perform test_helpers.login(v_pay);
  perform test_helpers.assert((public.employee_tax_profile_get(e1, '2025-06-01') ->> 'recorded') = 'false', 'no tax facts recorded yet');
  perform test_helpers.expect_msg(format('select public.employee_set_tax_profile(%L, ''k-p9a-t1'', ''2024-12-01'', ''unknown'', null, ''unknown'')', e1), 'INVALID', 'not before the join date');
  perform test_helpers.expect_msg(format('select public.employee_set_tax_profile(%L, ''k-p9a-t2'', ''2025-01-01'', ''has_tax_id'', null, ''TK/0'')', e1), 'INVALID', 'a tax number is required when the status says so');
  perform test_helpers.expect_msg(format('select public.employee_set_tax_profile(%L, ''k-p9a-t3'', ''2025-01-01'', ''no_tax_id'', ''1234567890123456'', ''TK/0'')', e1), 'INVALID', 'no tax number when the status says none');
  perform test_helpers.expect_msg(format('select public.employee_set_tax_profile(%L, ''k-p9a-t4'', ''2025-01-01'', ''has_tax_id'', ''12345'', ''TK/0'')', e1), 'INVALID', 'a 15 or 16 digit number');
  perform test_helpers.expect_msg(format('select public.employee_set_tax_profile(%L, ''k-p9a-t5'', ''2025-01-01'', ''has_tax_id'', ''1234567890123456'', ''K/9'')', e1), 'INVALID', 'a known PTKP status');
  perform test_helpers.expect_msg(format('select public.employee_set_tax_profile(%L, ''k-p9a-t6'', ''2025-01-01'', ''has_tax_id'', ''1234567890123456'', ''TK/0'', ''company_pays'')', e1), 'INVALID', 'a known tax method');
  perform test_helpers.assert((public.employee_tax_profile_get(e1, '2025-06-01') ->> 'recorded') = 'false', 'refused facts change nothing');

  v_id := public.employee_set_tax_profile(e1, 'k-p9a-t7', '2025-01-01', 'has_tax_id', '12.345.678.9-012.345', 'TK/0');
  v_id2 := public.employee_set_tax_profile(e1, 'k-p9a-t7', '2025-01-01', 'has_tax_id', '12.345.678.9-012.345', 'TK/0');
  perform test_helpers.assert(v_id = v_id2, 'the same key replays the same record');
  j := public.employee_tax_profile_get(e1, '2025-06-01');
  perform test_helpers.assert(j ->> 'tax_id_status' = 'has_tax_id' and j ->> 'ptkp_status' = 'TK/0' and j ->> 'tax_method' = 'employee_borne', 'the facts are shown');
  perform test_helpers.assert(j ->> 'tax_id_masked' = '***********2345', 'the identifier is masked to its last four digits');
  perform test_helpers.assert(j::text not like '%1234567890%', 'the profile never carries the full identifier');
  perform test_helpers.expect_msg(format('select public.employee_set_tax_profile(%L, ''k-p9a-t8'', ''2025-01-01'', ''unknown'', null, ''unknown'')', e1), 'CONFLICT', 'one fact set per date');

  -- effective dating: the status changes from a later date
  perform public.employee_set_tax_profile(e1, 'k-p9a-t9', '2025-09-01', 'has_tax_id', '1234567890123456', 'K/1', 'gross_up', 'Married');
  perform test_helpers.assert(public.employee_tax_profile_get(e1, '2025-08-31') ->> 'ptkp_status' = 'TK/0', 'before the change');
  perform test_helpers.assert(public.employee_tax_profile_get(e1, '2025-09-01') ->> 'ptkp_status' = 'K/1'
    and public.employee_tax_profile_get(e1, '2025-09-01') ->> 'tax_method' = 'gross_up', 'from the change');
  -- unknown stays unknown
  perform public.employee_set_tax_profile(e2, 'k-p9a-t10', '2025-02-01', 'unknown', null, 'unknown');
  j := public.employee_tax_profile_get(e2, '2025-03-01');
  perform test_helpers.assert(j ->> 'tax_id_status' = 'unknown' and j ->> 'ptkp_status' = 'unknown' and j -> 'tax_id_masked' = 'null'::jsonb, 'unknown is recorded as unknown');

  -- the full identifier needs a recent step-up
  perform test_helpers.assert(public.employee_tax_identifier(e1, '2025-06-01') = '123456789012345', 'the identifier is readable after a recent login');
  perform test_helpers.logout();
  perform test_helpers.login(v_pay, 'aal2', interval '3 hours');
  perform test_helpers.expect_msg(format('select public.employee_tax_identifier(%L, ''2025-06-01'')', e1), 'STEP_UP_REQUIRED', 'a stale login cannot read the identifier');
  perform test_helpers.assert(public.employee_tax_profile_get(e1, '2025-06-01') ->> 'tax_id_masked' = '***********2345', 'the masked profile needs no step-up');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 5. BPJS enrolment
do $$
declare
  v_pay uuid := 'e0000000-0000-0000-0000-000000000002';
  v_acc uuid := 'e0000000-0000-0000-0000-000000000003';
  e1 uuid := test_helpers.g('e1');
  j jsonb;
begin
  perform test_helpers.login(v_acc);
  perform test_helpers.expect_msg(format('select public.employee_bpjs_get(%L)', e1), 'FORBIDDEN', 'an accountant cannot read enrolment');
  perform test_helpers.logout();
  perform test_helpers.login(v_pay);
  perform test_helpers.expect_msg(format('select public.employee_set_bpjs(%L, ''k-p9a-b1'', ''2025-01-01'', ''[{"component":"bpjs_xyz","enrolled":true}]'')', e1), 'INVALID', 'a known BPJS program');
  perform test_helpers.expect_msg(format('select public.employee_set_bpjs(%L, ''k-p9a-b2'', ''2025-01-01'', ''[{"component":"bpjs_kes","enrolled":"yes"}]'')', e1), 'INVALID', 'enrolled is true or false');
  perform test_helpers.expect_msg(format('select public.employee_set_bpjs(%L, ''k-p9a-b3'', ''2025-01-01'', ''[{"component":"bpjs_jkk","enrolled":true,"rate_key":"Grade 1"}]'')', e1), 'INVALID', 'a rate option key shape');
  perform test_helpers.expect_msg(format('select public.employee_set_bpjs(%L, ''k-p9a-b4'', ''2024-12-01'', ''[{"component":"bpjs_kes","enrolled":true}]'')', e1), 'INVALID', 'not before the join date');
  perform test_helpers.assert(public.employee_set_bpjs(e1, 'k-p9a-b5', '2025-01-01', '[
      {"component":"bpjs_kes","enrolled":true,"member_ref":"KES-SYN-1"},
      {"component":"bpjs_jht","enrolled":true},
      {"component":"bpjs_jp","enrolled":true},
      {"component":"bpjs_jkk","enrolled":true,"rate_key":"grade_1"},
      {"component":"bpjs_jkm","enrolled":true}]'::jsonb) = 5, 'five enrolments recorded');
  perform test_helpers.expect_msg(format('select public.employee_set_bpjs(%L, ''k-p9a-b6'', ''2025-01-01'', ''[{"component":"bpjs_kes","enrolled":false}]'')', e1), 'CONFLICT', 'one enrolment per program and date');
  j := public.employee_bpjs_get(e1, '2025-05-01');
  perform test_helpers.assert(jsonb_array_length(j -> 'enrolled') = 5, 'five programs in force');
  perform test_helpers.assert((select c ->> 'rate_key' from jsonb_array_elements(j -> 'enrolled') c where c ->> 'component' = 'bpjs_jkk') = 'grade_1', 'the rate option is kept');
  -- opting out from a date keeps the past
  perform public.employee_set_bpjs(e1, 'k-p9a-b7', '2025-10-01', '[{"component":"bpjs_jp","enrolled":false}]');
  perform test_helpers.assert(jsonb_array_length(public.employee_bpjs_get(e1, '2025-09-30') -> 'enrolled') = 5, 'September still has JP');
  perform test_helpers.assert(jsonb_array_length(public.employee_bpjs_get(e1, '2025-10-01') -> 'enrolled') = 4, 'October has no JP');
  perform test_helpers.assert(jsonb_array_length(public.employee_bpjs_get(e1, '2024-12-31') -> 'enrolled') = 0, 'nothing before the first record');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 6. leaving, updating, immutability, audit
do $$
declare
  v_pay uuid := 'e0000000-0000-0000-0000-000000000002';
  v_acc uuid := 'e0000000-0000-0000-0000-000000000003';
  e1 uuid := test_helpers.g('e1');
  e2 uuid := test_helpers.g('e2');
  pt uuid := test_helpers.entity('p9a_pt');
  n integer;
begin
  perform test_helpers.login(v_acc);
  perform test_helpers.expect_msg(format('select public.employee_update(%L, ''Nama Baru'')', e2), 'FORBIDDEN', 'an accountant cannot change an employee');
  perform test_helpers.expect_msg(format('select public.employee_end(%L, ''k-p9a-x1'', ''2025-09-30'', ''Resigned'')', e2), 'FORBIDDEN', 'an accountant cannot end an employment');
  perform test_helpers.logout();

  perform test_helpers.login(v_pay);
  perform test_helpers.expect_msg(format('select public.employee_update(%L, ''X'')', e2), 'INVALID', 'a name of at least two characters');
  perform public.employee_update(e2, 'Tester Dua Baru', '2025-02-15');
  perform test_helpers.assert((select full_name from public.employee_list(pt) where id = e2) = 'Tester Dua Baru'
    and (select join_date from public.employee_list(pt) where id = e2) = '2025-02-15', 'name and join date updated while no payroll counted the employee');
  perform test_helpers.expect_msg(format('select public.employee_end(%L, ''k-p9a-x2'', ''2025-02-01'', ''Resigned'')', e2), 'INVALID', 'not before the join date');
  perform test_helpers.expect_msg(format('select public.employee_end(%L, ''k-p9a-x3'', ''2025-09-30'', '' '')', e2), 'INVALID', 'a reason');
  perform public.employee_end(e2, 'k-p9a-x4', '2025-09-30', 'Resigned');
  perform public.employee_end(e2, 'k-p9a-x4', '2025-09-30', 'Resigned');
  perform test_helpers.assert((select status from public.employee_list(pt) where id = e2) = 'ended'
    and (select exit_date from public.employee_list(pt) where id = e2) = '2025-09-30', 'the employee has left (replay is a no-op)');
  perform test_helpers.expect_msg(format('select public.employee_end(%L, ''k-p9a-x5'', ''2025-10-31'', ''Again'')', e2), 'CONFLICT', 'a leaver cannot leave twice');
  perform test_helpers.assert((select count(*) from public.employee_list(pt, false)) = 1, 'active-only list leaves the leaver out');
  perform test_helpers.assert((select count(*) from public.employee_list(pt, true)) = 2, 'the full list keeps the leaver');
  perform test_helpers.logout();

  -- immutability (as the table owner: the triggers, not the privileges, are under test)
  perform test_helpers.expect_error(format('update public.employees set employee_code = ''EMP-HACK'' where id = %L', e1), '23000', 'the employee code cannot change');
  perform test_helpers.expect_error(format('update public.employees set entity_id = %L where id = %L', test_helpers.entity('p9a_pe'), e1), '23000', 'the Entity cannot change');
  perform test_helpers.expect_error(format('delete from public.employees where id = %L', e1), null, 'an employee is never deleted');
  perform test_helpers.expect_error(format('update public.employee_compensation set amount = 1 where employee_id = %L', e1), null, 'compensation is append-only');
  perform test_helpers.expect_error(format('delete from public.employee_compensation where employee_id = %L', e1), null, 'compensation cannot be deleted');
  perform test_helpers.expect_error(format('update public.employee_tax_profiles set ptkp_status = ''TK/3'' where employee_id = %L', e1), null, 'tax facts are append-only');
  perform test_helpers.expect_error(format('delete from public.employee_bpjs_enrollments where employee_id = %L', e1), null, 'enrolment cannot be deleted');
  perform test_helpers.expect_error(format('delete from public.employee_employments where employee_id = %L', e1), null, 'employment records cannot be deleted');
  perform test_helpers.expect_error('truncate public.employee_compensation', null, 'no truncate');
  perform test_helpers.expect_error(format('insert into public.employee_compensation (entity_id, employee_id, effective_from, component_code, kind, amount, label, bpjs_base) values (%L, %L, ''2025-12-01'', ''bonus'', ''deduction'', 1, ''x'', true)', pt, e1), '23514', 'a deduction is never a BPJS base');

  -- the audit trail records the change, never the money or the identifier
  select count(*) into n from public.audit_events a where a.target_table = 'employee_compensation' and a.entity_id = pt;
  perform test_helpers.assert(n >= 5, 'compensation changes are audited');
  perform test_helpers.assert(not exists (select 1 from public.audit_events a where a.target_table = 'employee_compensation'
    and (coalesce(a.after_state::text, '') ~ '5000000|6000000|600000|Gaji pokok|Cicilan')), 'no amount or label in the compensation audit');
  perform test_helpers.assert(exists (select 1 from public.audit_events a where a.target_table = 'employee_tax_profiles' and a.entity_id = pt), 'tax facts are audited');
  perform test_helpers.assert(not exists (select 1 from public.audit_events a where a.target_table = 'employee_tax_profiles'
    and (coalesce(a.after_state::text, '') ~ '1234567890|TK/0|K/1|has_tax_id|Married')), 'no identifier or tax fact in the tax audit');
  perform test_helpers.assert(not exists (select 1 from public.audit_events a where a.target_table = 'employee_bpjs_enrollments'
    and coalesce(a.after_state::text, '') like '%KES-SYN-1%'), 'no member reference in the BPJS audit');
  perform test_helpers.assert(exists (select 1 from public.audit_events a where a.target_table = 'employees' and a.entity_id = pt), 'the employee identity is audited');
  perform test_helpers.assert(exists (select 1 from public.outbox_events o where o.entity_id = pt and o.event_type = 'EmployeeCreated'), 'creation is announced');
end
$$;

rollback;
