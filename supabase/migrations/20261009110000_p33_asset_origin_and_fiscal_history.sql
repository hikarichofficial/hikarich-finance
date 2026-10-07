-- P33 (decision 343, owner request): assets bought used, fiscal groups for assets of any age, more fixed-asset accounts.
--   1. The fiscal groups (Art. 11 UU PPh) were stored from 1 January 2020 only, so an asset put in service before
--      that date was refused with "the fiscal class is unknown". The owner asked for no such limit. The statutory
--      groups (4, 8, 16, 20 years; buildings 20 and 10; land not depreciated) have the same lives and rates since the
--      income tax law of 1983 and its amendments, so version 2 of the same rule applies to every date before 2020 with
--      the same values. An asset keeps the version in force on its in-service date; nothing already recorded changes.
--   2. An asset records whether it was bought new or used, and its year of manufacture. The year is a fact kept on
--      the asset; the remaining useful life of a used asset is worked out by the form and sent as the useful life.
--      The fiscal group keeps the full life of the group (the tax rules do not shorten it for a used asset).

insert into public.tax_rule_versions
  (family, code, rule_version, effective_from, params, source_title, source_ref, source_url, verified_on,
   verification_status, status, published_at, notes)
select family, code, 2, date '1900-01-01', params,
       'UU PPh Pasal 11 (UU 7/1983 and its amendments up to UU 36/2008): the depreciation groups, unchanged in lives and rates',
       'UU PPh Pasal 11 (UU 36/2008); PMK-96/PMK.03/2009 (groups of tangible assets other than buildings)',
       source_url, date '2026-10-07', 'verified', 'published', now(),
       'Same groups and rates as version 1, applied to assets put in service before 1 January 2020, of any age. Added so that an asset owned before 2020 can carry its fiscal group. Confirm against the regulation text with the tax adviser.'
from public.tax_rule_versions
where code = 'FISCAL_DEP_CLASSES' and rule_version = 1
on conflict (code, rule_version) do nothing;

-- ------------------------------------------------------------ what the asset was when it was bought
alter table public.fixed_assets
  add column acquired_condition text not null default 'new' check (acquired_condition in ('new', 'used')),
  add column manufacture_year smallint check (manufacture_year is null or manufacture_year between 1900 and 2100),
  add constraint fixed_assets_used_has_year check (acquired_condition = 'new' or manufacture_year is not null);

-- Opening assets: the loader reads the optional "condition" and "manufacture_year" of each item. Built from the live
-- function by exact text replacement (the FX memo patched it earlier); if the old text is not found, this fails.
do $$
declare
  v_def text;
  v_patch text[][] := array[
    array[E'  v_fx_scale integer;\nbegin',
          E'  v_fx_scale integer;\n  v_cond text;\n  v_year integer;\nbegin'],
    array[E'    v_id := gen_random_uuid();\n    v_code := app_private.allocate_document_number(p_entity, ''asset'', v_acq);',
          E'    v_cond := coalesce(nullif(btrim(coalesce(v_item ->> ''condition'', '''')), ''''), ''new'');\n'
       || E'    begin\n      v_year := nullif(btrim(coalesce(v_item ->> ''manufacture_year'', '''')), '''')::integer;\n'
       || E'    exception when others then\n      raise exception ''INVALID: the year of manufacture of % is not a number'', v_item ->> ''name'' using errcode = ''invalid_parameter_value'';\n    end;\n'
       || E'    if v_cond not in (''new'', ''used'') then\n      raise exception ''INVALID: the condition of % is new or used'', v_item ->> ''name'' using errcode = ''invalid_parameter_value'';\n    end if;\n'
       || E'    if v_year is not null and v_year not between 1900 and extract(year from v_acq)::integer then\n'
       || E'      raise exception ''INVALID: the year of manufacture of % is before 1900 or after the year it was bought'', v_item ->> ''name'' using errcode = ''invalid_parameter_value'';\n    end if;\n'
       || E'    if v_cond = ''used'' and v_year is null then\n      raise exception ''INVALID: % was bought used, so its year of manufacture is needed'', v_item ->> ''name'' using errcode = ''invalid_parameter_value'';\n    end if;\n'
       || E'    v_id := gen_random_uuid();\n    v_code := app_private.allocate_document_number(p_entity, ''asset'', v_acq);'],
    array[E'fx_currency, fx_cost, fx_rate,\n       activated_at, activated_by, created_by)',
          E'fx_currency, fx_cost, fx_rate, acquired_condition, manufacture_year,\n       activated_at, activated_by, created_by)'],
    array[E'v_fx_currency, v_fx_cost, v_fx_rate, now(), auth.uid(), auth.uid());',
          E'v_fx_currency, v_fx_cost, v_fx_rate, v_cond, v_year, now(), auth.uid(), auth.uid());']
  ];
  i integer;
