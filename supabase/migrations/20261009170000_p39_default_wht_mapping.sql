-- OWNER, 8 October 2026: "kalau memang harus melakukan potongan PPh maka harusnya kamu petakan dari sekarang, mana yang
-- kena potongan PPh dan mana yang tidak. misalnya bayar Sewa." -- an expense line of an Entity that is a withholding
-- agent needs a withholding classification (decision 288 / determination). Until now the standard categories carried
-- none, so an ordinary expense (a meal) was held back with "Line 1 has no withholding classification".
--
-- The standard company expense categories now start with a classification where it does not depend on the vendor:
--   * Not a withholding object (wht_none): Biaya Bank, Biaya Payment Gateway, Gaji & Tunjangan (payroll has its own
--     PPh 21 flow), Kantor & Umum, Perjalanan & Transportasi, Pengeluaran Operasional Lainnya, and, as the owner asked
--     so that routine purchases raise no question (8 October 2026), Komunikasi & Internet, Software & Langganan,
--     Hosting/Domain/Cloud and Pemasaran & Iklan. NOTE: PMK 141/PMK.03/2015 lists internet, website, software,
--     hosting/data and advertising services as PPh 23 objects when the vendor is a domestic taxpayer; this default is
--     an assumption to be confirmed with the tax adviser (the platforms bought from are mostly foreign).
--   * Rent of land and/or building (wht_rent_land_building, PPh 4(2)): Sewa & Ruang Kerja.
--   * Left empty on purpose, so the line asks "Kena potongan PPh?": Jasa Profesional and Produksi Konten.
-- This is a working assumption to be confirmed with the tax adviser; a line's own choice always wins over the
-- category, and the category can be changed under Akuntansi > Kategori.
--
-- Existing Entities: only a standard category that has no classification yet is filled; one the OWNER already
-- classified is never touched. New Entities get the same through `provision_default_categories`.

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

update public.categories c
set tax_category_key = m.tax_key
from public.entities e,
     (values
       ('biaya bank', 'wht_none'),
       ('biaya payment gateway', 'wht_none'),
       ('gaji & tunjangan', 'wht_none'),
       ('kantor & umum', 'wht_none'),
       ('perjalanan & transportasi', 'wht_none'),
       ('pengeluaran operasional lainnya', 'wht_none'),
       ('pemasaran & iklan', 'wht_none'),
       ('software & langganan', 'wht_none'),
       ('hosting, domain & cloud', 'wht_none'),
       ('komunikasi & internet', 'wht_none'),
       ('sewa & ruang kerja', 'wht_rent_land_building')
     ) as m (normalized_name, tax_key)
where e.id = c.entity_id and e.entity_type = 'company'
  and c.kind = 'expense' and c.tax_category_key is null and c.normalized_name = m.normalized_name;
