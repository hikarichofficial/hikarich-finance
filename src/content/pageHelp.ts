/**
 * Penjelasan fungsi setiap halaman dan setiap bagian isian (decision 410, permintaan OWNER 12 Oktober 2026):
 * satu kalimat tentang apa fungsi halaman/bagian itu dan apa dampaknya, di bawah judulnya, dengan penjelasan
 * lebih panjang yang terlipat ("Selengkapnya"). Semua teks ada di SATU berkas ini supaya mudah dibaca dan diubah
 * tanpa membuka layar satu per satu.
 *
 * PAGE_HELP dikunci dengan alamat halaman (tanpa query); bagian yang dinamis ditulis `:id` (uuid). Halaman yang
 * tidak ada di sini tidak menampilkan apa-apa. SECTION_HELP dikunci dengan kunci bagian dan dipakai oleh
 * komponen SectionHelp di bawah judul bagian.
 */
export interface HelpEntry {
  /** Satu atau dua kalimat: fungsi dan dampak. */
  summary: string;
  /** Penjelasan tambahan yang terlipat. */
  more?: string;
}

export const PAGE_HELP: Readonly<Record<string, HelpEntry>> = {
  // ---- Ringkasan
  "/": {
    summary:
      "Gambaran keuangan satu bulan, satu tahun, atau sejak awal: kas, pendapatan, beban, laba, piutang, utang, dan pajak.",
    more: "Angka dibaca dari jurnal yang sudah diposting, jadi hanya berubah bila ada transaksi yang dicatat. Bulan yang kosong tampil Rp 0; pakai panah atau pilih Tahunan atau Sejak Awal untuk melihat bulan lain.",
  },
  "/cash-snapshot": {
    summary: "Saldo setiap rekening kas dan bank saat ini, dengan status rekonsiliasinya.",
  },
  "/activity": {
    summary: "Daftar transaksi dan perubahan terbaru di buku ini, urut dari yang terbaru.",
  },

  // ---- Penjualan
  "/sales/invoices": {
    summary: "Daftar invoice penjualan beserta statusnya (draf, terbit, dibayar, batal).",
    more: "Invoice yang terbit membentuk piutang dan pendapatan, dan ikut dasar pajak bulan tanggal terbitnya. Draf belum mempengaruhi pembukuan.",
  },
  "/sales/invoices/new": {
    summary:
      "Membuat invoice untuk pelanggan. Setelah diterbitkan, invoice mencatat piutang dan pendapatan secara otomatis.",
    more: "Simpan sebagai draf bila belum final. Pajak (PPN atau PPh) dihitung dari baris invoice saat terbit.",
  },
  "/sales/payments": {
    summary:
      "Pembayaran dari pelanggan atas invoice. Setiap pembayaran menambah saldo rekening dan mengurangi piutang.",
  },
  "/sales/claims": {
    summary:
      "Klaim pembayaran yang dikirim pelanggan lewat halaman invoice publik dan menunggu Anda konfirmasi.",
    more: "Klaim belum mengubah pembukuan. Setelah dikonfirmasi, pembayaran tercatat dan piutang berkurang.",
  },
  "/sales/refunds": {
    summary:
      "Pengembalian uang kepada pelanggan. Mengurangi pendapatan dan saldo rekening sesuai invoice asalnya.",
  },
  "/sales/payment-links": {
    summary: "Tautan pembayaran invoice yang bisa dibagikan ke pelanggan.",
  },
  "/sales/customers": {
    summary: "Daftar pelanggan. Data di sini dipakai sebagai pilihan di invoice dan pembayaran.",
  },
  "/sales/customers/new": {
    summary: "Menambah pelanggan baru agar bisa dipilih saat membuat invoice.",
  },
  "/sales/products": {
    summary:
      "Produk dan jasa yang Anda jual. Nama dan harga di sini muncul sebagai saran saat mengisi baris invoice.",
  },
  "/sales/products/new": {
    summary: "Menambah produk atau jasa beserta harga dan kategori pendapatannya.",
  },
  "/sales/income": {
    summary:
      "Pendapatan yang tidak lewat invoice: penjualan tunai, komisi, bunga bank, dividen, dan sejenisnya.",
    more: "Jumlah pendapatan bulan ini digabung dengan invoice terbit bulan yang sama. Jenis pendapatan menentukan akun yang dikredit dan apakah ikut dasar PPh Final 0,5% atau tidak (bunga, dividen, dan sejenisnya tidak ikut).",
  },
  "/sales/income/new": {
    summary:
      "Mencatat uang masuk tanpa invoice. Sistem membuat jurnalnya sendiri: menambah saldo rekening dan mengkredit akun pendapatan sesuai jenisnya.",
    more: "Pilih jenis pendapatan dengan tepat: Bunga Tabungan dan Bunga Deposito dianggap sudah dipotong PPh final oleh bank, sehingga tidak dihitung lagi di perkiraan PPh tahunan. Catat jumlah yang benar-benar masuk ke rekening.",
  },
  "/sales/marketplace": {
    summary:
      "Pencairan dana dari marketplace: mencatat penjualan dan potongan biaya platform dalam satu entri.",
  },

  // ---- Pembelian
  "/purchases/bills": {
    summary:
      "Tagihan dari vendor yang harus Anda bayar. Tagihan yang diposting membentuk utang usaha dan beban.",
  },
  "/purchases/bills/new": {
    summary: "Mencatat tagihan vendor. Setelah diposting, tagihan menjadi utang sampai dibayar.",
    more: "Pajak yang dipotong (PPh) dan PPN masukan dihitung dari baris tagihan.",
  },
  "/purchases/expenses": {
    summary:
      "Pengeluaran yang langsung dibayar (tanpa tagihan). Setiap pengeluaran mengurangi saldo rekening dan menambah beban.",
  },
  "/purchases/expenses/new": {
    summary:
      "Mencatat pengeluaran yang sudah dibayar. Mengurangi saldo rekening dan menambah beban pada kategorinya.",
    more: "Jangan dipakai untuk membayar pajak ke negara: setoran pajak dicatat lewat Pajak > Pelaporan & Bukti > Catat Pembayaran supaya utang pajaknya ikut tertutup dan tidak terhitung dua kali sebagai beban.",
  },
  "/purchases/payments": {
    summary: "Pembayaran ke vendor atas tagihan. Mengurangi utang usaha dan saldo rekening.",
  },
  "/purchases/vendors": {
    summary: "Daftar vendor, dipakai sebagai pilihan di tagihan dan pengeluaran.",
  },
  "/purchases/vendors/new": { summary: "Menambah vendor baru." },

  // ---- Kas & Bank
  "/money/accounts": {
    summary:
      "Rekening kas dan bank beserta saldonya. Saldo dihitung dari transaksi, bukan diketik manual.",
  },
  "/money/accounts/new": {
    summary:
      "Menambah rekening kas atau bank baru. Uang yang sudah ada di dalamnya dicatat terpisah di Akuntansi > Saldo Awal.",
  },
  "/money/activity": {
    summary: "Semua uang masuk dan keluar di semua rekening, dalam satu daftar.",
  },
  "/money/transfers": {
    summary: "Perpindahan uang antar rekening milik sendiri. Tidak mengubah laba.",
  },
  "/money/transfers/new": {
    summary:
      "Memindahkan uang dari satu rekening ke rekening lain. Saldo keduanya berubah, laba tidak.",
  },
  "/money/reconciliation": {
    summary:
      "Mencocokkan saldo rekening di buku dengan rekening koran bank untuk memastikan tidak ada selisih.",
  },
  "/money/reconciliation/new": {
    summary: "Memulai rekonsiliasi baru untuk satu rekening dan satu periode.",
  },

  // ---- Akuntansi
  "/accounting/journal": {
    summary: "Daftar jurnal: catatan debit dan kredit dari semua transaksi dan jurnal manual.",
    more: "Jurnal yang sudah diposting tidak diubah atau dihapus; koreksi dilakukan dengan jurnal pembalik.",
  },
  "/accounting/journal/new": {
    summary:
      "Membuat jurnal manual untuk hal yang belum punya menu sendiri. Total debit harus sama dengan total kredit.",
  },
  "/accounting/coa": {
    summary:
      "Daftar akun (bagan akun) yang dipakai semua jurnal dan laporan. Nama akun menentukan di mana angka muncul di laporan.",
  },
  "/accounting/categories": {
    summary:
      "Kategori pendapatan dan pengeluaran. Setiap kategori terhubung ke akun dan (bila perlu) aturan pajak.",
  },
  "/accounting/periods": {
    summary: "Periode akuntansi. Periode yang ditutup mengunci transaksi di dalamnya.",
  },
  "/accounting/opening-balances": { summary: "Saldo awal akun saat mulai memakai sistem ini." },
  "/accounting/adjustments": {
    summary: "Penyesuaian saldo lanjutan dengan jejak audit; bukan untuk transaksi harian.",
  },
  "/accounting/statement": {
    summary: "Rekening koran per bulan: mutasi dan saldo berjalan satu akun.",
  },

  // ---- Pajak
  "/tax": {
    summary:
      "Ringkasan seluruh pajak: berapa yang terutang, perkiraan PPh bulan ini dan tahun ini, dan tenggat terdekat.",
    more: "Rekap Pajak dapat difilter per bulan, per tahun, atau seluruhnya sejak awal, hanya untuk dilihat. Angka dibaca dari buku besar pajak; membayar dan melapor dilakukan di Pelaporan & Bukti.",
  },
  "/tax/ledger": {
    summary:
      "Buku besar pajak: setiap pajak yang dihitung (dan dibalik), per masa pajak dan jenisnya.",
  },
  "/tax/calendar": {
    summary: "Kalender tenggat pajak: kapan menghitung, membayar, melapor, dan menyimpan bukti.",
  },
  "/tax/pph": {
    summary: "PPh Final UMKM 0,5% per bulan: omzet, pajak yang dihitung, dan statusnya.",
    more: "Pajak dihitung otomatis dari invoice terbit dan pendapatan usaha. Bulan yang sudah lewat dihitung ulang sendiri bila ada transaksi baru atau terlambat dicatat; bulan berjalan tampil sebagai perkiraan.",
  },
  "/tax/ppn": {
    summary: "PPN keluaran dan masukan per masa pajak, dan selisih yang harus disetor.",
  },
  "/tax/withholding": {
    summary:
      "Pajak yang dipotong dari pembayaran ke pihak lain (PPh 21, 23, 4 ayat 2) per masa pajak.",
  },
  "/tax/filing": {
    summary:
      "Tempat mencatat setoran pajak ke negara, laporan (SPT), dan bukti pendukung untuk satu jenis pajak dan masa.",
    more: "Pembayaran pajak harus dicatat di sini, bukan lewat Beban: sistem menutup utang pajaknya dan menghindari beban ganda. PPh Final UMKM tidak punya laporan bulanan; bukti setoran (NTPN) dianggap SPT Masa, dan laporan tahunan dicatat pada masa Desember.",
  },
  "/tax/payments/:id": {
    summary:
      "Rincian satu pembayaran pajak: jumlah, rekening, NTPN, jurnal, dan bukti setornya (lampiran).",
    more: "Unggah bukti bayar (BPN atau bukti NTPN) di bagian Lampiran kapan saja, juga setelah pembayaran dicatat. Pembayaran yang salah dibalik dari sini dengan jurnal pembalik; datanya tidak dihapus.",
  },
  "/tax/personal": {
    summary:
      "Perkiraan pajak pribadi tahunan: PPh final UMKM dan PPh progresif setelah pajak yang sudah dipotong.",
  },
  "/tax/rules": {
    summary: "Aturan pajak yang dipakai mesin pajak (tarif, batas, tanggal berlaku).",
  },
  "/tax/setup": {
    summary:
      "Profil pajak entitas: jenis wajib pajak, rezim penghasilan, status PPN, dan pemotong pajak.",
  },

  // ---- Aset & Pendanaan
  "/assets": { summary: "Daftar aset tetap dengan nilai buku dan penyusutannya." },
  "/assets/new": {
    summary: "Mendaftarkan aset tetap baru; penyusutan dihitung otomatis tiap bulan.",
  },
  "/assets/depreciation": { summary: "Penyusutan aset per bulan. Diposting otomatis ke jurnal." },
  "/assets/loans": {
    summary: "Pinjaman yang Anda terima, sisa pokok, bunga, dan jadwal cicilannya.",
  },
  "/assets/loans/new": {
    summary: "Mencatat pinjaman baru lengkap dengan bunga dan jadwal cicilan.",
  },
  "/assets/other-receivables": {
    summary: "Piutang di luar penjualan (misalnya pinjaman ke pihak lain).",
  },
  "/assets/other-payables": { summary: "Utang di luar tagihan vendor." },
  "/assets/equity": { summary: "Modal dan ekuitas pemilik: setoran, penarikan, dan pembagian." },
  "/assets/opening": { summary: "Aset yang sudah dimiliki sebelum memakai sistem ini." },

  // ---- Payroll
  "/payroll/employees": { summary: "Daftar karyawan beserta data gaji, BPJS, dan pajaknya." },
  "/payroll/employees/new": { summary: "Menambah karyawan baru dan data dasarnya." },
  "/payroll/runs": {
    summary:
      "Proses payroll bulanan: menghitung gaji, BPJS, dan PPh 21, lalu memposting jurnalnya.",
  },
  "/payroll/payslips": { summary: "Slip gaji karyawan per bulan." },
  "/payroll/tax": {
    summary: "Kewajiban pajak dan BPJS payroll yang harus disetor, serta bukti potongnya.",
  },

  // ---- Perencanaan
  "/planning/budgets": { summary: "Anggaran per kategori dibandingkan dengan realisasi." },
  "/planning/targets": { summary: "Target pendapatan dan progresnya." },
  "/planning/recurring": {
    summary: "Transaksi yang berulang otomatis (misalnya sewa atau langganan).",
  },
  "/planning/forecasts": { summary: "Perkiraan arus kas ke depan berdasarkan data yang ada." },

  // ---- Laporan
  "/reports": {
    summary: "Laporan keuangan: laba rugi, neraca, arus kas, dan lainnya, per periode.",
  },
  "/reports/cashflow": { summary: "Arus kas: dari mana uang masuk dan ke mana keluar." },
  "/reports/tax": { summary: "Laporan pajak per periode." },
  "/reports/custom": { summary: "Laporan kustom: pilih data dan kelompokkan sesuai kebutuhan." },
  "/reports/saved": { summary: "Laporan kustom yang pernah Anda simpan." },
  "/reports/sales-purchase": { summary: "Rekap penjualan dan pembelian per periode." },
  "/reports/assets": { summary: "Laporan penyusutan dan pergerakan aset." },
  "/reports/loans": { summary: "Laporan pinjaman: pokok, bunga, dan sisa." },
  "/reports/payroll": { summary: "Laporan payroll per periode." },

  // ---- Dokumen
  "/documents": {
    summary: "Semua lampiran dan dokumen yang diunggah, dengan pencarian dan pratinjau.",
  },
  "/documents/archive": { summary: "Arsip dokumen yang sudah tidak aktif." },
  "/documents/evidence": { summary: "Bukti transaksi dan pajak yang terhubung ke catatan." },
  "/documents/uploads": { summary: "Unggahan terbaru dan statusnya." },

  // ---- Administrasi
  "/admin/users": { summary: "Pengguna dan peran: siapa boleh melihat dan mengubah apa." },
  "/admin/audit": { summary: "Jejak audit: siapa mengubah apa dan kapan. Tidak bisa diubah." },
  "/admin/backup": { summary: "Cadangan dan pemulihan data." },
  "/admin/imports": { summary: "Impor data dari berkas." },
  "/admin/invoice-layout": { summary: "Mengatur tampilan invoice: blok, perataan, dan logo." },
  "/admin/security": { summary: "Keamanan akun: verifikasi dua langkah dan sesi." },
  "/admin/settings": {
    summary: "Pengaturan entitas: nama, logo, zona waktu, dan identitas pada invoice.",
  },
  "/admin/sku": { summary: "Konfigurasi SKU produk." },
};

