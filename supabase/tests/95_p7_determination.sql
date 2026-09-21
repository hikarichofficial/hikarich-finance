-- P7 gate part 2 (Step 15 §11, Step 16 §15): the determination engine integrated with sales and purchases.
-- Covers the evaluators (output VAT, input VAT, PPh 23 withholding) with effective-date boundaries, NEEDS_REVIEW,
-- overrides and line confirmation, recognition of invoices, bills and expenses with their determinations and tax
-- ledger, reversal, correction, the AP sub-ledger net of withholding, the tax control against the General Ledger,
-- tax payments (cash and VAT offset), filings and reconciliation, the final-tax computation, the tax calendar and
-- authorization. All data is synthetic; dates are relative to the Entity's today. One transaction, rolled back.
begin;
set local client_min_messages = warning;

create table test_helpers.p7e (k text primary key, v uuid not null);
grant all on test_helpers.p7e to public;
create function test_helpers.eput(p_k text, p_v uuid) returns uuid
language sql as $f$ insert into test_helpers.p7e values (p_k, p_v) on conflict (k) do update set v = excluded.v returning v $f$;
create function test_helpers.eg(p_k text) returns uuid
language sql stable as $f$ select v from test_helpers.p7e where k = p_k $f$;
grant execute on function test_helpers.eput(text, uuid), test_helpers.eg(text) to public;

-- Debit / credit of one account (by system key) inside one journal, and a ledger balance by system key.
create function test_helpers.jd7(p_journal uuid, p_key text) returns numeric
language sql security definer set search_path = pg_catalog, public as $f$
  select coalesce(sum(l.debit), 0) from public.journal_lines l
  join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
  where l.journal_id = p_journal and a.system_key = p_key $f$;
create function test_helpers.jc7(p_journal uuid, p_key text) returns numeric
language sql security definer set search_path = pg_catalog, public as $f$
  select coalesce(sum(l.credit), 0) from public.journal_lines l
  join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
  where l.journal_id = p_journal and a.system_key = p_key $f$;
create function test_helpers.bal7(p_entity uuid, p_key text) returns numeric
language sql security definer set search_path = pg_catalog, public as $f$
  select coalesce(sum(l.debit - l.credit), 0)
  from public.journal_lines l
  join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id and j.status = 'posted'
  join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
  where l.entity_id = p_entity and a.system_key = p_key $f$;
grant execute on function test_helpers.jd7(uuid, text), test_helpers.jc7(uuid, text), test_helpers.bal7(uuid, text) to public;


-- Windows onto the app_private sub-ledger reports, usable whichever role the test acts as.
create function test_helpers.apc(p_entity uuid, p_as_of date default null)
returns table (sub_ledger numeric, ledger_purchases numeric, ledger_total numeric)
language sql security definer set search_path = pg_catalog, public as
$f$ select * from app_private.ap_control(p_entity, p_as_of) $f$;
create function test_helpers.bpos(p_entity uuid, p_as_of date default null)
returns table (bill_id uuid, bill_number text, vendor_id uuid, vendor_reference text, currency public.currency_code,
               status text, bill_date date, due_date date, total numeric, settled numeric, outstanding numeric,
               base_total numeric, base_settled numeric, base_outstanding numeric, settlement_status text,
               is_overdue boolean, days_overdue integer)
language sql security definer set search_path = pg_catalog, public as
$f$ select * from app_private.bill_positions(p_entity, p_as_of) $f$;
create function test_helpers.arc(p_entity uuid, p_as_of date default null)
returns table (sub_ledger numeric, ledger_sales numeric, ledger_total numeric,
               advance_sub_ledger numeric, advance_ledger_sales numeric, advance_ledger_total numeric)
language sql security definer set search_path = pg_catalog, public as
$f$ select * from app_private.ar_control(p_entity, p_as_of) $f$;
grant execute on function test_helpers.apc(uuid, date), test_helpers.bpos(uuid, date), test_helpers.arc(uuid, date) to public;

create function test_helpers.mc(p_entity uuid, p_as_of date default null)
returns table (financial_account_id uuid, name text, kind text, currency text, is_active boolean,
               movement_balance numeric, movement_base_balance numeric, ledger_balance numeric)
language sql security definer set search_path = pg_catalog, public as
$f$ select * from app_private.money_control_rows(p_entity, p_as_of) $f$;
create function test_helpers.tctl(p_entity uuid, p_as_of date default null)
returns table (account_key text, sub_ledger numeric, ledger_workflow numeric, ledger_other numeric, ledger_total numeric)
language sql security definer set search_path = pg_catalog, public as
$f$ select * from app_private.tax_control(p_entity, p_as_of) $f$;
grant execute on function test_helpers.mc(uuid, date), test_helpers.tctl(uuid, date) to public;

-- ================================================================ fixtures (superuser)
do $$
declare
  v_pt uuid;
  v_pe uuid;
