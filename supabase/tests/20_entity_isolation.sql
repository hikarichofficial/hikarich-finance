-- Entity separation (Step 08 §4): PT and Personal can never reference each other's records.
begin;

do $$
declare
  pt uuid := test_helpers.entity('demo_pt');
  pe uuid := test_helpers.entity('demo_personal');
  v_pe_acct uuid := test_helpers.acct(pe, 'PERSONAL_BANK');
  v_pt_acct uuid := test_helpers.acct(pt, 'BANK_OPERATING');
  v_j uuid;
  v_cat_pt uuid;
  v_cat_pe uuid;
  v_period_pe uuid;
begin
  perform test_helpers.assert((select count(*) from public.ledger_accounts where entity_id = pt) > 40, 'PT COA provisioned');
  perform test_helpers.assert((select count(*) from public.ledger_accounts where entity_id = pe) > 25, 'Personal COA provisioned');
  perform test_helpers.assert(
    not exists (select 1 from public.ledger_accounts a join public.ledger_accounts b on a.id = b.id and a.entity_id <> b.entity_id),
    'accounts belong to exactly one Entity');
  perform test_helpers.assert(app_private.provision_default_coa(pt) = 0, 'COA provisioning is idempotent');
  perform test_helpers.assert(
    (select parent_id from public.ledger_accounts where entity_id = pt and code = '1120')
      = (select id from public.ledger_accounts where entity_id = pt and code = '1100'),
    'COA parent links provisioned');

  -- Journal line cannot use another Entity's account.
  v_j := test_helpers.draft_journal(pt, date '2026-09-10');
  perform test_helpers.expect_error(
    format('insert into public.journal_lines (entity_id, journal_id, line_no, ledger_account_id, debit) values (%L,%L,1,%L,10)',
           pt, v_j, v_pe_acct), '23503', 'line uses other Entity account');
  -- Journal cannot use another Entity's period.
  select id into v_period_pe from public.accounting_periods where entity_id = pe limit 1;
  perform test_helpers.expect_error(
    format('insert into public.journal_entries (entity_id, entry_date, period_id, entry_type, description) values (%L,%L,%L,%L,%L)',
           pt, date '2026-09-10', v_period_pe, 'manual', 'x'), '23503', 'journal uses other Entity period');

  -- Categories: parent must be in the same Entity; entity_id is immutable.
  insert into public.categories (entity_id, name, kind) values (pt, 'Iso PT', 'expense') returning id into v_cat_pt;
  perform test_helpers.expect_error(
    format('insert into public.categories (entity_id, parent_id, name, kind) values (%L,%L,%L,%L)', pe, v_cat_pt, 'Iso child', 'expense'),
    '23503', 'category parent in other Entity');
  insert into public.categories (entity_id, name, kind) values (pe, 'Iso PE', 'expense') returning id into v_cat_pe;
  perform test_helpers.expect_error(
    format('update public.categories set entity_id = %L where id = %L', pe, v_cat_pt), '23000', 'entity_id immutable');
  perform test_helpers.expect_error(
    format('update public.ledger_accounts set entity_id = %L where id = %L', pe, v_pt_acct), '23000', 'account entity_id immutable');

  -- Financial account / mapping / product references stay inside the Entity.
  perform test_helpers.expect_error(
    format('insert into public.financial_accounts (entity_id, kind, name, currency, ledger_account_id) values (%L,%L,%L,%L,%L)',
           pt, 'bank', 'Cross', 'IDR', v_pe_acct), '23503', 'financial account maps other Entity ledger account');
  perform test_helpers.expect_error(
    format('insert into public.category_account_mappings (entity_id, category_id, debit_ledger_account_id, effective_from) values (%L,%L,%L,%L)',
           pt, v_cat_pe, v_pt_acct, date '2026-01-01'), '23503', 'mapping uses other Entity category');
  perform test_helpers.expect_error(
    format('insert into public.products (entity_id, kind, name, default_category_id) values (%L,%L,%L,%L)', pt, 'product', 'X', v_cat_pe),
    '23503', 'product default category in other Entity');

  -- Legal identity boundaries.
  perform test_helpers.expect_error(
    format('update public.entities set entity_type = %L where id = %L', 'company', pe), '23000', 'entity type is fixed');
  perform test_helpers.expect_error(
    format('update public.entities set base_currency = %L where id = %L', 'USD', pt), '23000', 'base currency fixed once ledger exists');
  perform test_helpers.expect_error(
    format('insert into public.entities (entity_type, code, legal_name, timezone) values (%L,%L,%L,%L)', 'other', 'bad_tz', 'X', 'Mars/Base'),
    '23514', 'unknown timezone');
  perform test_helpers.expect_error(
    format('insert into public.entities (entity_type, code, legal_name) values (%L,%L,%L)', 'other', 'Bad Code', 'X'),
    '23514', 'entity code format');
  perform test_helpers.expect_error(
    format('insert into public.entities (entity_type, code, legal_name) values (%L,%L,%L)', 'other', 'demo_pt', 'X'),
    '23505', 'entity code unique');
  -- An Entity without a ledger can still change base currency (nothing to protect yet).
  insert into public.entities (entity_type, code, legal_name) values ('other', 'scratch', 'Scratch');
  update public.entities set base_currency = 'USD' where code = 'scratch';
  perform test_helpers.assert((select base_currency from public.entities where code = 'scratch') = 'USD', 'scratch base currency changed');
end
$$;

rollback;
