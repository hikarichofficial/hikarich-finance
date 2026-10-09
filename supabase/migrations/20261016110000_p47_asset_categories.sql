-- P47 (owner, 9 October 2026): "kategori pada catat pengeluaran kenapa tidak ada satupun ... buatkan yang paling lengkap
-- dan maksimal". On an expense line the Perlakuan "Aset" (and "Biaya dibayar di muka") only offers categories of kind
-- 'asset', and no Entity had a single one: only expense and revenue categories were ever provisioned, so buying a phone or
-- a laptop showed "Belum ada kategori". The database requires kind 'asset' for both treatments (purchase_prepare_lines),
-- so both kinds of asset category live under it, each tied to the account it must post to:
--   * fixed assets -> the fixed-asset accounts of the chart (computers, communication/security, studio, machines, shop and
--     kitchen equipment, tools, AC/genset, furniture, the four vehicle classes, land, buildings, renovation, installations,
--     construction in progress, leasing, plantations, art), found by account code (most have no system key);
--   * prepaid -> Biaya Dibayar di Muka (1300) and Uang Muka & Deposit (1310); their names start with "Dibayar di Muka" /
--     "Deposit" / "Uang Muka" so they are not mistaken for a fixed asset.
-- Personal books get the few that apply. A name already used (any kind) is left alone; accounts that do not exist in an
-- Entity's chart are skipped. Existing Entities receive them now; new Entities through provision_default_coa.
create function app_private.provision_asset_categories(p_entity uuid) returns integer
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
      -- Company: fixed assets
      ('company', 'Laptop, Komputer & Tablet', 'code', '1510', 310),
      ('company', 'Smartphone & Gadget', 'code', '1510', 311),
      ('company', 'Printer, Scanner & Periferal', 'code', '1510', 312),
      ('company', 'Server, Hard Disk & Perangkat Penyimpanan', 'code', '1510', 313),
      ('company', 'Telepon, Router & CCTV', 'code', '1511', 314),
      ('company', 'Kamera, Lensa, Mikrofon & Peralatan Studio', 'code', '1512', 315),
      ('company', 'Mesin & Peralatan Produksi', 'code', '1513', 316),
      ('company', 'Peralatan Toko, Gudang & Dapur', 'code', '1514', 317),
      ('company', 'Perkakas & Alat Ukur', 'code', '1515', 318),
      ('company', 'AC, Genset & Peralatan Listrik', 'code', '1516', 319),
      ('company', 'Peralatan Kantor', 'code', '1520', 320),
      ('company', 'Meja, Kursi & Furnitur Kantor', 'code', '1520', 321),
      ('company', 'Mobil & Kendaraan Roda Empat', 'code', '1531', 322),
      ('company', 'Motor & Kendaraan Roda Dua', 'code', '1532', 323),
      ('company', 'Truk, Bus & Alat Berat', 'code', '1533', 324),
      ('company', 'Kapal, Perahu & Pesawat', 'code', '1534', 325),
      ('company', 'Tanah', 'code', '1501', 326),
      ('company', 'Bangunan Permanen', 'code', '1502', 327),
      ('company', 'Bangunan Tidak Permanen', 'code', '1503', 328),
      ('company', 'Renovasi Bangunan Sewa', 'code', '1504', 329),
      ('company', 'Instalasi, Jaringan & Prasarana', 'code', '1505', 330),
      ('company', 'Aset Dalam Pembangunan', 'code', '1540', 331),
      ('company', 'Aset Sewa Guna Usaha (Leasing)', 'code', '1550', 332),
      ('company', 'Tanaman, Kebun & Ternak Produktif', 'code', '1560', 333),
      ('company', 'Barang Seni, Koleksi & Barang Berharga', 'code', '1570', 334),
      ('company', 'Aset Tetap Lainnya', 'key', 'FIXED_ASSET_OTHER', 339),
      -- Company: prepaid expenses and deposits
      ('company', 'Dibayar di Muka: Sewa', 'key', 'PREPAID_EXPENSE', 340),
      ('company', 'Dibayar di Muka: Asuransi', 'key', 'PREPAID_EXPENSE', 341),
      ('company', 'Dibayar di Muka: Langganan & Lisensi Tahunan', 'key', 'PREPAID_EXPENSE', 342),
      ('company', 'Dibayar di Muka: Iklan & Pemasaran', 'key', 'PREPAID_EXPENSE', 343),
      ('company', 'Dibayar di Muka: Jasa & Kontrak', 'key', 'PREPAID_EXPENSE', 344),
      ('company', 'Biaya Dibayar di Muka Lainnya', 'key', 'PREPAID_EXPENSE', 349),
      ('company', 'Uang Muka ke Vendor', 'key', 'ADVANCES_DEPOSITS', 350),
      ('company', 'Deposit Sewa & Jaminan', 'key', 'ADVANCES_DEPOSITS', 351),
      ('company', 'Deposit Listrik, Air & Layanan', 'key', 'ADVANCES_DEPOSITS', 352),
      -- Personal
      ('personal', 'Kendaraan Pribadi', 'key', 'PERSONAL_FIXED_ASSET', 310),
      ('personal', 'Elektronik & Gadget', 'key', 'PERSONAL_FIXED_ASSET', 311),
      ('personal', 'Perabot & Perlengkapan Rumah', 'key', 'PERSONAL_FIXED_ASSET', 312),
      ('personal', 'Properti & Renovasi Rumah', 'key', 'PERSONAL_FIXED_ASSET', 313),
      ('personal', 'Barang Berharga & Koleksi', 'key', 'PERSONAL_FIXED_ASSET', 314),
      ('personal', 'Aset Pribadi Lainnya', 'key', 'PERSONAL_FIXED_ASSET', 319),
      ('personal', 'Dibayar di Muka: Sewa & Langganan', 'key', 'PREPAID_DEPOSIT', 340),
      ('personal', 'Deposit & Uang Muka', 'key', 'PREPAID_DEPOSIT', 341)
    ) as t (entity_type, name, lookup, ref, sort_order)
    where t.entity_type = v_type
  loop
    if exists (select 1 from public.categories c
               where c.entity_id = p_entity
                 and c.normalized_name = lower(regexp_replace(btrim(r.name), '\s+', ' ', 'g'))) then
      continue;
    end if;
    select a.id into v_account from public.ledger_accounts a
    where a.entity_id = p_entity and a.status = 'active' and not a.is_group
      and case r.lookup when 'code' then a.code = r.ref else a.system_key = r.ref end;
    if v_account is null then
      continue;
    end if;
    insert into public.categories (entity_id, name, kind, sort_order)
    values (p_entity, r.name, 'asset', r.sort_order)
    returning id into v_cat;
    insert into public.category_account_mappings
      (entity_id, category_id, context, debit_ledger_account_id, effective_from)
    values (p_entity, v_cat, 'purchases', v_account, date '2000-01-01');
    v_count := v_count + 1;
  end loop;
  return v_count;
end
$$;
revoke all on function app_private.provision_asset_categories(uuid) from public;

-- New Entities: the same call next to the other category sets (patched in place, count-checked).
do $patch$
declare
  v_def text;
  v_old constant text := E'  perform app_private.provision_personal_tax_categories(p_entity);';
  v_new constant text := v_old || E'\n  perform app_private.provision_asset_categories(p_entity);';
begin
  v_def := pg_get_functiondef('app_private.provision_default_coa(uuid)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'P47: expected exactly one patch point in provision_default_coa';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

-- The Entities that already exist.
select app_private.provision_asset_categories(e.id) from public.entities e;
