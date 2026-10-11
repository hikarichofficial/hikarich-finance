# Mengosongkan produksi sebelum go-live

Dokumen ini sengaja ditulis dalam bahasa Indonesia, berbeda dari dokumen lain di `docs/`, karena
langkah-langkahnya dijalankan sendiri oleh OWNER di layar Supabase dan GitHub — bukan oleh kode dan
bukan oleh sesi Claude.

**Setiap langkah di bawah menghapus data secara permanen dan tidak bisa dibatalkan.** Tidak ada
"undo", tidak ada keranjang sampah. Jalankan hanya kalau Anda memang ingin membuang seluruh hasil uji
coba. Claude tidak menjalankan langkah penghapusan ini atas nama Anda.

Proyek produksi: `hikarich-finance-prod` (`yvuakaxwgwfjyvjmvpbn`).

## Sebelum mulai: ambil cadangan

Walaupun datanya hanya uji coba, ambil cadangan dulu. Satu langkah, dan menjadi jaring kalau ternyata
ada satu angka yang masih Anda butuhkan.

1. Masuk ke aplikasi → **Administrasi → Backup** → unduh **Full backup**.
2. Simpan berkasnya di luar Supabase dan Vercel (komputer Anda sendiri).

## Cara 1 — Bangun ulang database (disarankan)

Ini yang membuat sistem betul-betul seperti hari pertama: nomor faktur mulai dari satu lagi, nomor
jurnal dari satu lagi, jejak audit kosong, tidak ada sisa baris di mana pun. Seluruh data referensi
sistem kembali sendiri karena memang dibuat oleh migration.

### Langkah 1 — Hapus skema aplikasinya

Supabase → proyek `hikarich-finance-prod` → **SQL Editor** → jalankan:

```sql
drop schema if exists public cascade;
drop schema if exists app_private cascade;
drop schema if exists app_authz cascade;

create schema public;
grant usage on schema public to anon, authenticated, service_role;
grant all on schema public to postgres;

-- Supaya CLI tahu belum ada migration yang terpasang, dan memasang semuanya dari awal.
delete from supabase_migrations.schema_migrations;
```

Yang TIDAK tersentuh: skema `auth` (akun login dan authenticator Anda tetap ada) dan `storage`
(berkas lampiran, dibersihkan di langkah 3).

### Langkah 2 — Pasang ulang seluruh migration

GitHub → repositori → **Actions** → **Production migrations** → **Run workflow** (branch `main`).

Tunggu sampai hijau. Workflow ini butuh dua secret yang sudah Anda isi sebelumnya
(`SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD`); kalau belum, lihat `docs/GO_LIVE.md` bagian 1.
Berkas seed tidak pernah dipakai di produksi.

Setelah hijau, database punya skema lengkap dan seluruh data referensi sistem: aturan pajak, katalog
izin, jenis dokumen, dan kategori serta COA bawaan (dipasang per Entity saat Entity dibuat).

### Langkah 3 — Kosongkan berkas lampiran

Supabase → **Storage** → bucket `documents` → pilih semua → hapus. Berkas yang diunggah saat uji coba
tidak ikut terhapus oleh langkah 1, karena tersimpan di luar database.

### Langkah 4 — Siapkan lagi dari awal

Ikuti `docs/GO_LIVE.md` bagian 2 sampai 4, yang memang urutan hari pertama:

1. Entity dibuat lagi (`pt` dan `hikarich`) — kodenya boleh sama seperti sebelumnya, karena data
   lamanya sudah tidak ada.
2. `select app_private.bootstrap_owner('<id user auth Anda>', '<nama tampilan>')` dijalankan sekali.
   Akun login Anda masih ada dari sebelumnya, jadi tidak perlu dibuat ulang — yang perlu dibuat ulang
   hanya keanggotaannya, karena itu tersimpan di database yang baru saja dikosongkan.
3. Pajak → Pengaturan Pajak: profil wajib pajak tiap Entity, lalu aktifkan mesin pajaknya.
4. Kas & Bank, Saldo Awal, Aset yang Sudah Dimiliki — isi dengan angka yang sebenarnya.

### Yang hilang dan tidak kembali sendiri

- **Kategori yang Anda buat sendiri.** Kategori bawaan kembali otomatis; yang Anda tambahkan sendiri
  (misalnya "Penjualan Ebook") perlu dibuat lagi. Catat dulu namanya sebelum langkah 1 kalau ada.
- **Jenis lampiran yang Anda buat sendiri**, pelanggan, vendor, produk, akun kas dan bank, kanal
  pembayaran, karyawan — semuanya data Anda, jadi semuanya hilang dan diisi lagi dengan data
  sebenarnya.

## Cara 2 — Kosongkan datanya saja, skema tetap

Dipakai kalau Anda ingin menyimpan kategori, pelanggan, vendor atau produk yang sudah diisi, dan
hanya ingin membuang transaksinya.

Ini lebih rumit dan lebih berisiko daripada Cara 1, dan hasilnya bukan "seperti baru":

