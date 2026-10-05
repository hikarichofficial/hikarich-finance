-- OWNER, 5 October 2026: "untuk terjemahan nama akun, sebaiknya disesuaikan dengan penggunaan bahasa
-- indonesia. tapi jangan mengurangi makna, atau jangan terlalu nama yang berbelit karena terjemahkan
-- semua kata." -- the default chart-of-accounts names become natural Indonesian accounting terms
-- (Piutang Usaha, Utang Usaha, Laba Ditahan, Beban ...), short, and no longer a word-for-word translation.
--
-- Names only. Codes, classes, normal balances and system keys are untouched, and posting never reads a
-- name (Step 04 §16), so no journal, report or tax computation changes. Two steps, in this order:
--   1. Existing ledger accounts are renamed ONLY where the name is still the old default of the template.
--      An account the OWNER renamed or created herself (for example 1121 "Mandiri Bisnis HKD") is kept.
--   2. The template names are replaced, so an Entity created from now on starts in Indonesian.
-- Idempotent: after the first run no ledger name equals a template name that differs from the new one.

create temporary table coa_name_map (template_key text, code text, new_name text) on commit drop;

insert into coa_name_map (template_key, code, new_name) values
  -- ---------------- PT (company_default)
  ('company_default', '1100', 'Kas dan Setara Kas'),
  ('company_default', '1110', 'Kas Tunai'),
  ('company_default', '1120', 'Rekening Operasional BCA'),
  ('company_default', '1190', 'Bank & Dompet Digital Lainnya'),
  ('company_default', '1200', 'Piutang Usaha'),
  ('company_default', '1210', 'Piutang Lain-lain'),
  ('company_default', '1300', 'Biaya Dibayar di Muka'),
  ('company_default', '1310', 'Uang Muka & Deposit'),
  ('company_default', '1400', 'Pajak Dibayar di Muka'),
  ('company_default', '1500', 'Aset Tetap'),
  ('company_default', '1510', 'Komputer & Peralatan Elektronik'),
  ('company_default', '1520', 'Furnitur & Perlengkapan Kantor'),
  ('company_default', '1530', 'Aset Tetap Lainnya'),
  ('company_default', '1590', 'Akumulasi Penyusutan'),
  ('company_default', '2100', 'Utang Usaha'),
  ('company_default', '2110', 'Utang Lain-lain'),
  ('company_default', '2120', 'Utang Dividen'),
  ('company_default', '2200', 'Utang Pajak'),
  ('company_default', '2210', 'Utang Gaji & Karyawan'),
  ('company_default', '2220', 'Utang BPJS Ketenagakerjaan'),
  ('company_default', '2221', 'Utang BPJS Kesehatan'),
  ('company_default', '2300', 'Pinjaman Jangka Pendek'),
  ('company_default', '2400', 'Pinjaman Jangka Panjang'),
  ('company_default', '2500', 'Uang Muka Pelanggan'),
  ('company_default', '3100', 'Modal Disetor'),
  ('company_default', '3200', 'Tambahan Modal'),
  ('company_default', '3300', 'Laba Ditahan'),
  ('company_default', '3400', 'Laba Tahun Berjalan'),
  ('company_default', '4100', 'Pendapatan Produk Digital'),
  ('company_default', '4110', 'Pendapatan E-book'),
  ('company_default', '4120', 'Pendapatan Software & Alat Digital'),
  ('company_default', '4190', 'Pendapatan Usaha Lainnya'),
  ('company_default', '4200', 'Diskon & Retur Penjualan'),
  ('company_default', '5100', 'Biaya Langsung Produk & Pengiriman'),
  ('company_default', '5200', 'Biaya Payment Gateway'),
  ('company_default', '6100', 'Beban Pemasaran & Iklan'),
  ('company_default', '6110', 'Beban Produksi Konten'),
  ('company_default', '6200', 'Beban Software & Langganan'),
  ('company_default', '6210', 'Beban Hosting, Domain & Cloud'),
  ('company_default', '6300', 'Beban Administrasi Bank'),
  ('company_default', '6400', 'Beban Jasa Profesional'),
  ('company_default', '6500', 'Beban Kantor & Umum'),
  ('company_default', '6510', 'Beban Komunikasi & Internet'),
  ('company_default', '6520', 'Beban Perjalanan & Transportasi'),
  ('company_default', '6600', 'Beban Gaji & Tunjangan'),
  ('company_default', '6610', 'Beban BPJS & Biaya Karyawan Lain'),
  ('company_default', '6700', 'Beban Penyusutan'),
  ('company_default', '6800', 'Beban Sewa & Ruang Kerja'),
  ('company_default', '6900', 'Beban Operasional Lainnya'),
  ('company_default', '6950', 'Beban Piutang Tak Tertagih'),
  ('company_default', '7100', 'Pendapatan Bunga'),
  ('company_default', '7190', 'Pendapatan Lain-lain'),
  ('company_default', '7200', 'Beban Bunga'),
  ('company_default', '7290', 'Beban Lain-lain'),
  ('company_default', '7300', 'Laba/Rugi Selisih Kurs'),
  ('company_default', '7310', 'Selisih Pembulatan'),
  ('company_default', '7400', 'Laba/Rugi Pelepasan Aset'),
  ('company_default', '8100', 'Beban Pajak Penghasilan'),
  ('company_default', '8200', 'Denda & Beban Pajak Lainnya'),
  ('company_default', '8900', 'Penampung Saldo Awal'),
  -- ---------------- Personal (personal_default)
  ('personal_default', '1100', 'Kas dan Setara Kas'),
  ('personal_default', '1110', 'Kas Tunai'),
  ('personal_default', '1120', 'Rekening Bank Pribadi'),
  ('personal_default', '1190', 'Dompet Digital & Kas Lainnya'),
  ('personal_default', '1200', 'Piutang Pribadi'),
  ('personal_default', '1210', 'Piutang Pribadi Lainnya'),
  ('personal_default', '1300', 'Deposit & Uang Muka'),
  ('personal_default', '1400', 'Investasi & Aset Keuangan'),
  ('personal_default', '1500', 'Aset Tetap & Barang Berharga'),
  ('personal_default', '2100', 'Utang Pribadi'),
  ('personal_default', '2110', 'Utang Pribadi Lainnya'),
  ('personal_default', '2200', 'Utang Pajak Pribadi'),
  ('personal_default', '2300', 'Pinjaman Pribadi'),
  ('personal_default', '3100', 'Kekayaan Bersih Awal'),
  ('personal_default', '3200', 'Transfer dari/ke Usaha'),
  ('personal_default', '3300', 'Akumulasi Surplus/Defisit Pribadi'),
  ('personal_default', '4100', 'Gaji & Penghasilan Kerja'),
  ('personal_default', '4200', 'Dividen & Bagi Hasil Usaha'),
  ('personal_default', '4300', 'Bunga & Hasil Investasi'),
  ('personal_default', '4400', 'Penghasilan Pribadi Lainnya'),
  ('personal_default', '6100', 'Hunian & Sewa'),
  ('personal_default', '6200', 'Makan & Kebutuhan Sehari-hari'),
  ('personal_default', '6300', 'Transportasi & Perjalanan'),
  ('personal_default', '6400', 'Utilitas, Komunikasi & Langganan'),
  ('personal_default', '6500', 'Belanja & Gaya Hidup'),
  ('personal_default', '6600', 'Kesehatan'),
  ('personal_default', '6700', 'Pendidikan & Pengembangan Diri'),
  ('personal_default', '6800', 'Keluarga, Hadiah & Bantuan'),
  ('personal_default', '6900', 'Pengeluaran Pribadi Lainnya'),
  ('personal_default', '7100', 'Laba/Rugi Investasi'),
  ('personal_default', '7200', 'Bunga & Biaya Pinjaman'),
  ('personal_default', '7300', 'Laba/Rugi Selisih Kurs'),
  ('personal_default', '7310', 'Selisih Pembulatan'),
  ('personal_default', '7400', 'Laba/Rugi Pelepasan Aset'),
  ('personal_default', '8100', 'Pajak Penghasilan Pribadi'),
  ('personal_default', '8900', 'Penampung Saldo Awal');

-- 1. Existing accounts: only where the name is still the old default (the template still holds it here).
update public.ledger_accounts la
set name = m.new_name
from public.entities e
join public.coa_templates ct on ct.entity_type = e.entity_type
join public.coa_template_accounts ta on ta.template_key = ct.template_key
join coa_name_map m on m.template_key = ta.template_key and m.code = ta.code
where la.entity_id = e.id
  and la.code = ta.code
  and la.name = ta.name
  and la.name <> m.new_name;

-- 2. Templates: new Entities start in Indonesian.
update public.coa_template_accounts ta
set name = m.new_name
from coa_name_map m
where ta.template_key = m.template_key and ta.code = m.code and ta.name <> m.new_name;
