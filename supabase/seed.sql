-- NON-PRODUCTION seed data (Step 15 §5: "seed only non-production").
-- Synthetic records only: no real people, businesses, banks, invoices or figures. Applied by
-- `supabase db reset` (local/dev) and by scripts/db-test.sh; never applied to the production project.

do $$
declare
  v_pt uuid;
  v_pe uuid;
  v_bank uuid;
  v_cat_rev uuid;
  v_cat_exp uuid;
  v_contact uuid;
begin
  insert into public.entities (entity_type, code, legal_name, brand_name)
  values ('company', 'demo_pt', 'DEMO PT (synthetic)', 'Demo Brand')
  returning id into v_pt;
  insert into public.entities (entity_type, code, legal_name)
  values ('personal', 'demo_personal', 'DEMO Personal (synthetic)')
  returning id into v_pe;

  insert into public.entity_profiles (entity_id, city) values (v_pt, 'Jakarta'), (v_pe, 'Jakarta');

  perform app_private.provision_default_coa(v_pt);
  perform app_private.provision_default_coa(v_pe);
  perform app_private.ensure_accounting_period(v_pt, date '2026-08-15');
  perform app_private.ensure_accounting_period(v_pt, date '2026-09-15');
  perform app_private.ensure_accounting_period(v_pe, date '2026-08-15');
  perform app_private.ensure_accounting_period(v_pe, date '2026-09-15');

  insert into public.numbering_sequences (entity_id, scope, prefix)
  values (v_pt, 'invoice', 'DMO'), (v_pt, 'payment_receipt', 'DMR');

  insert into public.financial_accounts (entity_id, kind, name, institution_name, currency, ledger_account_id)
  select v_pt, 'bank', 'Demo Bank Account', 'Demo Bank', 'IDR', id
  from public.ledger_accounts where entity_id = v_pt and system_key = 'BANK_OPERATING'
  returning id into v_bank;
  insert into public.payment_channels (entity_id, method_kind, name, settlement_financial_account_id)
  values (v_pt, 'qris', 'Demo QRIS', v_bank);

  insert into public.categories (entity_id, name, kind, counts_as_turnover)
  values (v_pt, 'Demo Sales', 'revenue', true) returning id into v_cat_rev;
  insert into public.categories (entity_id, name, kind)
  values (v_pt, 'Demo Software', 'expense') returning id into v_cat_exp;
  insert into public.category_account_mappings
    (entity_id, category_id, credit_ledger_account_id, effective_from)
  select v_pt, v_cat_rev, id, date '2026-01-01'
  from public.ledger_accounts where entity_id = v_pt and system_key = 'DIGITAL_PRODUCT_REVENUE';
  insert into public.category_account_mappings
    (entity_id, category_id, debit_ledger_account_id, effective_from)
  select v_pt, v_cat_exp, id, date '2026-01-01'
  from public.ledger_accounts where entity_id = v_pt and system_key = 'SOFTWARE_SUBSCRIPTION_EXPENSE';

  insert into public.contacts (entity_id, kind, display_name)
  values (v_pt, 'customer', 'Demo Customer') returning id into v_contact;
  insert into public.products (entity_id, kind, sku, name, default_unit_price, default_currency, default_category_id)
  values (v_pt, 'product', 'DEMO-001', 'Demo Digital Product', 100000, 'IDR', v_cat_rev);
end
$$;
