-- Decision 366: the tax a person pays in themselves (PPh Final UMKM, monthly PPh 25) is two ready expense categories;
-- the Pajak Pribadi summary returns what was paid so the estimate can subtract it. One transaction, rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  me uuid;
  v_owner uuid := 'e4400000-0000-0000-0000-000000000001';
  v_fa uuid;
  v_today date;
  v_year integer;
  v_cur date;
  v_cat_final uuid;
  v_cat_inst uuid;
  v_cat_cost uuid;
  v_cat_rev uuid;
  v_exp uuid;
  s jsonb;
begin
  insert into public.entities (entity_type, code, legal_name) values ('personal', 'p44_me', 'Buku Uji Setoran') returning id into me;
  perform app_private.provision_default_coa(me);
  perform test_helpers.mk_user(v_owner, 'p44_owner');
  perform test_helpers.mk_member(me, v_owner, 'owner');
  insert into public.financial_accounts (entity_id, kind, name, currency, ledger_account_id)
  values (me, 'cash', 'Tabungan Pribadi', 'IDR', test_helpers.acct(me, 'PERSONAL_BANK')) returning id into v_fa;
  v_today := app_private.entity_today(me);
  v_year := extract(year from v_today)::integer;
  v_cur := date_trunc('month', v_today)::date;

  -- 1. the two categories and their account exist, tagged, on an expense account
  select id into v_cat_final from public.categories where entity_id = me and name = 'Setoran PPh Final UMKM';
  select id into v_cat_inst from public.categories where entity_id = me and name = 'Setoran PPh 25 (Angsuran)';
  select id into v_cat_cost from public.categories where entity_id = me and personal_tax_role = 'business_cost';
  select id into v_cat_rev from public.categories where entity_id = me and personal_tax_role = 'freelance';
  perform test_helpers.assert(v_cat_final is not null and v_cat_inst is not null
    and (select personal_tax_role from public.categories where id = v_cat_final) = 'tax_paid_final'
    and (select personal_tax_role from public.categories where id = v_cat_inst) = 'tax_paid_installment'
    and (select kind from public.categories where id = v_cat_final) = 'expense',
    '1.1 a new Personal book starts with both payment categories, tagged');
  perform test_helpers.assert(exists (select 1 from public.ledger_accounts where entity_id = me and system_key = 'PERSONAL_INCOME_TAX_PAID' and account_class = 'expense'),
    '1.2 the account for tax paid exists');
  perform test_helpers.assert(app_private.provision_personal_tax_categories(me) = 0, '1.3 provisioning again adds nothing');

  -- 2. a payment tag only fits an expense category
  begin
    update public.categories set personal_tax_role = 'tax_paid_installment' where id = v_cat_rev;
    perform test_helpers.assert(false, '2.1 a revenue category cannot carry a payment tag');
  exception when check_violation then
    perform test_helpers.assert(true, '2.1 a revenue category cannot carry a payment tag');
  end;

  -- 3. the summary adds up what was paid, by tax, and ignores costs and reversed documents
  alter table public.expenses drop constraint expense_state_consistent;
  set local session_replication_role = replica;
  v_exp := gen_random_uuid();
  insert into public.expenses (id, entity_id, status, payee_name, financial_account_id, currency, expense_date, subtotal, tax_total, total, base_total)
  values (v_exp, me, 'confirmed', 'Kas Negara', v_fa, 'IDR', v_cur, 150000, 0, 150000, 150000);
  insert into public.expense_lines (entity_id, expense_id, line_no, description, quantity, unit_price, line_subtotal, line_total, category_id, treatment, base_amount)
  values (me, v_exp, 1, 'PPh 25', 1, 150000, 150000, 150000, v_cat_inst, 'expense', 150000);
  v_exp := gen_random_uuid();
  insert into public.expenses (id, entity_id, status, payee_name, financial_account_id, currency, expense_date, subtotal, tax_total, total, base_total)
  values (v_exp, me, 'confirmed', 'Kas Negara', v_fa, 'IDR', v_cur, 150000, 0, 150000, 150000);
  insert into public.expense_lines (entity_id, expense_id, line_no, description, quantity, unit_price, line_subtotal, line_total, category_id, treatment, base_amount)
  values (me, v_exp, 1, 'PPh 25', 1, 150000, 150000, 150000, v_cat_inst, 'expense', 150000);
  v_exp := gen_random_uuid();
  insert into public.expenses (id, entity_id, status, payee_name, financial_account_id, currency, expense_date, subtotal, tax_total, total, base_total)
  values (v_exp, me, 'confirmed', 'Kas Negara', v_fa, 'IDR', v_cur, 500000, 0, 500000, 500000);
  insert into public.expense_lines (entity_id, expense_id, line_no, description, quantity, unit_price, line_subtotal, line_total, category_id, treatment, base_amount)
  values (me, v_exp, 1, 'PPh Final', 1, 500000, 500000, 500000, v_cat_final, 'expense', 500000);
  v_exp := gen_random_uuid();
  insert into public.expenses (id, entity_id, status, payee_name, financial_account_id, currency, expense_date, subtotal, tax_total, total, base_total)
  values (v_exp, me, 'reversed', 'Kas Negara', v_fa, 'IDR', v_cur, 999000, 0, 999000, 999000);
  insert into public.expense_lines (entity_id, expense_id, line_no, description, quantity, unit_price, line_subtotal, line_total, category_id, treatment, base_amount)
  values (me, v_exp, 1, 'Dibatalkan', 1, 999000, 999000, 999000, v_cat_inst, 'expense', 999000);
  v_exp := gen_random_uuid();
  insert into public.expenses (id, entity_id, status, payee_name, financial_account_id, currency, expense_date, subtotal, tax_total, total, base_total)
  values (v_exp, me, 'confirmed', 'Toko Uji', v_fa, 'IDR', v_cur, 1500000, 0, 1500000, 1500000);
  insert into public.expense_lines (entity_id, expense_id, line_no, description, quantity, unit_price, line_subtotal, line_total, category_id, treatment, base_amount)
  values (me, v_exp, 1, 'Alat', 1, 1500000, 1500000, 1500000, v_cat_cost, 'expense', 1500000);
  set local session_replication_role = origin;

  perform test_helpers.login(v_owner);
  s := public.personal_tax_summary(me, v_year);
  perform test_helpers.assert((s -> 'payments' ->> 'installment')::numeric = 300000
    and (s -> 'payments' ->> 'final')::numeric = 500000,
    '3.1 payments: two instalments of 150.000 and one final payment of 500.000, the reversed one left out');
  perform test_helpers.assert((s -> 'payments' -> 'installment_months' ->> (extract(month from v_cur)::integer - 1))::numeric = 300000
    and jsonb_array_length(s -> 'payments' -> 'installment_months') = 12,
    '3.2 instalments by month, twelve entries');
  perform test_helpers.assert((s -> 'costs' ->> 'total')::numeric = 1500000,
    '3.3 the payment categories are not business costs');
  perform test_helpers.logout();
end
$$;

rollback;
