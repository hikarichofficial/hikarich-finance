-- P15 decision 291 (OWNER, 5 October 2026): every Entity starts with standard categories already tied to the
-- right ledger accounts. Covers a new company and personal Entity, that the mapping really drives revenue
-- posting, that running the provisioning again adds nothing, and that a category the OWNER already made under
-- the same name is neither duplicated nor re-mapped. Synthetic data; one transaction, rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  e_co uuid;
  e_pe uuid;
  v_mine uuid;
  v_n integer;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p155_co', 'P15 categories company (synthetic)')
  returning id into e_co;
  insert into public.entities (entity_type, code, legal_name) values ('personal', 'p155_pe', 'P15 categories personal (synthetic)')
  returning id into e_pe;

  -- the owner already has her own "penjualan produk" (different case and spacing) before provisioning
  perform app_private.provision_default_accounts(e_co);
  insert into public.categories (entity_id, name, kind) values (e_co, 'penjualan   PRODUK', 'revenue') returning id into v_mine;

  perform app_private.provision_default_coa(e_co);
  perform app_private.provision_default_coa(e_pe);

  -- 1. the standard set exists, revenue and expense, with the account each one posts to
  perform test_helpers.assert((select count(*) from public.categories where entity_id = e_co and kind = 'revenue') = 14
    and (select count(*) from public.categories where entity_id = e_co and kind = 'expense') = 13,
    '1.1 company: 14 revenue (5 standard + 9 for income without an invoice, decision 350) and 13 expense categories (her own Penjualan Produk counts as one of the revenue ones)');
  perform test_helpers.assert(app_private.resolve_revenue_account(e_co,
      (select id from public.categories where entity_id = e_co and name = 'Penjualan E-book'), current_date)
    = (select id from public.ledger_accounts where entity_id = e_co and system_key = 'EBOOK_REVENUE'),
    '1.2 Penjualan E-book posts to the e-book revenue account');
  perform test_helpers.assert((select count(*) from public.categories where entity_id = e_pe and kind = 'revenue') = 4
    and (select count(*) from public.categories where entity_id = e_pe and kind = 'expense') = 9,
    '1.3 personal: 4 income and 9 expense categories');
  perform test_helpers.assert(not exists (select 1 from public.categories where entity_id in (e_co, e_pe) and tax_category_key is not null),
    '1.4 the tax classification stays empty (automatic from the tax profile)');
  perform test_helpers.assert(exists (select 1 from public.category_account_mappings m
      join public.categories c on c.id = m.category_id
      join public.ledger_accounts a on a.id = m.debit_ledger_account_id
      where c.entity_id = e_co and c.name = 'Hosting, Domain & Cloud' and m.context = 'purchases' and a.system_key = 'HOSTING_CLOUD_EXPENSE'),
    '1.5 an expense category maps to its expense account in the purchases context');

  -- 2. her own category is kept as it is: not duplicated, not mapped
  perform test_helpers.assert((select count(*) from public.categories where entity_id = e_co and normalized_name = 'penjualan produk') = 1
    and not exists (select 1 from public.category_account_mappings where category_id = v_mine),
    '2.1 an owner-made category of the same name is neither duplicated nor re-mapped');

  -- 3. idempotent
  select count(*) into v_n from public.categories where entity_id = e_co;
  perform app_private.provision_default_categories(e_co);
  perform test_helpers.assert((select count(*) from public.categories where entity_id = e_co) = v_n,
    '3.1 provisioning again adds nothing');
end
$$;

rollback;