begin
  insert into public.entities (entity_type, code, legal_name)
  values ('company', 'p7e_pt', 'P7E PT (synthetic)') returning id into v_pt;
  perform app_private.provision_default_coa(v_pt);
  insert into public.entities (entity_type, code, legal_name)
  values ('personal', 'p7e_pe', 'P7E PERSONAL (synthetic)') returning id into v_pe;
  perform app_private.provision_default_coa(v_pe);

  insert into public.entities (entity_type, code, legal_name)
  values ('company', 'p7e_b', 'P7E BOUNDARY (synthetic)');
  perform app_private.provision_default_coa((select id from public.entities where code = 'p7e_b'));

  perform test_helpers.mk_user('e0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_user('e0000000-0000-0000-0000-000000000002', 'admin');
  perform test_helpers.mk_user('e0000000-0000-0000-0000-000000000003', 'taxer');
  perform test_helpers.mk_user('e0000000-0000-0000-0000-000000000004', 'viewer');
  perform test_helpers.mk_user('e0000000-0000-0000-0000-000000000005', 'staff');
  perform test_helpers.mk_user('e0000000-0000-0000-0000-000000000006', 'nobody');
  perform test_helpers.mk_user('e0000000-0000-0000-0000-000000000007', 'pe_admin');
  perform test_helpers.mk_user('e0000000-0000-0000-0000-000000000008', 'accountant');
  perform test_helpers.mk_member(v_pt, 'e0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member((select id from public.entities where code = 'p7e_b'), 'e0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pe, 'e0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pt, 'e0000000-0000-0000-0000-000000000002', 'finance_admin');
  perform test_helpers.mk_member(v_pt, 'e0000000-0000-0000-0000-000000000003', 'tax');
  perform test_helpers.mk_member(v_pt, 'e0000000-0000-0000-0000-000000000004', 'viewer_auditor');
  perform test_helpers.mk_member(v_pt, 'e0000000-0000-0000-0000-000000000005', 'finance_staff');
  perform test_helpers.mk_member(v_pe, 'e0000000-0000-0000-0000-000000000007', 'finance_admin');
  perform test_helpers.mk_member(v_pt, 'e0000000-0000-0000-0000-000000000008', 'accountant');
end
$$;

-- One result of an evaluation by kind.
create function test_helpers.res(p_eval jsonb, p_kind text) returns jsonb
language sql immutable as $f$ select x from jsonb_array_elements(p_eval -> 'results') x where x ->> 'kind' = p_kind $f$;
grant execute on function test_helpers.res(jsonb, text) to public;

-- ================================================================ 1. masters, tax facts and the engine switch
do $$
declare
  pt uuid := test_helpers.entity('p7e_pt');
  v_owner uuid := 'e0000000-0000-0000-0000-000000000001';
  v_taxer uuid := 'e0000000-0000-0000-0000-000000000003';
  v_today date := test_helpers.today(pt);
  v_cat uuid;
begin
  perform test_helpers.login(v_owner);
  perform test_helpers.eput('cust', public.create_contact(pt, 'key-p7e-ct-01', 'customer', 'Customer One', 'c1@cust.example.invalid'));
  perform test_helpers.eput('vco', public.create_contact(pt, 'key-p7e-ct-02', 'vendor', 'Vendor Co (company, NPWP)', 'a@vendor.example.invalid', null, '01.234.567.8-901.000', 'PT Vendor Co'));
  perform test_helpers.eput('vnp', public.create_contact(pt, 'key-p7e-ct-03', 'vendor', 'Vendor No NPWP', null, null, null, 'PT Vendor NoNPWP'));
  perform test_helpers.eput('vind', public.create_contact(pt, 'key-p7e-ct-04', 'vendor', 'Vendor Individual', null, null, null, 'Budi (synthetic)'));
  perform test_helpers.eput('vnof', public.create_contact(pt, 'key-p7e-ct-05', 'vendor', 'Vendor Without Facts'));
  perform test_helpers.eput('vnres', public.create_contact(pt, 'key-p7e-ct-06', 'vendor', 'Vendor Abroad'));
  perform test_helpers.eput('vskb', public.create_contact(pt, 'key-p7e-ct-07', 'vendor', 'Vendor With Certificate'));
  perform test_helpers.logout();

  -- categories: sales, purchases (mapped), and one carrying a tax mapping key
  insert into public.categories (entity_id, name, kind) values (pt, 'Digital Products', 'revenue') returning id into v_cat;
  perform test_helpers.eput('cat_rev', v_cat);
  insert into public.categories (entity_id, name, kind, tax_category_key) values (pt, 'Digital Products VAT', 'revenue', 'vat_taxable') returning id into v_cat;
  perform test_helpers.eput('cat_rev_vat', v_cat);
  insert into public.categories (entity_id, name, kind) values (pt, 'Office Supplies', 'expense') returning id into v_cat;
  insert into public.category_account_mappings (entity_id, category_id, context, debit_ledger_account_id, effective_from)
  values (pt, v_cat, 'purchases', test_helpers.acct(pt, 'OFFICE_GENERAL_EXPENSE'), date '2000-01-01');
  perform test_helpers.eput('cat_exp', v_cat);
  insert into public.categories (entity_id, name, kind, tax_category_key) values (pt, 'Rent', 'expense', 'wht_rent_movable') returning id into v_cat;
  insert into public.category_account_mappings (entity_id, category_id, context, debit_ledger_account_id, effective_from)
  values (pt, v_cat, 'purchases', test_helpers.acct(pt, 'OFFICE_GENERAL_EXPENSE'), date '2000-01-01');
  perform test_helpers.eput('cat_rent', v_cat);
  insert into public.categories (entity_id, name, kind, tax_category_key) values (pt, 'Supplies (not withholding)', 'expense', 'wht_none') returning id into v_cat;
  insert into public.category_account_mappings (entity_id, category_id, context, debit_ledger_account_id, effective_from)
  values (pt, v_cat, 'purchases', test_helpers.acct(pt, 'OFFICE_GENERAL_EXPENSE'), date '2000-01-01');
  perform test_helpers.eput('cat_none', v_cat);
  insert into public.categories (entity_id, name, kind, tax_category_key) values (pt, 'Bogus Key', 'expense', 'not_a_key') returning id into v_cat;
  perform test_helpers.eput('cat_bogus', v_cat);

  perform test_helpers.login(v_owner);
  perform test_helpers.eput('bca', public.create_financial_account(pt, 'key-p7e-fa-01', 'bank', 'BCA Main', 'IDR', test_helpers.acct(pt, 'BANK_OPERATING'), 'BCA', 'ACC-SECRET-7', 'PT P7E'));
  perform test_helpers.eput('cash', public.create_financial_account(pt, 'key-p7e-fa-02', 'cash', 'Petty Cash', 'IDR', test_helpers.acct(pt, 'CASH')));
  perform test_helpers.eput('usd', public.create_financial_account(pt, 'key-p7e-fa-03', 'bank', 'USD Account', 'USD'));
  perform test_helpers.logout();

  -- Tax facts of the counterparties (the tax role records them).
  perform test_helpers.login(v_taxer);
  perform public.tax_record_contact_facts(test_helpers.eg('vco'), 'key-p7e-cf-01', date '2026-01-01', 'company', 'resident', 'has_npwp', 'non_pkp', 'none', 'synthetic');
  perform public.tax_record_contact_facts(test_helpers.eg('vnp'), 'key-p7e-cf-02', date '2026-01-01', 'company', 'resident', 'no_npwp', 'non_pkp', 'none', 'synthetic');
  perform public.tax_record_contact_facts(test_helpers.eg('vind'), 'key-p7e-cf-03', date '2026-01-01', 'individual', 'resident', 'has_npwp', 'non_pkp', 'none', 'synthetic');
  perform public.tax_record_contact_facts(test_helpers.eg('vnres'), 'key-p7e-cf-04', date '2026-01-01', 'company', 'non_resident', 'no_npwp', 'non_pkp', 'none', 'synthetic');
  perform public.tax_record_contact_facts(test_helpers.eg('vskb'), 'key-p7e-cf-05', date '2026-01-01', 'company', 'resident', 'has_npwp', 'non_pkp', 'certificate', 'SKB (synthetic)');
  -- The Entity: a Perseroan Perorangan on the final regime, a withholding agent, not PKP until 40 days before today.
  perform public.tax_record_entity_profile(pt, 'key-p7e-f-01', v_today - 90, 'perseroan_perorangan', 'resident', 'final_umkm', 'none', 'none',
    'non_pkp', 'yes', '01.234.567.8-901.000', 'synthetic');
  perform public.tax_record_entity_profile(pt, 'key-p7e-f-02', v_today - 40, 'perseroan_perorangan', 'resident', 'final_umkm', 'none', 'none',
    'pkp', 'yes', null, 'PKP from this date (synthetic)');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.assert(public.tax_engine_activate(pt, 'key-p7e-a-01', v_today - 60) = v_today - 60, 'the engine is active from 60 days ago');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 2. the evaluators (previews of drafts)
do $$
declare
  pt uuid := test_helpers.entity('p7e_pt');
  v_owner uuid := 'e0000000-0000-0000-0000-000000000001';
  v_staff uuid := 'e0000000-0000-0000-0000-000000000005';
  v_today date := test_helpers.today(pt);
  v_id uuid;
  e jsonb;
  w jsonb;
  v jsonb;
begin
  perform test_helpers.login(v_owner);

  -- 2.1 rent from a company with a tax number: 2% withheld, input VAT credited (PKP on this date)
  v_id := public.create_bill_draft(pt, 'key-p7e-b-01', test_helpers.eg('vco'), v_today - 20, v_today + 10,
    jsonb_build_array(jsonb_build_object('description', 'Office rent', 'unit_price', '10000000', 'tax_amount', '1100000',
      'wht_object', 'wht_rent_movable', 'vat_invoice_ref', '010.000-26.00000001')));
  perform test_helpers.eput('b1', v_id);
  e := public.tax_preview_document('bill', v_id);
  w := test_helpers.res(e, 'wht_pph23');
  v := test_helpers.res(e, 'vat_input');
  perform test_helpers.assert(e ->> 'engine' = 'active' and e ->> 'status' = 'auto_determined', '2.1 a complete rent bill is auto-determined');
  perform test_helpers.assert((w ->> 'tax')::numeric = 200000 and (w ->> 'base')::numeric = 10000000, '2.2 PPh 23 on rent: 2% of 10,000,000 = 200,000');
  perform test_helpers.assert((v ->> 'tax')::numeric = 1100000 and (v ->> 'not_creditable')::numeric = 0, '2.3 input VAT of a PKP with a tax-invoice reference is creditable');
  perform test_helpers.assert(w -> 'rules' -> 0 ->> 'code' = 'PPH23_RATE_2' and (w -> 'rules' -> 0 ->> 'rule_version')::int = 1
    and w -> 'rules' -> 0 ->> 'source_ref' is not null, '2.4 the result names the rule version and its source');
  perform test_helpers.assert(jsonb_array_length(w -> 'trace') >= 3 and w ->> 'consequence' like '%withheld%' and jsonb_array_length(w -> 'components') = 1,
    '2.5 the result is explainable: a trace, a formula and a consequence');
  perform test_helpers.assert((e ->> 'withheld_total')::numeric = 200000 and (e ->> 'vat_input_creditable')::numeric = 1100000, '2.6 the summary totals');

  -- 2.7 no tax number: the rate is doubled
  v_id := public.create_bill_draft(pt, 'key-p7e-b-02', test_helpers.eg('vnp'), v_today - 20, v_today + 10,
    jsonb_build_array(jsonb_build_object('description', 'Rent', 'unit_price', '10000000', 'wht_object', 'wht_rent_movable')));
  e := public.tax_preview_document('bill', v_id);
  perform test_helpers.assert((test_helpers.res(e, 'wht_pph23') ->> 'tax')::numeric = 400000, '2.7 a payee without a tax number: 4% of 10,000,000');
  perform test_helpers.assert(test_helpers.res(e, 'vat_input') is null, '2.8 no VAT charged: no input-VAT result');

  -- 2.9 15% objects and the individual rule
  v_id := public.create_bill_draft(pt, 'key-p7e-b-03', test_helpers.eg('vind'), v_today - 20, v_today + 10,
    jsonb_build_array(jsonb_build_object('description', 'Royalty', 'unit_price', '1000000', 'wht_object', 'wht_royalty')));
  e := public.tax_preview_document('bill', v_id);
  perform test_helpers.assert(e ->> 'status' = 'auto_determined' and (test_helpers.res(e, 'wht_pph23') ->> 'tax')::numeric = 150000
    and test_helpers.res(e, 'wht_pph23') -> 'rules' -> 0 ->> 'code' = 'PPH23_RATE_15', '2.9 royalty to an individual: 15% under the 15% rule');
  v_id := public.create_bill_draft(pt, 'key-p7e-b-04', test_helpers.eg('vind'), v_today - 20, v_today + 10,
    jsonb_build_array(jsonb_build_object('description', 'Technical service', 'unit_price', '1000000', 'wht_object', 'wht_service_technical')));
  e := public.tax_preview_document('bill', v_id);
  perform test_helpers.assert(e ->> 'status' = 'needs_review' and e -> 'reasons' ->> 0 like '%individual%', '2.10 a service paid to an individual needs a legal classification review');

  -- 2.11-2.16 missing or unsupported facts are never guessed
  v_id := public.create_bill_draft(pt, 'key-p7e-b-05', test_helpers.eg('vnof'), v_today - 20, v_today + 10,
    jsonb_build_array(jsonb_build_object('description', 'Rent', 'unit_price', '1000000', 'wht_object', 'wht_rent_movable')));
  e := public.tax_preview_document('bill', v_id);
  perform test_helpers.assert(e ->> 'status' = 'needs_review' and e -> 'reasons' ->> 0 like '%No tax facts%', '2.11 a payee with no tax facts: review');
  v_id := public.create_bill_draft(pt, 'key-p7e-b-06', test_helpers.eg('vnres'), v_today - 20, v_today + 10,
    jsonb_build_array(jsonb_build_object('description', 'Rent', 'unit_price', '1000000', 'wht_object', 'wht_rent_movable')));
  e := public.tax_preview_document('bill', v_id);
  perform test_helpers.assert(e ->> 'status' = 'needs_review' and e -> 'reasons' ->> 0 like '%non-resident%', '2.12 a non-resident payee: review');
  v_id := public.create_bill_draft(pt, 'key-p7e-b-07', test_helpers.eg('vco'), v_today - 20, v_today + 10,
    jsonb_build_array(jsonb_build_object('description', 'Things', 'unit_price', '1000000')));
  e := public.tax_preview_document('bill', v_id);
  perform test_helpers.assert(e ->> 'status' = 'needs_review' and e -> 'reasons' ->> 0 like 'Line 1 has no withholding classification%',
    '2.13 a line without a classification is not guessed from anything else');
  v_id := public.create_bill_draft(pt, 'key-p7e-b-08', test_helpers.eg('vco'), v_today - 20, v_today + 10,
    jsonb_build_array(jsonb_build_object('description', 'Things', 'unit_price', '1000000', 'category_id', test_helpers.eg('cat_bogus'))));
  e := public.tax_preview_document('bill', v_id);
  perform test_helpers.assert(e ->> 'status' = 'needs_review', '2.14 a category with an invalid tax key does not count as a fact');
  v_id := public.create_bill_draft(pt, 'key-p7e-b-09', test_helpers.eg('vco'), v_today - 20, v_today + 10,
    jsonb_build_array(jsonb_build_object('description', 'Things', 'unit_price', '1000000', 'wht_object', 'wht_review')));
  e := public.tax_preview_document('bill', v_id);
  perform test_helpers.assert(e ->> 'status' = 'needs_review' and e -> 'reasons' ->> 0 like '%not sure%', '2.15 "not sure" waits for a tax review');
  -- the category mapping IS a recorded fact: rent maps to a withholding object, supplies map to "not one"
  v_id := public.create_bill_draft(pt, 'key-p7e-b-10', test_helpers.eg('vco'), v_today - 20, v_today + 10,
    jsonb_build_array(jsonb_build_object('description', 'Rent', 'unit_price', '5000000', 'category_id', test_helpers.eg('cat_rent')),
                      jsonb_build_object('description', 'Paper', 'unit_price', '250000', 'category_id', test_helpers.eg('cat_none'))));
  e := public.tax_preview_document('bill', v_id);
  w := test_helpers.res(e, 'wht_pph23');
  perform test_helpers.assert(e ->> 'status' = 'auto_determined' and (w ->> 'tax')::numeric = 100000 and (w ->> 'base')::numeric = 5000000,
    '2.16 a mapped category supplies the classification; only the rent line is taxed');
  perform test_helpers.eput('b10', v_id);
  -- an exemption certificate on file: nothing withheld
  v_id := public.create_bill_draft(pt, 'key-p7e-b-11', test_helpers.eg('vskb'), v_today - 20, v_today + 10,
    jsonb_build_array(jsonb_build_object('description', 'Rent', 'unit_price', '2000000', 'wht_object', 'wht_rent_movable')));
  e := public.tax_preview_document('bill', v_id);
  perform test_helpers.assert(e ->> 'status' = 'auto_determined' and (e ->> 'withheld_total')::numeric = 0
    and test_helpers.res(e, 'wht_pph23') ->> 'consequence' like 'Nothing is withheld%', '2.17 an exemption certificate: nothing withheld, and the result says why');
  -- two rates on one bill
  v_id := public.create_bill_draft(pt, 'key-p7e-b-12', test_helpers.eg('vco'), v_today - 20, v_today + 10,
    jsonb_build_array(jsonb_build_object('description', 'Rent', 'unit_price', '1000000', 'wht_object', 'wht_rent_movable'),
                      jsonb_build_object('description', 'Royalty', 'unit_price', '2000000', 'wht_object', 'wht_royalty')));
  e := public.tax_preview_document('bill', v_id);
  perform test_helpers.assert((e ->> 'withheld_total')::numeric = 320000 and jsonb_array_length(test_helpers.res(e, 'wht_pph23') -> 'components') = 2,
    '2.18 two rates on one document: 2% x 1,000,000 + 15% x 2,000,000 = 320,000');

  -- 2.19-2.22 input VAT
  v_id := public.create_bill_draft(pt, 'key-p7e-b-13', test_helpers.eg('vco'), v_today - 20, v_today + 10,
    jsonb_build_array(jsonb_build_object('description', 'Paper', 'unit_price', '1000000', 'tax_amount', '110000', 'wht_object', 'wht_none')));
  e := public.tax_preview_document('bill', v_id);
  perform test_helpers.assert(e ->> 'status' = 'needs_review' and e -> 'reasons' ->> 0 like '%tax-invoice reference%', '2.19 VAT without a tax-invoice reference is not credited on a guess');
  v_id := public.create_bill_draft(pt, 'key-p7e-b-14', test_helpers.eg('vco'), v_today - 20, v_today + 10,
    jsonb_build_array(jsonb_build_object('description', 'Paper', 'unit_price', '1000000', 'tax_amount', '110000', 'wht_object', 'wht_none',
      'vat_not_creditable', true)));
  e := public.tax_preview_document('bill', v_id);
  perform test_helpers.assert(e ->> 'status' = 'auto_determined' and (test_helpers.res(e, 'vat_input') ->> 'tax')::numeric = 0
    and (test_helpers.res(e, 'vat_input') ->> 'not_creditable')::numeric = 110000, '2.20 a restriction the user asserts makes the VAT part of the cost');
  v_id := public.create_bill_draft(pt, 'key-p7e-b-15', test_helpers.eg('vco'), v_today - 50, v_today + 10,
    jsonb_build_array(jsonb_build_object('description', 'Paper', 'unit_price', '1000000', 'tax_amount', '110000', 'wht_object', 'wht_none',
      'vat_invoice_ref', '010.000-26.00000009')));
  e := public.tax_preview_document('bill', v_id);
  perform test_helpers.assert(e ->> 'status' = 'auto_determined' and (test_helpers.res(e, 'vat_input') ->> 'tax')::numeric = 0
    and (test_helpers.res(e, 'vat_input') ->> 'not_creditable')::numeric = 110000, '2.21 before PKP status the same VAT cannot be credited');
  v_id := public.create_bill_draft(pt, 'key-p7e-b-16', test_helpers.eg('vco'), v_today - 70, v_today + 10,
    jsonb_build_array(jsonb_build_object('description', 'Paper', 'unit_price', '1000000')));
  e := public.tax_preview_document('bill', v_id);
  perform test_helpers.assert(e ->> 'engine' = 'inactive' and e ->> 'status' = 'not_configured' and jsonb_array_length(e -> 'results') = 0,
    '2.22 before the engine start date a document is explicitly "not configured"');
  -- the amount the vendor charged is a fact; the formula is shown for information only
  perform test_helpers.assert(test_helpers.res(public.tax_preview_document('bill', test_helpers.eg('b1')), 'vat_input') -> 'trace' -> 0 ->> 'text' like '%would give 1100000%',
    '2.23 the standard formula is displayed next to the charged VAT');

  -- 2.24 expenses use the same engine (payee is a contact) and a free-text payee has no tax facts
  v_id := public.create_expense_draft(pt, 'key-p7e-x-01', test_helpers.eg('bca'), v_today - 5, jsonb_build_array(
    jsonb_build_object('description', 'Rent', 'unit_price', '3000000', 'wht_object', 'wht_rent_movable')), test_helpers.eg('vco'));
  e := public.tax_preview_document('expense', v_id);
  perform test_helpers.assert((e ->> 'withheld_total')::numeric = 60000, '2.24 an expense paid to a contact: 2% withheld');
  v_id := public.create_expense_draft(pt, 'key-p7e-x-02', test_helpers.eg('bca'), v_today - 5, jsonb_build_array(
    jsonb_build_object('description', 'Rent', 'unit_price', '3000000', 'wht_object', 'wht_rent_movable')), null, 'A market stall');
  e := public.tax_preview_document('expense', v_id);
  perform test_helpers.assert(e ->> 'status' = 'needs_review' and e -> 'reasons' ->> 0 like '%not a contact%', '2.25 a free-text payee has unknown tax facts: review');
  v_id := public.create_expense_draft(pt, 'key-p7e-x-03', test_helpers.eg('bca'), v_today - 5, jsonb_build_array(
    jsonb_build_object('description', 'Snack', 'unit_price', '30000', 'wht_object', 'wht_none')), null, 'A market stall');
  e := public.tax_preview_document('expense', v_id);
  perform test_helpers.assert(e ->> 'status' = 'auto_determined' and (e ->> 'withheld_total')::numeric = 0, '2.26 a plain purchase from a free-text payee needs no payee facts');
  perform test_helpers.eput('x3', v_id);
  perform test_helpers.logout();
end
$$;

-- ================================================================ 3. output VAT, and effective-date boundaries
do $$
declare
  pt uuid := test_helpers.entity('p7e_pt');
  bt uuid := test_helpers.entity('p7e_b');
  v_owner uuid := 'e0000000-0000-0000-0000-000000000001';
  v_today date := test_helpers.today(pt);
  v_id uuid;
  e jsonb;
  r jsonb;
  v_cust uuid;
  v_vend uuid;
begin
  perform test_helpers.login(v_owner);
  -- 3.1 a taxable supply while PKP: 1,000,000 x 11/12 x 12% = 110,000
  v_id := public.create_invoice_draft(pt, 'key-p7e-i-01', test_helpers.eg('cust'), v_today - 10, v_today + 20, jsonb_build_array(
    jsonb_build_object('description', 'Course', 'unit_price', '1000000', 'vat_treatment', 'vat_taxable', 'category_id', test_helpers.eg('cat_rev')),
    jsonb_build_object('description', 'Book', 'unit_price', '500000', 'vat_treatment', 'vat_exempt')));
  perform test_helpers.eput('i1', v_id);
  e := public.tax_preview_document('invoice', v_id);
  r := test_helpers.res(e, 'vat_output');
  perform test_helpers.assert(e ->> 'status' = 'auto_determined' and (r ->> 'tax')::numeric = 110000 and (r ->> 'base')::numeric = 1000000
    and (e ->> 'vat_output_total')::numeric = 110000, '3.1 output VAT: DPP 11/12 x 12% of the taxable lines only = 110,000');
  perform test_helpers.assert(r -> 'rules' -> 0 ->> 'code' = 'PPN_STANDARD' and r -> 'components' -> 0 ->> 'rate' = '0.12', '3.2 the rule version and the statutory rate are in the result');
  perform test_helpers.assert((select total from public.invoices where id = v_id) = 1500000, '3.3 the draft total stays pre-tax; the tax is added when the invoice is issued');
  -- 3.4 a category mapping is a fact too
  v_id := public.create_invoice_draft(pt, 'key-p7e-i-02', test_helpers.eg('cust'), v_today - 10, v_today + 20, jsonb_build_array(
    jsonb_build_object('description', 'Course', 'unit_price', '1000000', 'category_id', test_helpers.eg('cat_rev_vat'))));
  e := public.tax_preview_document('invoice', v_id);
  perform test_helpers.assert((e ->> 'vat_output_total')::numeric = 110000, '3.4 a category mapped to "taxable" supplies the treatment');
  -- 3.5 no treatment: review, never a default
  v_id := public.create_invoice_draft(pt, 'key-p7e-i-03', test_helpers.eg('cust'), v_today - 10, v_today + 20, jsonb_build_array(
    jsonb_build_object('description', 'Course', 'unit_price', '1000000', 'category_id', test_helpers.eg('cat_rev'))));
  e := public.tax_preview_document('invoice', v_id);
  perform test_helpers.assert(e ->> 'status' = 'needs_review' and e -> 'reasons' ->> 0 like 'Line 1 has no VAT treatment%', '3.5 a PKP invoice line without a treatment goes to review');
  -- 3.6 special and digital treatments are not computed
  v_id := public.create_invoice_draft(pt, 'key-p7e-i-04', test_helpers.eg('cust'), v_today - 10, v_today + 20, jsonb_build_array(
    jsonb_build_object('description', 'Special', 'unit_price', '1000000', 'vat_treatment', 'vat_special')));
  e := public.tax_preview_document('invoice', v_id);
  perform test_helpers.assert(e ->> 'status' = 'needs_review' and e -> 'reasons' ->> 0 like '%special VAT treatment%', '3.6 a special formula goes to review');
  -- 3.7 full DPP
  v_id := public.create_invoice_draft(pt, 'key-p7e-i-05', test_helpers.eg('cust'), v_today - 10, v_today + 20, jsonb_build_array(
    jsonb_build_object('description', 'Luxury', 'unit_price', '1000000', 'vat_treatment', 'vat_taxable_full_dpp')));
  e := public.tax_preview_document('invoice', v_id);
  perform test_helpers.assert((e ->> 'vat_output_total')::numeric = 120000, '3.7 the full-DPP treatment: 12% of the price');
  -- 3.8 whole-rupiah rounding, half up: 33,333 x 11/12 x 12% = 3,666.63 -> 3,667
  v_id := public.create_invoice_draft(pt, 'key-p7e-i-06', test_helpers.eg('cust'), v_today - 10, v_today + 20, jsonb_build_array(
    jsonb_build_object('description', 'Odd', 'unit_price', '33333', 'vat_treatment', 'vat_taxable')));
  e := public.tax_preview_document('invoice', v_id);
  perform test_helpers.assert((e ->> 'vat_output_total')::numeric = 3667, '3.8 rounding to the whole rupiah');
  -- 3.9 before PKP status no VAT is created merely because a supply is taxable in nature
  v_id := public.create_invoice_draft(pt, 'key-p7e-i-07', test_helpers.eg('cust'), v_today - 50, v_today + 20, jsonb_build_array(
    jsonb_build_object('description', 'Course', 'unit_price', '1000000', 'vat_treatment', 'vat_taxable')));
  e := public.tax_preview_document('invoice', v_id);
  perform test_helpers.assert(e ->> 'status' = 'auto_determined' and (e ->> 'vat_output_total')::numeric = 0
    and test_helpers.res(e, 'vat_output') -> 'trace' ->> 1 like '%not PKP%', '3.9 before the PKP date: no output VAT, and the trace says why');
  -- 3.10 the boundary is the profile's effective date
  v_id := public.create_invoice_draft(pt, 'key-p7e-i-08', test_helpers.eg('cust'), v_today - 40, v_today + 20, jsonb_build_array(
    jsonb_build_object('description', 'Course', 'unit_price', '1000000', 'vat_treatment', 'vat_taxable')));
  perform test_helpers.assert((public.tax_preview_document('invoice', v_id) ->> 'vat_output_total')::numeric = 110000, '3.10 on the PKP effective date VAT applies');
  v_id := public.create_invoice_draft(pt, 'key-p7e-i-09', test_helpers.eg('cust'), v_today - 41, v_today + 20, jsonb_build_array(
    jsonb_build_object('description', 'Course', 'unit_price', '1000000', 'vat_treatment', 'vat_taxable')));
  perform test_helpers.assert((public.tax_preview_document('invoice', v_id) ->> 'vat_output_total')::numeric = 0, '3.11 the day before it does not');
  -- 3.12 a foreign-currency taxable supply is not converted on a guess
  v_id := public.create_invoice_draft(pt, 'key-p7e-i-10', test_helpers.eg('cust'), v_today - 10, v_today + 20, jsonb_build_array(
    jsonb_build_object('description', 'Course', 'unit_price', '100', 'vat_treatment', 'vat_taxable')), 'USD', 15500);
  e := public.tax_preview_document('invoice', v_id);
  perform test_helpers.assert(e ->> 'status' = 'needs_review' and e -> 'reasons' ->> 0 like '%foreign-currency%', '3.12 a foreign-currency taxable invoice goes to review');
  perform test_helpers.logout();

  -- 3.13 regression by effective date: a second Entity whose engine started before the rules did
  perform test_helpers.login(v_owner);
  v_cust := public.create_contact(bt, 'key-p7e-b-c1', 'customer', 'B Customer');
  v_vend := public.create_contact(bt, 'key-p7e-b-c2', 'vendor', 'B Vendor');
  perform public.tax_record_contact_facts(v_vend, 'key-p7e-b-f0', date '2024-01-01', 'company', 'resident', 'has_npwp', 'non_pkp', 'none', 'synthetic');
  perform public.tax_record_entity_profile(bt, 'key-p7e-b-f1', date '2024-06-01', 'company', 'resident', 'general', 'none', 'none', 'pkp', 'yes', null, 'synthetic');
  perform public.tax_engine_activate(bt, 'key-p7e-b-a1', date '2024-06-01');
  v_id := public.create_invoice_draft(bt, 'key-p7e-b-i1', v_cust, date '2024-12-31', date '2025-01-30', jsonb_build_array(
    jsonb_build_object('description', 'Course', 'unit_price', '1000000', 'vat_treatment', 'vat_taxable')));
  e := public.tax_preview_document('invoice', v_id);
  perform test_helpers.assert(e ->> 'status' = 'needs_review' and e -> 'reasons' ->> 0 like 'No VAT rule is in force on 2024-12-31%',
    '3.13 the day before the VAT rule is effective there is no rule: review, not a guess');
  v_id := public.create_invoice_draft(bt, 'key-p7e-b-i2', v_cust, date '2025-01-01', date '2025-01-30', jsonb_build_array(
    jsonb_build_object('description', 'Course', 'unit_price', '1000000', 'vat_treatment', 'vat_taxable')));
  perform test_helpers.assert((public.tax_preview_document('invoice', v_id) ->> 'vat_output_total')::numeric = 110000, '3.14 on the effective date the rule applies');
  v_id := public.create_bill_draft(bt, 'key-p7e-b-b1', v_vend, date '2025-12-31', date '2026-01-30', jsonb_build_array(
    jsonb_build_object('description', 'Rent', 'unit_price', '1000000', 'wht_object', 'wht_rent_movable')));
  e := public.tax_preview_document('bill', v_id);
  perform test_helpers.assert(e ->> 'status' = 'needs_review' and e -> 'reasons' ->> 0 like 'No single withholding rule covers%', '3.15 before the PPh 23 rule takes effect: review');
  v_id := public.create_bill_draft(bt, 'key-p7e-b-b2', v_vend, date '2026-01-01', date '2026-01-30', jsonb_build_array(
    jsonb_build_object('description', 'Rent', 'unit_price', '1000000', 'wht_object', 'wht_rent_movable')));
  perform test_helpers.assert((public.tax_preview_document('bill', v_id) ->> 'withheld_total')::numeric = 20000, '3.16 on its effective date the withholding applies');
  perform test_helpers.logout();

  -- 3.17 visibility of the preview: document viewers and tax viewers; strangers see nothing
  perform test_helpers.login('e0000000-0000-0000-0000-000000000004');
  perform test_helpers.assert(public.tax_preview_document('invoice', test_helpers.eg('i1')) ->> 'status' = 'auto_determined', '3.17 an auditor can preview');
  perform test_helpers.logout();
  perform test_helpers.login('e0000000-0000-0000-0000-000000000006');
  perform test_helpers.expect_msg(format($q$select public.tax_preview_document('invoice', %L)$q$, test_helpers.eg('i1')), 'FORBIDDEN', '3.18 a stranger cannot');
  perform test_helpers.logout();
  perform test_helpers.login('e0000000-0000-0000-0000-000000000007');
  perform test_helpers.expect_msg(format($q$select public.tax_preview_document('invoice', %L)$q$, test_helpers.eg('i1')), 'FORBIDDEN', '3.19 another Entity cannot');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 4. invoices: output VAT is recognised with the sale
do $$
declare
  pt uuid := test_helpers.entity('p7e_pt');
  v_owner uuid := 'e0000000-0000-0000-0000-000000000001';
  v_today date := test_helpers.today(pt);
  v_id uuid;
  v_j uuid;
  i public.invoices%rowtype;
  d public.tax_determinations%rowtype;
begin
  perform test_helpers.login(v_owner);
  -- 4.1 issue the taxable invoice from section 3 (Course 1,000,000 taxable + Book 500,000 exempt)
  perform public.issue_invoice(test_helpers.eg('i1'), 'key-p7e-is-01');
  perform test_helpers.logout();
  select * into i from public.invoices where id = test_helpers.eg('i1');
  perform test_helpers.eput('i1j', i.journal_id);
  perform test_helpers.assert(i.status = 'issued' and i.tax_total = 110000 and i.total = 1610000 and i.base_total = 1610000 and i.tax_status = 'determined',
    '4.1 the invoice total carries the output VAT and its tax status is "determined"');
  perform test_helpers.assert(test_helpers.jd7(i.journal_id, 'ACCOUNTS_RECEIVABLE') = 1610000 and test_helpers.jc7(i.journal_id, 'TAX_PAYABLE') = 110000
    and (select sum(credit) from public.journal_lines where journal_id = i.journal_id) = 1610000
    and (select sum(debit) from public.journal_lines where journal_id = i.journal_id) = 1610000,
    '4.2 Dr Accounts Receivable for the gross; Cr revenue for the price; Cr Tax Payable for the VAT');
  perform test_helpers.assert((select coalesce(sum(l.credit), 0) from public.journal_lines l join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
      where l.journal_id = i.journal_id and a.system_key is distinct from 'TAX_PAYABLE') = 1500000,
    '4.3 revenue is booked at the price, not at the VAT-inclusive amount');
  perform test_helpers.assert((select array_agg(base_amount::numeric order by line_no) from public.invoice_lines where invoice_id = i.id) = array[1000000, 500000]::numeric[],
    '4.4 line base amounts stay the pre-tax price (VAT is a separate ledger consequence)');
  select * into d from public.tax_determinations where source_type = 'invoice' and source_id = i.id and superseded_at is null;
  perform test_helpers.assert(d.tax_kind = 'vat_output' and d.tax_amount = 110000 and d.base_amount = 1000000 and d.journal_id = i.journal_id
    and d.status = 'auto_determined' and d.direction = 'payable' and d.tax_period = date_trunc('month', v_today - 10)::date
    and d.rules -> 0 ->> 'code' = 'PPN_STANDARD' and jsonb_array_length(d.trace) >= 2, '4.5 the determination is stored with its rule version, trace and period');
  perform test_helpers.assert((select count(*) from public.tax_ledger_entries where determination_id = d.id and amount = 110000 and entry_kind = 'accrual' and journal_id = i.journal_id) = 1,
    '4.6 one tax ledger entry accrues the liability');
  -- 4.7 replay returns the same invoice and posts nothing twice
  perform test_helpers.login(v_owner);
  perform test_helpers.assert(public.issue_invoice(test_helpers.eg('i1'), 'key-p7e-is-01') = test_helpers.eg('i1'), '4.7 issuing replays on the same key');
  perform test_helpers.logout();
  perform test_helpers.assert((select count(*) from public.tax_determinations where source_type = 'invoice' and source_id = i.id) = 1
    and (select count(*) from public.journal_entries where source_type = 'invoice' and source_id = i.id) = 1, '4.8 a replay does not duplicate the determination or the journal');

  -- 4.9 a document that needs review is not posted
  perform test_helpers.login(v_owner);
  v_id := public.create_invoice_draft(pt, 'key-p7e-i-11', test_helpers.eg('cust'), v_today - 10, v_today + 20, jsonb_build_array(
    jsonb_build_object('description', 'Course', 'unit_price', '1000000', 'category_id', test_helpers.eg('cat_rev'))));
  perform test_helpers.expect_msg(format('select public.issue_invoice(%L, ''key-p7e-is-02'')', v_id), 'CONFLICT', '4.9 an invoice whose VAT treatment is unknown cannot be issued');
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.invoices where id = v_id) = 'draft' and (select journal_id from public.invoices where id = v_id) is null
    and not exists (select 1 from public.tax_determinations where source_id = v_id), '4.10 nothing was posted or recorded');
  -- 4.11 confirming the line resolves it
  perform test_helpers.login('e0000000-0000-0000-0000-000000000003');
  perform public.tax_confirm_line('invoice', v_id, 1, 'vat_taxable');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform public.issue_invoice(v_id, 'key-p7e-is-03');
  perform test_helpers.logout();
  select * into i from public.invoices where id = v_id;
  select * into d from public.tax_determinations where source_type = 'invoice' and source_id = v_id and superseded_at is null;
  perform test_helpers.assert(i.status = 'issued' and i.tax_total = 110000 and d.status = 'owner_confirmed' and d.confirmed,
    '4.11 a confirmed line posts with the tax reviewer''s confirmation on record');
  perform test_helpers.eput('i11', v_id);

  -- 4.12 before PKP status: no VAT, but a determination of zero is on record
  perform test_helpers.login(v_owner);
  v_id := public.create_invoice_draft(pt, 'key-p7e-i-12', test_helpers.eg('cust'), v_today - 50, v_today + 20, jsonb_build_array(
    jsonb_build_object('description', 'Course', 'unit_price', '1000000', 'vat_treatment', 'vat_taxable')));
  perform public.issue_invoice(v_id, 'key-p7e-is-04');
  perform test_helpers.logout();
  select * into i from public.invoices where id = v_id;
  perform test_helpers.assert(i.tax_total = 0 and i.total = 1000000 and i.tax_status = 'determined'
    and (select count(*) from public.tax_determinations where source_id = v_id and tax_amount = 0) = 1
    and not exists (select 1 from public.tax_ledger_entries e join public.tax_determinations x on x.id = e.determination_id where x.source_id = v_id)
    and test_helpers.jc7(i.journal_id, 'TAX_PAYABLE') = 0, '4.12 a non-PKP sale carries no VAT: a zero determination and no ledger entry');
  perform test_helpers.eput('i12', v_id);

  -- 4.13 the invoice document view shows the VAT
  perform test_helpers.login(v_owner);
  perform test_helpers.assert((public.invoice_document(test_helpers.eg('i1')) -> 'invoice' ->> 'tax_total')::numeric = 110000
    or (public.invoice_document(test_helpers.eg('i1')) ->> 'tax_total')::numeric = 110000, '4.13 the invoice document carries the tax total');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 5. bills and expenses: input VAT and withholding are recognised on approval
