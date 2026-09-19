-- Master data, financial accounts and mappings (Step 02 §4, Step 03 §6/§7, Step 08 §15).
begin;
set local client_min_messages = warning;

do $$
declare
  pt uuid := test_helpers.entity('demo_pt');
  pe uuid := test_helpers.entity('demo_personal');
  v_c1 uuid;
  v_c2 uuid;
  v_contact uuid;
  v_contact_pe uuid;
  v_prod uuid;
  v_fa uuid;
  v_ch uuid;
  a_bank uuid := test_helpers.acct(pt, 'BANK_OPERATING');
  a_cash uuid := test_helpers.acct(pt, 'CASH');
  a_exp uuid := test_helpers.acct(pt, 'OFFICE_GENERAL_EXPENSE');
  a_rev uuid := test_helpers.acct(pt, 'OTHER_OPERATING_REVENUE');
  a_grp uuid;
  v_user uuid := gen_random_uuid();
  v_role uuid;
  v_m uuid;
begin
  select id into a_grp from public.ledger_accounts where entity_id = pt and code = '1100';

  -- ---- categories
  insert into public.categories (entity_id, name, kind) values (pt, 'Parent', 'expense') returning id into v_c1;
  insert into public.categories (entity_id, name, kind, parent_id) values (pt, 'Child', 'expense', v_c1) returning id into v_c2;
  perform test_helpers.expect_error(format('update public.categories set parent_id = %L where id = %L', v_c2, v_c1), '23000', 'category cycle');
  perform test_helpers.expect_error(format('update public.categories set parent_id = id where id = %L', v_c1), '23000', 'category self parent');
  perform test_helpers.expect_error(format('delete from public.categories where id = %L', v_c1), '23503', 'category with children');
  perform test_helpers.expect_error(
    format('insert into public.categories (entity_id, name, kind) values (%L,%L,%L)', pt, 'Bad', 'weird'), '23514', 'category kind domain');

  -- ---- contacts: normalized columns support duplicate detection, never auto-merge
  insert into public.contacts (entity_id, kind, display_name, email, phone)
  values (pt, 'both', '  Acme    Corp ', 'Sales@ACME.example', '+62 812-3456') returning id into v_contact;
  perform test_helpers.assert((select normalized_name from public.contacts where id = v_contact) = 'acme corp', 'name normalized');
  perform test_helpers.assert((select normalized_email from public.contacts where id = v_contact) = 'sales@acme.example', 'email normalized');
  perform test_helpers.assert((select normalized_phone from public.contacts where id = v_contact) = '628123456', 'phone normalized');
  insert into public.contacts (entity_id, kind, display_name) values (pt, 'customer', 'acme corp');
  perform test_helpers.assert((select count(*) from public.contacts where entity_id = pt and normalized_name = 'acme corp') = 2, 'duplicates are detectable, not merged');
  perform test_helpers.expect_error(
    format('insert into public.contacts (entity_id, kind, display_name, country_code) values (%L,%L,%L,%L)', pt, 'vendor', 'X', 'idn'), '23514', 'country code');

  insert into public.contact_bank_accounts (entity_id, contact_id, bank_name, account_number, account_holder, is_default)
  values (pt, v_contact, 'B', '111', 'H', true);
  perform test_helpers.expect_error(
    format('insert into public.contact_bank_accounts (entity_id, contact_id, bank_name, account_number, account_holder, is_default) values (%L,%L,%L,%L,%L,true)',
           pt, v_contact, 'B', '222', 'H'), '23505', 'one default bank account per contact');
  insert into public.contacts (entity_id, kind, display_name) values (pe, 'vendor', 'PE Vendor') returning id into v_contact_pe;
  perform test_helpers.expect_error(
    format('insert into public.contact_bank_accounts (entity_id, contact_id, bank_name, account_number, account_holder) values (%L,%L,%L,%L,%L)',
           pt, v_contact_pe, 'B', '333', 'H'), '23503', 'bank account of another Entity contact');

  -- ---- products and aliases
  insert into public.products (entity_id, kind, sku, name) values (pt, 'product', 'SKU-1', 'Widget') returning id into v_prod;
  perform test_helpers.expect_error(
    format('insert into public.products (entity_id, kind, sku, name) values (%L,%L,%L,%L)', pt, 'product', 'SKU-1', 'Widget 2'), '23505', 'sku unique per Entity');
  insert into public.products (entity_id, kind, sku, name) values (pe, 'product', 'SKU-1', 'Other Entity Widget');
  insert into public.product_aliases (entity_id, product_id, alias) values (pt, v_prod, '  Widget   Pro ');
  perform test_helpers.expect_error(
    format('insert into public.product_aliases (entity_id, product_id, alias) values (%L,%L,%L)', pt, v_prod, 'widget pro'), '23505', 'alias resolves to one product');
  perform test_helpers.expect_error(
    format('insert into public.products (entity_id, kind, name, default_unit_price) values (%L,%L,%L,-1)', pt, 'service', 'Neg'), '23514', 'negative default price');
  delete from public.products where id = v_prod;
  perform test_helpers.assert(not exists (select 1 from public.product_aliases where product_id = v_prod), 'aliases follow their product');

  -- ---- exchange rates
  insert into public.exchange_rates (from_currency, to_currency, rate_date, rate, source) values ('USD', 'IDR', date '2026-09-01', 16250.5, 'manual');
  perform test_helpers.expect_error(
    format('insert into public.exchange_rates (from_currency, to_currency, rate_date, rate, source) values (%L,%L,%L,16000,%L)', 'USD', 'IDR', date '2026-09-01', 'manual'), '23505', 'duplicate rate');
  perform test_helpers.expect_error(
    format('insert into public.exchange_rates (from_currency, to_currency, rate_date, rate, source) values (%L,%L,%L,1,%L)', 'USD', 'USD', date '2026-09-01', 'manual'), '23514', 'same currency');
  perform test_helpers.expect_error(
    format('insert into public.exchange_rates (from_currency, to_currency, rate_date, rate, source) values (%L,%L,%L,0,%L)', 'USD', 'EUR', date '2026-09-01', 'manual'), '23514', 'zero rate');
  perform test_helpers.expect_error(
    format('insert into public.exchange_rates (from_currency, to_currency, rate_date, rate, source) values (%L,%L,%L,1,%L)', 'usd', 'EUR', date '2026-09-01', 'manual'), '23514', 'currency code format');
  perform test_helpers.expect_error(
    format('insert into public.exchange_rates (from_currency, to_currency, rate_date, rate, source) values (%L,%L,%L,1,%L)', 'USD', 'XXX', date '2026-09-01', 'manual'), '23503', 'unknown currency');
  perform test_helpers.expect_error('update public.exchange_rates set rate = 1', '23000', 'rates are append-only (update)');
  perform test_helpers.expect_error('delete from public.exchange_rates', '23000', 'rates are append-only (delete)');

  -- ---- financial accounts (1:1 with a ledger asset account)
  insert into public.financial_accounts (entity_id, kind, name, currency, ledger_account_id)
  values (pt, 'cash', 'Petty Cash', 'IDR', a_cash) returning id into v_fa;
  perform test_helpers.expect_error(
    format('insert into public.financial_accounts (entity_id, kind, name, currency, ledger_account_id) values (%L,%L,%L,%L,%L)', pt, 'cash', 'Second on same ledger', 'IDR', a_cash),
    '23505', 'ledger account backs one financial account');
  perform test_helpers.expect_error(
    format('insert into public.financial_accounts (entity_id, kind, name, currency, ledger_account_id) values (%L,%L,%L,%L,%L)', pt, 'bank', 'On expense', 'IDR', a_exp),
    '23514', 'must map to an asset account');
  perform test_helpers.expect_error(
    format('insert into public.financial_accounts (entity_id, kind, name, currency, ledger_account_id) values (%L,%L,%L,%L,%L)', pt, 'bank', 'On group', 'IDR', a_grp),
    '23514', 'must not map to a group account');
  perform test_helpers.expect_error(
    format('insert into public.financial_accounts (entity_id, kind, name, currency, ledger_account_id) values (%L,%L,%L,%L,%L)', pt, 'bank', 'Bad currency', 'idr', a_bank),
    '23514', 'currency code format');
  perform test_helpers.simple_journal(pt, date '2026-09-10', a_cash, a_rev, 1000, 'system', true);
  perform test_helpers.expect_error(
    format('update public.financial_accounts set currency = %L where id = %L', 'USD', v_fa), '23000', 'currency frozen after postings');
  perform test_helpers.expect_error(
    format('delete from public.ledger_accounts where id = %L', a_cash), '23000', 'mapped protected ledger account cannot be deleted');

  -- ---- payment channels
  insert into public.payment_channels (entity_id, method_kind, name, settlement_financial_account_id)
  values (pt, 'qris', 'Test QRIS', v_fa) returning id into v_ch;
  perform test_helpers.expect_error(
    format('insert into public.payment_channels (entity_id, method_kind, name, settlement_financial_account_id) values (%L,%L,%L,%L)',
           pe, 'qris', 'Cross', v_fa), '23503', 'settlement account of another Entity');
  perform test_helpers.expect_error(format('delete from public.financial_accounts where id = %L', v_fa), '23503', 'referenced financial account');

  -- ---- category -> COA mappings (effective-dated, one interpretation at a time)
  insert into public.category_account_mappings (entity_id, category_id, debit_ledger_account_id, effective_from, effective_to)
  values (pt, v_c1, a_exp, date '2026-01-01', date '2026-06-30');
  insert into public.category_account_mappings (entity_id, category_id, debit_ledger_account_id, effective_from)
  values (pt, v_c1, a_exp, date '2026-07-01');
  perform test_helpers.expect_error(
    format('insert into public.category_account_mappings (entity_id, category_id, debit_ledger_account_id, effective_from) values (%L,%L,%L,%L)', pt, v_c1, a_exp, date '2026-05-01'),
    '23P01', 'overlapping mapping');
  insert into public.category_account_mappings (entity_id, category_id, context, credit_ledger_account_id, effective_from)
  values (pt, v_c1, 'refund', a_rev, date '2026-05-01');
  perform test_helpers.assert(true, 'a different context may overlap in time');
  perform test_helpers.expect_error(
    format('insert into public.category_account_mappings (entity_id, category_id, effective_from) values (%L,%L,%L)', pt, v_c2, date '2026-01-01'), '23514', 'mapping needs an account');
  perform test_helpers.expect_error(
    format('insert into public.category_account_mappings (entity_id, category_id, debit_ledger_account_id, effective_from, effective_to) values (%L,%L,%L,%L,%L)', pt, v_c2, a_exp, date '2026-02-01', date '2026-01-01'),
    '23514', 'mapping end before start');

  -- ---- identity, roles, memberships, approval rules
  insert into auth.users (id, email) values (v_user, 'synthetic2@example.invalid');
  perform test_helpers.expect_error(
    format('insert into public.profiles (id, display_name) values (%L,%L)', gen_random_uuid(), 'x'), '23503', 'profile needs an auth user');
  insert into public.profiles (id, display_name) values (v_user, 'Synthetic User');
  perform test_helpers.expect_error(
    format('update public.profiles set is_active = false where id = %L', v_user), '23514', 'disabled profile needs timestamp');
  insert into public.roles (role_key, name) values ('test_role', 'Test role') returning id into v_role;
  insert into public.entity_memberships (entity_id, user_id, role_id) values (pt, v_user, v_role) returning id into v_m;
  perform test_helpers.expect_error(
    format('insert into public.entity_memberships (entity_id, user_id, role_id) values (%L,%L,%L)', pt, v_user, v_role), '23505', 'one membership per user and Entity');
  perform test_helpers.expect_error(
    format('update public.entity_memberships set entity_id = %L where id = %L', pe, v_m), '23000', 'membership Entity is fixed');
  insert into public.permissions (key, module, action) values ('invoice.issue', 'invoice', 'issue');
  insert into public.role_permissions (role_id, permission_key) values (v_role, 'invoice.issue');
  perform test_helpers.expect_error(
    format('insert into public.permissions (key, module, action) values (%L,%L,%L)', 'BadKey', 'm', 'a'), '23514', 'permission key format');
  perform test_helpers.expect_error(
    format('insert into public.membership_permission_overrides (membership_id, permission_key, effect) values (%L,%L,%L)', v_m, 'invoice.issue', 'maybe'), '23514', 'override effect');

  insert into public.approval_rules (entity_id, module, action, min_amount, effective_from, effective_to)
  values (pt, 'bill', 'pay', 1000000, date '2026-01-01', date '2026-12-31');
  perform test_helpers.expect_error(
    format('insert into public.approval_rules (entity_id, module, action, min_amount, effective_from) values (%L,%L,%L,1000000,%L)', pt, 'bill', 'pay', date '2026-06-01'),
    '23P01', 'overlapping approval rules');
  insert into public.approval_rules (entity_id, module, action, min_amount, effective_from)
  values (pt, 'bill', 'pay', 1000000, date '2027-01-01');
  insert into public.approval_rules (entity_id, module, action, min_amount, effective_from)
  values (pt, 'bill', 'pay', 5000000, date '2026-06-01');
  perform test_helpers.assert(true, 'different thresholds may coexist');

  -- ---- entity settings and disabled entities
  insert into public.entity_settings (entity_id, setting_key, setting_value) values (pt, 'invoice.footer', '"thanks"');
  perform test_helpers.expect_error(
    format('insert into public.entity_settings (entity_id, setting_key, setting_value) values (%L,%L,%L)', pt, 'Bad Key', '1'), '23514', 'setting key format');
  perform test_helpers.expect_error(
    format('update public.entities set status = %L where id = %L', 'disabled', pe), '23514', 'disabled Entity needs timestamp');
  update public.entities set status = 'disabled', disabled_at = now() where id = pe;
end
$$;

rollback;
