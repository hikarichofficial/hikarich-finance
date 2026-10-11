-- Decision 409: interest income by kind (tabungan, deposito, lainnya), the interest already taxed by the bank is not
-- taxed again in the yearly estimate, and the filtered tax summary. One transaction, rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  pf uuid;
  v_owner uuid := 'e3630000-0000-0000-0000-000000000001';
  v_cust uuid;
  v_fa uuid;
  v_i uuid;
  v_cur date;
  v_old date;
  v_today date;
  v_year integer;
  v_n integer;
  r jsonb;
  s record;
  v_cat_tab uuid;
  v_cat_lain uuid;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p63_pf', 'P63 Interest (synthetic)') returning id into pf;
  perform app_private.provision_default_coa(pf);
  perform test_helpers.mk_user(v_owner, 'p63_owner');
  perform test_helpers.mk_member(pf, v_owner, 'owner');
  insert into public.financial_accounts (entity_id, kind, name, currency, ledger_account_id)
  values (pf, 'cash', 'Kas Uji', 'IDR', test_helpers.acct(pf, 'CASH')) returning id into v_fa;
  v_today := app_private.entity_today(pf);
  v_year := extract(year from v_today)::integer;
  v_cur := date_trunc('month', v_today)::date;
  v_old := (v_cur - interval '3 months')::date;

  -- 1. the categories
  perform test_helpers.assert((select count(*) from public.categories where entity_id = pf
    and name in ('Bunga Tabungan', 'Bunga Deposito', 'Bunga Lainnya')) = 3, '1.1 the three interest categories exist');
  perform test_helpers.assert(not exists (select 1 from public.categories where entity_id = pf and name = 'Bunga Bank & Deposito'),
    '1.2 the single old category is gone from a new Entity');
  perform test_helpers.assert((select a.code from public.category_account_mappings m join public.ledger_accounts a on a.id = m.credit_ledger_account_id
    join public.categories c on c.id = m.category_id where c.entity_id = pf and c.name = 'Bunga Tabungan') = '7101'
    and (select a.code from public.category_account_mappings m join public.ledger_accounts a on a.id = m.credit_ledger_account_id
    join public.categories c on c.id = m.category_id where c.entity_id = pf and c.name = 'Bunga Deposito') = '7102'
    and (select a.code from public.category_account_mappings m join public.ledger_accounts a on a.id = m.credit_ledger_account_id
    join public.categories c on c.id = m.category_id where c.entity_id = pf and c.name = 'Bunga Lainnya') = '7100',
    '1.3 each category books to its own account (7101, 7102, 7100)');

  -- 2. the yearly estimate leaves out what the bank already taxed
  select id into v_cat_tab from public.categories where entity_id = pf and name = 'Bunga Tabungan';
  select id into v_cat_lain from public.categories where entity_id = pf and name = 'Bunga Lainnya';
  perform test_helpers.login(v_owner);
  perform public.tax_record_entity_profile(pf, 'key-p63-f-01', v_old, 'perseroan_perorangan', 'resident', 'final_umkm', 'none', 'none',
    'non_pkp', 'no', null, 'confirmed (synthetic)');
  perform public.tax_engine_activate(pf, 'key-p63-a-01', v_old);
  perform public.record_income_entry(pf, 'key-p63-r-01', v_cat_tab, v_today, v_fa, '1000000');
  perform public.record_income_entry(pf, 'key-p63-r-02', v_cat_lain, v_today, v_fa, '500000');
  r := public.tax_non_final_income(pf, v_year);
  perform test_helpers.logout();
  perform test_helpers.assert((r ->> 'total')::numeric = 500000 and (r ->> 'estimated_tax')::numeric = 110000,
    '2.1 the estimate counts only the other interest: 500,000 and 110,000 tax');
  perform test_helpers.assert(exists (select 1 from jsonb_array_elements(r -> 'rows') x
    where x ->> 'code' = '7101' and (x ->> 'withheld')::boolean and not (x ->> 'counted')::boolean and (x ->> 'total')::numeric = 1000000),
    '2.2 the savings interest is still shown, marked as withheld and not counted');

  -- 3. the filtered summary
  perform test_helpers.login(v_owner);
  v_cust := public.create_contact(pf, 'key-p63-c-01', 'customer', 'Pelanggan Uji');
  v_i := public.create_invoice_draft(pf, 'key-p63-i-01', v_cust, v_old + 27, v_old + 57, jsonb_build_array(
    jsonb_build_object('description', 'Kursus', 'unit_price', '23362891')));
  perform public.issue_invoice(v_i, 'key-p63-is-01');
  perform test_helpers.logout();
  set constraints all immediate;
  v_n := app_private.tax_final_auto_run();

  perform test_helpers.login(v_owner);
  select * into s from public.tax_scope_summary(pf, v_old, v_old) where tax_type = 'final_umkm';
  perform test_helpers.assert(s.accrued::numeric = 116814 and s.paid::numeric = 0 and s.outstanding::numeric = 116814,
    '3.1 one month: 116,814 counted, nothing paid, 116,814 left');
  perform public.tax_record_payment(pf, 'key-p63-p-01', 'final_umkm', v_old, v_today, v_fa, '16814', '0', '0', 'NTPN-TEST', 'part');
  select * into s from public.tax_scope_summary(pf, v_old, v_old) where tax_type = 'final_umkm';
  perform test_helpers.assert(s.paid::numeric = 16814 and s.outstanding::numeric = 100000,
    '3.2 a payment reduces what is left, for that month only');
  perform test_helpers.assert(not exists (select 1 from public.tax_scope_summary(pf, (v_old - interval '2 months')::date, (v_old - interval '1 month')::date)
    where tax_type = 'final_umkm' and accrued::numeric <> 0),
    '3.3 months before it show nothing');
  select * into s from public.tax_scope_summary(pf) where tax_type = 'final_umkm';
  perform test_helpers.assert(s.accrued::numeric >= 116814 and s.paid::numeric = 16814,
    '3.4 without a range the whole history is summed');
  perform test_helpers.logout();
end
$$;
rollback;