do $$
declare
  pt uuid := test_helpers.entity('p7e_pt');
  v_owner uuid := 'e0000000-0000-0000-0000-000000000001';
  v_today date := test_helpers.today(pt);
  v_id uuid;
  b public.bills%rowtype;
  x public.expenses%rowtype;
  d public.tax_determinations%rowtype;
begin
  -- 5.1 b1: rent 10,000,000 + VAT 1,100,000, PPh 23 200,000
  perform test_helpers.login(v_owner);
  perform public.submit_bill(test_helpers.eg('b1'), 'key-p7e-sb-01');
  perform public.approve_bill(test_helpers.eg('b1'), 'key-p7e-ab-01');
  perform test_helpers.logout();
  select * into b from public.bills where id = test_helpers.eg('b1');
  perform test_helpers.assert(b.status = 'approved' and b.total = 11100000 and b.withheld_total = 200000 and b.base_total = 10900000 and b.tax_status = 'determined',
    '5.1 the bill keeps its gross total; the amount payable is net of withholding');
  perform test_helpers.assert(test_helpers.jc7(b.journal_id, 'ACCOUNTS_PAYABLE') = 10900000 and test_helpers.jc7(b.journal_id, 'TAX_PAYABLE') = 200000
    and test_helpers.jd7(b.journal_id, 'TAX_ASSET') = 1100000
    and (select sum(debit) from public.journal_lines where journal_id = b.journal_id) = 11100000
    and (select sum(credit) from public.journal_lines where journal_id = b.journal_id) = 11100000,
    '5.2 Dr expense + Dr Tax Asset (creditable VAT); Cr Accounts Payable net; Cr Tax Payable for the PPh 23 withheld');
  perform test_helpers.assert((select coalesce(sum(debit), 0) from public.journal_lines l join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
      where l.journal_id = b.journal_id and a.system_key is distinct from 'TAX_ASSET') = 10000000,
    '5.3 the expense is the price alone: the creditable VAT is an asset, not a cost');
  perform test_helpers.assert((select count(*) from public.tax_determinations where source_type = 'bill' and source_id = b.id and superseded_at is null) = 2
    and (select tax_amount from public.tax_determinations where source_id = b.id and tax_kind = 'wht_pph23') = 200000
    and (select tax_amount from public.tax_determinations where source_id = b.id and tax_kind = 'vat_input') = 1100000
    and (select direction from public.tax_determinations where source_id = b.id and tax_kind = 'vat_input') = 'asset',
    '5.4 two determinations: PPh 23 (payable) and input VAT (asset)');
  perform test_helpers.assert((select sum(amount) from public.tax_ledger_entries where journal_id = b.journal_id and tax_kind = 'wht_pph23') = 200000
    and (select sum(amount) from public.tax_ledger_entries where journal_id = b.journal_id and tax_kind = 'vat_input') = 1100000, '5.5 the tax ledger holds both amounts');
  -- 5.6 the payable is net of withholding everywhere
  perform test_helpers.assert((select outstanding from test_helpers.bpos(pt) where bill_id = b.id) = 10900000
    and (select total from test_helpers.bpos(pt) where bill_id = b.id) = 10900000, '5.6 the bill position shows the net payable');

  -- 5.7 paying the net amount settles the bill; paying the gross is refused
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format($q$select public.record_vendor_payment(%L, 'key-p7e-vp-00', %L, %L, %L, 11100000, %L::jsonb)$q$, pt, test_helpers.eg('vco'), test_helpers.eg('bca'), v_today,
    jsonb_build_array(jsonb_build_object('bill_id', b.id, 'amount', 11100000))::text), 'INVALID', '5.7 the payment cannot exceed the payable net of withholding');
  perform public.record_vendor_payment(pt, 'key-p7e-vp-01', test_helpers.eg('vco'), test_helpers.eg('bca'), v_today, 10900000,
    jsonb_build_array(jsonb_build_object('bill_id', b.id, 'amount', 10900000)));
  perform test_helpers.logout();
  perform test_helpers.assert((select settlement_status from test_helpers.bpos(pt) where bill_id = b.id) = 'paid'
    and (select outstanding from test_helpers.bpos(pt) where bill_id = b.id) = 0, '5.8 paying the net amount settles the bill');
  perform test_helpers.assert((select sub_ledger from test_helpers.apc(pt)) = (select ledger_purchases from test_helpers.apc(pt)), '5.9 the AP sub-ledger still equals the General Ledger');

  -- 5.10 an expense paid at once: cash out is net of withholding
  perform test_helpers.login(v_owner);
  v_id := public.create_expense_draft(pt, 'key-p7e-x-04', test_helpers.eg('bca'), v_today - 5, jsonb_build_array(
    jsonb_build_object('description', 'Rent', 'unit_price', '3000000', 'wht_object', 'wht_rent_movable')), test_helpers.eg('vco'));
  perform public.submit_expense(v_id, 'key-p7e-se-01');
  perform public.confirm_expense(v_id, 'key-p7e-ce-01');
  perform test_helpers.logout();
  select * into x from public.expenses where id = v_id;
  perform test_helpers.assert(x.status = 'confirmed' and x.total = 3000000 and x.withheld_total = 60000 and x.base_total = 2940000 and x.tax_status = 'determined',
    '5.10 the expense is recognised with its withholding');
  perform test_helpers.assert(test_helpers.jc7(x.journal_id, 'TAX_PAYABLE') = 60000 and (select sum(credit) from public.journal_lines where journal_id = x.journal_id) = 3000000
    and (select sum(debit) from public.journal_lines where journal_id = x.journal_id) = 3000000, '5.11 Cr Tax Payable 60,000; the rest leaves the account');
  perform test_helpers.assert((select coalesce(sum(amount), 0) from public.money_movements where source_type = 'expense' and source_id = x.id and direction = 'out') = 2940000,
    '5.12 the money movement out is what actually left the account: the total net of the withholding');
  perform test_helpers.eput('x4', v_id);

  -- 5.13 a plain expense (wht_none, free-text payee) has a determination of zero and needs no tax facts
  perform test_helpers.login(v_owner);
  perform public.submit_expense(test_helpers.eg('x3'), 'key-p7e-se-02');
  perform public.confirm_expense(test_helpers.eg('x3'), 'key-p7e-ce-02');
  perform test_helpers.logout();
  select * into x from public.expenses where id = test_helpers.eg('x3');
  perform test_helpers.assert(x.status = 'confirmed' and x.withheld_total = 0 and x.base_total = 30000 and x.tax_status = 'determined'
    and test_helpers.jc7(x.journal_id, 'TAX_PAYABLE') = 0, '5.13 no withholding: the expense posts as before with a zero determination');

  -- 5.14 needs-review stops approval
  perform test_helpers.login(v_owner);
  v_id := public.create_bill_draft(pt, 'key-p7e-b-20', test_helpers.eg('vnof'), v_today - 5, v_today + 20,
    jsonb_build_array(jsonb_build_object('description', 'Service', 'unit_price', '1000000', 'wht_object', 'wht_service_technical')));
  perform public.submit_bill(v_id, 'key-p7e-sb-02');
  perform test_helpers.expect_msg(format($q$select public.approve_bill(%L, 'key-p7e-ab-02')$q$, v_id), 'CONFLICT', '5.14 a bill whose withholding needs review cannot be approved');
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.bills where id = v_id) = 'submitted' and not exists (select 1 from public.tax_determinations where source_id = v_id), '5.15 it stays submitted; nothing recorded');
  perform test_helpers.eput('b20', v_id);

  -- 5.16 stated VAT on a bill before the engine start date is refused, not silently recognised
  perform test_helpers.login(v_owner);
  v_id := public.create_bill_draft(pt, 'key-p7e-b-21', test_helpers.eg('vco'), v_today - 70, v_today + 20,
    jsonb_build_array(jsonb_build_object('description', 'Old purchase', 'unit_price', '1000000', 'tax_amount', '110000', 'wht_object', 'wht_none')));
  perform public.submit_bill(v_id, 'key-p7e-sb-03');
  perform test_helpers.expect_msg(format($q$select public.approve_bill(%L, 'key-p7e-ab-03')$q$, v_id), 'CONFLICT', '5.16 tax before the engine start date is not recognised');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 6. overrides, confirmation, reversal and correction
