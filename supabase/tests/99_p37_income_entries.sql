-- Decision 350: income entered without an invoice ("Catat Pendapatan"): the journal and the cash movement it makes,
-- its place in the final-tax base, the permissions, the refusals, and the reversal. One transaction, rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  pf uuid;
  other uuid;
  v_owner uuid := 'e3700000-0000-0000-0000-000000000001';
  v_nopower uuid := 'e3700000-0000-0000-0000-000000000002';
  v_role_no text;
  v_cash uuid;
  v_fa uuid;
  v_fa_other uuid;
  v_today date;
  v_cur date;
  v_prev date;
  v_id uuid;
  v_id2 uuid;
  v_id3 uuid;
  v_n integer;
  v_types jsonb;
  v_cat_prod uuid;
  v_cat_serv uuid;
  v_cat_bunga uuid;
  v_cat_new uuid;
  v_cat_other uuid;
  v_rev uuid;
  e jsonb;
  n public.income_entries%rowtype;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p37_pf', 'P37 Income PP (synthetic)') returning id into pf;
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p37_other', 'P37 Other (synthetic)') returning id into other;
  perform app_private.provision_default_coa(pf);
  perform app_private.provision_default_coa(other);
  perform test_helpers.mk_user(v_owner, 'p37_owner');
  perform test_helpers.mk_member(pf, v_owner, 'owner');
  perform test_helpers.mk_user(v_nopower, 'p37_nopower');
  select ro.role_key into v_role_no from public.roles ro
  where not exists (select 1 from public.role_permissions rp where rp.role_id = ro.id and rp.permission_key = 'invoices.issue') and ro.role_key <> 'owner'
  order by 1 limit 1;
  perform test_helpers.mk_member(pf, v_nopower, v_role_no);
  insert into public.financial_accounts (entity_id, kind, name, currency, ledger_account_id)
  values (pf, 'cash', 'Kas Uji', 'IDR', test_helpers.acct(pf, 'CASH')) returning id into v_fa;
  insert into public.financial_accounts (entity_id, kind, name, currency, ledger_account_id)
  values (other, 'cash', 'Kas Lain', 'IDR', test_helpers.acct(other, 'CASH')) returning id into v_fa_other;
  v_today := app_private.entity_today(pf);
  v_cur := date_trunc('month', v_today)::date;
  v_prev := (v_cur - interval '1 month')::date;

  perform test_helpers.login(v_owner);
  perform public.tax_record_entity_profile(pf, 'key-p37-f-01', v_prev, 'perseroan_perorangan', 'resident', 'final_umkm', 'none', 'none',
    'non_pkp', 'no', null, 'confirmed (synthetic)');
  perform public.tax_engine_activate(pf, 'key-p37-a-01', v_prev);

  select id into v_cat_prod from public.categories where entity_id = pf and name = 'Penjualan Produk';
  select id into v_cat_serv from public.categories where entity_id = pf and name = 'Penjualan Jasa';
  select id into v_cat_bunga from public.categories where entity_id = pf and name = 'Bunga Bank & Deposito';
  select id into v_cat_other from public.categories where entity_id = other and name = 'Penjualan Jasa';

  -- 1. the categories the form shows: the same revenue categories an invoice line uses
  perform test_helpers.login(v_owner);
  v_types := public.list_income_categories(pf);
  perform test_helpers.logout();
  perform test_helpers.assert(jsonb_array_length(v_types) >= 14 and v_cat_bunga is not null
    and not exists (select 1 from jsonb_array_elements(v_types) t where not (t ->> 'available')::boolean),
    '1.1 the ready revenue categories are listed, each with its account available');
  perform test_helpers.assert(
    (select (t ->> 'in_turnover')::boolean from jsonb_array_elements(v_types) t where t ->> 'name' = 'Penjualan Produk')
    and not (select (t ->> 'in_turnover')::boolean from jsonb_array_elements(v_types) t where t ->> 'name' = 'Bunga Bank & Deposito')
    and (select t ->> 'account_code' from jsonb_array_elements(v_types) t where t ->> 'name' = 'Bunga Bank & Deposito') = '7100',
    '1.2 a revenue account counts as turnover; interest (other income) does not');
  -- a category the person adds on the spot posts to the default revenue account and counts as turnover
  insert into public.categories (entity_id, name, kind) values (pf, 'Penjualan Kelas Offline', 'revenue') returning id into v_cat_new;
  perform test_helpers.login(v_owner);
  v_types := public.list_income_categories(pf);
  perform test_helpers.logout();
  perform test_helpers.assert((select (t ->> 'in_turnover')::boolean from jsonb_array_elements(v_types) t where t ->> 'name' = 'Penjualan Kelas Offline'),
    '1.3 a newly added category counts as business turnover by default');

  -- 2. a business income: journal, cash movement, entry
  perform test_helpers.login(v_owner);
  v_id := public.record_income_entry(pf, 'key-p37-r-01', v_cat_prod, v_prev + 9, v_fa, '5000000', null, 'Transfer BCA', 'Kursus tunai');
  perform test_helpers.assert(public.record_income_entry(pf, 'key-p37-r-01', v_cat_prod, v_prev + 9, v_fa, '5000000', null, 'Transfer BCA', 'Kursus tunai') = v_id,
    '2.0 the same request again returns the same entry');
  perform test_helpers.logout();
  select * into n from public.income_entries where id = v_id;
  perform test_helpers.assert(n.status = 'recorded' and n.amount = 5000000 and n.in_turnover and n.currency = 'IDR'
    and n.entry_date = v_prev + 9 and n.category_id = v_cat_prod, '2.1 the entry holds what was entered');
  perform test_helpers.assert((select a.code from public.ledger_accounts a where a.id = n.income_account_id) = '4100',
    '2.2 digital product income credits account 4100');
  perform test_helpers.assert(
    (select coalesce(sum(l.debit), 0) from public.journal_lines l where l.journal_id = n.journal_id and l.ledger_account_id = test_helpers.acct(pf, 'CASH')) = 5000000
    and (select coalesce(sum(l.credit), 0) from public.journal_lines l where l.journal_id = n.journal_id and l.ledger_account_id = n.income_account_id) = 5000000,
    '2.3 debit cash and credit income for the full amount');
  perform test_helpers.assert(app_private.account_balance(v_fa) = 5000000, '2.4 the balance of the receiving account rose by the amount');
  perform test_helpers.assert((select count(*) from public.money_movements where source_type = 'income_entry' and source_id = v_id and direction = 'in' and amount = 5000000) = 1,
    '2.5 one cash movement in');

  -- 3. the final tax: business income counts, non-operating income does not
  e := app_private.tax_final_evaluate(pf, v_prev);
  perform test_helpers.assert(e ->> 'status' = 'auto_determined' and (e ->> 'turnover_month')::numeric = 5000000 and (e ->> 'tax')::numeric = 25000
    and (e ->> 'turnover_income')::numeric = 5000000, '3.1 0,5% of the business income is the final tax of the month');
  perform test_helpers.login(v_owner);
  v_id2 := public.record_income_entry(pf, 'key-p37-r-02', v_cat_bunga, v_prev + 10, v_fa, '1000000');
  perform test_helpers.logout();
  e := app_private.tax_final_evaluate(pf, v_prev);
  perform test_helpers.assert((e ->> 'turnover_month')::numeric = 5000000 and (e ->> 'tax')::numeric = 25000,
    '3.2 bank interest is booked but is not part of the final-tax turnover');
  perform test_helpers.assert((select a.code from public.ledger_accounts a join public.income_entries x on x.income_account_id = a.id where x.id = v_id2) = '7100'
    and not (select in_turnover from public.income_entries where id = v_id2), '3.3 interest credits 7100 and is not turnover');
  -- the running month is an estimate and follows the entries made so far
  perform test_helpers.login(v_owner);
  v_id3 := public.record_income_entry(pf, 'key-p37-r-03', v_cat_serv, v_today, v_fa, '2000000');
  perform test_helpers.logout();
  e := app_private.tax_final_evaluate(pf, v_cur, true);
  perform test_helpers.assert((e ->> 'turnover_month')::numeric = 2000000 and (e ->> 'tax')::numeric = 10000,
    '3.4 the estimate of the running month follows income entered so far');

  -- 4. refusals
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.record_income_entry(%L, %L, %L, %L, %L, %L)', pf, 'key-p37-e-01', v_cat_serv, v_today + 1, v_fa, '1000'),
    'INVALID', '4.1 a future date is refused');
  perform test_helpers.expect_msg(format('select public.record_income_entry(%L, %L, %L, %L, %L, %L)', pf, 'key-p37-e-02', v_cat_serv, v_today, v_fa, '0'),
    'INVALID', '4.2 a zero amount is refused');
  perform test_helpers.expect_msg(format('select public.record_income_entry(%L, %L, %L, %L, %L, %L)', pf, 'key-p37-e-03', gen_random_uuid(), v_today, v_fa, '1000'),
    'INVALID', '4.3 an unknown category is refused');
  perform test_helpers.expect_msg(format('select public.record_income_entry(%L, %L, %L, %L, %L, %L)', pf, 'key-p37-e-04', v_cat_serv, v_today, v_fa_other, '1000'),
    'INVALID', '4.4 an account of another Entity is refused');
  perform test_helpers.expect_msg(format('select public.record_income_entry(%L, %L, %L, %L, %L, %L)', pf, 'key-p37-e-07', v_cat_other, v_today, v_fa, '1000'),
    'INVALID', '4.4b a category of another Entity is refused');
  perform test_helpers.logout();
  perform test_helpers.login(v_nopower);
  perform test_helpers.expect_msg(format('select public.record_income_entry(%L, %L, %L, %L, %L, %L)', pf, 'key-p37-e-05', v_cat_serv, v_today, v_fa, '1000'),
    'FORBIDDEN', '4.5 a role without invoices.issue cannot record income');
  perform test_helpers.expect_msg(format('select public.reverse_income_entry(%L, %L, %L, %L)', v_id, 'key-p37-e-06', v_today, 'Salah catat'),
    'FORBIDDEN', '4.6 a role without invoices.void cannot reverse');
  perform test_helpers.logout();
  perform test_helpers.assert(test_helpers.sqlerrm_of(format('update public.income_entries set amount = 1 where id = %L', v_id)) <> '', '4.7 an entry cannot be edited');

  -- 5. reversal: journal, cash and tax go back
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.reverse_income_entry(%L, %L, %L, %L)', v_id, 'key-p37-v-00', v_today, 'ok'),
    'INVALID', '5.0 a reason of at least five characters is required');
  v_rev := public.reverse_income_entry(v_id, 'key-p37-v-01', v_today, 'Salah catat jumlah');
  perform test_helpers.expect_msg(format('select public.reverse_income_entry(%L, %L, %L, %L)', v_id, 'key-p37-v-02', v_today, 'Salah catat jumlah'),
    'CONFLICT', '5.1 an entry is reversed only once');
  perform test_helpers.logout();
  select * into n from public.income_entries where id = v_id;
  perform test_helpers.assert(n.status = 'reversed' and n.reversal_journal_id is not null and n.reverse_reason = 'Salah catat jumlah',
    '5.2 the entry shows as reversed with its reason');
  perform test_helpers.assert(app_private.account_balance(v_fa) = 1000000 + 2000000, '5.3 the balance fell by the reversed amount');
  e := app_private.tax_final_evaluate(pf, v_prev);
  perform test_helpers.assert((e ->> 'turnover_month')::numeric = 0 and (e ->> 'tax')::numeric = 0, '5.4 a reversed entry leaves the final-tax base');

  -- 6. attachments are accepted for an entry
  perform test_helpers.assert(exists (select 1 from app_private.document_target_kinds where target_type = 'income_entry'), '6.1 income entries take documents');
end
$$;

rollback;
