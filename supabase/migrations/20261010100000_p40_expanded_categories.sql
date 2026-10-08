-- OWNER, 8 October 2026: "lebih perluas dan perinci lagi ... supaya tidak ada yang terlewat. supaya next saat mengisi
-- pengeluaran tidak akan ada lagi kendala saat mau simpan." -- more standard company expense categories, each with its
-- withholding classification from the research table (PMK 141/PMK.03/2015, PP 34/2016, PPh 23 / 4(2)), so the common
-- bills pick the right treatment by themselves:
--   * Certain objects (no question asked): Sewa Kendaraan & Peralatan (PPh 23, rent other than land/building),
--     Jasa Konsultan & Manajemen, Jasa Hukum / Akuntan / Notaris, Jasa Teknik & Pemeliharaan, Jasa Konstruksi &
--     Renovasi, Jasa Kebersihan / Keamanan / Tenaga Kerja, Katering & Konsumsi Acara (PPh 23 2% of the price before
--     VAT; construction per its own rate) and Royalti & Hak Cipta (PPh 23 15%).
--   * Routine, not an object (owner: "petakan saja pada tidak kena PPh"): Perlengkapan & Peralatan Kecil, Makan /
--     Minum & Representasi, Ekspedisi & Pengiriman, Pajak / Perizinan & Biaya Pemerintah, Asuransi.
--   * Still asked per line: Jasa Profesional, Produksi Konten, Influencer & Kontrak Besar (the vendor may be an
--     individual or a company).
-- Working assumptions to confirm with the tax adviser (listed in docs/DECISIONS.md, decision 360): ekspedisi, and the
-- already mapped internet / software / hosting / advertising. A line's own choice always wins over the category.
-- Existing Entities receive the new categories (a name already used is left alone); new Entities through the
-- provision function.