- Setiap tabel transaksi punya pemicu `tg_forbid_delete` dan `tg_forbid_update` yang sengaja menolak
  penghapusan — itu memang dirancang begitu, supaya pembukuan tidak bisa dihapus diam-diam. Untuk
  menghapus, pemicunya harus dimatikan dulu, satu per satu, lalu dinyalakan lagi. Satu yang lupa
  dinyalakan berarti pembukuan Anda kehilangan pengamannya tanpa Anda sadari.
- Penghapusan harus berurutan mengikuti ketergantungan antar tabel (alokasi pembayaran sebelum
  pembayaran, baris jurnal sebelum jurnal, dan seterusnya).
- Nomor dokumen dan nomor jurnal tetap lanjut dari nomor terakhir, kecuali penghitungnya juga
  disetel ulang.

Kalau ini yang Anda pilih, minta Claude menyiapkan skripnya lebih dulu, dengan daftar tabel dan
urutannya. Jangan menyusunnya sambil jalan di layar SQL produksi.

## Setelah selesai

Periksa di aplikasi: Dasbor kosong, daftar faktur kosong, Buku Besar kosong, dan Pengaturan sudah
berisi nama Entity yang benar. Lalu ambil **Full backup** pertama dari sistem yang masih bersih,
sebagai titik awal.

## Cara 3 — bangun ulang, tetapi Entity dan pengaturannya kembali sendiri

Dipakai setelah sistem sudah pernah disiapkan: transaksinya dibuang, tetapi Entity, profil Entity
(alamat, kontak, logo), profil pajak, mesin pajak, rekening kas/bank dan keanggotaan OWNER tetap ada
tanpa diisi ulang.

Caranya: baris yang harus bertahan disalin ke schema `restore_tmp` lebih dulu. Schema itu di luar
`public`, jadi selamat dari penghapusan, lalu dikembalikan setelah migration dipasang ulang. Logo dan
nomor rekening ikut pindah apa adanya — tidak pernah dilihat, dibaca, atau diketik ulang siapa pun.

Dua hal perlu dipetakan ulang saat dikembalikan, karena migration membuat id baru untuknya: peran
(lewat `role_key`) dan akun buku besar sebuah rekening (lewat kode akun). Entity sendiri dimasukkan
dengan **id aslinya**, sehingga semua yang menunjuk ke Entity tetap cocok.

### Langkah 1 — Simpan yang harus bertahan

```sql
create schema if not exists restore_tmp;

create table restore_tmp.entities as select * from public.entities;
create table restore_tmp.profiles as select * from public.profiles;
create table restore_tmp.memberships as
  select m.entity_id, m.user_id, r.role_key, m.status
  from public.entity_memberships m join public.roles r on r.id = m.role_id;
create table restore_tmp.entity_profiles as select * from public.entity_profiles;
create table restore_tmp.entity_settings as select * from public.entity_settings;
create table restore_tmp.financial_accounts as
  select a.*, la.code as ledger_code
  from public.financial_accounts a
  left join public.ledger_accounts la on la.id = a.ledger_account_id;
create table restore_tmp.tax_entity_profiles as select * from public.tax_entity_profiles;
create table restore_tmp.tax_settings as select * from public.tax_settings;
```

### Langkah 2 — Hapus skema dan riwayat migration

Sama persis dengan Cara 1 langkah 1. `restore_tmp` tidak ikut terhapus.

### Langkah 3 — Pasang ulang migration

Sama dengan Cara 1 langkah 2: Actions → Production migrations → Run workflow.

### Langkah 4 — Kembalikan

```sql
insert into public.entities select * from restore_tmp.entities;

select e.code, app_private.provision_default_coa(e.id) from public.entities e order by e.code;

insert into public.profiles select * from restore_tmp.profiles on conflict (id) do nothing;

insert into public.entity_memberships (entity_id, user_id, role_id, status)
select m.entity_id, m.user_id, r.id, m.status
from restore_tmp.memberships m join public.roles r on r.role_key = m.role_key;

insert into public.entity_profiles select * from restore_tmp.entity_profiles;
insert into public.entity_settings select * from restore_tmp.entity_settings;

insert into public.financial_accounts
  (id, entity_id, kind, name, institution_name, account_number, account_holder, currency,
   ledger_account_id, is_active, created_at, created_by, updated_at, updated_by, version,
   deleted_at, account_number_masked)
select a.id, a.entity_id, a.kind, a.name, a.institution_name, a.account_number, a.account_holder,
       a.currency, la.id, a.is_active, a.created_at, a.created_by, a.updated_at, a.updated_by,
       a.version, a.deleted_at, a.account_number_masked
from restore_tmp.financial_accounts a
left join public.ledger_accounts la on la.entity_id = a.entity_id and la.code = a.ledger_code;

insert into public.tax_entity_profiles select * from restore_tmp.tax_entity_profiles;
insert into public.tax_settings select * from restore_tmp.tax_settings;

drop schema restore_tmp cascade;
```

### Yang tetap hilang

Seluruh transaksi: jurnal dan barisnya, mutasi kas, faktur, pengeluaran, periode akuntansi, kontak,
produk, dokumen beserta berkas di bucket `documents`, dan jejak audit. Itu memang yang dibuang.