begin
  v_def := pg_catalog.pg_get_functiondef('public.asset_load_opening(uuid, text, jsonb)'::regprocedure);
  for i in 1 .. array_length(v_patch, 1) loop
    if position(v_patch[i][1] in v_def) = 0 then
      raise exception 'p33 patch % not found in asset_load_opening', i;
    end if;
    v_def := replace(v_def, v_patch[i][1], v_patch[i][2]);
  end loop;
  execute v_def;

  -- the asset detail shows the two new facts
  v_def := pg_catalog.pg_get_functiondef('public.asset_detail(uuid)'::regprocedure);
  if position('''plan_version'', a.plan_version, ''fiscal_class_key'', a.fiscal_class_key,' in v_def) = 0 then
    raise exception 'p33 patch not found in asset_detail';
  end if;
  v_def := replace(v_def, '''plan_version'', a.plan_version, ''fiscal_class_key'', a.fiscal_class_key,',
                   '''acquired_condition'', a.acquired_condition, ''manufacture_year'', a.manufacture_year, ''plan_version'', a.plan_version, ''fiscal_class_key'', a.fiscal_class_key,');
  execute v_def;
end
$$;

-- A draft asset (from a purchase line) or an active one can have its origin recorded or corrected.
create function public.asset_set_origin(p_asset uuid, p_condition text, p_year integer default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  a public.fixed_assets%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into a from public.fixed_assets where id = p_asset;
  if not found or not app_authz.has_permission(a.entity_id, 'assets.manage') then
    raise exception 'FORBIDDEN: changing an asset needs assets.manage' using errcode = 'insufficient_privilege';
  end if;
  if p_condition not in ('new', 'used') then
    raise exception 'INVALID: the condition is new or used' using errcode = 'invalid_parameter_value';
  end if;
  if p_year is not null and p_year not between 1900 and extract(year from a.acquisition_date)::integer then
    raise exception 'INVALID: the year of manufacture is before 1900 or after the year it was bought' using errcode = 'invalid_parameter_value';
  end if;
  if p_condition = 'used' and p_year is null then
    raise exception 'INVALID: an asset bought used needs its year of manufacture' using errcode = 'invalid_parameter_value';
  end if;
  select * into a from public.fixed_assets where id = p_asset for update;
  if a.status = 'cancelled' then
    raise exception 'CONFLICT: a cancelled asset cannot change' using errcode = 'integrity_constraint_violation';
  end if;
  update public.fixed_assets set acquired_condition = p_condition, manufacture_year = p_year where id = a.id;
  perform app_private.asset_event(a.id, 'details_changed', app_private.entity_today(a.entity_id),
    jsonb_build_object('condition', p_condition, 'manufacture_year', p_year));
end
$$;

revoke all on function public.asset_set_origin(uuid, text, integer) from public, anon;
grant execute on function public.asset_set_origin(uuid, text, integer) to authenticated;

-- ------------------------------------------------------------ more asset accounts (owner request, 7 and 8 October 2026)
-- The default chart had three fixed-asset accounts. Land, buildings, vehicles, machinery and the other usual kinds of
-- fixed asset now each get their own account under the same group (1500), so nothing is lumped into "Aset Tetap
-- Lainnya". They have no system key: the database already accepts any account beside the built-in ones under the same
-- group as a fixed-asset cost account, so assets, purchases and the asset control treat them like the others. They are
-- control accounts (no manual journals), because they are fed by the asset register. Accumulated depreciation stays
-- one account (1590); the register keeps the figure per asset.
--
-- Two further groups hold things that are NOT fixed assets but are often asked for next to them: intangible assets
-- (software, brand, website; 1600) and long-term investments (term deposits over three months, shares, bonds, gold;
-- 1700). They sit outside group 1500 on purpose (the asset register, its depreciation plan and the asset control do not
-- apply to them) and accept manual journals; amortisation and revaluation of them are booked by journal.
insert into public.coa_template_accounts
  (template_key, code, name, account_class, normal_balance, system_key, parent_code, is_group, is_control, allows_manual_posting)
values
  -- money held with a broker or trading platform, and crypto (not fixed assets; booked by journal)
  ('company_default', '1220', 'Dana di Pialang & Platform Trading (forex, saham, kripto)', 'asset', 'debit', null, null, false, false, true),
  ('company_default', '1230', 'Aset Kripto', 'asset', 'debit', null, null, false, false, true),
  -- land and buildings
  ('company_default', '1501', 'Tanah', 'asset', 'debit', null, '1500', false, true, false),
  ('company_default', '1502', 'Bangunan Permanen (gedung, ruko, rumah, kantor)', 'asset', 'debit', null, '1500', false, true, false),
  ('company_default', '1503', 'Bangunan Tidak Permanen (semi permanen, kayu, bongkar-pasang)', 'asset', 'debit', null, '1500', false, true, false),
  ('company_default', '1504', 'Renovasi Bangunan Sewa', 'asset', 'debit', null, '1500', false, true, false),
  ('company_default', '1505', 'Instalasi, Jaringan & Prasarana (listrik, air, pagar, jalan, parkir)', 'asset', 'debit', null, '1500', false, true, false),
  -- equipment and machinery
  ('company_default', '1511', 'Peralatan Komunikasi & Keamanan (telepon, router, CCTV)', 'asset', 'debit', null, '1500', false, true, false),
  ('company_default', '1512', 'Peralatan Studio, Foto, Video & Audio', 'asset', 'debit', null, '1500', false, true, false),
  ('company_default', '1513', 'Mesin & Peralatan Produksi', 'asset', 'debit', null, '1500', false, true, false),
  ('company_default', '1514', 'Peralatan Toko, Gudang & Dapur', 'asset', 'debit', null, '1500', false, true, false),
  ('company_default', '1515', 'Perkakas & Alat Ukur', 'asset', 'debit', null, '1500', false, true, false),
  ('company_default', '1516', 'Pendingin Ruangan, Genset & Peralatan Listrik', 'asset', 'debit', null, '1500', false, true, false),
  -- vehicles
  ('company_default', '1531', 'Kendaraan Roda Empat (mobil, pick-up, minibus)', 'asset', 'debit', null, '1500', false, true, false),
  ('company_default', '1532', 'Kendaraan Roda Dua (motor)', 'asset', 'debit', null, '1500', false, true, false),
  ('company_default', '1533', 'Truk, Bus & Alat Berat', 'asset', 'debit', null, '1500', false, true, false),
  ('company_default', '1534', 'Kapal, Perahu & Pesawat', 'asset', 'debit', null, '1500', false, true, false),
  -- other
  ('company_default', '1540', 'Aset Dalam Pembangunan', 'asset', 'debit', null, '1500', false, true, false),
  ('company_default', '1550', 'Aset Sewa Guna Usaha (leasing)', 'asset', 'debit', null, '1500', false, true, false),
  ('company_default', '1560', 'Tanaman, Kebun & Ternak Produktif', 'asset', 'debit', null, '1500', false, true, false),
  ('company_default', '1570', 'Barang Seni, Koleksi & Barang Berharga', 'asset', 'debit', null, '1500', false, true, false),
  -- intangible assets (not in the asset register)
  ('company_default', '1600', 'Aset Tidak Berwujud', 'asset', 'debit', null, null, true, false, false),
  ('company_default', '1610', 'Perangkat Lunak & Lisensi', 'asset', 'debit', null, '1600', false, false, true),
  ('company_default', '1620', 'Merek, Hak Cipta & Paten', 'asset', 'debit', null, '1600', false, false, true),
  ('company_default', '1630', 'Pengembangan Website & Aplikasi', 'asset', 'debit', null, '1600', false, false, true),
  ('company_default', '1640', 'Aset Tidak Berwujud Lainnya', 'asset', 'debit', null, '1600', false, false, true),
  ('company_default', '1690', 'Akumulasi Amortisasi', 'contra_asset', 'credit', null, '1600', false, false, true),
  -- long-term investments (not in the asset register)
  ('company_default', '1700', 'Investasi Jangka Panjang', 'asset', 'debit', null, null, true, false, false),
  ('company_default', '1710', 'Deposito Berjangka (lebih dari 3 bulan)', 'asset', 'debit', null, '1700', false, false, true),
  ('company_default', '1720', 'Penyertaan Saham & Modal pada Perusahaan Lain', 'asset', 'debit', null, '1700', false, false, true),
  ('company_default', '1730', 'Obligasi & Surat Berharga', 'asset', 'debit', null, '1700', false, false, true),
  ('company_default', '1740', 'Reksa Dana', 'asset', 'debit', null, '1700', false, false, true),
  ('company_default', '1750', 'Logam Mulia (emas)', 'asset', 'debit', null, '1700', false, false, true),
  ('company_default', '1760', 'Properti Investasi (tanah atau bangunan yang disewakan)', 'asset', 'debit', null, '1700', false, false, true),
  ('company_default', '1790', 'Investasi Jangka Panjang Lainnya', 'asset', 'debit', null, '1700', false, false, true)
on conflict (template_key, code) do nothing;

-- Income, gain/loss and cost accounts for the investments above (owner request, 8 October 2026): dividends, interest
-- and yield, forex, crypto, shares, gold, valuation, broker fees and the final tax withheld on them. Gains and losses
-- of one kind share one account of the class "other" (like 7300 and 7400): a gain is a credit and a loss a debit.
-- All accept manual journals and have no system key, so they are chosen like any other account in the journal form.
insert into public.coa_template_accounts
  (template_key, code, name, account_class, normal_balance, system_key, parent_code, is_group, is_control, allows_manual_posting)
values
  -- income
  ('company_default', '7110', 'Pendapatan Dividen', 'other_income', 'credit', null, null, false, false, true),
  ('company_default', '7120', 'Pendapatan Sewa Properti Investasi', 'other_income', 'credit', null, null, false, false, true),
  ('company_default', '7130', 'Pendapatan Imbal Hasil Investasi (sukuk, obligasi, reksa dana)', 'other_income', 'credit', null, null, false, false, true),
  ('company_default', '7140', 'Pendapatan Bonus, Cashback & Rebate Broker/Platform', 'other_income', 'credit', null, null, false, false, true),
  ('company_default', '7150', 'Pendapatan Kripto (staking, airdrop, mining)', 'other_income', 'credit', null, null, false, false, true),
  ('company_default', '7160', 'Pendapatan Investasi Lainnya', 'other_income', 'credit', null, null, false, false, true),
  -- gains and losses
  ('company_default', '7320', 'Laba/Rugi Trading Forex', 'other', 'debit', null, null, false, false, true),
  ('company_default', '7330', 'Laba/Rugi Aset Kripto', 'other', 'debit', null, null, false, false, true),
  ('company_default', '7340', 'Laba/Rugi Penjualan Saham, Reksa Dana & Obligasi', 'other', 'debit', null, null, false, false, true),
  ('company_default', '7350', 'Laba/Rugi Logam Mulia (emas)', 'other', 'debit', null, null, false, false, true),
  ('company_default', '7360', 'Laba/Rugi Penjualan Investasi Lainnya', 'other', 'debit', null, null, false, false, true),
  ('company_default', '7370', 'Laba/Rugi Penilaian Ulang Investasi (belum direalisasi)', 'other', 'debit', null, null, false, false, true),
  ('company_default', '7380', 'Laba/Rugi Properti Investasi', 'other', 'debit', null, null, false, false, true),
  -- costs
  ('company_default', '7210', 'Beban Komisi, Spread & Biaya Transaksi Broker', 'other_expense', 'debit', null, null, false, false, true),
  ('company_default', '7220', 'Beban Swap & Biaya Margin (forex)', 'other_expense', 'debit', null, null, false, false, true),
  ('company_default', '7230', 'Beban Biaya Jaringan & Exchange Kripto', 'other_expense', 'debit', null, null, false, false, true),
  ('company_default', '7240', 'Beban Penurunan Nilai Investasi', 'other_expense', 'debit', null, null, false, false, true),
  ('company_default', '6710', 'Beban Amortisasi (aset tidak berwujud)', 'expense', 'debit', null, null, false, false, true),
  ('company_default', '8300', 'Beban Pajak Final Penghasilan Investasi (bunga, dividen, kripto)', 'tax', 'debit', null, null, false, false, true)
on conflict (template_key, code) do nothing;

select app_private.provision_default_coa(e.id) from public.entities e where e.entity_type = 'company' and e.status = 'active';
