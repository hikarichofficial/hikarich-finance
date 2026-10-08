-- Decision 365: Pajak Pribadi. The tags that sort a Personal book into PPh Final and progressive tax, income with tax
-- withheld by the client, the PTKP status, the income read from the owner's own PT, the turnover of the owner's books
-- together, the yearly summary and its permission. One transaction, rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  pt uuid;
  me uuid;
  other_owner_book uuid;
  v_owner uuid := 'e4300000-0000-0000-0000-000000000001';
  v_nopower uuid := 'e4300000-0000-0000-0000-000000000002';
  v_stranger uuid := 'e4300000-0000-0000-0000-000000000003';
  v_role_no text;
  v_fa_me uuid;
  v_fa_pt uuid;
  v_today date;
  v_year integer;
  v_cur date;
  v_prev date;
  v_cat_free uuid;
  v_cat_pt uuid;
  v_cat_biz uuid;
  v_cat_cost uuid;
  v_cat_pt_sale uuid;
  v_id uuid;
  v_id2 uuid;
  v_id3 uuid;
  v_contact uuid;
  v_contact2 uuid;
  v_exp uuid;
  v_bill uuid;
  n public.income_entries%rowtype;
  s jsonb;
  g jsonb;
  e jsonb;
  r jsonb;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p43_pt', 'PT Uji Hikarich (synthetic)') returning id into pt;
  insert into public.entities (entity_type, code, legal_name) values ('personal', 'p43_me', 'Budi Uji Pribadi') returning id into me;
  insert into public.entities (entity_type, code, legal_name) values ('personal', 'p43_lone', 'Buku Orang Lain') returning id into other_owner_book;
  perform app_private.provision_default_coa(pt);
  perform app_private.provision_default_coa(me);
  perform app_private.provision_default_coa(other_owner_book);
  perform test_helpers.mk_user(v_owner, 'p43_owner');
  perform test_helpers.mk_member(pt, v_owner, 'owner');
  perform test_helpers.mk_member(me, v_owner, 'owner');
  perform test_helpers.mk_user(v_stranger, 'p43_stranger');
  perform test_helpers.mk_member(other_owner_book, v_stranger, 'owner');
  perform test_helpers.mk_user(v_nopower, 'p43_nopower');
  select ro.role_key into v_role_no from public.roles ro
  where not exists (select 1 from public.role_permissions rp where rp.role_id = ro.id and rp.permission_key = 'tax.view') and ro.role_key <> 'owner'
  order by 1 limit 1;
  perform test_helpers.mk_member(me, v_nopower, v_role_no);
  insert into public.financial_accounts (entity_id, kind, name, currency, ledger_account_id)
  values (me, 'cash', 'Tabungan Pribadi', 'IDR', test_helpers.acct(me, 'PERSONAL_BANK')) returning id into v_fa_me;
  insert into public.financial_accounts (entity_id, kind, name, currency, ledger_account_id)
  values (pt, 'cash', 'Kas PT', 'IDR', test_helpers.acct(pt, 'CASH')) returning id into v_fa_pt;
  v_today := app_private.entity_today(me);
  v_year := extract(year from v_today)::integer;
  v_cur := date_trunc('month', v_today)::date;
  v_prev := (v_cur - interval '1 month')::date;

  select id into v_cat_free from public.categories where entity_id = me and name = 'Pendapatan Jasa & Pekerjaan Bebas';
  select id into v_cat_pt from public.categories where entity_id = me and name = 'Honor dari PT Saya';
  select id into v_cat_biz from public.categories where entity_id = me and name = 'Pendapatan Usaha (Penjualan)';
  select id into v_cat_cost from public.categories where entity_id = me and name = 'Biaya Usaha & Jasa';
  select id into v_cat_pt_sale from public.categories where entity_id = pt and name = 'Penjualan Produk';

  -- 1. ready categories and accounts of a Personal book only
  perform test_helpers.assert(
    (select personal_tax_role from public.categories where id = v_cat_free) = 'freelance'
    and (select personal_tax_role from public.categories where id = v_cat_pt) = 'company_payout'
    and (select personal_tax_role from public.categories where id = v_cat_biz) = 'umkm_business'
    and (select personal_tax_role from public.categories where id = v_cat_cost) = 'business_cost',
    '1.1 a Personal book starts with the four tagged categories');
  perform test_helpers.assert(
    (select count(*) from public.ledger_accounts where entity_id = me and code in ('1310', '4500', '4600', '6050')) = 4
    and not exists (select 1 from public.categories where entity_id = pt and personal_tax_role is not null),
    '1.2 the Personal chart has the credit, services, sales and cost accounts; a PT book has no tags');
  perform test_helpers.assert(app_private.provision_personal_tax_categories(pt) = 0
    and app_private.provision_personal_tax_categories(me) = 0, '1.3 provisioning is idempotent and Personal only');
  begin
    update public.categories set personal_tax_role = 'business_cost' where id = v_cat_free;
    perform test_helpers.assert(false, '1.4 a revenue category cannot carry the cost tag');
  exception when check_violation then
    perform test_helpers.assert(true, '1.4 a revenue category cannot carry the cost tag');
  end;

  perform test_helpers.login(v_owner);
  perform public.tax_record_entity_profile(me, 'key-p43-f-01', make_date(v_year, 1, 1), 'individual', 'resident', 'final_umkm', 'none', 'none',
    'non_pkp', 'no', '12.345.678.9-012.345', 'confirmed (synthetic)');
  perform public.tax_engine_activate(me, 'key-p43-a-01', make_date(v_year, 1, 1));
  r := public.list_income_categories(me);
  perform test_helpers.logout();
  perform test_helpers.assert(
    (select (t ->> 'in_turnover')::boolean from jsonb_array_elements(r) t where t ->> 'name' = 'Pendapatan Usaha (Penjualan)')
    and not (select (t ->> 'in_turnover')::boolean from jsonb_array_elements(r) t where t ->> 'name' = 'Pendapatan Jasa & Pekerjaan Bebas')
    and not (select (t ->> 'in_turnover')::boolean from jsonb_array_elements(r) t where t ->> 'name' = 'Gaji & Penghasilan Kerja')
    and (select t ->> 'tax_role' from jsonb_array_elements(r) t where t ->> 'name' = 'Honor dari PT Saya') = 'company_payout',
    '1.5 in a Personal book only sales count as final-tax turnover; the list says each tag');

  -- 2. services income with tax withheld by the client
  perform test_helpers.login(v_owner);
  v_id := public.record_income_entry(me, 'key-p43-r-01', v_cat_free, v_prev + 2, v_fa_me, '10000000', null, 'Invoice 01', 'Desain logo', '250000');
  perform test_helpers.assert(public.record_income_entry(me, 'key-p43-r-01', v_cat_free, v_prev + 2, v_fa_me, '10000000', null, 'Invoice 01', 'Desain logo', '250000') = v_id,
    '2.0 the same request again returns the same entry');
  perform test_helpers.logout();
  select * into n from public.income_entries where id = v_id;
  perform test_helpers.assert(n.amount = 10000000 and n.tax_withheld = 250000 and not n.in_turnover,
    '2.1 the entry keeps the gross, the tax withheld, and is not final-tax turnover');
  perform test_helpers.assert(
    (select coalesce(sum(l.debit), 0) from public.journal_lines l where l.journal_id = n.journal_id and l.ledger_account_id = test_helpers.acct(me, 'PERSONAL_BANK')) = 9750000
    and (select coalesce(sum(l.debit), 0) from public.journal_lines l join public.ledger_accounts a on a.id = l.ledger_account_id
         where l.journal_id = n.journal_id and a.system_key = 'PERSONAL_TAX_CREDIT') = 250000
    and (select coalesce(sum(l.credit), 0) from public.journal_lines l where l.journal_id = n.journal_id and l.ledger_account_id = n.income_account_id) = 10000000,
    '2.2 the bank gets the gross less the tax, the tax becomes a credit, the income is the gross');
  perform test_helpers.assert(app_private.account_balance(v_fa_me) = 9750000, '2.3 the account balance rose by what arrived');
  perform test_helpers.assert((select count(*) from public.money_movements where source_type = 'income_entry' and source_id = v_id and direction = 'in' and amount = 9750000) = 1,
    '2.4 one cash movement for what arrived');
  perform test_helpers.login(v_owner);
  begin
    perform public.record_income_entry(pt, 'key-p43-r-02', v_cat_pt_sale, v_prev + 3, v_fa_pt, '1000000', null, null, null, '20000');
    perform test_helpers.assert(false, '2.5 a PT book does not take tax withheld in this entry');
  exception when others then
    perform test_helpers.assert(sqlerrm like 'INVALID: tax withheld%', '2.5 a PT book does not take tax withheld in this entry');
  end;
  begin
    perform public.record_income_entry(me, 'key-p43-r-03', v_cat_free, v_cur, v_fa_me, '1000000', null, null, null, '1000000');
    perform test_helpers.assert(false, '2.6 the tax withheld must be less than the income');
  exception when others then
    perform test_helpers.assert(sqlerrm like 'INVALID: the tax withheld must be less%', '2.6 the tax withheld must be less than the income');
  end;
  -- 2.7 reversing returns the money movement and the journal
  v_id3 := public.record_income_entry(me, 'key-p43-r-04', v_cat_free, v_cur, v_fa_me, '2000000', null, null, null, '50000');
  perform public.reverse_income_entry(v_id3, 'key-p43-rev-01', v_cur, 'Salah catat (uji)');
  perform test_helpers.logout();
  perform test_helpers.assert(app_private.account_balance(v_fa_me) = 9750000, '2.7 a reversed entry leaves the balance as before');

  -- 3. business sale (final tax) and the ceiling across books
  perform test_helpers.login(v_owner);
  v_id2 := public.record_income_entry(me, 'key-p43-r-05', v_cat_biz, v_prev + 4, v_fa_me, '20000000');
  perform public.record_income_entry(pt, 'key-p43-r-06', v_cat_pt_sale, v_prev + 5, v_fa_pt, '5000000');
  perform test_helpers.logout();
  perform test_helpers.assert((select in_turnover from public.income_entries where id = v_id2), '3.1 a sale in a Personal book is final-tax turnover');
  e := app_private.tax_final_evaluate(me, v_prev);
  perform test_helpers.assert(e ->> 'status' = 'auto_determined' and (e ->> 'turnover_month')::numeric = 20000000 and (e ->> 'tax')::numeric = 0,
    '3.2 only the sale counts as the final base (inside the Rp 500 juta band, so no tax yet)');
  perform test_helpers.assert((e ->> 'turnover_outside')::numeric = 5000000 + 10000000,
    '3.3 the PT sales and the services income count toward the ceiling by themselves, nothing typed');
  perform test_helpers.assert(app_private.group_other_turnover(pt, extract(year from v_prev)::integer, v_prev + 27) = 20000000 + 10000000,
    '3.4 the PT sees the whole turnover of the Personal book: sales and services together');
  perform test_helpers.assert(app_private.group_other_turnover(other_owner_book, extract(year from v_prev)::integer, v_prev + 27) = 0,
    '3.5 a book of another owner is never mixed in');

  -- 4. costs of the services: confirmed expense lines in the tagged category
  -- Documents are seeded as rows (the posting workflow is tested elsewhere); the state checks are dropped inside this
  -- transaction only, which is rolled back at the end.
  alter table public.expenses drop constraint expense_state_consistent;
  alter table public.bills drop constraint bill_state_consistent;
  set local session_replication_role = replica;
  v_exp := gen_random_uuid();
  insert into public.expenses (id, entity_id, status, payee_name, financial_account_id, currency, expense_date, subtotal, tax_total, total, base_total)
  values (v_exp, me, 'confirmed', 'Toko Uji', v_fa_me, 'IDR', v_cur, 1500000, 0, 1500000, 1500000);
  insert into public.expense_lines (entity_id, expense_id, line_no, description, quantity, unit_price, line_subtotal, line_total, category_id, treatment, base_amount)
  values (me, v_exp, 1, 'Langganan alat desain', 1, 1500000, 1500000, 1500000, v_cat_cost, 'expense', 1500000);
  v_exp := gen_random_uuid();
  insert into public.expenses (id, entity_id, status, payee_name, financial_account_id, currency, expense_date, subtotal, tax_total, total, base_total)
  values (v_exp, me, 'confirmed', 'Toko Uji', v_fa_me, 'IDR', v_cur, 700000, 0, 700000, 700000);
  insert into public.expense_lines (entity_id, expense_id, line_no, description, quantity, unit_price, line_subtotal, line_total, category_id, treatment, base_amount)
  select me, v_exp, 1, 'Makan siang', 1, 700000, 700000, 700000, c.id, 'expense', 700000
  from public.categories c where c.entity_id = me and c.name = 'Makan & Kebutuhan Harian';
  v_exp := gen_random_uuid();
  insert into public.expenses (id, entity_id, status, payee_name, financial_account_id, currency, expense_date, subtotal, tax_total, total, base_total)
  values (v_exp, me, 'reversed', 'Toko Uji', v_fa_me, 'IDR', v_cur, 900000, 0, 900000, 900000);
  insert into public.expense_lines (entity_id, expense_id, line_no, description, quantity, unit_price, line_subtotal, line_total, category_id, treatment, base_amount)
  values (me, v_exp, 1, 'Dibatalkan', 1, 900000, 900000, 900000, v_cat_cost, 'expense', 900000);

  -- 5. the PT paid the owner: a contact with the owner's tax number and a confirmed expense with PPh withheld
  v_contact := gen_random_uuid();
  insert into public.contacts (id, entity_id, kind, display_name, tax_identifier) values (v_contact, pt, 'vendor', 'Pak Budi', '123456789012345');
  v_exp := gen_random_uuid();
  insert into public.expenses (id, entity_id, status, financial_account_id, currency, expense_date, payee_id, subtotal, tax_total, total, base_total, withheld_total)
  values (v_exp, pt, 'confirmed', v_fa_pt, 'IDR', v_cur, v_contact, 10000000, 0, 10000000, 9750000, 250000);
  -- a second contact matched by name only, a bill approved for it
  v_contact2 := gen_random_uuid();
  insert into public.contacts (id, entity_id, kind, display_name) values (v_contact2, pt, 'vendor', 'budi uji   pribadi');
  v_bill := gen_random_uuid();
  insert into public.bills (id, entity_id, status, vendor_id, currency, bill_date, due_date, subtotal, tax_total, total, base_total, withheld_total)
  values (v_bill, pt, 'approved', v_contact2, 'IDR', v_cur, v_cur + 10, 4000000, 0, 4000000, 3900000, 100000);
  -- an unrelated vendor and a voided bill are never counted
  insert into public.contacts (id, entity_id, kind, display_name) values (gen_random_uuid(), pt, 'vendor', 'CV Lain');
  insert into public.bills (id, entity_id, status, vendor_id, currency, bill_date, due_date, subtotal, tax_total, total, base_total, withheld_total)
  values (gen_random_uuid(), pt, 'void', v_contact2, 'IDR', v_cur, v_cur + 10, 8000000, 0, 8000000, 8000000, 0);
  set local session_replication_role = origin;

  -- 6. the yearly summary
  perform test_helpers.login(v_owner);
  s := public.personal_tax_summary(me, v_year);
  perform test_helpers.logout();
  perform test_helpers.assert((s ->> 'applicable')::boolean and s ->> 'status' = 'running' and s ->> 'currency' = 'IDR' and s ->> 'ptkp_status' is null,
    '6.1 the current year is running and no PTKP status is chosen yet');
  perform test_helpers.assert((s -> 'business' ->> 'turnover')::numeric = 20000000, '6.2 sales are the PPh Final turnover');
  perform test_helpers.assert(
    (s -> 'freelance' ->> 'own_gross')::numeric = 10000000 and (s -> 'freelance' ->> 'own_withheld')::numeric = 250000,
    '6.3 services income recorded here, with the tax the clients withheld (the reversed entry is gone)');
  perform test_helpers.assert(
    (s -> 'freelance' ->> 'pt_gross')::numeric = 14000000 and (s -> 'freelance' ->> 'pt_withheld')::numeric = 350000
    and jsonb_array_length(s -> 'linked_pt') = 2,
    '6.4 the PT payments are read by themselves: matched by tax number and by name, gross before the PPh, void bills left out');
  perform test_helpers.assert((s -> 'costs' ->> 'total')::numeric = 1500000, '6.5 only the tagged category is a cost of the services');
  perform test_helpers.assert(
    (select (x::numeric) from jsonb_array_elements_text(s -> 'freelance' -> 'months') with ordinality as t(x, i) where i = extract(month from v_cur)) = 14000000
    and (select (x::numeric) from jsonb_array_elements_text(s -> 'freelance' -> 'months') with ordinality as t(x, i) where i = extract(month from v_prev)) = 10000000,
    '6.6 the month series put each source of services income in its month');
  perform test_helpers.assert(jsonb_array_length(s -> 'group' -> 'others') = 1 and (s -> 'group' -> 'others' -> 0 ->> 'turnover')::numeric = 5000000,
    '6.7 the other book of the same owner is listed with its turnover');
  perform test_helpers.assert((s #>> '{rules,final,params,rate}') = '0.005' and (s #>> '{rules,tariff,params,pkp_round_down_to}') = '1000'
    and jsonb_array_length(s #> '{rules,tariff,params,brackets}') = 5 and (s #>> '{rules,tariff,params,ptkp,TK/0}') = '54000000',
    '6.8 the summary carries the rule data it needs: rates, brackets, PTKP');

  -- 7. PTKP status
  perform test_helpers.login(v_owner);
  perform public.personal_tax_set_ptkp(me, v_year, 'K/1');
  perform public.personal_tax_set_ptkp(me, v_year, 'TK/0');
  s := public.personal_tax_summary(me, v_year);
  perform test_helpers.assert(s ->> 'ptkp_status' = 'TK/0', '7.1 the PTKP status is saved once per year (the latest wins)');
  begin
    perform public.personal_tax_set_ptkp(me, v_year, 'XX/9');
    perform test_helpers.assert(false, '7.2 an unknown status is refused');
  exception when check_violation then
    perform test_helpers.assert(true, '7.2 an unknown status is refused');
  end;
  begin
    perform public.personal_tax_set_ptkp(pt, v_year, 'TK/0');
    perform test_helpers.assert(false, '7.3 a PT book has no PTKP');
  exception when others then
    perform test_helpers.assert(sqlerrm like 'INVALID: the PTKP status belongs%', '7.3 a PT book has no PTKP');
  end;
  perform test_helpers.assert(public.personal_tax_summary(pt, v_year) ->> 'applicable' = 'false', '7.4 a PT book has no personal summary');
  g := public.tax_group_turnover(pt, v_year);
  perform test_helpers.assert((g ->> 'own_turnover')::numeric = 5000000 and jsonb_array_length(g -> 'others') = 1
    and (g -> 'others' -> 0 ->> 'turnover')::numeric = 20000000 + 10000000 + 14000000 and g ->> 'ceiling' = '4800000000',
    '7.5 the PT shows the Personal book turnover together with its own, and the ceiling');
  perform test_helpers.logout();

  -- 8. permission
  perform test_helpers.login(v_nopower);
  begin
    perform public.personal_tax_summary(me, v_year);
    perform test_helpers.assert(false, '8.1 the summary needs tax.view');
  exception when insufficient_privilege then
    perform test_helpers.assert(true, '8.1 the summary needs tax.view');
  end;
  begin
    perform public.personal_tax_set_ptkp(me, v_year, 'K/0');
    perform test_helpers.assert(false, '8.2 choosing the PTKP status needs tax.confirm_facts');
  exception when insufficient_privilege then
    perform test_helpers.assert(true, '8.2 choosing the PTKP status needs tax.confirm_facts');
  end;
  perform test_helpers.logout();
  perform test_helpers.login(v_stranger);
  begin
    perform public.personal_tax_summary(me, v_year);
    perform test_helpers.assert(false, '8.3 a stranger cannot read another book');
  exception when insufficient_privilege then
    perform test_helpers.assert(true, '8.3 a stranger cannot read another book');
  end;
  perform test_helpers.logout();
end
$$;

rollback;