do $$
declare
  pt uuid := test_helpers.entity('p7e_pt');
  v_owner uuid := 'e0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'e0000000-0000-0000-0000-000000000002';
  v_taxer uuid := 'e0000000-0000-0000-0000-000000000003';
  v_today date := test_helpers.today(pt);
  v_id uuid;
  v_ov uuid;
  v_new uuid;
  b public.bills%rowtype;
  d public.tax_determinations%rowtype;
  n_before integer;
  v_payable_before numeric;
begin
  -- 6.1 an owner override with a reason and evidence: a certificate of exemption is on file, so nothing is withheld
  perform test_helpers.login(v_owner);
  v_id := public.create_bill_draft(pt, 'key-p7e-b-30', test_helpers.eg('vco'), v_today - 8, v_today + 20,
    jsonb_build_array(jsonb_build_object('description', 'Rent', 'unit_price', '2000000', 'wht_object', 'wht_rent_movable')));
  perform test_helpers.eput('b30', v_id);
  perform public.submit_bill(v_id, 'key-p7e-sb-30');
  perform test_helpers.logout();

  perform test_helpers.login(v_taxer);
  perform test_helpers.expect_msg(format($q$select public.tax_override_set('bill', %L, 'key-p7e-ov-00', 'wht_pph23', '0', 'Certificate of exemption on file', 'SKB 123')$q$, v_id), 'FORBIDDEN', '6.1 the tax role cannot override');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format($q$select public.tax_override_set('bill', %L, 'key-p7e-ov-00', 'wht_pph23', '0', 'Certificate of exemption on file', 'SKB 123')$q$, v_id), 'FORBIDDEN', '6.2 a finance admin cannot override');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner, 'aal2', interval '10 hours');
  perform test_helpers.expect_msg(format($q$select public.tax_override_set('bill', %L, 'key-p7e-ov-00', 'wht_pph23', '0', 'Certificate of exemption on file', 'SKB 123')$q$, v_id), 'STEP_UP_REQUIRED', '6.3 an override needs a recent step-up');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format($q$select public.tax_override_set('bill', %L, 'key-p7e-ov-00', 'wht_pph23', '0', 'short', 'x')$q$, v_id), 'INVALID', '6.4 an override needs a reason and an evidence note');
  perform test_helpers.expect_msg(format($q$select public.tax_override_set('bill', %L, 'key-p7e-ov-00', 'wht_pph23', '2000001', 'Certificate of exemption on file', 'SKB 123')$q$, v_id), 'INVALID', '6.5 an override cannot exceed the base');
  perform test_helpers.expect_msg(format($q$select public.tax_override_set('bill', %L, 'key-p7e-ov-00', 'vat_input', '0', 'Certificate of exemption on file', 'SKB 123')$q$, v_id), 'CONFLICT', '6.6 there is no input-VAT result to override on this bill');
  v_ov := public.tax_override_set('bill', v_id, 'key-p7e-ov-01', 'wht_pph23', '0', 'Certificate of exemption on file', 'SKB 123');
  perform test_helpers.assert(public.tax_override_set('bill', v_id, 'key-p7e-ov-01', 'wht_pph23', '0', 'Certificate of exemption on file', 'SKB 123') = v_ov, '6.7 an override replays on the same key');
  perform test_helpers.assert(public.tax_preview_document('bill', v_id) ->> 'status' = 'overridden' and (public.tax_preview_document('bill', v_id) ->> 'withheld_total')::numeric = 0,
    '6.8 the preview shows the overridden result');
  perform public.approve_bill(v_id, 'key-p7e-ab-30');
  perform test_helpers.logout();
  select * into d from public.tax_determinations where source_type = 'bill' and source_id = v_id and tax_kind = 'wht_pph23';
  perform test_helpers.assert(d.status = 'overridden' and d.tax_amount = 0 and d.computed_tax_amount = 40000 and d.override_id = v_ov,
    '6.9 the determination keeps what the engine computed next to the override');
  perform test_helpers.assert((select determination_id from public.tax_overrides where id = v_ov) = d.id and (select withheld_total from public.bills where id = v_id) = 0
    and (select base_total from public.bills where id = v_id) = 2000000, '6.10 the override is tied to the determination; nothing is withheld');
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format($q$select public.tax_override_withdraw(%L, 'Changed my mind')$q$, v_ov), 'CONFLICT', '6.11 a used override cannot be withdrawn');
  perform test_helpers.expect_msg(format($q$select public.tax_override_set('bill', %L, 'key-p7e-ov-02', 'wht_pph23', '0', 'Certificate of exemption on file', 'SKB 123')$q$, v_id), 'CONFLICT', '6.12 an approved bill is corrected, not overridden');
  perform test_helpers.logout();

  -- 6.13 an override that is withdrawn before use no longer applies; a newer one replaces the older
  perform test_helpers.login(v_owner);
  v_id := public.create_bill_draft(pt, 'key-p7e-b-31', test_helpers.eg('vco'), v_today - 8, v_today + 20,
    jsonb_build_array(jsonb_build_object('description', 'Rent', 'unit_price', '2000000', 'wht_object', 'wht_rent_movable')));
  v_ov := public.tax_override_set('bill', v_id, 'key-p7e-ov-03', 'wht_pph23', '10000', 'Partly exempt per contract', 'Contract clause 4');
  perform test_helpers.assert((public.tax_preview_document('bill', v_id) ->> 'withheld_total')::numeric = 10000, '6.13 the override amount is used');
  perform public.tax_override_withdraw(v_ov, 'Wrong document');
  perform test_helpers.assert((public.tax_preview_document('bill', v_id) ->> 'withheld_total')::numeric = 40000 and public.tax_preview_document('bill', v_id) ->> 'status' = 'auto_determined',
    '6.14 once withdrawn, the engine result applies again');
  perform test_helpers.logout();

  -- 6.15 void an issued invoice: the determination is superseded and the tax ledger reverses
  select * into d from public.tax_determinations where source_type = 'invoice' and source_id = test_helpers.eg('i11') and superseded_at is null;
  select coalesce(sum(amount), 0) into v_payable_before from public.tax_ledger_entries where tax_kind = 'vat_output' and entity_id = pt;
  perform test_helpers.login(v_owner);
  perform public.void_invoice(test_helpers.eg('i11'), 'key-p7e-vd-01', 'Sold to the wrong party');
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.tax_determinations where id = d.id) = 'superseded'
    and (select amount from public.tax_ledger_entries where determination_id = d.id and entry_kind = 'reversal') = -110000
    and (select entry_date from public.tax_ledger_entries where determination_id = d.id and entry_kind = 'reversal') = v_today
    and (select journal_id from public.tax_ledger_entries where determination_id = d.id and entry_kind = 'reversal') <> d.journal_id,
    '6.15 voiding supersedes the determination and reverses its ledger entry in a reversal journal');
  perform test_helpers.assert((select coalesce(sum(amount), 0) from public.tax_ledger_entries where tax_kind = 'vat_output' and entity_id = pt) = v_payable_before - 110000
    and not exists (select 1 from public.tax_determinations where source_id = test_helpers.eg('i11') and superseded_at is null), '6.16 the tax ledger nets to zero for the voided invoice');

  -- 6.17 correct an issued invoice: reversed, then a new draft with the same lines is issued again with fresh tax
  perform test_helpers.login(v_owner);
  v_id := public.create_invoice_draft(pt, 'key-p7e-i-13', test_helpers.eg('cust'), v_today - 3, v_today + 20, jsonb_build_array(
    jsonb_build_object('description', 'Course', 'unit_price', '2000000', 'vat_treatment', 'vat_taxable')));
  perform public.issue_invoice(v_id, 'key-p7e-is-13');
  v_new := public.correct_invoice(v_id, 'key-p7e-cr-13', 'Wrong price on the invoice');
  perform test_helpers.assert(v_new is not null and v_new <> v_id and (select status from public.invoices where id = v_new) = 'draft', '6.17 correction returns a new draft');
  perform test_helpers.assert(test_helpers.eput('i13n', v_new) = v_new, '6.18 (stored)');
  perform public.update_invoice_draft(v_new, jsonb_build_object('lines', jsonb_build_array(
    jsonb_build_object('description', 'Course', 'unit_price', '1500000', 'vat_treatment', 'vat_taxable'))));
  perform public.issue_invoice(v_new, 'key-p7e-is-14');
  perform test_helpers.logout();
  perform test_helpers.assert((select coalesce(sum(amount), 0) from public.tax_ledger_entries e join public.tax_determinations x on x.id = e.determination_id
      where x.source_id in (v_id, v_new)) = 165000, '6.19 the corrected invoice leaves only its own VAT: 12% x 11/12 x 1,500,000 = 165,000');
  perform test_helpers.assert((select count(*) from public.tax_determinations where source_id = v_id and status = 'superseded') = 1
    and (select count(*) from public.tax_determinations where source_id = v_new and superseded_at is null) = 1, '6.20 the original determination is superseded; the new one is live');
  perform test_helpers.eput('i14', v_new);

  -- 6.21 void a bill with input VAT and withholding: both reverse
  perform test_helpers.login(v_owner);
  v_id := public.create_bill_draft(pt, 'key-p7e-b-32', test_helpers.eg('vco'), v_today - 6, v_today + 20,
    jsonb_build_array(jsonb_build_object('description', 'Rent', 'unit_price', '5000000', 'tax_amount', '550000', 'wht_object', 'wht_rent_movable', 'vat_invoice_ref', '010.000-26.00000032')));
  perform public.submit_bill(v_id, 'key-p7e-sb-32');
  perform public.approve_bill(v_id, 'key-p7e-ab-32');
  select * into b from public.bills where id = v_id;
  perform test_helpers.assert(b.withheld_total = 100000 and b.base_total = 5450000, '6.21 (setup) bill approved with 100,000 withheld');
  perform public.void_bill(v_id, 'key-p7e-vb-32', 'Vendor cancelled the service');
  perform test_helpers.logout();
  perform test_helpers.assert((select sum(amount) from public.tax_ledger_entries e join public.tax_determinations x on x.id = e.determination_id where x.source_id = v_id) = 0
    and (select count(*) from public.tax_determinations where source_id = v_id and status = 'superseded') = 2
    and (select count(*) from public.tax_ledger_entries e join public.tax_determinations x on x.id = e.determination_id where x.source_id = v_id and entry_kind = 'reversal') = 2,
    '6.22 voiding reverses both the withholding and the creditable VAT');

  -- 6.23 reverse a confirmed expense
  perform test_helpers.login(v_owner);
  perform public.reverse_expense(test_helpers.eg('x4'), 'key-p7e-rx-04', 'Booked twice by mistake');
  perform test_helpers.logout();
  perform test_helpers.assert((select sum(amount) from public.tax_ledger_entries e join public.tax_determinations x on x.id = e.determination_id where x.source_id = test_helpers.eg('x4')) = 0
    and (select status from public.tax_determinations where source_id = test_helpers.eg('x4') and tax_kind = 'wht_pph23') = 'superseded', '6.23 reversing an expense reverses its withholding');

  -- 6.24 the tax ledger agrees with the General Ledger accounts, live documents only
  perform test_helpers.assert(-test_helpers.bal7(pt, 'TAX_PAYABLE') = (select coalesce(sum(amount), 0) from public.tax_ledger_entries where entity_id = pt and direction = 'payable')
    and test_helpers.bal7(pt, 'TAX_ASSET') = (select coalesce(sum(amount), 0) from public.tax_ledger_entries where entity_id = pt and direction = 'asset'),
    '6.24 the tax ledger equals Tax Payable and Tax Asset in the General Ledger');
end
$$;

