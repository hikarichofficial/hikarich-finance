-- Decision 352: income outside the PPh Final on Ringkasan Pajak: per account and month, losses against gains,
-- what is left out, the 22% estimate, the year status, the permission. One transaction, rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  pf uuid;
  other uuid;
  v_owner uuid := 'e3800000-0000-0000-0000-000000000001';
  v_nopower uuid := 'e3800000-0000-0000-0000-000000000002';
  v_role_no text;
  v_fa uuid;
  v_today date;
  v_year integer;
  v_cat_inv uuid;
  v_cat_prod uuid;
  v_id uuid;
  v_j uuid;
  r jsonb;
  row7160 jsonb;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p38_pf', 'P38 Non Final (synthetic)') returning id into pf;
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p38_other', 'P38 Other (synthetic)') returning id into other;
  perform app_private.provision_default_coa(pf);
  perform app_private.provision_default_coa(other);
  perform test_helpers.mk_user(v_owner, 'p38_owner');
  perform test_helpers.mk_member(pf, v_owner, 'owner');
  perform test_helpers.mk_user(v_nopower, 'p38_nopower');
  select ro.role_key into v_role_no from public.roles ro
  where not exists (select 1 from public.role_permissions rp where rp.role_id = ro.id and rp.permission_key = 'tax.view') and ro.role_key <> 'owner'
  order by 1 limit 1;
  perform test_helpers.mk_member(pf, v_nopower, v_role_no);
  insert into public.financial_accounts (entity_id, kind, name, currency, ledger_account_id)
  values (pf, 'cash', 'Kas Uji', 'IDR', test_helpers.acct(pf, 'CASH')) returning id into v_fa;
  v_today := app_private.entity_today(pf);
  v_year := extract(year from v_today)::integer;

  select id into v_cat_inv from public.categories where entity_id = pf and name = 'Pendapatan Investasi Lainnya';
  select id into v_cat_prod from public.categories where entity_id = pf and name = 'Penjualan Produk';

  -- 1. nothing yet
  perform test_helpers.login(v_owner);
  r := public.tax_non_final_income(pf);
  perform test_helpers.logout();
  perform test_helpers.assert((r ->> 'year')::integer = v_year and r ->> 'status' = 'running' and jsonb_array_length(r -> 'rows') = 0
    and (r ->> 'total')::numeric = 0 and jsonb_array_length(r -> 'month_totals') = 12, '1.1 an empty year: no rows, total zero, twelve months');

  -- 2. a gain (income entry on 7160), a business income (not counted), a forex loss, a cost, an unrealised line
  perform test_helpers.login(v_owner);
  v_id := public.record_income_entry(pf, 'key-p38-r-01', v_cat_inv, v_today, v_fa, '10000000');
  perform public.record_income_entry(pf, 'key-p38-r-02', v_cat_prod, v_today, v_fa, '5200000');
  perform test_helpers.logout();
  v_j := app_private.post_system_journal(pf, 'income_entry', gen_random_uuid(), 'income_entry.record', 'income_entry.v1', v_today,
    'Rugi trading forex (uji)', jsonb_build_array(
      jsonb_build_object('account_id', test_helpers.acct(pf, 'CASH'), 'debit', 0, 'credit', 3000000, 'description', 'uji'),
      jsonb_build_object('account_id', (select id from public.ledger_accounts where entity_id = pf and code = '7320'), 'debit', 3000000, 'credit', 0, 'description', 'uji')));
  v_j := app_private.post_system_journal(pf, 'income_entry', gen_random_uuid(), 'income_entry.record', 'income_entry.v1', v_today,
    'Beban swap (uji)', jsonb_build_array(
      jsonb_build_object('account_id', test_helpers.acct(pf, 'CASH'), 'debit', 0, 'credit', 500000, 'description', 'uji'),
      jsonb_build_object('account_id', (select id from public.ledger_accounts where entity_id = pf and code = '7220'), 'debit', 500000, 'credit', 0, 'description', 'uji')));
  v_j := app_private.post_system_journal(pf, 'income_entry', gen_random_uuid(), 'income_entry.record', 'income_entry.v1', v_today,
    'Penilaian ulang (uji)', jsonb_build_array(
      jsonb_build_object('account_id', test_helpers.acct(pf, 'CASH'), 'debit', 0, 'credit', 700000, 'description', 'uji'),
      jsonb_build_object('account_id', (select id from public.ledger_accounts where entity_id = pf and code = '7370'), 'debit', 700000, 'credit', 0, 'description', 'uji')));

  perform test_helpers.login(v_owner);
  r := public.tax_non_final_income(pf, v_year);
  perform test_helpers.logout();
  select x into row7160 from jsonb_array_elements(r -> 'rows') x where x ->> 'code' = '7160';
  perform test_helpers.assert((row7160 ->> 'total')::numeric = 10000000 and (row7160 -> 'months' ->> (extract(month from v_today)::integer - 1))::numeric = 10000000,
    '2.1 the gain shows under its account and the month it happened');
  perform test_helpers.assert(not exists (select 1 from jsonb_array_elements(r -> 'rows') x where x ->> 'code' like '4%'),
    '2.2 business income (4xxx) is not in the list: it is in the final-tax base');
  perform test_helpers.assert((select (x ->> 'total')::numeric from jsonb_array_elements(r -> 'rows') x where x ->> 'code' = '7320') = -3000000
    and (select (x ->> 'total')::numeric from jsonb_array_elements(r -> 'rows') x where x ->> 'code' = '7220') = -500000,
    '2.3 a forex loss and a swap cost are negative');
  perform test_helpers.assert(not (select (x ->> 'counted')::boolean from jsonb_array_elements(r -> 'rows') x where x ->> 'code' = '7370')
    and (r ->> 'total')::numeric = 6500000, '2.4 the unrealised line is shown but not counted; the total is gains minus losses and costs');
  perform test_helpers.assert((r -> 'month_totals' ->> (extract(month from v_today)::integer - 1))::numeric = 6500000, '2.5 the month total follows');

  -- 3. the estimate: 22% only for a company kind; none without a profile
  perform test_helpers.assert(r ->> 'rate' is null and r ->> 'estimated_tax' is null, '3.1 without a taxpayer profile no rate is assumed');
  perform test_helpers.login(v_owner);
  perform public.tax_record_entity_profile(pf, 'key-p38-f-01', date_trunc('month', v_today)::date, 'company', 'resident', 'general', 'none', 'none',
    'non_pkp', 'no', null, 'confirmed (synthetic)');
  r := public.tax_non_final_income(pf);
  perform test_helpers.logout();
  perform test_helpers.assert((r ->> 'rate')::numeric = 0.22 and (r ->> 'estimated_tax')::numeric = 1430000, '3.2 a company: 22% of 6.500.000');

  -- 4. a loss year pays no estimated tax; a reversed entry leaves the list
  perform test_helpers.login(v_owner);
  perform public.reverse_income_entry(v_id, 'key-p38-v-01', v_today, 'Salah catat jumlah');
  r := public.tax_non_final_income(pf);
  perform test_helpers.logout();
  perform test_helpers.assert((r ->> 'total')::numeric = -3500000 and (r ->> 'estimated_tax')::numeric = 0, '4.1 a reversed entry leaves the result; a loss gives an estimated tax of zero');

  -- 5. the year status and the refusals
  perform test_helpers.login(v_owner);
  r := public.tax_non_final_income(pf, v_year - 1);
  perform test_helpers.assert(r ->> 'status' = 'settled' and (r ->> 'settles_on')::date = make_date(v_year, 1, 1)
    and (r ->> 'annual_return_due')::date = make_date(v_year, 4, 30), '5.1 an earlier year is settled; the return is due 30 April');
  perform test_helpers.expect_msg(format('select public.tax_non_final_income(%L, %L)', pf, v_year + 1), 'INVALID', '5.2 a future year is refused');
  perform test_helpers.expect_msg(format('select public.tax_non_final_income(%L)', other), 'FORBIDDEN', '5.3 another Entity is refused');
  perform test_helpers.logout();
  perform test_helpers.login(v_nopower);
  perform test_helpers.expect_msg(format('select public.tax_non_final_income(%L)', pf), 'FORBIDDEN', '5.4 a role without tax.view is refused');
  perform test_helpers.logout();
end
$$;

rollback;
