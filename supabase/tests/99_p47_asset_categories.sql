-- P47 (OWNER, 9 October 2026): the expense form's "Aset" and "Dibayar di muka" treatments had no category at all.
-- Every Entity now starts with ready asset categories (kind 'asset'), each tied to an account that treatment accepts, so
-- a phone, a laptop or a prepaid rent can be saved at once. Synthetic data; one transaction, rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  e_co uuid;
  e_pe uuid;
  v_n integer;
  v_cat uuid;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p47_co', 'P47 asset categories company (synthetic)')
  returning id into e_co;
  insert into public.entities (entity_type, code, legal_name) values ('personal', 'p47_pe', 'P47 asset categories personal (synthetic)')
  returning id into e_pe;
  perform app_private.provision_default_coa(e_co);
  perform app_private.provision_default_coa(e_pe);

  -- 1. a company gets the full set; every fixed-asset category posts to a fixed-asset account and every prepaid one to a prepaid account
  perform test_helpers.assert((select count(*) from public.categories where entity_id = e_co and kind = 'asset') = 35,
    '1.1 a new company starts with 35 asset categories (26 fixed-asset, 9 prepaid or deposit)');
  perform test_helpers.assert(
    (select count(*) from public.categories c
       join public.category_account_mappings m on m.category_id = c.id and m.context = 'purchases'
      where c.entity_id = e_co and c.kind = 'asset'
        and app_private.purchase_account_ok(e_co, m.debit_ledger_account_id, 'asset')) = 26
    and (select count(*) from public.categories c
       join public.category_account_mappings m on m.category_id = c.id and m.context = 'purchases'
      where c.entity_id = e_co and c.kind = 'asset'
        and app_private.purchase_account_ok(e_co, m.debit_ledger_account_id, 'prepaid')) = 9,
    '1.2 26 categories post to a fixed-asset account (Aset) and 9 to a prepaid / deposit account (Dibayar di muka)');
  perform test_helpers.assert(exists (select 1 from public.categories where entity_id = e_co and name = 'Smartphone & Gadget' and kind = 'asset')
    and exists (select 1 from public.categories where entity_id = e_co and name = 'Peralatan Kantor' and kind = 'asset')
    and app_private.resolve_purchase_account(e_co,
        (select id from public.categories where entity_id = e_co and name = 'Smartphone & Gadget'), 'asset', null, current_date)
      = (select id from public.ledger_accounts where entity_id = e_co and code = '1510'),
    '1.3 a smartphone is booked to Komputer & Peralatan Elektronik');
  perform test_helpers.assert(app_private.resolve_purchase_account(e_co,
        (select id from public.categories where entity_id = e_co and name = 'Dibayar di Muka: Sewa'), 'prepaid', null, current_date)
      = (select id from public.ledger_accounts where entity_id = e_co and system_key = 'PREPAID_EXPENSE'),
    '1.4 prepaid rent is booked to Biaya Dibayar di Muka');

  -- 2. personal gets its own few
  perform test_helpers.assert((select count(*) from public.categories where entity_id = e_pe and kind = 'asset') = 8,
    '2.1 a new personal book starts with 8 asset categories');

  -- 3. idempotent, and an owner-made category of the same name is left alone
  select count(*) into v_n from public.categories where entity_id = e_co;
  perform app_private.provision_asset_categories(e_co);
  perform test_helpers.assert((select count(*) from public.categories where entity_id = e_co) = v_n,
    '3.1 provisioning again adds nothing');
  delete from public.category_account_mappings where entity_id = e_co and category_id = (select id from public.categories where entity_id = e_co and name = 'Tanah');
  delete from public.categories where entity_id = e_co and name = 'Tanah';
  insert into public.categories (entity_id, name, kind) values (e_co, 'tanah', 'asset') returning id into v_cat;
  perform app_private.provision_asset_categories(e_co);
  perform test_helpers.assert((select count(*) from public.categories where entity_id = e_co and normalized_name = 'tanah') = 1
    and not exists (select 1 from public.category_account_mappings where category_id = v_cat),
    '3.2 an owner-made category of the same name is neither duplicated nor re-mapped');
end
$$;

rollback;