-- ================================================================ 7. tax payments, filings, evidence and reconciliation
do $$
declare
  pc uuid;
  v_owner uuid := 'e0000000-0000-0000-0000-000000000001';
  v_taxer uuid := 'e0000000-0000-0000-0000-000000000003';
  v_admin uuid := 'e0000000-0000-0000-0000-000000000002';
  v_viewer uuid := 'e0000000-0000-0000-0000-000000000004';
  v_staff uuid := 'e0000000-0000-0000-0000-000000000005';
  v_today date;
  v_cust uuid;
  v_vend uuid;
  v_id uuid;
  v_bank uuid;
  v_usd uuid;
  v_period date;
  v_p1 uuid;
  v_p2 uuid;
  v_j uuid;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p7e_c', 'P7E PAYMENTS (synthetic)') returning id into pc;
  perform app_private.provision_default_coa(pc);
  perform test_helpers.mk_member(pc, v_owner, 'owner');
  perform test_helpers.mk_member(pc, v_taxer, 'tax');
  perform test_helpers.mk_member(pc, v_admin, 'finance_admin');
  perform test_helpers.mk_member(pc, v_viewer, 'viewer_auditor');
  perform test_helpers.mk_member(pc, v_staff, 'finance_staff');
  v_today := test_helpers.today(pc);
  v_period := date_trunc('month', v_today)::date;
  perform test_helpers.eput('pc', pc);

  perform test_helpers.login(v_owner);
  v_cust := public.create_contact(pc, 'key-p7c-ct-01', 'customer', 'C Customer');
  v_vend := public.create_contact(pc, 'key-p7c-ct-02', 'vendor', 'C Vendor', null, null, '01.234.567.8-901.000', 'PT C Vendor');
  v_bank := public.create_financial_account(pc, 'key-p7c-fa-01', 'bank', 'BCA C', 'IDR', test_helpers.acct(pc, 'BANK_OPERATING'), 'BCA', 'ACC-C-1', 'PT C');
  v_usd := public.create_financial_account(pc, 'key-p7c-fa-02', 'bank', 'USD C', 'USD');
  perform test_helpers.eput('c_bank', v_bank);
  perform public.tax_record_contact_facts(v_vend, 'key-p7c-cf-01', v_today - 90, 'company', 'resident', 'has_npwp', 'non_pkp', 'none', 'synthetic');
  perform public.tax_record_entity_profile(pc, 'key-p7c-f-01', v_today - 90, 'company', 'resident', 'general', 'none', 'none', 'pkp', 'yes', null, 'synthetic');
  perform public.tax_engine_activate(pc, 'key-p7c-a-01', v_today - 5);
  -- three sales (VAT 110,000 each), one rent bill with input VAT, one rent bill without, one small service
  for i in 1 .. 3 loop
    v_id := public.create_invoice_draft(pc, 'key-p7c-i-0' || i, v_cust, v_today, v_today + 20, jsonb_build_array(
      jsonb_build_object('description', 'Course', 'unit_price', '1000000', 'vat_treatment', 'vat_taxable')));
    perform public.issue_invoice(v_id, 'key-p7c-is-0' || i);
  end loop;
  v_id := public.create_bill_draft(pc, 'key-p7c-b-01', v_vend, v_today, v_today + 20, jsonb_build_array(
    jsonb_build_object('description', 'Rent A', 'unit_price', '10000000', 'tax_amount', '1100000', 'wht_object', 'wht_rent_movable', 'vat_invoice_ref', '010.000-26.00000101')));
  perform public.submit_bill(v_id, 'key-p7c-sb-01');
  perform public.approve_bill(v_id, 'key-p7c-ab-01');
  v_id := public.create_bill_draft(pc, 'key-p7c-b-02', v_vend, v_today, v_today + 20, jsonb_build_array(
    jsonb_build_object('description', 'Rent B', 'unit_price', '5000000', 'wht_object', 'wht_rent_movable')));
  perform public.submit_bill(v_id, 'key-p7c-sb-02');
  perform public.approve_bill(v_id, 'key-p7c-ab-02');
  perform test_helpers.logout();

  -- 7.1 the position of the period before any payment
  perform test_helpers.login(v_viewer);
  perform test_helpers.assert(public.tax_period_position(pc, 'wht_pph23', v_period) ->> 'accrued_payable' = '300000.0000'
    and public.tax_period_position(pc, 'wht_pph23', v_period) ->> 'outstanding_payable' = '300000.0000', '7.1 PPh 23 for the period: 300,000 accrued, all outstanding');
  perform test_helpers.assert(public.tax_period_position(pc, 'vat', v_period) ->> 'accrued_payable' = '330000.0000'
    and public.tax_period_position(pc, 'vat', v_period) ->> 'accrued_asset' = '1100000.0000'
    and public.tax_period_position(pc, 'vat', v_period) ->> 'asset_available' = '1100000.0000', '7.2 VAT: 330,000 output and 1,100,000 input');
  perform test_helpers.logout();

  -- 7.3 who may record a payment
  foreach v_id in array array[v_viewer, v_staff, v_admin] loop
    perform test_helpers.login(v_id);
    perform test_helpers.expect_msg(format($q$select public.tax_record_payment(%L, 'key-p7c-tp-00', 'wht_pph23', %L, %L, %L, '100000')$q$, pc, v_period, v_today, v_bank),
      'FORBIDDEN', '7.3 only tax.mark_filed records a payment');
    perform test_helpers.logout();
  end loop;

  -- 7.4 part payment from the bank
  perform test_helpers.login(v_taxer);
  v_p1 := public.tax_record_payment(pc, 'key-p7c-tp-01', 'wht_pph23', v_period, v_today, v_bank, '100000', '0', '0', 'NTPN-0001', 'part payment');
  perform test_helpers.assert(public.tax_record_payment(pc, 'key-p7c-tp-01', 'wht_pph23', v_period, v_today, v_bank, '100000', '0', '0', 'NTPN-0001', 'part payment') = v_p1, '7.4 a payment replays on the same key');
  perform test_helpers.logout();
  select journal_id into v_j from public.tax_payments where id = v_p1;
  perform test_helpers.assert(test_helpers.jd7(v_j, 'TAX_PAYABLE') = 100000
    and (select sum(credit) from public.journal_lines where journal_id = v_j) = 100000
    and (select payment_number from public.tax_payments where id = v_p1) like 'TAXPAY%'
    and (select cash_amount from public.tax_payments where id = v_p1) = 100000, '7.5 Dr Tax Payable, Cr the bank; no expense is created');
  perform test_helpers.assert((select coalesce(sum(amount), 0) from public.money_movements where source_type = 'tax_payment' and source_id = v_p1 and direction = 'out') = 100000
    and (select bool_and(ledger_balance = movement_base_balance) from test_helpers.mc(pc)), '7.6 one money movement out; the money control still agrees with the ledger');
  perform test_helpers.login(v_taxer);
  perform test_helpers.assert(public.tax_period_position(pc, 'wht_pph23', v_period) ->> 'outstanding_payable' = '200000.0000', '7.7 200,000 remains');
  perform test_helpers.expect_msg(format($q$select public.tax_record_payment(%L, 'key-p7c-tp-02', 'wht_pph23', %L, %L, %L, '250000')$q$, pc, v_period, v_today, v_bank),
    'INVALID: wht_pph23 for', '7.8 a payment cannot exceed what is outstanding');
  perform test_helpers.expect_msg(format($q$select public.tax_record_payment(%L, 'key-p7c-tp-03', 'wht_pph23', %L, %L, %L, '100000', '10000')$q$, pc, v_period, v_today, v_bank),
    'INVALID: only VAT can be settled', '7.9 only VAT can be offset against input VAT');
  perform test_helpers.expect_msg(format($q$select public.tax_record_payment(%L, 'key-p7c-tp-04', 'wht_pph23', %L, %L, %L, '100000')$q$, pc, v_period, v_today + 1, v_bank),
    'INVALID', '7.10 a payment cannot be dated in the future');
  perform test_helpers.expect_msg(format($q$select public.tax_record_payment(%L, 'key-p7c-tp-05', 'wht_pph23', %L, %L, %L, '100000')$q$, pc, v_period, v_period - 1, v_bank),
    'INVALID', '7.11 a payment cannot be dated before its period');
  perform test_helpers.expect_msg(format($q$select public.tax_record_payment(%L, 'key-p7c-tp-06', 'wht_pph23', %L, %L, %L, '100000')$q$, pc, v_period, v_today, v_usd),
    'INVALID: tax is paid from an account in the Entity', '7.12 tax is paid from a base-currency account');
  perform test_helpers.expect_msg(format($q$select public.tax_record_payment(%L, 'key-p7c-tp-07', 'wht_pph23', %L, %L, null, '100000')$q$, pc, v_period, v_today),
    'INVALID', '7.13 a cash payment needs an account');
  perform test_helpers.expect_msg(format($q$select public.tax_record_payment(%L, 'key-p7c-tp-08', 'wht_pph23', %L, %L, %L, '0')$q$, pc, v_period, v_today, v_bank),
    'INVALID', '7.14 the amount must be positive');
  perform test_helpers.expect_msg(format($q$select public.tax_record_payment(%L, 'key-p7c-tp-09', 'wht_pph23', %L, %L, %L, '100000', '0', '5000')$q$, pc, v_period, v_today, v_bank),
    'INVALID', '7.15 a penalty needs an explanatory note');
  perform test_helpers.expect_msg(format($q$select public.tax_record_payment(%L, 'key-p7c-tp-10', 'wht_pph23', %L, %L, %L, '100000')$q$, pc, (v_period - interval '1 month')::date, v_today, v_bank),
    'INVALID', '7.16 a period with nothing accrued has nothing to pay');
  v_p2 := public.tax_record_payment(pc, 'key-p7c-tp-11', 'wht_pph23', v_period, v_today, v_bank, '200000', '0', '0', 'NTPN-0002');
  perform test_helpers.assert(public.tax_period_position(pc, 'wht_pph23', v_period) ->> 'outstanding_payable' = '0.0000', '7.17 the period is settled');
  perform test_helpers.expect_msg(format($q$select public.tax_record_payment(%L, 'key-p7c-tp-12', 'wht_pph23', %L, %L, %L, '1')$q$, pc, v_period, v_today, v_bank),
    'INVALID', '7.18 a settled period takes no more payments');

  -- 7.19 VAT: cash net of input VAT, then a payment fully offset (no account, no movement)
  v_id := public.tax_record_payment(pc, 'key-p7c-tp-13', 'vat', v_period, v_today, v_bank, '220000', '100000', '0', 'NTPN-0003');
  perform test_helpers.expect_msg(format($q$select public.tax_record_payment(%L, 'key-p7c-tp-14', 'vat', %L, %L, %L, '110000', '110001')$q$, pc, v_period, v_today, v_bank),
    'INVALID: the input VAT offset cannot exceed', '7.20 the offset cannot exceed the VAT paid against');
  perform test_helpers.expect_msg(format($q$select public.tax_record_payment(%L, 'key-p7c-tp-14', 'vat', %L, %L, %L, '110000', '110000')$q$, pc, v_period, v_today, v_bank),
    'INVALID: no account is needed', '7.21 a fully offset payment takes no account');
  perform public.tax_record_payment(pc, 'key-p7c-tp-15', 'vat', v_period, v_today, null, '110000', '110000', '0', 'offset only');
  perform test_helpers.logout();
  select journal_id into v_j from public.tax_payments where id = v_id;
  perform test_helpers.assert(test_helpers.jd7(v_j, 'TAX_PAYABLE') = 220000 and test_helpers.jc7(v_j, 'TAX_ASSET') = 100000
    and test_helpers.jc7(v_j, 'BANK_OPERATING') = 120000, '7.22 Dr Tax Payable 220,000; Cr Tax Asset 100,000; Cr bank 120,000');
  perform test_helpers.assert((select cash_amount from public.tax_payments where payment_number is not null and reference = 'offset only') = 0
    and not exists (select 1 from public.money_movements m join public.tax_payments p on p.id = m.source_id where p.reference = 'offset only'), '7.23 a fully offset payment moves no money');
  perform test_helpers.login(v_taxer);
  perform test_helpers.assert(public.tax_period_position(pc, 'vat', v_period) ->> 'outstanding_payable' = '0.0000'
    and public.tax_period_position(pc, 'vat', v_period) ->> 'asset_available' = '890000.0000', '7.24 VAT settled; 890,000 of input VAT carries forward');
  perform test_helpers.logout();

  -- 7.25 a late-payment penalty is its own expense; the recognised liability creates none
  perform test_helpers.login(v_owner);
  v_id := public.create_bill_draft(pc, 'key-p7c-b-03', v_vend, v_today, v_today + 20, jsonb_build_array(
    jsonb_build_object('description', 'Rent C', 'unit_price', '2000000', 'wht_object', 'wht_rent_movable')));
  perform public.submit_bill(v_id, 'key-p7c-sb-03');
  perform public.approve_bill(v_id, 'key-p7c-ab-03');
  v_id := public.tax_record_payment(pc, 'key-p7c-tp-16', 'wht_pph23', v_period, v_today, v_bank, '40000', '0', '5000', 'NTPN-0004', 'STP 123 (synthetic)');
  perform test_helpers.logout();
  select journal_id into v_j from public.tax_payments where id = v_id;
  perform test_helpers.assert(test_helpers.jd7(v_j, 'TAX_PAYABLE') = 40000 and test_helpers.jd7(v_j, 'TAX_PENALTY_EXPENSE') = 5000
    and (select cash_amount from public.tax_payments where id = v_id) = 45000, '7.25 Dr Tax Payable 40,000 and Dr Penalty 5,000; Cr bank 45,000');
  perform test_helpers.eput('c_pen', v_id);

  -- 7.26 reversing a payment restores the liability and the cash
  perform test_helpers.login(v_taxer);
  perform test_helpers.expect_msg(format($q$select public.tax_reverse_payment(%L, 'key-p7c-rp-00', %L, 'no')$q$, v_p1, v_today), 'INVALID', '7.26 a reversal needs a reason');
  perform test_helpers.expect_msg(format($q$select public.tax_reverse_payment(%L, 'key-p7c-rp-00b', %L, 'Dated before the payment')$q$, v_p1, v_today - 1),
    'INVALID: a reversal cannot be dated before the payment', '7.26b a reversal cannot be dated before the payment');
  perform public.tax_reverse_payment(v_p1, 'key-p7c-rp-01', v_today, 'Paid from the wrong account');
  perform test_helpers.expect_msg(format($q$select public.tax_reverse_payment(%L, 'key-p7c-rp-02', %L, 'Reversing twice over')$q$, v_p1, v_today), 'CONFLICT', '7.27 a reversed payment cannot be reversed again');
  perform test_helpers.assert(public.tax_period_position(pc, 'wht_pph23', v_period) ->> 'outstanding_payable' = '100000.0000', '7.28 the reversed 100,000 is outstanding again');
  perform test_helpers.logout();
  perform test_helpers.assert((select bool_and(ledger_balance = movement_base_balance) from test_helpers.mc(pc))
    and (select status from public.tax_payments where id = v_p1) = 'reversed', '7.29 the money control agrees after the reversal');
  perform test_helpers.login(v_taxer);
  v_p1 := public.tax_record_payment(pc, 'key-p7c-tp-17', 'wht_pph23', v_period, v_today, v_bank, '100000', '0', '0', 'NTPN-0005');
  perform test_helpers.logout();

  -- 7.30 the tax control: the tax sub-ledger equals the workflow's share of Tax Payable and Tax Asset
  perform test_helpers.assert((select bool_and(sub_ledger = ledger_workflow and ledger_other = 0) from test_helpers.tctl(pc)), '7.30 the tax control agrees with the General Ledger');
  perform test_helpers.assert((select sub_ledger from test_helpers.tctl(pc) where account_key = 'TAX_PAYABLE') = 0
    and (select sub_ledger from test_helpers.tctl(pc) where account_key = 'TAX_ASSET') = 890000, '7.31 nothing is left to pay; 890,000 of input VAT is a credit');
  perform test_helpers.login(v_viewer);
  perform test_helpers.assert((select count(*) from public.tax_control_report(pc)) = 2, '7.32 the control report is readable by a tax viewer');
  perform test_helpers.logout();
  perform test_helpers.eput('c_period', pc);
end
$$;

-- ================================================================ 8. filings, evidence and reconciliation
do $$
declare
  pc uuid := test_helpers.eg('pc');
  v_owner uuid := 'e0000000-0000-0000-0000-000000000001';
  v_taxer uuid := 'e0000000-0000-0000-0000-000000000003';
  v_viewer uuid := 'e0000000-0000-0000-0000-000000000004';
  v_today date := test_helpers.today(pc);
  v_period date := date_trunc('month', test_helpers.today(pc))::date;
  v_f1 uuid;
  v_f2 uuid;
  v_f3 uuid;
  v_r1 uuid;
  v_r2 uuid;
  v_doc uuid;
  v_link uuid;
  v_pay uuid;
  pos jsonb;
