-- Decision 417: the tax a person pays in themselves goes through the tax module (PPh Final UMKM payment settles the
-- accrual; PPh 25 is a new type, Personal books only) and the Pajak Pribadi summary reads it from there.
-- One transaction, rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  me uuid;
  co uuid;
  v_owner uuid := 'e6600000-0000-0000-0000-000000000001';
  v_fa uuid;
  v_fa_co uuid;
  v_cat_rev uuid;
  v_cat_biz uuid;
  v_today date;
  v_year integer;
  v_cur date;
  v_old date;
  v_pay uuid;
  v_pay2 uuid;
  v_n integer;
  v_journal uuid;
  s jsonb;
  f jsonb;
begin
  insert into public.entities (entity_type, code, legal_name) values ('personal', 'p66_me', 'Buku Uji Setoran Pajak') returning id into me;
  perform app_private.provision_default_coa(me);
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p66_co', 'PT Uji Setoran') returning id into co;
  perform app_private.provision_default_coa(co);
  perform test_helpers.mk_user(v_owner, 'p66_owner');
  perform test_helpers.mk_member(me, v_owner, 'owner');
  perform test_helpers.mk_member(co, v_owner, 'owner');
  insert into public.financial_accounts (entity_id, kind, name, currency, ledger_account_id)
  values (me, 'cash', 'Tabungan Pribadi', 'IDR', test_helpers.acct(me, 'PERSONAL_BANK')) returning id into v_fa;
  insert into public.financial_accounts (entity_id, kind, name, currency, ledger_account_id)
  values (co, 'cash', 'Kas PT', 'IDR', test_helpers.acct(co, 'CASH')) returning id into v_fa_co;
  v_today := app_private.entity_today(me);
  v_year := extract(year from v_today)::integer;
  v_cur := date_trunc('month', v_today)::date;
  v_old := (v_cur - interval '3 months')::date;

  -- 1. a new Personal book no longer gets the two Beban categories for tax paid, but keeps the account
  perform test_helpers.assert(not exists (select 1 from public.categories where entity_id = me and personal_tax_role in ('tax_paid_final', 'tax_paid_installment')),
    '1.1 no Beban category for tax paid in a new Personal book');
  perform test_helpers.assert(exists (select 1 from public.categories where entity_id = me and personal_tax_role = 'business_cost'),
    '1.2 the business-cost category is still provisioned');
  perform test_helpers.assert(exists (select 1 from public.ledger_accounts where entity_id = me and system_key = 'PERSONAL_INCOME_TAX_PAID'),
    '1.3 the account for tax paid exists');

  select id into v_cat_rev from public.categories where entity_id = me and personal_tax_role = 'freelance';
  perform test_helpers.login(v_owner);
  perform public.record_income_entry(me, 'key-p66-r-01', v_cat_rev, v_today, v_fa, '5000000');

  -- 2. PPh 25: a Personal book only; no liability to settle; debit 6060, credit the bank
  v_pay := public.tax_record_payment(me, 'key-p66-p-01', 'pph25', v_cur, v_today, v_fa, '150000', '0', '0', 'NTPN-ANGSURAN', 'angsuran');
  perform test_helpers.assert((select tax_type = 'pph25' and payable_applied = 150000 and cash_amount = 150000 and status = 'confirmed'
    from public.tax_payments where id = v_pay), '2.1 the instalment is a confirmed payment of its own type');
  select journal_id into v_journal from public.tax_payments where id = v_pay;
  perform test_helpers.assert(
    (select coalesce(sum(l.debit), 0) from public.journal_lines l join public.ledger_accounts a on a.id = l.ledger_account_id
      where l.journal_id = v_journal and a.system_key = 'PERSONAL_INCOME_TAX_PAID') = 150000
    and (select coalesce(sum(l.credit), 0) from public.journal_lines l join public.ledger_accounts a on a.id = l.ledger_account_id
      where l.journal_id = v_journal and a.id = (select ledger_account_id from public.financial_accounts where id = v_fa)) = 150000
    and not exists (select 1 from public.journal_lines l join public.ledger_accounts a on a.id = l.ledger_account_id
      where l.journal_id = v_journal and a.system_key = 'TAX_PAYABLE'),
    '2.2 it debits the account for tax paid and credits the bank, never the tax payable account');
  perform test_helpers.expect_msg(format('select public.tax_record_payment(%L, ''key-p66-p-02'', ''pph25'', %L, %L, %L, ''1000'')', co, v_cur, v_today, v_fa_co),
    'INVALID: the PPh 25 instalment', '2.3 a company cannot record a PPh 25 instalment');
  v_pay2 := public.tax_record_payment(me, 'key-p66-p-03', 'pph25', v_cur, v_today, v_fa, '150000');
  perform test_helpers.assert(v_pay2 <> v_pay, '2.4 a second instalment of the same month is allowed (no accrual caps it)');
  perform test_helpers.assert((select count(*) from public.tax_list_payments(me, 'pph25', v_cur)) = 2, '2.5 the payments are listed');
  f := public.tax_period_position(me, 'pph25', v_cur);
  perform test_helpers.assert((f ->> 'paid_payable')::numeric = 300000 and jsonb_array_length(f -> 'differences') = 0,
    '2.6 the position shows 300,000 paid and no difference');
  perform test_helpers.assert(not exists (select 1 from public.tax_control_report(me) where difference::numeric <> 0),
    '2.7 the tax control against the tax payable account is untouched');
  perform test_helpers.assert(not exists (select 1 from public.tax_scope_summary(me) where tax_type = 'pph25'),
    '2.8 the filtered tax summary does not list an instalment as a tax owed');
  perform test_helpers.expect_msg(format('select public.tax_reconcile_period(%L, ''key-p66-rc-01'', ''pph25'', %L)', me, v_cur),
    'INVALID: unknown tax type', '2.9 an instalment is not reconciled by period');

  -- 3. the summary reads the instalments from the tax module
  s := public.personal_tax_summary(me, v_year);
  perform test_helpers.assert((s -> 'payments' ->> 'installment')::numeric = 300000
    and (s -> 'payments' -> 'installment_months' ->> (extract(month from v_cur)::integer - 1))::numeric = 300000,
    '3.1 the summary shows the instalments paid, in the month they are for');

  -- 4. reversing a payment takes it out of the summary
  perform public.tax_reverse_payment(v_pay2, 'key-p66-rv-01', v_today, 'salah catat');
  s := public.personal_tax_summary(me, v_year);
  perform test_helpers.assert((s -> 'payments' ->> 'installment')::numeric = 150000,
    '4.1 a reversed payment is left out');

  -- 5. PPh Final UMKM of the Personal book: the payment settles the accrual and shows as paid
  perform public.tax_record_entity_profile(me, 'key-p66-f-01', make_date(v_year, 1, 1), 'individual', 'resident', 'final_umkm', 'none', 'none',
    'non_pkp', 'no', null, 'confirmed (synthetic)');
  perform public.tax_engine_activate(me, 'key-p66-a-01', make_date(v_year, 1, 1));
  -- a business sale of 600 juta in one month: 100 juta above the Rp 500 juta band, so 0.5% = 500,000 of final tax
  select id into v_cat_biz from public.categories where entity_id = me and personal_tax_role = 'umkm_business';
  perform public.record_income_entry(me, 'key-p66-r-02', v_cat_biz, v_old + 4, v_fa, '600000000');
  perform test_helpers.logout();
  set constraints all immediate;
  v_n := app_private.tax_final_auto_run();
  perform test_helpers.login(v_owner);
  perform public.tax_record_payment(me, 'key-p66-p-04', 'final_umkm', v_old, v_today, v_fa, '16814', '0', '0', 'NTPN-FINAL', 'sebagian');
  s := public.personal_tax_summary(me, v_year);
  perform test_helpers.assert((s -> 'payments' ->> 'final')::numeric = 16814 or v_old < make_date(v_year, 1, 1),
    '5.1 the final-tax payment of the tax module counts as paid in the yearly estimate');
  perform test_helpers.assert(not exists (select 1 from public.tax_control_report(me) where difference::numeric <> 0),
    '5.2 the tax control still balances with the instalment and the final payment together');
  perform test_helpers.logout();
end
$$;

rollback;
