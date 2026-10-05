-- OWNER, 5 October 2026: "untuk kategori, sebaiknya kamu buat kategori standard. misalnya Penjualan Produk.
-- dan lainya yang diperlukan untuk standard." -- every Entity starts with a ready set of categories, each
-- already tied to the right ledger account, so a new invoice or bill line can simply pick one (or none).
--
-- What this adds, and what it leaves alone:
--   * Categories only (revenue and expense), with the account mapping the posting engine already reads
--     (`category_account_mappings`, context sales / purchases). The tax classification is left empty: it stays
--     automatic from the tax profile (decision 288).
--   * A category whose name the Entity already has (compared the way the table does, `normalized_name`) is
--     skipped together with its mapping, so nothing the OWNER made herself is duplicated or re-mapped.
--   * Mappings start on 2000-01-01 so a back-dated invoice (income that came in before the site was ready) maps
--     too.
--   * New Entities get the same set: `provision_default_coa` now also provisions the categories, and the
--     original account provisioning keeps its own name `provision_default_accounts`.
-- Idempotent: running it again adds nothing.

create function app_private.provision_default_categories(p_entity uuid) returns integer
language plpgsql as $$
declare
  v_type text;
  r record;
  v_cat uuid;
  v_account uuid;
  v_count integer := 0;
begin
  select entity_type into v_type from public.entities where id = p_entity;
  if v_type is null then
    raise exception 'Unknown entity %', p_entity using errcode = 'no_data_found';
  end if;

  for r in
    select * from (values
      -- PT / any company Entity
      ('company', 'revenue', 'Penjualan Produk', 'DIGITAL_PRODUCT_REVENUE', 10),
      ('company', 'revenue', 'Penjualan E-book', 'EBOOK_REVENUE', 20),
      ('company', 'revenue', 'Penjualan Software & Alat Digital', 'SOFTWARE_REVENUE', 30),
      ('company', 'revenue', 'Penjualan Jasa', 'OTHER_OPERATING_REVENUE', 40),
      ('company', 'revenue', 'Pendapatan Lainnya', 'OTHER_OPERATING_REVENUE', 90),
      ('company', 'expense', 'Pemasaran & Iklan', 'MARKETING_EXPENSE', 110),
      ('company', 'expense', 'Produksi Konten', 'CONTENT_PRODUCTION_EXPENSE', 120),
      ('company', 'expense', 'Software & Langganan', 'SOFTWARE_SUBSCRIPTION_EXPENSE', 130),
      ('company', 'expense', 'Hosting, Domain & Cloud', 'HOSTING_CLOUD_EXPENSE', 140),
      ('company', 'expense', 'Biaya Payment Gateway', 'PAYMENT_PROCESSING_COST', 150),
      ('company', 'expense', 'Biaya Bank', 'BANK_FEE_EXPENSE', 160),
      ('company', 'expense', 'Jasa Profesional', 'PROFESSIONAL_FEE_EXPENSE', 170),
      ('company', 'expense', 'Kantor & Umum', 'OFFICE_GENERAL_EXPENSE', 180),
      ('company', 'expense', 'Komunikasi & Internet', 'COMMUNICATION_EXPENSE', 190),
      ('company', 'expense', 'Perjalanan & Transportasi', 'TRAVEL_TRANSPORT_EXPENSE', 200),
      ('company', 'expense', 'Gaji & Tunjangan', 'SALARY_EXPENSE', 210),
      ('company', 'expense', 'Sewa & Ruang Kerja', 'RENT_EXPENSE', 220),
      ('company', 'expense', 'Pengeluaran Operasional Lainnya', 'OTHER_OPERATING_EXPENSE', 290),
      -- Personal Entity
      ('personal', 'revenue', 'Gaji & Penghasilan Kerja', 'SALARY_INCOME', 10),
      ('personal', 'revenue', 'Dividen & Bagi Hasil Usaha', 'BUSINESS_DISTRIBUTION_INCOME', 20),
      ('personal', 'revenue', 'Bunga & Hasil Investasi', 'INVESTMENT_INCOME', 30),
      ('personal', 'revenue', 'Penghasilan Lainnya', 'OTHER_PERSONAL_INCOME', 90),
      ('personal', 'expense', 'Hunian & Sewa', 'PERSONAL_HOUSING', 110),
      ('personal', 'expense', 'Makan & Kebutuhan Harian', 'PERSONAL_FOOD', 120),
      ('personal', 'expense', 'Transportasi & Perjalanan', 'PERSONAL_TRANSPORT', 130),
      ('personal', 'expense', 'Utilitas, Komunikasi & Langganan', 'PERSONAL_UTILITIES', 140),
      ('personal', 'expense', 'Belanja & Gaya Hidup', 'PERSONAL_LIFESTYLE', 150),
      ('personal', 'expense', 'Kesehatan', 'PERSONAL_HEALTH', 160),
      ('personal', 'expense', 'Pendidikan & Pengembangan Diri', 'PERSONAL_EDUCATION', 170),
      ('personal', 'expense', 'Keluarga, Hadiah & Bantuan', 'PERSONAL_FAMILY_SUPPORT', 180),
      ('personal', 'expense', 'Pengeluaran Pribadi Lainnya', 'OTHER_PERSONAL_EXPENSE', 290)
    ) as t (entity_type, kind, name, system_key, sort_order)
    where t.entity_type = v_type
  loop
    -- Already there under this name (any kind): the OWNER's own category stays exactly as it is.
    if exists (select 1 from public.categories c
               where c.entity_id = p_entity
                 and c.normalized_name = lower(regexp_replace(btrim(r.name), '\s+', ' ', 'g'))) then
      continue;
    end if;
    select a.id into v_account from public.ledger_accounts a
    where a.entity_id = p_entity and a.system_key = r.system_key and a.status = 'active' and not a.is_group;
    if v_account is null then
      continue;
    end if;
    insert into public.categories (entity_id, name, kind, sort_order)
    values (p_entity, r.name, r.kind, r.sort_order)
    returning id into v_cat;
    insert into public.category_account_mappings
      (entity_id, category_id, context, debit_ledger_account_id, credit_ledger_account_id, effective_from)
    values (p_entity, v_cat,
            case r.kind when 'revenue' then 'sales' else 'purchases' end,
            case when r.kind = 'expense' then v_account end,
            case when r.kind = 'revenue' then v_account end,
            date '2000-01-01');
    v_count := v_count + 1;
  end loop;
  return v_count;
end
$$;
revoke all on function app_private.provision_default_categories(uuid) from public;

-- The original provisioning (accounts) keeps working under its own name; the public entry point every caller
-- already uses (create_entity, the P8 backfill) now also gives the Entity its categories.
alter function app_private.provision_default_coa(uuid) rename to provision_default_accounts;

create function app_private.provision_default_coa(p_entity uuid) returns integer
language plpgsql as $$
declare
  v_count integer;
begin
  v_count := app_private.provision_default_accounts(p_entity);
  perform app_private.provision_default_categories(p_entity);
  return v_count;
end
$$;
revoke all on function app_private.provision_default_coa(uuid) from public;

-- Existing Entities.
select app_private.provision_default_categories(e.id) from public.entities e;