begin
  -- 8.1 the PPh 23 return of the period as filed
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format($q$select public.tax_record_filing(%L, 'key-p7c-fl-00', 'wht_pph23', %L, %L, 'BPE-0001', '17000000', '340000')$q$, pc, v_period, v_today),
    'FORBIDDEN', '8.1 a viewer cannot record a filing');
  perform test_helpers.logout();
  perform test_helpers.login(v_taxer);
  perform test_helpers.expect_msg(format($q$select public.tax_record_filing(%L, 'key-p7c-fl-00', 'wht_pph23', %L, %L, 'BPE-0001', '17000000', '340000')$q$, pc, v_period, v_period - 1),
    'INVALID', '8.2 a filing cannot be dated before its period');
  perform test_helpers.expect_msg(format($q$select public.tax_record_filing(%L, 'key-p7c-fl-00', 'wht_pph23', %L, %L, 'BPE-0001', '17000000', '340000')$q$, pc, v_period, v_today + 1),
    'INVALID', '8.3 a filing cannot be dated in the future');
  perform test_helpers.expect_msg(format($q$select public.tax_record_filing(%L, 'key-p7c-fl-00', 'wht_pph23', %L, %L, 'B', '17000000', '340000')$q$, pc, v_period, v_today),
    'INVALID', '8.4 a filing needs its reference');
  perform test_helpers.expect_msg(format($q$select public.tax_record_filing(%L, 'key-p7c-fl-00', 'wht_pph23', %L, %L, 'BPE-0001', '17000000', '340000', '5')$q$, pc, v_period, v_today),
    'INVALID', '8.5 only a VAT return has a credit');
  perform test_helpers.expect_msg(format($q$select public.tax_record_filing(%L, 'key-p7c-fl-00', 'wht_pph23', %L, %L, 'BPE-0001', '17000000', '340000', '0', true, 'Amending nothing')$q$, pc, v_period, v_today),
    'INVALID', '8.6 there is nothing to amend before the first filing');
  v_f1 := public.tax_record_filing(pc, 'key-p7c-fl-01', 'wht_pph23', v_period, v_today, 'BPE-0001', '17000000', '340000');
  perform test_helpers.assert(public.tax_record_filing(pc, 'key-p7c-fl-01', 'wht_pph23', v_period, v_today, 'BPE-0001', '17000000', '340000') = v_f1, '8.7 a filing replays on the same key');
  perform test_helpers.expect_msg(format($q$select public.tax_record_filing(%L, 'key-p7c-fl-02', 'wht_pph23', %L, %L, 'BPE-0002', '17000000', '340000')$q$, pc, v_period, v_today),
    'CONFLICT', '8.8 a filed period takes an amendment, not a second original');
  perform test_helpers.logout();

  -- 8.9 reconcile the period: ledger, payments and filing agree
  perform test_helpers.login(v_taxer);
  v_r1 := public.tax_reconcile_period(pc, 'key-p7c-rc-01', 'wht_pph23', v_period);
  perform test_helpers.assert(public.tax_reconcile_period(pc, 'key-p7c-rc-01', 'wht_pph23', v_period) = v_r1, '8.9 a reconciliation replays on the same key');
  pos := public.tax_period_position(pc, 'wht_pph23', v_period);
  perform test_helpers.assert(pos -> 'reconciliation' ->> 'outcome' = 'reconciled' and (pos -> 'reconciliation' ->> 'stale')::boolean = false
    and pos -> 'differences' = '[]'::jsonb and pos ->> 'filed_reference' = 'BPE-0001', '8.10 the period is reconciled and not stale');

  -- 8.11 VAT with no filing: differences need a note and stay visible
  perform test_helpers.expect_msg(format($q$select public.tax_reconcile_period(%L, 'key-p7c-rc-02', 'vat', %L)$q$, pc, v_period), 'INVALID', '8.11 differences need an explanation');
  v_r2 := public.tax_reconcile_period(pc, 'key-p7c-rc-03', 'vat', v_period, 'The VAT return is being prepared');
  perform test_helpers.assert((select outcome from public.tax_reconciliations where id = v_r2) = 'differences_noted'
    and (select differences -> 0 ->> 'code' from public.tax_reconciliations where id = v_r2) = 'filing_missing', '8.12 the difference is recorded');
  perform public.tax_record_filing(pc, 'key-p7c-fl-03', 'vat', v_period, v_today, 'BPE-VAT-1', '3000000', '330000', '1100000');
  pos := public.tax_period_position(pc, 'vat', v_period);
  perform test_helpers.assert((pos -> 'reconciliation' ->> 'stale')::boolean, '8.13 a filing recorded after the reconciliation makes it stale');
  v_r2 := public.tax_reconcile_period(pc, 'key-p7c-rc-04', 'vat', v_period);
  perform test_helpers.assert((select outcome from public.tax_reconciliations where id = v_r2) = 'reconciled'
    and (select count(*) from public.tax_reconciliations where entity_id = pc and tax_type = 'vat' and tax_period = v_period and status = 'current') = 1
    and (select count(*) from public.tax_reconciliations where entity_id = pc and tax_type = 'vat' and tax_period = v_period and status = 'superseded') = 1,
    '8.14 the newer reconciliation is current; the earlier one stays as history');
  perform test_helpers.expect_msg(format($q$select public.tax_reconcile_period(%L, 'key-p7c-rc-05', 'wht_pph23', %L)$q$, pc, v_period + interval '2 months'),
    'INVALID', '8.15 a period that has not started cannot be reconciled');
  perform test_helpers.expect_msg(format($q$select public.tax_reconcile_period(%L, 'key-p7c-rc-05', 'wht_pph23', %L, 'A note that would explain differences')$q$, pc, (v_period - interval '3 months')::date),
    'INVALID: there is nothing to reconcile', '8.16 a period with no activity has nothing to reconcile');

  -- 8.17 an amendment keeps the original visible and becomes the live filing
  perform test_helpers.expect_msg(format($q$select public.tax_record_filing(%L, 'key-p7c-fl-04', 'wht_pph23', %L, %L, 'BPE-0002', '15000000', '300000', '0', true)$q$, pc, v_period, v_today),
    'INVALID', '8.17 an amendment needs a note that says what changed');
  v_f2 := public.tax_record_filing(pc, 'key-p7c-fl-04', 'wht_pph23', v_period, v_today, 'BPE-0002', '15000000', '300000', '0', true, 'Corrected the base after a vendor credit note');
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.tax_filings where id = v_f1) = 'superseded' and (select status from public.tax_filings where id = v_f2) = 'filed'
    and (select revision from public.tax_filings where id = v_f2) = 1 and (select filing_kind from public.tax_filings where id = v_f2) = 'amendment'
    and (select superseded_by from public.tax_filings where id = v_f1) = v_f2, '8.18 original superseded, amendment live at revision 1');
  perform test_helpers.login(v_taxer);
  pos := public.tax_period_position(pc, 'wht_pph23', v_period);
  perform test_helpers.assert((pos -> 'reconciliation' ->> 'stale')::boolean and exists (select 1 from jsonb_array_elements(pos -> 'differences') x where x ->> 'code' = 'filed_tax_differs' and x ->> 'amount' = '-40000.0000')
    and exists (select 1 from jsonb_array_elements(pos -> 'differences') x where x ->> 'code' = 'filed_base_differs' and x ->> 'amount' = '-2000000.0000'),
    '8.19 the amendment shows against the ledger and makes the earlier reconciliation stale; the books did not change');
  perform test_helpers.logout();
end
$$;

do $$
declare
  pc uuid := test_helpers.eg('pc');
  v_owner uuid := 'e0000000-0000-0000-0000-000000000001';
  v_taxer uuid := 'e0000000-0000-0000-0000-000000000003';
  v_viewer uuid := 'e0000000-0000-0000-0000-000000000004';
  v_period date := date_trunc('month', test_helpers.today(pc))::date;
  v_f uuid;
  v_pay uuid;
  v_doc uuid;
  v_link uuid;
  v_link2 uuid;
begin
  select id into v_f from public.tax_filings where entity_id = pc and tax_type = 'wht_pph23' and status = 'filed';
  select id into v_pay from public.tax_payments where entity_id = pc and reference = 'NTPN-0002';
  -- 8.21 evidence: the file is registered by a person who may upload; the tax role attaches it to the record
  perform test_helpers.login(v_owner);
  v_doc := public.register_document(pc, 'key-p7c-dc-01', 'bpe-0002.pdf', 'application/pdf', 1200, repeat('a', 64));
  perform test_helpers.logout();
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format($q$select public.tax_link_evidence(%L, 'tax_filing', %L)$q$, v_doc, v_f), 'FORBIDDEN', '8.21 a viewer cannot attach tax evidence');
  perform test_helpers.logout();
  perform test_helpers.login(v_taxer);
  v_link := public.tax_link_evidence(v_doc, 'tax_filing', v_f);
  perform test_helpers.assert(public.tax_link_evidence(v_doc, 'tax_filing', v_f) = v_link, '8.22 linking twice returns the same link');
  v_link2 := public.tax_link_evidence(v_doc, 'tax_payment', v_pay, 'payment_proof');
  perform test_helpers.expect_msg(format($q$select public.tax_link_evidence(%L, 'bill', %L)$q$, v_doc, v_f), 'INVALID', '8.23 tax evidence attaches to a filing or a payment only');
  perform test_helpers.expect_msg(format($q$select public.tax_link_evidence(%L, 'tax_filing', %L, 'receipt')$q$, v_doc, v_f), 'INVALID', '8.24 the purpose is one of the tax purposes');
  perform test_helpers.expect_msg(format($q$select public.tax_link_evidence(%L, 'tax_filing', %L)$q$, v_doc, gen_random_uuid()), 'FORBIDDEN', '8.25 an unknown record is refused');
  perform test_helpers.logout();
  perform test_helpers.login(v_viewer);
  perform test_helpers.assert((select count(*) from public.tax_list_evidence(pc, 'tax_filing', v_f)) = 1
    and (select purpose from public.tax_list_evidence(pc, 'tax_filing', v_f)) = 'filing_receipt', '8.26 the evidence is listed with its purpose');
  perform test_helpers.assert((public.tax_period_position(pc, 'wht_pph23', v_period) ->> 'evidence_count')::int = 2, '8.27 the period position counts the evidence');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format($q$select public.unlink_document(%L, 'Attached by mistake')$q$, v_link), 'CONFLICT', '8.28 tax evidence cannot be unlinked');
  perform test_helpers.expect_msg(format($q$select public.link_document(%L, 'tax_filing', %L)$q$, v_doc, v_f), 'INVALID', '8.29 the purchase linker does not take tax records');
  perform test_helpers.logout();

  -- 8.30 history cannot be rewritten: payments, filings and reconciliations are frozen
  perform test_helpers.expect_error(format($q$update public.tax_payments set payable_applied = 1 where id = %L$q$, v_pay), '23000', '8.30 a payment cannot be edited');
  perform test_helpers.expect_error(format($q$update public.tax_filings set reported_tax = 1 where id = %L$q$, v_f), '23000', '8.31 a filing cannot be edited');
  perform test_helpers.expect_error(format($q$update public.tax_reconciliations set note = 'x' where entity_id = %L and status = 'current'$q$, pc), '23000', '8.32 a reconciliation cannot be edited');
  perform test_helpers.expect_error(format($q$delete from public.tax_payments where id = %L$q$, v_pay), '23000', '8.33 a payment cannot be deleted');
  perform test_helpers.expect_error(format($q$delete from public.tax_filings where id = %L$q$, v_f), '23000', '8.34 a filing cannot be deleted');
  perform test_helpers.expect_error(format($q$delete from public.tax_reconciliations where entity_id = %L$q$, pc), '23000', '8.35 a reconciliation cannot be deleted');
  -- the source transactions are untouched by filing and reconciliation: their determinations are as recognised
  perform test_helpers.assert((select count(*) from public.tax_determinations where entity_id = pc and superseded_at is null and tax_kind = 'wht_pph23') = 3
    and (select sum(tax_amount) from public.tax_determinations where entity_id = pc and superseded_at is null and tax_kind = 'wht_pph23') = 340000,
    '8.36 filing and reconciliation leave the determinations of the sources unchanged');
end
$$;

-- ================================================================ 9. PPh Final UMKM, the tax calendar and the period close
do $$
declare
  pf uuid;
  ph uuid;
  pg uuid;
  v_owner uuid := 'e0000000-0000-0000-0000-000000000001';
  v_taxer uuid := 'e0000000-0000-0000-0000-000000000003';
  v_viewer uuid := 'e0000000-0000-0000-0000-000000000004';
  v_staff uuid := 'e0000000-0000-0000-0000-000000000005';
  v_cust uuid;
  v_id uuid;
  v_i1 uuid;
  v_i2 uuid;
  v_d1 uuid;
  v_d2 uuid;
  v_bank uuid;
  e jsonb;
  d public.tax_determinations%rowtype;
  v_j uuid;
