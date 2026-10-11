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
