-- Decision 426: tax_turnover_receivables shows the unpaid part of a month's invoiced turnover. Read-only: it must not
-- change the turnover base. Covers an unpaid and a part-paid invoice, a payment that settles one, a month without
-- invoices, and the tax.view gate. One transaction, rolled back. Synthetic data.
begin;
set local client_min_messages = warning;

do $$
declare
  pt uuid;
  v_owner uuid := 'e7200000-0000-0000-0000-000000000001';
  v_stranger uuid := 'e7200000-0000-0000-0000-000000000002';
  v_cust uuid;
  v_cat uuid;
  v_prod uuid;
  v_bank uuid;
  v_a uuid;
  v_b uuid;
  v_today date;
  v_month date;
  r jsonb;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p72_pt', 'PT P72 (synthetic)') returning id into pt;
  perform app_private.provision_default_coa(pt);
  perform test_helpers.mk_user(v_owner, 'p72_owner');
  perform test_helpers.mk_user(v_stranger, 'p72_stranger');
  perform test_helpers.mk_member(pt, v_owner, 'owner');
  v_today := test_helpers.today(pt);
  v_month := date_trunc('month', v_today::timestamp)::date;

  insert into public.categories (entity_id, name, kind) values (pt, 'Kursus', 'revenue') returning id into v_cat;
  insert into public.category_account_mappings (entity_id, category_id, context, credit_ledger_account_id, effective_from)
  values (pt, v_cat, 'sales', test_helpers.acct(pt, 'EBOOK_REVENUE'), date '2000-01-01');
  insert into public.products (entity_id, kind, name, default_unit_price, default_currency, default_category_id)
  values (pt, 'service', 'Kursus A', 1000000, 'IDR', v_cat) returning id into v_prod;

  perform test_helpers.login(v_owner);
  v_cust := public.create_contact(pt, 'key-p72-ct-01', 'customer', 'Pelanggan P72');
  v_bank := public.create_financial_account(pt, 'key-p72-fa-01', 'bank', 'BCA P72', 'IDR', test_helpers.acct(pt, 'BANK_OPERATING'));

  -- invoice A: 1.000.000, invoice B: 500.000 (half a unit), both issued today
  v_a := public.create_invoice_draft(pt, 'key-p72-inv-01', v_cust, v_today, v_today + 30,
    jsonb_build_array(jsonb_build_object('product_id', v_prod, 'quantity', '1')));
  perform public.issue_invoice(v_a, 'key-p72-is-01');
  v_b := public.create_invoice_draft(pt, 'key-p72-inv-02', v_cust, v_today, v_today + 30,
    jsonb_build_array(jsonb_build_object('product_id', v_prod, 'quantity', '0.5')));
  perform public.issue_invoice(v_b, 'key-p72-is-02');

  r := public.tax_turnover_receivables(pt, v_month);
  perform test_helpers.assert((r->>'turnover_invoiced')::numeric = 1500000, 'invoiced turnover is the sum of issued invoices');
  perform test_helpers.assert((r->>'turnover_unpaid')::numeric = 1500000, 'nothing paid: all of it is unpaid');
  perform test_helpers.assert((r->>'unpaid_invoice_count')::int = 2, 'two invoices are unpaid');

  -- half of A is paid: the unpaid part falls, the invoiced turnover (the tax base) does not
  perform public.record_payment(pt, 'key-p72-py-01', v_cust, v_bank, v_today, 400000,
    jsonb_build_array(jsonb_build_object('invoice_id', v_a, 'amount', 400000)));
  r := public.tax_turnover_receivables(pt, v_month);
  perform test_helpers.assert((r->>'turnover_invoiced')::numeric = 1500000, 'a payment does not change the invoiced turnover');
  perform test_helpers.assert((r->>'turnover_unpaid')::numeric = 1100000, 'unpaid = 600.000 of A + 500.000 of B');
  perform test_helpers.assert((r->>'unpaid_invoice_count')::int = 2, 'a part-paid invoice still counts as unpaid');

  -- A is settled: only B remains
  perform public.record_payment(pt, 'key-p72-py-02', v_cust, v_bank, v_today, 600000,
    jsonb_build_array(jsonb_build_object('invoice_id', v_a, 'amount', 600000)));
  r := public.tax_turnover_receivables(pt, v_month);
  perform test_helpers.assert((r->>'turnover_unpaid')::numeric = 500000, 'only B is unpaid');
  perform test_helpers.assert((r->>'unpaid_invoice_count')::int = 1, 'one invoice is unpaid');

  -- another month has no invoices
  r := public.tax_turnover_receivables(pt, (v_month - interval '1 month')::date);
  perform test_helpers.assert((r->>'turnover_invoiced')::numeric = 0 and (r->>'unpaid_invoice_count')::int = 0, 'an empty month is zero');
  perform test_helpers.logout();

  -- the turnover base used by the tax is untouched
  perform test_helpers.assert(app_private.entity_gross_turnover(pt, v_month, (v_month + interval '1 month - 1 day')::date) = 1500000,
    'the PPh Final turnover base is still the invoiced amount');

  -- a stranger is refused
  perform test_helpers.login(v_stranger);
  perform test_helpers.expect_msg(format('select public.tax_turnover_receivables(%L, %L)', pt, v_month), 'FORBIDDEN', 'tax.view is required');
  perform test_helpers.logout();
end
$$;

rollback;