export const SECTION_HELP: Readonly<Record<string, HelpEntry>> = {
  "tax.filing.position": {
    summary:
      "Rekap satu jenis pajak untuk satu masa: yang terutang, yang sudah dibayar, dan sisanya. Hanya tampilan.",
  },
  "tax.filing.payments": {
    summary:
      "Setoran yang sudah dicatat untuk masa ini. Pembayaran yang salah dibatalkan dengan jurnal pembalik, tidak dihapus.",
  },
  "tax.filing.record-payment": {
    summary:
      "Mencatat setoran pajak ke negara (NTPN dan kode billing). Mengurangi saldo rekening dan menutup utang pajak masa ini.",
    more: "Jumlah dibayar tidak boleh melebihi pajak yang terutang. Jangan mencatat setoran pajak sebagai Beban: pajaknya akan terhitung dua kali.",
  },
  "tax.filing.filings": {
    summary: "Laporan pajak (SPT) yang sudah dicatat untuk masa ini beserta nomor tanda terimanya.",
  },
  "tax.filing.record-filing": {
    summary:
      "Mencatat bahwa laporan pajak sudah dikirim, dengan nomor tanda terima elektronik (NTTE). Tidak mengubah jurnal.",
  },
  "tax.filing.reconcile": {
    summary:
      "Membandingkan angka laporan dengan angka buku untuk masa ini dan mencatat penjelasan selisihnya.",
  },
  "tax.filing.evidence": {
    summary:
      "Bukti setoran, bukti potong, dan dokumen pendukung masa ini. Unggah berkas langsung ke pembayaran atau pelaporan kapan saja setelah dicatat, dan klik berkas untuk pratinjau.",
  },
};

/** Mengubah alamat halaman menjadi kunci PAGE_HELP: uuid menjadi `:id`, tanpa garis miring penutup. */
export function pageHelpKey(pathname: string): string {
  const trimmed = pathname.length > 1 ? pathname.replace(/\/+$/, "") : pathname;
  return trimmed
    .split("/")
    .map((part) =>
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(part) ? ":id" : part,
    )
    .join("/");
}