begin
  -- Entity F: a Perseroan Perorangan on the final regime from 1 May 2026 (the rule applies from 22 April 2026)
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p7e_f', 'P7E FINAL PP (synthetic)') returning id into pf;
  perform app_private.provision_default_coa(pf);
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p7e_h', 'P7E FINAL INDIVIDUAL (synthetic)') returning id into ph;
  perform app_private.provision_default_coa(ph);
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p7e_g', 'P7E FINAL PT (synthetic)') returning id into pg;
  perform app_private.provision_default_coa(pg);
  perform test_helpers.mk_member(pf, v_owner, 'owner');
  perform test_helpers.mk_member(ph, v_owner, 'owner');
  perform test_helpers.mk_member(pg, v_owner, 'owner');
  perform test_helpers.mk_member(pf, v_taxer, 'tax');
  perform test_helpers.mk_member(pf, v_viewer, 'viewer_auditor');
  perform test_helpers.mk_member(pf, v_staff, 'finance_staff');
  perform test_helpers.eput('pf', pf);
  perform test_helpers.eput('ph', ph);

  perform test_helpers.login(v_owner);
  -- 9.1 unknown facts go to review, not to a guess
  perform public.tax_record_entity_profile(pf, 'key-p7f-f-01', date '2026-05-01', 'perseroan_perorangan', 'resident', 'final_umkm', 'none', 'unknown',
    'non_pkp', 'no', null, 'synthetic');
  perform public.tax_engine_activate(pf, 'key-p7f-a-01', date '2026-05-01');
  v_cust := public.create_contact(pf, 'key-p7f-c-01', 'customer', 'F Customer');
  v_i1 := public.create_invoice_draft(pf, 'key-p7f-i-01', v_cust, date '2026-05-10', date '2026-06-10', jsonb_build_array(
    jsonb_build_object('description', 'Course', 'unit_price', '100000000')));
  perform public.issue_invoice(v_i1, 'key-p7f-is-01');
  v_i2 := public.create_invoice_draft(pf, 'key-p7f-i-02', v_cust, date '2026-05-20', date '2026-06-20', jsonb_build_array(
    jsonb_build_object('description', 'Workshop', 'unit_price', '20000000')));
  perform public.issue_invoice(v_i2, 'key-p7f-is-02');
  e := public.tax_final_preview(pf, date '2026-05-01');
  perform test_helpers.assert(e ->> 'status' = 'needs_review' and e -> 'reasons' ->> 0 like '%turnover of spouse%', '9.1 unknown aggregation status: review');
  perform test_helpers.expect_msg(format($q$select public.tax_final_compute(%L, 'key-p7f-fc-00', date '2026-05-01')$q$, pf), 'CONFLICT', '9.2 nothing is computed while facts are unconfirmed');
  perform public.tax_record_entity_profile(pf, 'key-p7f-f-02', date '2026-05-01', 'perseroan_perorangan', 'resident', 'final_umkm', 'none', 'none',
    'non_pkp', 'no', null, 'confirmed (synthetic)');
  e := public.tax_final_preview(pf, date '2026-05-01');
  perform test_helpers.assert(e ->> 'status' = 'auto_determined' and (e ->> 'tax')::numeric = 600000 and (e ->> 'base')::numeric = 120000000
    and (e ->> 'exempt_band')::numeric = 0 and e -> 'rules' -> 0 ->> 'code' = 'PPH_FINAL_UMKM',
    '9.3 0.5% of 120,000,000 = 600,000; the individual exempt band is never applied to a Perseroan Perorangan');
  perform test_helpers.assert(public.tax_final_preview(pf, date '2026-04-01') ->> 'status' = 'not_configured', '9.4 a period before the engine start is not computed');
  perform test_helpers.assert(public.tax_final_preview(pf, date_trunc('month', current_date)::date) ->> 'status' = 'not_configured', '9.5 a period that is not over is not computed');
  perform test_helpers.logout();

  -- 9.6 who may compute
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format($q$select public.tax_final_compute(%L, 'key-p7f-fc-00', date '2026-05-01')$q$, pf), 'FORBIDDEN', '9.6 a viewer cannot compute');
  perform test_helpers.assert(public.tax_final_preview(pf, date '2026-05-01') ->> 'status' = 'auto_determined', '9.7 a viewer can preview');
  perform test_helpers.logout();

  -- 9.8 compute: expense and liability are recognised together
  perform test_helpers.login(v_taxer);
  v_d1 := public.tax_final_compute(pf, 'key-p7f-fc-01', date '2026-05-01');
  perform test_helpers.assert(public.tax_final_compute(pf, 'key-p7f-fc-01', date '2026-05-01') = v_d1, '9.8 computing replays on the same key');
  perform test_helpers.assert(public.tax_final_compute(pf, 'key-p7f-fc-02', date '2026-05-01') = v_d1, '9.9 an unchanged recomputation returns the same determination');
  perform test_helpers.logout();
  select * into d from public.tax_determinations where id = v_d1;
  perform test_helpers.assert(d.tax_amount = 600000 and d.status = 'auto_determined' and d.source_type = 'period' and d.tax_period = date '2026-05-01'
    and d.event_date = date '2026-05-31' and d.revision = 1 and d.journal_id is not null
    and test_helpers.jd7(d.journal_id, 'INCOME_TAX_EXPENSE') = 600000 and test_helpers.jc7(d.journal_id, 'TAX_PAYABLE') = 600000
    and (select entry_date from public.journal_entries where id = d.journal_id) = date '2026-05-31',
    '9.10 Dr income-tax expense, Cr Tax Payable, dated at the end of the period');
  perform test_helpers.assert((select sum(amount) from public.tax_ledger_entries where determination_id = v_d1) = 600000
    and (select bool_and(sub_ledger = ledger_workflow) from test_helpers.tctl(pf)), '9.11 the tax ledger accrues and the control agrees');

  -- 9.12 the turnover changes (an invoice is voided): the period is recomputed; only the difference is posted
  perform test_helpers.login(v_owner);
  perform public.void_invoice(v_i2, 'key-p7f-vd-01', 'Sold to the wrong party', date '2026-06-05');
  perform test_helpers.logout();
  perform test_helpers.login(v_taxer);
  v_d2 := public.tax_final_compute(pf, 'key-p7f-fc-03', date '2026-05-01');
  perform test_helpers.logout();
  select * into d from public.tax_determinations where id = v_d2;
  perform test_helpers.assert(v_d2 <> v_d1 and d.tax_amount = 500000 and d.revision = 2 and d.supersedes_id = v_d1
    and (select status from public.tax_determinations where id = v_d1) = 'superseded'
    and test_helpers.jd7(d.journal_id, 'TAX_PAYABLE') = 100000 and test_helpers.jc7(d.journal_id, 'INCOME_TAX_EXPENSE') = 100000
    and (select amount from public.tax_ledger_entries where determination_id = v_d2) = -100000
    and (select entry_kind from public.tax_ledger_entries where determination_id = v_d2) = 'reversal',
    '9.12 recomputed: 500,000; a reversal of 100,000 is posted; the earlier result stays as history');
  perform test_helpers.assert((select sum(e2.amount) from public.tax_ledger_entries e2 where e2.entity_id = pf and e2.tax_type = 'final_umkm') = 500000
    and (select bool_and(sub_ledger = ledger_workflow) from test_helpers.tctl(pf)), '9.13 the ledger nets to the current liability and still agrees with the General Ledger');

  -- 9.14 pay and file the month
  perform test_helpers.login(v_owner);
  v_bank := public.create_financial_account(pf, 'key-p7f-fa-01', 'bank', 'BCA F', 'IDR', test_helpers.acct(pf, 'BANK_OPERATING'), 'BCA', 'ACC-F-1', 'PT F');
  perform public.tax_record_payment(pf, 'key-p7f-tp-01', 'final_umkm', date '2026-05-01', date '2026-06-12', v_bank, '500000', '0', '0', 'NTPN-F1');
  perform test_helpers.expect_msg(format($q$select public.tax_record_payment(%L, 'key-p7f-tp-02', 'final_umkm', date '2026-05-01', date '2026-06-12', %L, '1')$q$, pf, v_bank),
    'INVALID', '9.14 a settled month takes no more payments');
  perform public.tax_record_filing(pf, 'key-p7f-fl-01', 'final_umkm', date '2026-05-01', date '2026-06-18', 'BPE-F1', '100000000', '500000');
  perform test_helpers.logout();
  perform test_helpers.login(v_taxer);
  v_id := public.tax_reconcile_period(pf, 'key-p7f-rc-01', 'final_umkm', date '2026-05-01');
  perform test_helpers.assert((select outcome from public.tax_reconciliations where id = v_id) = 'reconciled',
    '9.15 the final-tax month reconciles: ledger, payment and filing agree');
  -- a recomputation below what was paid leaves a visible credit rather than a hidden change
  perform test_helpers.logout();

  -- 9.16 the calendar shows each step from the effective deadline rules
  perform test_helpers.login(v_viewer);
  perform test_helpers.assert(exists (select 1 from public.tax_calendar(pf, date '2026-05-01', date '2026-07-01')
      where tax_type = 'final_umkm' and tax_period = date '2026-05-01' and step = 'pay' and due_date = date '2026-06-15' and state = 'done'),
    '9.16 PPh Final: payment due the 15th of the following month, done');
  perform test_helpers.assert(exists (select 1 from public.tax_calendar(pf, date '2026-05-01', date '2026-07-01')
      where tax_type = 'final_umkm' and tax_period = date '2026-05-01' and step = 'file' and due_date = date '2026-06-20' and state = 'done'),
    '9.17 the return is due the 20th, done');
  perform test_helpers.assert(exists (select 1 from public.tax_calendar(pf, date '2026-05-01', date '2026-07-01')
      where tax_type = 'final_umkm' and tax_period = date '2026-05-01' and step = 'evidence' and state = 'due'), '9.18 the missing filing receipt is a reminder');
  perform test_helpers.assert(exists (select 1 from public.tax_calendar(pf, date '2026-05-01', date '2026-07-01')
      where tax_type = 'final_umkm' and tax_period = date '2026-06-01' and step = 'calculate' and state = 'due'), '9.19 the month that is over and not computed is due for calculation');
  perform test_helpers.assert(public.tax_overview(pf) ->> 'needs_review_count' = '0' and (public.tax_overview(pf) -> 'profile' ->> 'income_regime') = 'final_umkm'
    and (public.tax_overview(pf) -> 'outstanding' ->> 'final_umkm')::numeric = 0, '9.20 the overview shows the regime and nothing outstanding');
  perform test_helpers.logout();
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format($q$select public.tax_calendar(%L)$q$, pf), 'FORBIDDEN', '9.21 staff cannot see the tax calendar');
  perform test_helpers.logout();

  -- 9.22 the period close: an uncomputed month is a warning; a tax-ledger difference would be a blocker
  perform test_helpers.login(v_owner);
  perform test_helpers.assert(exists (select 1 from public.period_close_checks((select id from public.accounting_periods where entity_id = pf and date '2026-06-15' between period_start and period_end))
      where code = 'final_tax_not_computed' and severity = 'warning'), '9.22 the close warns about the month whose final tax is not computed');
  perform test_helpers.assert(not exists (select 1 from public.period_close_checks((select id from public.accounting_periods where entity_id = pf and date '2026-06-15' between period_start and period_end))
      where code = 'tax_ledger_mismatch'), '9.23 the tax control passes the close');
  perform test_helpers.logout();

  -- 9.24 a taxpayer that is not on the list of eligible kinds goes to review
  perform test_helpers.login(v_owner);
  perform public.tax_record_entity_profile(pg, 'key-p7g-f-01', date '2026-05-01', 'company', 'resident', 'final_umkm', 'none', 'none', 'non_pkp', 'no', null, 'synthetic');
  perform public.tax_engine_activate(pg, 'key-p7g-a-01', date '2026-05-01');
  perform test_helpers.assert(public.tax_final_preview(pg, date '2026-05-01') ->> 'status' = 'needs_review'
    and public.tax_final_preview(pg, date '2026-05-01') -> 'reasons' ->> 0 like '%not in the rule''s list of eligible kinds%', '9.24 an ordinary company on the final regime is a review case');
  perform public.tax_record_entity_profile(pg, 'key-p7g-f-02', date '2026-06-01', 'company', 'resident', 'general', 'none', 'none', 'non_pkp', 'no', null, 'synthetic');
  perform test_helpers.assert(public.tax_final_preview(pg, date '2026-06-01') ->> 'status' = 'not_applicable', '9.25 on the general regime there is no monthly final tax');
  perform test_helpers.assert(public.tax_final_preview(pg, date '2026-05-01') ->> 'status' = 'needs_review', '9.26 the earlier month still evaluates with the facts of its own date');
  perform test_helpers.logout();
end
$$;

-- an individual: the first 500 million of the year is not taxed; over the ceiling the computation stops
do $$
declare
  ph uuid := test_helpers.eg('ph');
  v_owner uuid := 'e0000000-0000-0000-0000-000000000001';
  v_cust uuid;
  v_id uuid;
  e jsonb;
  v_d uuid;
begin
  perform test_helpers.login(v_owner);
  perform public.tax_record_entity_profile(ph, 'key-p7h-f-01', date '2026-01-01', 'individual', 'resident', 'final_umkm', 'none', 'none', 'non_pkp', 'no', null, 'synthetic');
  perform public.tax_engine_activate(ph, 'key-p7h-a-01', date '2026-01-01');
  v_cust := public.create_contact(ph, 'key-p7h-c-01', 'customer', 'H Customer');
  v_id := public.create_invoice_draft(ph, 'key-p7h-i-01', v_cust, date '2026-05-10', date '2026-06-10', jsonb_build_array(jsonb_build_object('description', 'Course', 'unit_price', '300000000')));
  perform public.issue_invoice(v_id, 'key-p7h-is-01');
  v_id := public.create_invoice_draft(ph, 'key-p7h-i-02', v_cust, date '2026-06-10', date '2026-07-10', jsonb_build_array(jsonb_build_object('description', 'Course', 'unit_price', '400000000')));
  perform public.issue_invoice(v_id, 'key-p7h-is-02');
  e := public.tax_final_preview(ph, date '2026-05-01');
  perform test_helpers.assert(e ->> 'status' = 'auto_determined' and (e ->> 'tax')::numeric = 0 and (e ->> 'exempt_band')::numeric = 500000000
    and (e ->> 'base')::numeric = 0, '9.27 an individual: turnover of 300,000,000 is inside the exempt band, so nothing is taxed');
  v_d := public.tax_final_compute(ph, 'key-p7h-fc-01', date '2026-05-01');
  perform test_helpers.assert((select journal_id from public.tax_determinations where id = v_d) is null and (select tax_amount from public.tax_determinations where id = v_d) = 0
    and not exists (select 1 from public.tax_ledger_entries where determination_id = v_d), '9.28 a zero result is recorded without a journal or ledger entry');
  e := public.tax_final_preview(ph, date '2026-06-01');
  perform test_helpers.assert((e ->> 'base')::numeric = 200000000 and (e ->> 'tax')::numeric = 1000000, '9.29 cumulative 700,000,000: only the part above 500,000,000 is taxed, 0.5% = 1,000,000');
  v_id := public.create_invoice_draft(ph, 'key-p7h-i-03', v_cust, date '2026-07-10', date '2026-08-10', jsonb_build_array(jsonb_build_object('description', 'Big', 'unit_price', '4500000000')));
  perform public.issue_invoice(v_id, 'key-p7h-is-03');
  e := public.tax_final_preview(ph, date '2026-07-01');
  perform test_helpers.assert(e ->> 'status' = 'needs_review' and e -> 'reasons' ->> 0 like '%exceeds the annual ceiling%', '9.30 over the annual ceiling the computation stops for review');
  perform test_helpers.expect_msg(format($q$select public.tax_final_compute(%L, 'key-p7h-fc-02', date '2026-07-01')$q$, ph), 'CONFLICT', '9.31 and nothing is posted');
  perform test_helpers.logout();
