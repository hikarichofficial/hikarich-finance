-- Decision 369: income tax article 21 on a fee paid to an individual who is not an employee (PMK 168/2023):
-- base 50% of the gross, progressive layers of the personal tariff, x 1.2 without a tax number, review when the payee is
-- not an individual, article 26 when the payee is non-resident, and the result flows into the tax ledger. One transaction.
begin;
set local client_min_messages = warning;

create table test_helpers.p45 (k text primary key, v uuid not null);
grant all on test_helpers.p45 to public;
create function test_helpers.p45put(p_k text, p_v uuid) returns uuid
language sql as $f$ insert into test_helpers.p45 values (p_k, p_v) on conflict (k) do update set v = excluded.v returning v $f$;
create function test_helpers.p45get(p_k text) returns uuid
language sql stable as $f$ select v from test_helpers.p45 where k = p_k $f$;
grant execute on function test_helpers.p45put(text, uuid), test_helpers.p45get(text) to public;
create function test_helpers.p45res(p_eval jsonb, p_kind text) returns jsonb
language sql immutable as $f$ select x from jsonb_array_elements(p_eval -> 'results') x where x ->> 'kind' = p_kind $f$;
grant execute on function test_helpers.p45res(jsonb, text) to public;

do $$
declare
  pt uuid;
  v_today date;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p45_pt', 'P45 PT (synthetic)') returning id into pt;
  perform app_private.provision_default_coa(pt);
  perform test_helpers.mk_user('f4500000-0000-0000-0000-000000000001', 'p45owner');
  perform test_helpers.mk_user('f4500000-0000-0000-0000-000000000003', 'p45tax');
  perform test_helpers.mk_member(pt, 'f4500000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(pt, 'f4500000-0000-0000-0000-000000000003', 'tax');
  v_today := test_helpers.today(pt);

  perform test_helpers.login('f4500000-0000-0000-0000-000000000001');
  perform test_helpers.p45put('ind', public.create_contact(pt, 'key-p45-ct-1', 'vendor', 'Freelancer With NPWP', null, null, null, 'Sari (synthetic)'));
  perform test_helpers.p45put('indno', public.create_contact(pt, 'key-p45-ct-2', 'vendor', 'Freelancer No NPWP', null, null, null, 'Rudi (synthetic)'));
  perform test_helpers.p45put('co', public.create_contact(pt, 'key-p45-ct-3', 'vendor', 'A Company', null, null, null, 'PT Mitra (synthetic)'));
  perform test_helpers.p45put('abroad', public.create_contact(pt, 'key-p45-ct-4', 'vendor', 'Freelancer Abroad', null, null, null, 'John (synthetic)'));
  perform test_helpers.p45put('bca', public.create_financial_account(pt, 'key-p45-fa-1', 'bank', 'BCA', 'IDR', test_helpers.acct(pt, 'BANK_OPERATING'), 'BCA', 'ACC-45', 'PT P45'));
  perform test_helpers.logout();

  perform test_helpers.login('f4500000-0000-0000-0000-000000000003');
  perform public.tax_record_contact_facts(test_helpers.p45get('ind'), 'key-p45-cf-1', date '2026-01-01', 'individual', 'resident', 'has_npwp', 'non_pkp', 'none', 'synthetic');
  perform public.tax_record_contact_facts(test_helpers.p45get('indno'), 'key-p45-cf-2', date '2026-01-01', 'individual', 'resident', 'no_npwp', 'non_pkp', 'none', 'synthetic');
  perform public.tax_record_contact_facts(test_helpers.p45get('co'), 'key-p45-cf-3', date '2026-01-01', 'company', 'resident', 'has_npwp', 'non_pkp', 'none', 'synthetic');
  perform public.tax_record_contact_facts(test_helpers.p45get('abroad'), 'key-p45-cf-4', date '2026-01-01', 'individual', 'non_resident', 'no_npwp', 'non_pkp', 'none', 'synthetic');
  perform public.tax_record_entity_profile(pt, 'key-p45-f-1', v_today - 90, 'company', 'resident', 'general', 'none', 'none', 'non_pkp', 'yes', '01.234.567.8-901.000', 'synthetic');
  perform test_helpers.logout();
  perform test_helpers.login('f4500000-0000-0000-0000-000000000001');
  perform public.tax_engine_activate(pt, 'key-p45-a-1', v_today - 60);
  perform test_helpers.logout();
end
$$;

do $$
declare
  pt uuid := test_helpers.entity('p45_pt');
  v_today date := test_helpers.today(pt);
  v_id uuid;
  e jsonb;
  w jsonb;
  x public.expenses;
begin
  perform test_helpers.login('f4500000-0000-0000-0000-000000000001');

  -- 1. base 50%, first layer 5%: 20,000,000 -> 10,000,000 x 5% = 500,000
  v_id := public.create_expense_draft(pt, 'key-p45-x-1', test_helpers.p45get('bca'), v_today - 5, jsonb_build_array(
    jsonb_build_object('description', 'Design fee', 'unit_price', '20000000', 'wht_object', 'wht_pph21_non_employee')), test_helpers.p45get('ind'));
  e := public.tax_preview_document('expense', v_id);
  w := test_helpers.p45res(e, 'wht_pph21');
  perform test_helpers.assert(e ->> 'status' = 'auto_determined' and (w ->> 'tax')::numeric = 500000 and (w ->> 'base')::numeric = 20000000
    and w -> 'rules' -> 0 ->> 'code' = 'PPH21_NON_EMPLOYEE' and test_helpers.p45res(e, 'wht_pph23') is null and (e ->> 'withheld_total')::numeric = 500000,
    '1.1 fee to an individual with a tax number: 50% x 5% = 500,000 on 20,000,000');
  perform test_helpers.assert(w ->> 'consequence' like '%PPh 21%' or jsonb_array_length(w -> 'trace') >= 3, '1.2 the result explains itself');

  -- 2. layers: 200,000,000 -> base 100,000,000 -> 60,000,000 x 5% + 40,000,000 x 15% = 9,000,000
  v_id := public.create_expense_draft(pt, 'key-p45-x-2', test_helpers.p45get('bca'), v_today - 5, jsonb_build_array(
    jsonb_build_object('description', 'Big project', 'unit_price', '200000000', 'wht_object', 'wht_pph21_non_employee')), test_helpers.p45get('ind'));
  e := public.tax_preview_document('expense', v_id);
  perform test_helpers.assert((test_helpers.p45res(e, 'wht_pph21') ->> 'tax')::numeric = 9000000, '2.1 the layers of the personal tariff apply to the 50% base');

  -- 3. no tax number: x 1.2
  v_id := public.create_expense_draft(pt, 'key-p45-x-3', test_helpers.p45get('bca'), v_today - 5, jsonb_build_array(
    jsonb_build_object('description', 'Design fee', 'unit_price', '20000000', 'wht_object', 'wht_pph21_non_employee')), test_helpers.p45get('indno'));
  e := public.tax_preview_document('expense', v_id);
  perform test_helpers.assert((test_helpers.p45res(e, 'wht_pph21') ->> 'tax')::numeric = 600000, '3.1 a payee without a tax number: 500,000 x 1.2 = 600,000');

  -- 4. a company payee is a PPh 23 matter, not PPh 21
  v_id := public.create_expense_draft(pt, 'key-p45-x-4', test_helpers.p45get('bca'), v_today - 5, jsonb_build_array(
    jsonb_build_object('description', 'Design fee', 'unit_price', '20000000', 'wht_object', 'wht_pph21_non_employee')), test_helpers.p45get('co'));
  e := public.tax_preview_document('expense', v_id);
  perform test_helpers.assert(e ->> 'status' = 'needs_review' and e -> 'reasons' ->> 0 like '%not recorded as an individual%', '4.1 a company payee goes to review');

  -- 5. a non-resident individual: article 26 at 20%
  v_id := public.create_expense_draft(pt, 'key-p45-x-5', test_helpers.p45get('bca'), v_today - 5, jsonb_build_array(
    jsonb_build_object('description', 'Design fee', 'unit_price', '20000000', 'wht_object', 'wht_pph21_non_employee')), test_helpers.p45get('abroad'));
  e := public.tax_preview_document('expense', v_id);
  perform test_helpers.assert(e ->> 'status' = 'auto_determined' and (test_helpers.p45res(e, 'wht_pph26') ->> 'tax')::numeric = 4000000
    and test_helpers.p45res(e, 'wht_pph21') is null, '5.1 a non-resident individual: PPh 26, 20% of 20,000,000');

  -- 6. posted: the tax reaches the tax ledger as PPh 21, and the period position counts it
  v_id := public.create_expense_draft(pt, 'key-p45-x-6', test_helpers.p45get('bca'), v_today - 5, jsonb_build_array(
    jsonb_build_object('description', 'Design fee', 'unit_price', '20000000', 'wht_object', 'wht_pph21_non_employee')), test_helpers.p45get('ind'));
  perform public.submit_expense(v_id, 'key-p45-se-1');
  perform public.confirm_expense(v_id, 'key-p45-ce-1');
  select * into x from public.expenses where id = v_id;
  perform test_helpers.assert(x.status = 'confirmed' and x.withheld_total = 500000 and x.tax_status = 'determined', '6.1 the expense is recognised with its income tax');
  perform test_helpers.assert((select coalesce(sum(amount), 0) from public.tax_ledger_entries
                               where entity_id = pt and tax_type = 'wht_pph21' and tax_kind = 'wht_pph21' and direction = 'payable') = 500000,
    '6.2 the tax ledger holds 500,000 of PPh 21');
  perform test_helpers.logout();
  perform test_helpers.assert(app_private.tax_outstanding(pt, 'wht_pph21') = 500000, '6.3 it is outstanding until paid');

  -- 7. a published rule that names the object exists once; the master still passes its own audit
  perform test_helpers.assert((select count(*) from public.tax_rule_versions where code = 'PPH21_NON_EMPLOYEE' and status = 'published') = 1
    and exists (select 1 from public.tax_treatment_catalog where treatment_key = 'wht_pph21_non_employee' and side = 'purchase_wht'),
    '7.1 rule and catalogue entry exist');
end
$$;

rollback;
select 'OK 99_p45';