create or replace function app_private.provision_default_categories(p_entity uuid) returns integer
language plpgsql set search_path = pg_catalog, public as $$
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
      ('company', 'revenue', 'Penjualan Produk', 'DIGITAL_PRODUCT_REVENUE', 10, null::text),
      ('company', 'revenue', 'Penjualan E-book', 'EBOOK_REVENUE', 20, null::text),
      ('company', 'revenue', 'Penjualan Software & Alat Digital', 'SOFTWARE_REVENUE', 30, null::text),
      ('company', 'revenue', 'Penjualan Jasa', 'OTHER_OPERATING_REVENUE', 40, null::text),
      ('company', 'revenue', 'Pendapatan Lainnya', 'OTHER_OPERATING_REVENUE', 90, null::text),
      ('company', 'expense', 'Pemasaran & Iklan', 'MARKETING_EXPENSE', 110, 'wht_none'),
      ('company', 'expense', 'Produksi Konten', 'CONTENT_PRODUCTION_EXPENSE', 120, null::text),
      ('company', 'expense', 'Influencer & Kontrak Besar', 'MARKETING_EXPENSE', 125, null::text),
      ('company', 'expense', 'Software & Langganan', 'SOFTWARE_SUBSCRIPTION_EXPENSE', 130, 'wht_none'),
      ('company', 'expense', 'Hosting, Domain & Cloud', 'HOSTING_CLOUD_EXPENSE', 140, 'wht_none'),
      ('company', 'expense', 'Biaya Payment Gateway', 'PAYMENT_PROCESSING_COST', 150, 'wht_none'),
      ('company', 'expense', 'Biaya Bank', 'BANK_FEE_EXPENSE', 160, 'wht_none'),
      ('company', 'expense', 'Jasa Profesional', 'PROFESSIONAL_FEE_EXPENSE', 170, null::text),
      ('company', 'expense', 'Kantor & Umum', 'OFFICE_GENERAL_EXPENSE', 180, 'wht_none'),
      ('company', 'expense', 'Komunikasi & Internet', 'COMMUNICATION_EXPENSE', 190, 'wht_none'),
      ('company', 'expense', 'Perjalanan & Transportasi', 'TRAVEL_TRANSPORT_EXPENSE', 200, 'wht_none'),
      ('company', 'expense', 'Gaji & Tunjangan', 'SALARY_EXPENSE', 210, 'wht_none'),
      ('company', 'expense', 'Sewa & Ruang Kerja', 'RENT_EXPENSE', 220, 'wht_rent_land_building'),
      ('company', 'expense', 'Royalti & Hak Cipta', 'CONTENT_PRODUCTION_EXPENSE', 126, 'wht_royalty'),
      ('company', 'expense', 'Jasa Konsultan & Manajemen', 'PROFESSIONAL_FEE_EXPENSE', 171, 'wht_service_consulting'),
      ('company', 'expense', 'Jasa Hukum, Akuntan & Notaris', 'PROFESSIONAL_FEE_EXPENSE', 172, 'wht_service_other_listed'),
      ('company', 'expense', 'Jasa Teknik & Pemeliharaan', 'PROFESSIONAL_FEE_EXPENSE', 173, 'wht_service_technical'),
      ('company', 'expense', 'Jasa Konstruksi & Renovasi', 'OFFICE_GENERAL_EXPENSE', 174, 'wht_service_construction'),
      ('company', 'expense', 'Perlengkapan & Peralatan Kecil', 'OFFICE_GENERAL_EXPENSE', 185, 'wht_none'),
      ('company', 'expense', 'Makan, Minum & Representasi', 'OFFICE_GENERAL_EXPENSE', 195, 'wht_none'),
      ('company', 'expense', 'Ekspedisi & Pengiriman', 'TRAVEL_TRANSPORT_EXPENSE', 205, 'wht_none'),
      ('company', 'expense', 'Sewa Kendaraan & Peralatan', 'RENT_EXPENSE', 225, 'wht_rent_movable'),
      ('company', 'expense', 'Jasa Kebersihan, Keamanan & Tenaga Kerja', 'OTHER_OPERATING_EXPENSE', 230, 'wht_service_other_listed'),
      ('company', 'expense', 'Katering & Konsumsi Acara', 'OTHER_OPERATING_EXPENSE', 235, 'wht_service_other_listed'),
      ('company', 'expense', 'Pajak, Perizinan & Biaya Pemerintah', 'OTHER_OPERATING_EXPENSE', 240, 'wht_none'),
      ('company', 'expense', 'Asuransi', 'OTHER_OPERATING_EXPENSE', 245, 'wht_none'),
      ('company', 'expense', 'Pengeluaran Operasional Lainnya', 'OTHER_OPERATING_EXPENSE', 290, 'wht_none'),
      -- Personal Entity
      ('personal', 'revenue', 'Gaji & Penghasilan Kerja', 'SALARY_INCOME', 10, null::text),
      ('personal', 'revenue', 'Dividen & Bagi Hasil Usaha', 'BUSINESS_DISTRIBUTION_INCOME', 20, null::text),
      ('personal', 'revenue', 'Bunga & Hasil Investasi', 'INVESTMENT_INCOME', 30, null::text),
      ('personal', 'revenue', 'Penghasilan Lainnya', 'OTHER_PERSONAL_INCOME', 90, null::text),
      ('personal', 'expense', 'Hunian & Sewa', 'PERSONAL_HOUSING', 110, null::text),
      ('personal', 'expense', 'Makan & Kebutuhan Harian', 'PERSONAL_FOOD', 120, null::text),
      ('personal', 'expense', 'Transportasi & Perjalanan', 'PERSONAL_TRANSPORT', 130, null::text),
      ('personal', 'expense', 'Utilitas, Komunikasi & Langganan', 'PERSONAL_UTILITIES', 140, null::text),
      ('personal', 'expense', 'Belanja & Gaya Hidup', 'PERSONAL_LIFESTYLE', 150, null::text),
      ('personal', 'expense', 'Kesehatan', 'PERSONAL_HEALTH', 160, null::text),
      ('personal', 'expense', 'Pendidikan & Pengembangan Diri', 'PERSONAL_EDUCATION', 170, null::text),
      ('personal', 'expense', 'Keluarga, Hadiah & Bantuan', 'PERSONAL_FAMILY_SUPPORT', 180, null::text),
      ('personal', 'expense', 'Pengeluaran Pribadi Lainnya', 'OTHER_PERSONAL_EXPENSE', 290, null::text)
    ) as t (entity_type, kind, name, system_key, sort_order, tax_key)
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
    insert into public.categories (entity_id, name, kind, sort_order, tax_category_key)
    values (p_entity, r.name, r.kind, r.sort_order, r.tax_key)
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


-- The new standard categories for the Entities that already exist.
select app_private.provision_default_categories(e.id) from public.entities e;