end
$$;
-- ================================================================ 9b. discounts with VAT, confirmation, offsets, differences and the close
do $$
declare
  pk uuid;
  pz uuid;
  v_owner uuid := 'e0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'e0000000-0000-0000-0000-000000000002';
  v_taxer uuid := 'e0000000-0000-0000-0000-000000000003';
  v_viewer uuid := 'e0000000-0000-0000-0000-000000000004';
  v_today date;
  v_period date;
  v_cust uuid;
  v_vend uuid;
  v_bank uuid;
  v_inv uuid;
  v_draft uuid;
  v_ba uuid;
  v_bb uuid;
  v_id uuid;
  i public.invoices%rowtype;
  e jsonb;
  pos jsonb;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p7e_k', 'P7E GAPS (synthetic)') returning id into pk;
  perform app_private.provision_default_coa(pk);
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p7e_z', 'P7E EXCLUDED (synthetic)') returning id into pz;
  perform app_private.provision_default_coa(pz);
  perform test_helpers.mk_member(pk, v_owner, 'owner');
  perform test_helpers.mk_member(pk, v_admin, 'finance_admin');
  perform test_helpers.mk_member(pk, v_taxer, 'tax');
  perform test_helpers.mk_member(pk, v_viewer, 'viewer_auditor');
  perform test_helpers.mk_member(pz, v_owner, 'owner');
  v_today := test_helpers.today(pk);
  v_period := date_trunc('month', v_today)::date;

  perform test_helpers.login(v_owner);
  v_cust := public.create_contact(pk, 'key-p7k-ct-01', 'customer', 'K Customer');
  v_vend := public.create_contact(pk, 'key-p7k-ct-02', 'vendor', 'K Vendor', null, null, '01.234.567.8-901.000', 'PT K Vendor');
  v_bank := public.create_financial_account(pk, 'key-p7k-fa-01', 'bank', 'BCA K', 'IDR', test_helpers.acct(pk, 'BANK_OPERATING'), 'BCA', 'ACC-K-1', 'PT K');
  perform public.tax_record_contact_facts(v_vend, 'key-p7k-cf-01', v_today - 90, 'company', 'resident', 'has_npwp', 'non_pkp', 'none', 'synthetic');
  perform public.tax_record_entity_profile(pk, 'key-p7k-f-01', v_today - 90, 'company', 'resident', 'general', 'none', 'none', 'pkp', 'yes', null, 'synthetic');
  perform public.tax_engine_activate(pk, 'key-p7k-a-01', v_today - 5);

  -- 9.32 a taxable line with a discount, booked through the contra-revenue account: the VAT is on the price after the
  -- discount; the revenue side of the journal carries the price before the discount, so the journal balances
  v_inv := public.create_invoice_draft(pk, 'key-p7k-i-01', v_cust, v_today, v_today + 20, jsonb_build_array(
    jsonb_build_object('description', 'Course', 'unit_price', '1000000', 'discount_type', 'percent', 'discount_value', '10', 'vat_treatment', 'vat_taxable')));
  perform public.issue_invoice(v_inv, 'key-p7k-is-01');
  select * into i from public.invoices where id = v_inv;
  perform test_helpers.assert(i.discount_total = 100000 and i.tax_total = 99000 and i.total = 999000 and i.base_total = 999000,
    '9.32 a 10% discount: VAT of 11% is charged on 900,000, giving a total of 999,000');
  perform test_helpers.assert(test_helpers.jd7(i.journal_id, 'ACCOUNTS_RECEIVABLE') = 999000 and test_helpers.jd7(i.journal_id, 'SALES_CONTRA') = 100000
    and test_helpers.jc7(i.journal_id, 'TAX_PAYABLE') = 99000
    and (select sum(credit) from public.journal_lines where journal_id = i.journal_id) = 1099000
    and (select sum(debit) from public.journal_lines where journal_id = i.journal_id) = 1099000
    and (select coalesce(sum(l.credit), 0) from public.journal_lines l join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
         where l.journal_id = i.journal_id and a.system_key is distinct from 'TAX_PAYABLE') = 1000000,
    '9.33 Dr receivable 999,000 and discount 100,000; Cr revenue 1,000,000 (before the discount) and Tax Payable 99,000');
  perform test_helpers.logout();

  -- 9.34 confirming a line: only tax.confirm_facts; a recognised document keeps its classification
  perform test_helpers.login(v_owner);
  v_draft := public.create_invoice_draft(pk, 'key-p7k-i-02', v_cust, v_today, v_today + 20, jsonb_build_array(
    jsonb_build_object('description', 'Course', 'unit_price', '1000000')));
  perform test_helpers.assert(public.tax_preview_document('invoice', v_draft) ->> 'status' = 'needs_review', '9.34 (setup) a line without a VAT treatment needs review');
  perform test_helpers.logout();
  foreach v_id in array array[v_viewer, v_admin] loop
    perform test_helpers.login(v_id);
    perform test_helpers.expect_msg(format($q$select public.tax_confirm_line('invoice', %L, 1, 'vat_taxable')$q$, v_draft), 'FORBIDDEN: confirming', '9.34 only tax.confirm_facts confirms a classification');
    perform test_helpers.logout();
  end loop;
  perform test_helpers.login(v_taxer);
  perform test_helpers.expect_msg(format($q$select public.tax_confirm_line('invoice', %L, 1, 'vat_taxable')$q$, v_inv), 'CONFLICT: a recognised document',
    '9.35 the classification of an issued invoice is not changed by confirming a line');
  perform test_helpers.logout();

  -- 9.36 the period close warns about the draft that still needs a tax review
  perform test_helpers.login(v_owner);
  perform test_helpers.assert(exists (select 1 from public.period_close_checks((select id from public.accounting_periods where entity_id = pk and v_today between period_start and period_end))
      where code = 'tax_review_pending' and severity = 'warning' and item_count = 1), '9.36 the close warns about one document that needs a tax review');
  perform test_helpers.logout();

  -- 9.37 the input-VAT offset is limited to the input VAT available, not only to the VAT paid against
  perform test_helpers.login(v_owner);
  v_ba := public.create_bill_draft(pk, 'key-p7k-b-01', v_vend, v_today, v_today + 20, jsonb_build_array(
    jsonb_build_object('description', 'Rent A', 'unit_price', '500000', 'tax_amount', '55000', 'wht_object', 'wht_rent_movable', 'vat_invoice_ref', '010.000-26.00000201')));
  perform public.submit_bill(v_ba, 'key-p7k-sb-01');
  perform public.approve_bill(v_ba, 'key-p7k-ab-01');
  v_bb := public.create_bill_draft(pk, 'key-p7k-b-02', v_vend, v_today, v_today + 20, jsonb_build_array(
    jsonb_build_object('description', 'Rent B', 'unit_price', '1000000', 'wht_object', 'wht_rent_movable')));
  perform public.submit_bill(v_bb, 'key-p7k-sb-02');
  perform public.approve_bill(v_bb, 'key-p7k-ab-02');
  perform test_helpers.logout();
  perform test_helpers.login(v_taxer);
  pos := public.tax_period_position(pk, 'vat', v_period);
  perform test_helpers.assert(pos ->> 'accrued_payable' = '99000.0000' and pos ->> 'asset_available' = '55000.0000', '9.37 (setup) 99,000 of output VAT against 55,000 of input VAT');
  perform test_helpers.expect_msg(format($q$select public.tax_record_payment(%L, 'key-p7k-tp-01', 'vat', %L, %L, %L, '99000', '60000')$q$, pk, v_period, v_today, v_bank),
    'INVALID: only 55000', '9.37 an offset larger than the input VAT available is refused');
  perform public.tax_record_payment(pk, 'key-p7k-tp-02', 'vat', v_period, v_today, v_bank, '99000', '55000', '0', 'NTPN-K1');
  pos := public.tax_period_position(pk, 'vat', v_period);
  perform test_helpers.assert((pos ->> 'outstanding_payable')::numeric = 0 and (pos ->> 'asset_available')::numeric = 0, '9.38 the VAT is paid; no input VAT is left to offset');

  -- 9.39 differences: unpaid tax shows against a filing that agrees with the ledger; the note is required
  perform public.tax_record_filing(pk, 'key-p7k-fl-01', 'wht_pph23', v_period, v_today, 'BPE-K1', '1500000', '30000');
  pos := public.tax_period_position(pk, 'wht_pph23', v_period);
  perform test_helpers.assert(jsonb_array_length(pos -> 'differences') = 1 and pos -> 'differences' -> 0 ->> 'code' = 'unpaid' and pos -> 'differences' -> 0 ->> 'amount' = '30000.0000',
    '9.39 PPh 23 of 30,000 is accrued and filed but not paid: one difference, "unpaid"');
  perform test_helpers.expect_msg(format($q$select public.tax_reconcile_period(%L, 'key-p7k-rc-01', 'wht_pph23', %L)$q$, pk, v_period), 'INVALID: the period has 1 difference',
    '9.40 an unpaid period needs a note to be reconciled');
  perform public.tax_record_payment(pk, 'key-p7k-tp-03', 'wht_pph23', v_period, v_today, v_bank, '30000', '0', '0', 'NTPN-K2');
  pos := public.tax_period_position(pk, 'wht_pph23', v_period);
  perform test_helpers.assert(pos -> 'differences' = '[]'::jsonb, '9.41 once paid, the period has no differences');
  perform test_helpers.logout();

  -- 9.42 voiding a source after its tax was paid leaves a visible credit, not a hidden change
  perform test_helpers.login(v_owner);
  perform public.void_bill(v_bb, 'key-p7k-vb-02', 'Vendor cancelled the service (synthetic)');
  perform test_helpers.logout();
  perform test_helpers.login(v_taxer);
  pos := public.tax_period_position(pk, 'wht_pph23', v_period);
  perform test_helpers.assert(pos ->> 'outstanding_payable' = '-20000.0000'
    and exists (select 1 from jsonb_array_elements(pos -> 'differences') x where x ->> 'code' = 'overpaid' and x ->> 'amount' = '-20000.0000')
    and exists (select 1 from jsonb_array_elements(pos -> 'differences') x where x ->> 'code' = 'filed_tax_differs' and x ->> 'amount' = '20000.0000')
    and exists (select 1 from jsonb_array_elements(pos -> 'differences') x where x ->> 'code' = 'filed_base_differs' and x ->> 'amount' = '1000000.0000'),
    '9.42 20,000 is overpaid; the filing reports 20,000 tax and 1,000,000 base more than the books now hold');
  perform test_helpers.logout();
  perform test_helpers.assert((select bool_and(sub_ledger = ledger_workflow and ledger_other = 0) from test_helpers.tctl(pk)), '9.43 the tax control still agrees with the General Ledger');

  -- 9.45 the lists return exact decimal text, never floating point
  perform test_helpers.login(v_viewer);
  perform test_helpers.assert((select count(*) from public.tax_list_payments(pk)) = 2
    and (select cash_amount from public.tax_list_payments(pk, 'vat')) = '44000.0000'
    and (select asset_applied from public.tax_list_payments(pk, 'vat')) = '55000.0000'
    and (select count(*) from public.tax_list_payments(pk, 'wht_pph23', v_period)) = 1, '9.45 tax payments are listed with exact amounts, filtered by type and period');
  perform test_helpers.assert((select sum(amount::numeric) from public.tax_ledger_report(pk, null, null, 'vat') where direction = 'payable') = 99000
    and (select bool_and(amount ~ '^-?[0-9]+(\.[0-9]+)?$') from public.tax_ledger_report(pk))
    and (select count(*) from public.tax_ledger_report(pk, v_today + 1, null)) = 0, '9.46 the tax ledger report lists exact amounts and filters by date');
  perform test_helpers.assert(public.tax_overview(pk) -> 'outstanding' ->> 'vat' = '0.0000' and public.tax_overview(pk) -> 'outstanding' ->> 'wht_pph23' = '-20000.0000',
    '9.47 the overview shows outstanding tax as text, with the overpaid PPh 23 as a negative figure');
  perform test_helpers.logout();

  -- 9.44 an entity recorded as excluded from the final regime is a review case
  perform test_helpers.login(v_owner);
  perform public.tax_record_entity_profile(pz, 'key-p7z-f-01', date '2026-01-01', 'individual', 'resident', 'final_umkm', 'excluded', 'none', 'non_pkp', 'no', null, 'synthetic');
  perform public.tax_engine_activate(pz, 'key-p7z-a-01', date '2026-01-01');
  e := public.tax_final_preview(pz, date '2026-05-01');
  perform test_helpers.assert(e ->> 'status' = 'needs_review' and e::text like '%excluded from the final regime%', '9.44 a taxpayer recorded as excluded goes to review');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 10. history is not rewritten by new rules; authorization
do $$
declare
  pt uuid := test_helpers.entity('p7e_pt');
  pc uuid := test_helpers.eg('pc');
  v_owner uuid := 'e0000000-0000-0000-0000-000000000001';
  v_today date := test_helpers.today(pt);
  v_rule uuid;
  v_p jsonb;
  v_id uuid;
  d0 public.tax_determinations%rowtype;
  d1 public.tax_determinations%rowtype;
  e jsonb;
begin
  -- 10.1 a recognised determination and the rule version it used (bill b1 of section 5: PPh 23 on rent, 2%)
  select * into d0 from public.tax_determinations where source_type = 'bill' and source_id = test_helpers.eg('b1') and tax_kind = 'wht_pph23';
  perform test_helpers.assert(d0.tax_amount = 200000 and d0.rules -> 0 ->> 'code' = 'PPH23_RATE_2' and (d0.rules -> 0 ->> 'rule_version')::int = 1, '10.1 (setup) the recognised result names version 1');

  -- 10.2 publish version 2 of the rule with a different rate, effective ten days ago
  select params into v_p from public.tax_rule_versions where code = 'PPH23_RATE_2' and rule_version = 1;
  perform test_helpers.login(v_owner);
  v_rule := public.tax_rule_draft_save('key-p7e-rv-01', null, 'pph23', 'PPH23_RATE_2', v_today - 10, false, jsonb_set(v_p, '{rate}', '"0.03"'),
    'Test amendment (synthetic)', 'TEST-REF-1', 'https://example.invalid/test', v_today, 'verified', 'synthetic regression rule');
  perform public.tax_rule_publish(v_rule, 'key-p7e-rp-01');
  -- three new bills around the effective date: before, on, after
  v_id := public.create_bill_draft(pt, 'key-p7e-b-40', test_helpers.eg('vco'), v_today - 11, v_today + 20,
    jsonb_build_array(jsonb_build_object('description', 'Rent', 'unit_price', '1000000', 'wht_object', 'wht_rent_movable')));
  e := public.tax_preview_document('bill', v_id);
  perform test_helpers.assert((e ->> 'withheld_total')::numeric = 20000 and test_helpers.res(e, 'wht_pph23') -> 'rules' -> 0 ->> 'rule_version' = '1', '10.2 the day before the change: 2%, version 1');
  v_id := public.create_bill_draft(pt, 'key-p7e-b-41', test_helpers.eg('vco'), v_today - 10, v_today + 20,
    jsonb_build_array(jsonb_build_object('description', 'Rent', 'unit_price', '1000000', 'wht_object', 'wht_rent_movable')));
  e := public.tax_preview_document('bill', v_id);
  perform test_helpers.assert((e ->> 'withheld_total')::numeric = 30000 and test_helpers.res(e, 'wht_pph23') -> 'rules' -> 0 ->> 'rule_version' = '2', '10.3 on the effective date: 3%, version 2');
  v_id := public.create_bill_draft(pt, 'key-p7e-b-42', test_helpers.eg('vco'), v_today - 9, v_today + 20,
    jsonb_build_array(jsonb_build_object('description', 'Rent', 'unit_price', '1000000', 'wht_object', 'wht_rent_movable')));
  perform test_helpers.assert((public.tax_preview_document('bill', v_id) ->> 'withheld_total')::numeric = 30000, '10.4 the day after: 3%');
  perform test_helpers.logout();

  -- 10.5 the earlier determination is exactly as it was: no recalculation, same version, same amount
  select * into d1 from public.tax_determinations where id = d0.id;
  perform test_helpers.assert(to_jsonb(d1) - 'updated_at' - 'version' = to_jsonb(d0) - 'updated_at' - 'version'
    and (select withheld_total from public.bills where id = test_helpers.eg('b1')) = 200000,
    '10.5 publishing a new rule version does not rewrite a recognised determination or its bill');
  perform test_helpers.assert((select count(*) from public.tax_rule_versions where code = 'PPH23_RATE_2') = 2
    and (select params ->> 'rate' from public.tax_rule_versions where code = 'PPH23_RATE_2' and rule_version = 1) = '0.02', '10.6 version 1 of the rule is unchanged');
  perform test_helpers.expect_error(format($q$update public.tax_determinations set tax_amount = 1 where id = %L$q$, d0.id), '23000', '10.7 a determination cannot be edited');
  perform test_helpers.expect_error(format($q$delete from public.tax_determinations where id = %L$q$, d0.id), '23000', '10.8 a determination cannot be deleted');
  perform test_helpers.expect_error(format($q$update public.tax_ledger_entries set amount = 1 where determination_id = %L$q$, d0.id), '23000', '10.9 a tax ledger entry cannot be edited');
  perform test_helpers.expect_error(format($q$delete from public.tax_ledger_entries where determination_id = %L$q$, d0.id), '23000', '10.10 a tax ledger entry cannot be deleted');

  -- 10.11 authorization: anonymous, strangers and other Entities
  perform test_helpers.as_anon();
  perform test_helpers.expect_error(format($q$select public.tax_record_payment(%L, 'key-anon-000', 'wht_pph23', date '2026-01-01', date '2026-01-02', null, '1')$q$, pc), '42501', '10.11 the anonymous role cannot record a payment');
  perform test_helpers.expect_error(format($q$select * from public.tax_calendar(%L)$q$, pc), '42501', '10.12 the anonymous role cannot read the calendar');
  perform test_helpers.expect_error('select count(*) from public.tax_payments', '42501', '10.12b the anonymous role cannot read tax payments');
  perform test_helpers.logout();
  perform test_helpers.login('e0000000-0000-0000-0000-000000000006');
  perform test_helpers.assert((select count(*) from public.tax_payments) = 0 and (select count(*) from public.tax_filings) = 0
    and (select count(*) from public.tax_reconciliations) = 0 and (select count(*) from public.tax_determinations) = 0
    and (select count(*) from public.tax_ledger_entries) = 0, '10.13 a stranger sees no tax rows');
  perform test_helpers.expect_msg(format($q$select public.tax_overview(%L)$q$, pc), 'FORBIDDEN', '10.14 a stranger cannot read the overview');
  perform test_helpers.expect_msg(format($q$select public.tax_control_report(%L)$q$, pc), 'FORBIDDEN', '10.15 a stranger cannot read the tax control');
  perform test_helpers.expect_msg(format($q$select public.tax_final_compute(%L, 'key-p7e-str-01', date '2026-05-01')$q$, pc), 'FORBIDDEN', '10.16 a stranger cannot compute');
  perform test_helpers.logout();
  perform test_helpers.login('e0000000-0000-0000-0000-000000000003');  -- the tax role of the PT sees the PT only
  perform test_helpers.assert((select count(*) from public.tax_determinations where entity_id in (test_helpers.eg('ph'), test_helpers.entity('p7e_b'), test_helpers.entity('p7e_pe'))) = 0
    and (select count(*) from public.tax_determinations where entity_id in (pt, pc, test_helpers.eg('pf'))) > 0, '10.17 the tax role sees only the Entities it belongs to');
  perform test_helpers.expect_error(format($q$insert into public.tax_payments (entity_id, payment_number, tax_type, tax_period, payment_date, currency, payable_applied, cash_amount, journal_id)
      values (%L, 'X', 'vat', date '2026-01-01', date '2026-01-02', 'IDR', 1, 1, gen_random_uuid())$q$, pc), '42501', '10.18 tables take no direct writes');
  perform test_helpers.logout();
  perform test_helpers.login('e0000000-0000-0000-0000-000000000007');  -- the Personal Entity's admin
  perform test_helpers.expect_msg(format($q$select public.tax_overview(%L)$q$, pt), 'FORBIDDEN', '10.19 the Personal Entity cannot read the PT tax overview');
  perform test_helpers.logout();
end
$$;

-- the control shows what the workflow did not post; a broken tax ledger blocks the period close
do $$
declare
  pc uuid := test_helpers.eg('pc');
  v_owner uuid := 'e0000000-0000-0000-0000-000000000001';
  v_today date := test_helpers.today(pc);
  v_j uuid;
  v_period uuid;
  v_before numeric;
begin
  select sub_ledger into v_before from test_helpers.tctl(pc) where account_key = 'TAX_PAYABLE';
  perform test_helpers.login(v_owner);
  v_j := public.create_journal_draft(pc, 'key-p7c-mj-01', 'manual', v_today, 'Manual adjustment to Tax Payable (synthetic)', jsonb_build_array(
    jsonb_build_object('account_key', 'OFFICE_GENERAL_EXPENSE', 'debit', 1000, 'credit', 0),
    jsonb_build_object('account_key', 'TAX_PAYABLE', 'debit', 0, 'credit', 1000)), 'Owner-approved adjustment (synthetic test)');
  perform public.post_journal(v_j, 'key-p7c-mj-02');
  perform test_helpers.logout();
  perform test_helpers.assert((select ledger_other from test_helpers.tctl(pc) where account_key = 'TAX_PAYABLE') = 1000
    and (select sub_ledger = ledger_workflow from test_helpers.tctl(pc) where account_key = 'TAX_PAYABLE')
    and (select ledger_total from test_helpers.tctl(pc) where account_key = 'TAX_PAYABLE') = v_before + 1000,
    '10.20 a manual posting to Tax Payable shows as its own column and does not disturb the workflow comparison');
  select id into v_period from public.accounting_periods where entity_id = pc and v_today between period_start and period_end;
  perform test_helpers.login(v_owner);
  perform test_helpers.assert(not exists (select 1 from public.period_close_checks(v_period) where code = 'tax_ledger_mismatch'), '10.21 the close is not blocked while the tax ledger agrees');
  perform test_helpers.logout();
  -- tamper with the tax ledger as a superuser (its triggers are switched off just for this probe)
  alter table public.tax_ledger_entries disable trigger tg_forbid_delete;
  delete from public.tax_ledger_entries where id = (select id from public.tax_ledger_entries where entity_id = pc and tax_type = 'wht_pph23' limit 1);
  alter table public.tax_ledger_entries enable trigger tg_forbid_delete;
  perform test_helpers.login(v_owner);
  perform test_helpers.assert(exists (select 1 from public.period_close_checks(v_period) where code = 'tax_ledger_mismatch' and severity = 'blocker'),
    '10.22 a difference between the tax ledger and the General Ledger blocks the period close');
  perform test_helpers.logout();
end
$$;

rollback;
