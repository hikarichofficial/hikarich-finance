# -*- coding: utf-8 -*-
"""
Panduan Penggunaan Hikarich Finance
Generates a multi-section Indonesian user guide PDF covering:
  - Fungsi setiap menu & sub-menu (12 modul navigasi)
  - Alur diagram proses bisnis utama
  - Peran & izin (role templates)
Built with reportlab Platypus, with an auto-generated Table of Contents.
"""

import json
import os
import re
import sys
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.platypus import (
    BaseDocTemplate, PageTemplate, Frame, Paragraph, Spacer, Table, TableStyle,
    PageBreak, NextPageTemplate, FrameBreak, KeepTogether, HRFlowable, CondPageBreak
)
from reportlab.platypus.tableofcontents import TableOfContents
from reportlab.platypus.flowables import Flowable
from reportlab.platypus import Image as RLImage

OUT_PATH = os.environ.get("GUIDE_PDF_OUT", "/mnt/user-data/outputs/Panduan_Penggunaan_Hikarich_Finance.pdf")
# The step-by-step guides (Bagian VI) are read from the SAME JSON files the website's "Panduan" menu uses, so
# the PDF and the website can never disagree. Screenshots live in <GUIDE_DIR>/images.
GUIDE_DIR = os.environ.get(
    "GUIDE_DIR",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "src", "content", "guide"),
)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import flow_diagrams  # noqa: E402 -- draws the flow diagrams (decision 300); same code as the website's SVG files

GUIDE_FILES = [
    "mulai.json",
    "kas-bank.json",
    "penjualan.json",
    "pembelian.json",
    "pajak-lainnya.json",
    "akuntansi-laporan.json",
    "aset-pinjaman.json",
    "payroll-perencanaan.json",
    "administrasi-dokumen.json",
]

# ----------------------------------------------------------------------------
# Styles
# ----------------------------------------------------------------------------
styles = getSampleStyleSheet()

styles.add(ParagraphStyle(
    name="CoverTitle", fontName="Helvetica-Bold", fontSize=26, leading=32,
    alignment=TA_CENTER, textColor=colors.HexColor("#1a2b4a"), spaceAfter=10,
))
styles.add(ParagraphStyle(
    name="CoverSubtitle", fontName="Helvetica", fontSize=14, leading=20,
    alignment=TA_CENTER, textColor=colors.HexColor("#44546a"), spaceAfter=6,
))
styles.add(ParagraphStyle(
    name="CoverMeta", fontName="Helvetica", fontSize=10.5, leading=16,
    alignment=TA_CENTER, textColor=colors.HexColor("#666666"),
))
styles.add(ParagraphStyle(
    name="ModuleHeading", fontName="Helvetica-Bold", fontSize=17, leading=21,
    textColor=colors.white, backColor=colors.HexColor("#1a2b4a"),
    spaceBefore=0, spaceAfter=14, leftIndent=8, borderPadding=(8, 8, 8, 8),
))
styles.add(ParagraphStyle(
    name="SubHeading", fontName="Helvetica-Bold", fontSize=13, leading=16,
    textColor=colors.HexColor("#1a2b4a"), spaceBefore=16, spaceAfter=8,
))
styles.add(ParagraphStyle(
    name="ItemName", fontName="Helvetica-Bold", fontSize=10.8, leading=14,
    textColor=colors.HexColor("#1a2b4a"),
))
styles.add(ParagraphStyle(
    name="ItemHref", fontName="Courier", fontSize=8.3, leading=11,
    textColor=colors.HexColor("#8a6d00"),
))
styles.add(ParagraphStyle(
    name="ItemDesc", fontName="Helvetica", fontSize=9.6, leading=13.5,
    textColor=colors.HexColor("#222222"), spaceAfter=2,
))
styles.add(ParagraphStyle(
    name="RefNote", fontName="Helvetica-Oblique", fontSize=7.3, leading=9.5,
    textColor=colors.HexColor("#9a9a9a"),
))
styles.add(ParagraphStyle(
    name="Intro", fontName="Helvetica", fontSize=10, leading=14.5,
    textColor=colors.HexColor("#333333"), spaceAfter=8,
))
styles.add(ParagraphStyle(
    name="FlowTitle", fontName="Helvetica-Bold", fontSize=13.5, leading=17,
    textColor=colors.white, backColor=colors.HexColor("#2f5233"),
    spaceBefore=4, spaceAfter=10, leftIndent=8, borderPadding=(7, 7, 7, 7),
))
styles.add(ParagraphStyle(
    name="StepText", fontName="Helvetica", fontSize=9.6, leading=13,
    textColor=colors.HexColor("#1a1a1a"),
))
styles.add(ParagraphStyle(
    name="StepNum", fontName="Helvetica-Bold", fontSize=11, leading=13,
    textColor=colors.white, alignment=TA_CENTER,
))
styles.add(ParagraphStyle(
    name="NoteText", fontName="Helvetica", fontSize=9.3, leading=13,
    textColor=colors.HexColor("#5a4400"), spaceAfter=4,
))
styles.add(ParagraphStyle(
    name="TOCHeading1", fontName="Helvetica-Bold", fontSize=11, leading=16,
    textColor=colors.HexColor("#1a2b4a"),
))
styles.add(ParagraphStyle(
    name="TOCHeading2", fontName="Helvetica", fontSize=9.5, leading=13,
    leftIndent=14, textColor=colors.HexColor("#333333"),
))
styles.add(ParagraphStyle(
    name="Footnote", fontName="Helvetica-Oblique", fontSize=7.8, leading=10,
    textColor=colors.HexColor("#888888"),
))

styles.add(ParagraphStyle(
    name="GuideGroupHeading", fontName="Helvetica-Bold", fontSize=15, leading=19,
    textColor=colors.white, backColor=colors.HexColor("#3b5b8c"),
    spaceBefore=6, spaceAfter=10, leftIndent=8, borderPadding=(6, 6, 6, 6),
))
styles.add(ParagraphStyle(
    name="GuideHeading", fontName="Helvetica-Bold", fontSize=13.5, leading=17,
    textColor=colors.HexColor("#1a2b4a"), spaceBefore=10, spaceAfter=4,
))
styles.add(ParagraphStyle(
    name="GuideH3", fontName="Helvetica-Bold", fontSize=10.8, leading=14,
    textColor=colors.HexColor("#1a2b4a"), spaceBefore=8, spaceAfter=3,
))
styles.add(ParagraphStyle(
    name="GuideMeta", fontName="Helvetica", fontSize=9, leading=12.5,
    textColor=colors.HexColor("#444444"),
))
styles.add(ParagraphStyle(
    name="GuideBody", fontName="Helvetica", fontSize=9.6, leading=13.5,
    textColor=colors.HexColor("#1a1a1a"), spaceAfter=4,
))
styles.add(ParagraphStyle(
    name="GuideCaption", fontName="Helvetica-Oblique", fontSize=8, leading=10.5,
    textColor=colors.HexColor("#666666"), alignment=TA_CENTER, spaceAfter=4,
))
styles.add(ParagraphStyle(
    name="GuideCell", fontName="Helvetica", fontSize=8.8, leading=11.5,
    textColor=colors.HexColor("#1a1a1a"),
))

DARK = colors.HexColor("#1a2b4a")
GREEN = colors.HexColor("#2f5233")
GOLD = colors.HexColor("#8a6d00")
LIGHTBOX = colors.HexColor("#eef2f8")
ALTBOX = colors.HexColor("#fdf2e3")
ENDBOX = colors.HexColor("#e6f2e8")


def esc(t):
    return t.replace("&", "&amp;")


def ref(text):
    """Trailing bracketed reference numbers rendered small & gray."""
    return '<font size="7.3" color="#9a9a9a">  Ref: %s</font>' % esc(text)


# ----------------------------------------------------------------------------
# Flow diagram flowable: a numbered, color-coded vertical box chain
# ----------------------------------------------------------------------------
def arrow_down():
    return Paragraph('<font color="#2f5233" size="14">&#x2193;</font>', ParagraphStyle(
        name="ArrowDown", alignment=TA_CENTER, fontName="Helvetica-Bold"))


def make_step_box(num, text, kind="normal"):
    bg = {"normal": LIGHTBOX, "alt": ALTBOX, "end": ENDBOX}.get(kind, LIGHTBOX)
    border = {"normal": DARK, "alt": colors.HexColor("#b5791a"), "end": GREEN}.get(kind, DARK)
    num_bg = {"normal": DARK, "alt": colors.HexColor("#b5791a"), "end": GREEN}.get(kind, DARK)
    num_cell = Table([[Paragraph(str(num), styles["StepNum"])]], colWidths=[24], rowHeights=[20])
    num_cell.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), num_bg),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("ALIGN", (0, 0), (-1, -1), "CENTER"),
        ("LEFTPADDING", (0, 0), (-1, -1), 0),
        ("RIGHTPADDING", (0, 0), (-1, -1), 0),
    ]))
    txt = Paragraph(text, styles["StepText"])
    t = Table([[num_cell, txt]], colWidths=[30, 416])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), bg),
        ("BOX", (0, 0), (-1, -1), 0.8, border),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("LEFTPADDING", (0, 0), (0, 0), 0),
        ("LEFTPADDING", (1, 0), (1, 0), 10),
        ("RIGHTPADDING", (1, 0), (1, 0), 8),
        ("TOPPADDING", (0, 0), (-1, -1), 6),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
    ]))
    return t


def flow_diagram(title, steps, note=None):
    """
    steps: list of (text, kind) where kind in {"normal","alt","end"}.
      "normal" = langkah utama, "alt" = jalur alternatif/koreksi/pembatalan,
      "end"    = status akhir / selesai.
    """
    flow = [Paragraph(esc(title), styles["FlowTitle"])]
    n = 1
    for i, item in enumerate(steps):
        text, kind = item
        if kind == "alt":
            badge = "!"  # alternate/branch path marker
        else:
            badge = str(n)
            n += 1
        flow.append(make_step_box(badge, text, kind))
        if i != len(steps) - 1:
            flow.append(Spacer(1, 2))
            flow.append(arrow_down())
            flow.append(Spacer(1, 2))
    if note:
        flow.append(Spacer(1, 6))
        flow.append(Paragraph("<i>Catatan: %s</i>" % note, styles["NoteText"]))
    flow.append(Spacer(1, 14))
    return flow



# ----------------------------------------------------------------------------
# CONTENT: Langkah Awal (apa yang dilakukan pertama kali memakai website)
# ----------------------------------------------------------------------------
START_INTRO = (
    "Bagian ini menjawab pertanyaan pertama setiap pengguna baru: <b>apa yang harus disiapkan dulu</b> supaya "
    "saat membuat invoice atau mencatat pengeluaran, semuanya tinggal diklik dan tidak perlu mengetik ulang. "
    "Lakukan urutan di bawah ini <b>satu kali per Entity</b> (PT dan Pribadi masing-masing). Pilih Entity di "
    "bagian atas layar; alamat halaman akan memuat <font face=\"Courier\" size=\"8.5\">?entity=pt</font> atau "
    "<font face=\"Courier\" size=\"8.5\">?entity=hikarich</font> sehingga PT dan Pribadi tidak tercampur."
)

START_STEPS = [
    ("Pilih Entity yang akan dikerjakan (PT Hikarich Kitana Digital atau Pribadi) lewat pemilih Entity di bagian "
     "atas. Semua langkah di bawah dilakukan di Entity yang sedang dipilih.", "normal"),
    ("<b>Pengaturan Pajak</b> (menu Pajak &rarr; Pengaturan Pajak): isi profil pajak Entity dan tanggal mulai "
     "mesin pajak. Pajak pada invoice dan pengeluaran dihitung otomatis dari profil ini.", "normal"),
    ("<b>Rekening Kas &amp; Bank</b> (menu Kas &amp; Bank &rarr; Rekening &rarr; Tambah Akun): buat setiap rekening "
     "bank, kas tunai, dan e-wallet yang dipakai, beserta mata uangnya. Rekening inilah yang nanti dipilih saat "
     "invoice dibayar dan saat pengeluaran dibayar. Salah buat? Rekening yang belum punya transaksi bisa dihapus "
     "dari halaman detailnya (tombol Hapus Rekening).", "normal"),
    ("<b>Saldo Awal</b> (menu Akuntansi &rarr; Saldo Awal): jika rekening sudah berisi uang sebelum memakai website, "
     "catat saldo pembukaannya di sini, bukan dengan mengetik saldo di rekening.", "normal"),
    ("<b>Kategori</b> (menu Akuntansi &rarr; Kategori): Entity sudah memiliki kategori standar (misalnya Penjualan "
     "Produk dan beban umum). Periksa daftarnya, tambah kategori yang kurang, dan pastikan kolom Akun tiap kategori "
     "sudah sesuai. Kolom Perlakuan Pajak biarkan &quot;Otomatis&quot; kecuali kategori itu selalu punya perlakuan pajak "
     "tertentu.", "normal"),
    ("<b>Pelanggan</b> (menu Penjualan &rarr; Pelanggan &rarr; tambah): masukkan nama pelanggan tetap, plus email/"
     "telepon bila ada. Sistem menolak data kembar. Pelanggan baru juga bisa ditambah langsung saat membuat invoice "
     "lewat tombol &quot;+ Tambah pelanggan baru&quot;.", "normal"),
    ("<b>Vendor</b> (menu Pembelian &rarr; Vendor &rarr; tambah): masukkan penyedia barang/jasa yang sering dibayar, "
     "supaya tinggal dipilih saat mencatat tagihan.", "normal"),
    ("<b>Produk &amp; Jasa</b> (menu Penjualan &rarr; Produk &amp; Jasa &rarr; tambah): isi Nama, Satuan, <b>Harga "
     "Satuan Bawaan</b>, dan Kategori Pendapatan Bawaan. Inilah yang membuat baris invoice terisi otomatis: "
     "produk yang sudah terdaftar muncul sebagai pilihan dengan harganya.", "normal"),
    ("<b>Buat invoice</b> (menu Penjualan &rarr; Invoice &rarr; Buat Invoice): pilih Pelanggan dari daftar, atur "
     "tanggal dan jatuh tempo, pilih Rekening Tujuan Pembayaran. Pada kolom <b>Deskripsi</b> baris, klik kolomnya: "
     "daftar nama yang sudah ada (produk dan baris invoice sebelumnya) muncul di atas kolom. Klik salah satu, maka "
     "deskripsi, harga satuan, dan kategori terisi otomatis. Harga tetap bisa diubah, dan Anda boleh mengetik nama "
     "yang berbeda. Isi Diskon bila perlu (persen atau nominal). Isian uang otomatis diberi pemisah ribuan saat diketik (misalnya 100.000.000); gunakan <b>koma</b> untuk desimal.", "normal"),
    ("<b>Terbitkan</b> invoice, lalu bagikan tautan pembayaran atau kirim ke email pelanggan. Saat pelanggan membayar, "
     "catat di Pembayaran Diterima atau konfirmasi Klaim Pembayaran, dan pilih rekening yang menerima uangnya: "
     "saldo rekening bertambah dan terlihat di halaman detail rekening.", "end"),
    ("<b>Pengeluaran</b> (menu Pembelian &rarr; Beban &rarr; buat): pilih kategori beban, isi deskripsi (saran nama "
     "muncul seperti pada invoice), <b>satu jumlah sesuai struk</b> (tidak perlu kuantitas dan harga satuan; centang "
     "&ldquo;Rinci per barang&rdquo; bila memang perlu), dan <b>rekening yang membayar</b>. Setelah Konfirmasi, saldo "
     "rekening berkurang dan jurnal tercatat otomatis. Pembelian dari vendor yang dibayar nanti dicatat sebagai Tagihan: "
     "setelah disetujui menjadi utang usaha, lalu dibayar dengan tombol <b>Bayar Tagihan</b> di halaman tagihan itu "
     "(Pembayaran Keluar hanya daftar riwayatnya).", "end"),
    ("<b>Pembayaran pajak</b> (menu Pajak &rarr; Pelaporan &amp; Bukti): cek dulu posisi terutang di PPN, "
     "PPh Vendor, atau PPh Final, lalu rekam pembayaran dari rekening kas/bank, rekam laporan SPT, dan "
     "lampirkan bukti.", "end"),
]

EMAIL_STEPS = [
    ("Alamat website resmi: <font face=\"Courier\" size=\"8.5\">https://finance.hikarichgroup.com</font>. "
     "Masuk lewat halaman <font face=\"Courier\" size=\"8.5\">/login</font>. Alamat ini sudah terpasang di Vercel "
     "dan di pengaturan Supabase, jadi tautan invoice dan tautan masuk memakai alamat ini.", "normal"),
    ("Layanan email memakai <b>Resend</b> dengan domain pengirim <font face=\"Courier\" size=\"8.5\">"
     "mail.hikarichgroup.com</font> yang sudah berstatus <b>Verified</b>. Email invoice dan bukti pembayaran dikirim "
     "dari <font face=\"Courier\" size=\"8.5\">invoice@mail.hikarichgroup.com</font>.", "normal"),
    ("<b>API Key</b> Resend dipasang oleh pemilik langsung di Vercel (variabel "
     "<font face=\"Courier\" size=\"8.5\">RESEND_API_KEY</font>). Jangan pernah mengirim API Key ke siapa pun, "
     "termasuk ke chat.", "normal"),
    ("Pengaturan di Vercel (Settings &rarr; Environment Variables, Production): "
     "<font face=\"Courier\" size=\"8.5\">RESEND_FROM_EMAIL</font> berisi <b>alamat email saja</b> "
     "(invoice@mail.hikarichgroup.com), tanpa nama tampilan seperti &quot;Hikarich &lt;...&gt;&quot; karena "
     "format itu membuat build gagal. <font face=\"Courier\" size=\"8.5\">APP_URL</font> berisi "
     "https://finance.hikarichgroup.com.", "normal"),
    ("Setiap kali variabel di Vercel diubah, lakukan <b>Redeploy</b> agar terbaca. Setelah itu, di halaman detail "
     "Invoice muncul formulir <b>Kirim / Kirim Ulang Invoice ke Email</b>, dan di halaman detail Pembayaran muncul "
     "<b>Kirim Bukti Pembayaran</b>. Alamat email terisi dari data pelanggan dan boleh diubah.", "end"),
    ("Setiap pengiriman tercatat di <b>Riwayat Pengiriman Email</b> pada halaman yang sama (tujuan, waktu, terkirim "
     "atau gagal), dan bisa dikirim ulang kapan saja selama tautan invoice masih aktif. Jika email tidak masuk, "
     "cek juga folder Spam penerima.", "end"),
]

START_TIPS = [
    "Mulai dari Pelanggan, Produk &amp; Jasa, dan Rekening. Tiga hal ini yang paling sering dipilih saat membuat invoice.",
    "Nama produk dan baris invoice yang pernah dipakai akan muncul sebagai saran, jadi nama tetap seragam di semua invoice.",
    "Jika salah memasukkan data awal (misalnya rekening), perbaiki atau hapus lewat halaman detailnya selama belum ada transaksi.",
    "Angka dan tanggal yang sudah diposting tidak diubah langsung. Koreksi dilakukan lewat pembatalan atau pembalikan, "
    "sehingga riwayat tetap utuh.",
    "Tautan &quot;&larr; Kembali ke ...&quot; di halaman data membawa Anda ke halaman yang dibuka sebelumnya (misalnya Aktivitas "
    "Terbaru), seperti tombol Back browser; bila halaman dibuka langsung, tautan itu menuju daftar aslinya.",
    "Warna angka: hijau = uang masuk, merah = uang keluar (mutasi rekening, Rekening Koran, Arus Kas, daftar pembayaran, "
    "Aktivitas Terbaru). Saldo, total, Laba Rugi, dan Neraca memakai warna biasa.",
    "Pinjaman bank tidak masuk kartu Utang Usaha (hanya tagihan vendor); sisa pokoknya tampil di kartu Pinjaman di Dashboard "
    "dan di Aset &amp; Pendanaan &rarr; Pinjaman. Bunga pinjaman berubah (misalnya bunga tetap lalu mengambang)? Isi "
    "tahap bunga (Bunga Berjenjang) saat membuat pinjaman, atau tekan Ubah Bunga pada pinjaman berjalan: cicilan mulai "
    "tanggal itu dihitung ulang dari sisa pokok dengan jangka waktu yang sama. Restrukturisasi Jadwal untuk pinjaman "
    "yang sulit dibayar.",
]

# ----------------------------------------------------------------------------
# CONTENT: 12 modul navigasi (fungsi menu & sub-menu)
# ----------------------------------------------------------------------------
# Each section: (num, module_title_id, intro, items)
# Each item: (name, href, description, refs)

SECTIONS = [
("1", "Ringkasan (Dashboard)",
 "Halaman pertama yang tampil setelah masuk ke sebuah Entity. Memberi ikhtisar cepat "
 "posisi keuangan Entity yang sedang aktif sebelum pengguna masuk ke modul lain.",
 [("Ringkasan", "/",
   "Ikhtisar satu layar: kartu angka (kas &amp; bank, pendapatan, beban, laba, piutang, utang), <b>Tren Arus Kas</b> "
   "dan kartu <b>Pendapatan</b> serta <b>Beban</b> berupa grafik enam bulan. Arahkan kursor ke titik atau batang "
   "untuk melihat angka pastinya, klik untuk membuka laporan bulan itu. Ada juga ringkasan pajak, tenggat terdekat, "
   "dan daftar Perlu Perhatian. Tidak mengubah data apa pun — murni tampilan baca.", "")]
),

("2", "Penjualan (Sales)",
 "Semua yang berhubungan dengan menjual ke pelanggan: membuat invoice, menerima pembayaran, "
 "menangani klaim pembayaran dari halaman publik, penjualan marketplace, dan refund.",
 [
  ("Invoice", "/sales/invoices",
   "Membuat, menerbitkan, dan memantau invoice ke pelanggan. Status: Draf &rarr; Diterbitkan &rarr; (Dibatalkan/Void). "
   "Invoice yang sudah diterbitkan punya nomor resmi dan tautan pembayaran publik yang bisa dibagikan ke pelanggan. "
   "Invoice juga bisa dikirim atau dikirim ulang ke email pelanggan (termasuk setelah lunas), dengan Riwayat Pengiriman Email. Pada baris invoice: mengeklik atau mengetik di kolom deskripsi memunculkan daftar produk dan baris yang pernah dibuat (harga satuan ikut terisi, "
   "tetap bisa diubah), ada kolom Diskon (persen atau nominal), dan angka uang otomatis diberi pemisah ribuan.",
   "64–66,71,165,257"),
  ("Catat Pendapatan", "/sales/income",
   "Mencatat uang masuk yang tidak punya invoice: penjualan tunai, jasa yang dibayar langsung, komisi, bunga, "
   "dividen, hasil trading. Cukup isi tanggal, jenis pendapatan (ketik untuk mencari atau tambah baru), jumlah, dan "
   "rekening penerima; jurnal dan saldo rekening diurus otomatis. Pendapatan usaha ikut dasar PPh Final 0,5%; bunga, "
   "dividen, hasil forex, dan sejenisnya tercatat tetapi tidak ikut dan tampil di Ringkasan Pajak. Salah catat "
   "dibatalkan dengan alasan, bukan diedit.", "350,352"),
  ("Pembayaran Diterima", "/sales/payments",
   "Daftar seluruh pembayaran masuk dari pelanggan terhadap invoice. Pembayaran yang salah catat bisa dibatalkan "
   "(dibalik/reverse) tanpa menghapus jejaknya. Di halaman detail pembayaran ada tombol Kirim Bukti Pembayaran "
   "ke email pelanggan beserta Riwayat Pengiriman Email.", "68,229"),
  ("Klaim Pembayaran", "/sales/claims",
   "Antrian klaim “Saya Sudah Bayar” yang dikirim pelanggan dari halaman invoice publik. Staf meninjau lalu "
   "Konfirmasi, Tolak, atau menandainya sebagai duplikat. Klaim yang masih menunggu tinjauan belum mengubah kas atau buku besar.",
   "70,259"),
  ("Marketplace", "/sales/marketplace",
   "Mencatat penjualan dari toko online per pencairan dana (payout) dari marketplace, termasuk PPh 22 yang sudah "
   "dipotong duluan oleh marketplace. Koreksi dilakukan lewat pembalikan (reversal), bukan edit langsung.", "260"),
  ("Pengembalian Dana", "/sales/refunds",
   "Mengembalikan dana ke pelanggan, sebagian atau penuh, baik dari alokasi pembayaran yang sudah ada maupun dari "
   "saldo lebih bayar (advance) pelanggan. Halaman ini hanya daftar pembayaran yang sudah punya refund dan tidak punya "
   "tombol tambah: refund baru dibuat dari detail pembayaran (Pembayaran Diterima > klik pembayaran > Refund ke Pelanggan).", "73,229,263,356"),
  ("Pelanggan", "/sales/customers",
   "Data induk pelanggan. Sistem mendeteksi duplikasi: email/telepon/NPWP yang sama persis akan ditolak, nama yang "
   "mirip akan meminta konfirmasi sebelum disimpan.", "67,445"),
  ("Produk & Jasa", "/sales/products",
   "Katalog produk/jasa untuk mengisi baris invoice secara cepat dan konsisten. Setiap produk mendapat SKU otomatis "
   "(mis. KEA-EA-001) dari Brand dan Jenis Produk yang dipilih; produk bisa punya variant (mis. KEA-EA-001-1B) dengan "
   "SKU, harga, dan status sendiri. Brand, Jenis Produk, Variant, dan Kategori bisa diketik dan ditambah langsung di "
   "form produk (bagi yang berizin SKU). Item di katalog tidak pernah dihapus permanen, hanya dinonaktifkan.", "245,324,351"),
 ]
),

("3", "Pembelian (Purchases)",
 "Semua yang berhubungan dengan membeli dari vendor: tagihan vendor, pembelian tunai langsung (beban), "
 "pembayaran ke vendor, dan data vendor.",
 [
  ("Tagihan", "/purchases/bills",
   "Tagihan dari vendor untuk barang/jasa/aset/beban dibayar di muka, dibayar nanti. Status: Draf &rarr; Diajukan &rarr; "
   "Disetujui (atau Ditolak/Dibatalkan/Void). Setelah disetujui, biaya tercatat dan utang usaha bertambah, dan data "
   "vendor dibekukan agar riwayat tidak berubah. Pembayaran dilakukan dengan tombol Bayar Tagihan di halaman tagihan: "
   "utang usaha dan saldo rekening berkurang, biaya tidak bertambah lagi. Satu jumlah per baris cukup (kuantitas dan "
   "harga satuan hanya bila &ldquo;Rinci per barang&rdquo; dicentang).",
   "78,167"),
  ("Beban", "/purchases/expenses",
   "Pembelian yang dibayar tunai langsung saat terjadi (bukan utang). Cukup isi satu jumlah sesuai struk, tanpa "
   "kuantitas dan harga satuan. Konfirmasi pada status Draf langsung membukukan beban sekaligus mencatat "
   "pembayarannya &mdash; tidak ada tahap utang usaha terpisah.", "82,245,353"),
  ("Pembayaran Keluar", "/purchases/payments",
   "Daftar pembayaran ke vendor. Pembayaran baru dimulai dari detail tagihan (tombol Bayar Tagihan), bukan dari "
   "halaman ini. Hanya memuat pembayaran Tagihan; Beban yang langsung dibayar tidak tampil di sini. Pembayaran yang salah "
   "catat bisa dibatalkan (dibalik) dari halaman detail pembayaran.", "77,230,356"),
  ("Vendor", "/purchases/vendors",
   "Data induk vendor, dengan deteksi duplikasi yang sama seperti pada data Pelanggan.", "445"),
 ]
),

("4", "Kas & Bank (Money)",
 "Mengelola rekening kas, bank, dan QRIS milik Entity: saldo, perpindahan uang antar rekening, "
 "rekonsiliasi dengan rekening koran, dan satu feed gabungan seluruh mutasi.",
 [
  ("Rekening", "/money/accounts",
   "Daftar seluruh rekening kas/bank/QRIS milik Entity, lengkap dengan saldo buku saat ini dan status rekonsiliasi "
   "masing-masing. Klik nama rekening untuk membuka detail: saldo sistem &amp; buku besar, total masuk/keluar pada rentang "
   "tanggal, dan daftar aktivitas dari invoice, pengeluaran, serta pajak. Rekening yang belum punya transaksi bisa "
   "dihapus (tombol Hapus Rekening); yang sudah punya transaksi hanya bisa dinonaktifkan.", "169,295"),
  ("Transfer", "/money/transfers",
   "Memindahkan uang antar rekening yang dimiliki Entity yang sama (bukan ke pihak luar). Transfer perlu "
   "dikonfirmasi oleh pihak yang berwenang sebelum dianggap final.", "56–58,170"),
  ("Rekonsiliasi Bank", "/money/reconciliation",
   "Mencocokkan mutasi pada rekening koran dengan mutasi yang tercatat di sistem, per rekening per periode. "
   "Lihat alur lengkapnya di bagian Alur Diagram.", "59–60,251"),
  ("Mutasi Kas & Bank", "/money/activity",
   "Satu daftar gabungan dari seluruh pemasukan dan pengeluaran di semua rekening, diurutkan berdasarkan tanggal "
   "&mdash; berguna untuk melihat aktivitas kas secara keseluruhan tanpa harus buka tiap rekening satu-satu.", "171"),
 ]
),

("5", "Akuntansi (Accounting)",
 "Jantung pembukuan: jurnal, daftar akun, kategori transaksi, status periode akuntansi (tutup buku), "
 "dan saldo awal saat migrasi/cutover.",
 [
  ("Jurnal", "/accounting/journals",
   "Daftar seluruh jurnal, baik yang dibuat otomatis dari transaksi (invoice, tagihan, pembayaran, dst.) maupun "
   "jurnal manual. Dari sini bisa dilihat detail, dibuat jurnal manual baru, diposting dari draf, atau dibalik "
   "(reverse) jika jurnal yang sudah posting ternyata salah.", "20,38,40,172"),
  ("Rekening Koran", "/accounting/statement",
   "Tampilan seperti rekening koran bank untuk kas dan bank: saldo awal, uang masuk, uang keluar, dan saldo akhir "
   "per bulan, dengan saldo berjalan di setiap baris, dibagi menjadi beberapa halaman bila panjang, plus ringkasan "
   "12 bulan. Angkanya dari jurnal yang sudah diposting.", "326"),
  ("Daftar Akun", "/accounting/accounts",
   "Peta/struktur akun (chart of accounts) milik Entity. Saat ini bersifat baca-saja dari aplikasi (belum ada "
   "fitur tambah/ubah akun sendiri). Sebagian akun ditandai sebagai Akun Kontrol atau Dilindungi karena perannya "
   "penting dalam integritas pembukuan.", "58,172"),
  ("Kategori", "/accounting/categories",
   "Mengatur kategori penjualan/pembelian: ke akun apa suatu kategori dibukukan, dan perlakuan pajak khususnya "
   "(opsional; pajak tetap dihitung otomatis dari profil pajak). Setiap Entity sudah memiliki kategori standar "
   "(misalnya Penjualan Produk), termasuk kategori Aset siap pakai (laptop, smartphone, peralatan kantor, kendaraan, "
   "bangunan, tanah) dan biaya dibayar di muka untuk baris pengeluaran berperlakuan Aset; akun dapat dipetakan sendiri "
   "lewat formulir di baris kategori.", "262,371"),
  ("Periode Akuntansi", "/accounting/periods",
   "Status tiap bulan pembukuan: Terbuka / Dalam Tinjauan Penutupan / Ditutup / Dibuka Kembali. Dari sini memulai "
   "proses tutup bulan, melihat checklist pemblokirnya, atau membuka kembali periode yang sudah ditutup (dengan "
   "alasan tertulis). Lihat alur lengkapnya di bagian Alur Diagram.", "22,42,226"),
  ("Saldo Awal", "/accounting/opening-balances",
   "Merekam saldo pembukaan akun-akun saat migrasi/cutover ke sistem ini. Satu batch saldo awal hanya diposting "
   "satu kali; selisih yang tidak terjelaskan otomatis masuk ke akun “Selisih Migrasi”.", "43,44,245"),
  ("Penyesuaian Lanjutan", "/accounting/advanced-adjustments",
   "Untuk koreksi saldo kas/bank di luar jalur normal (misalnya biaya administrasi bank yang dipotong otomatis "
   "oleh bank). Selalu membutuhkan alasan tertulis. Tidak bisa dipakai untuk mencatat pendapatan: pendapatan "
   "(termasuk bunga bank) dicatat lewat Penjualan &gt; Catat Pendapatan agar pajaknya ikut terhitung.", "54,232,370"),
 ]
),

("6", "Pajak (Tax)",
 "Pusat kepatuhan pajak Entity: posisi PPN, PPh Vendor, PPh Final UMKM, kalender jatuh tempo, "
 "pencatatan pelaporan & pembayaran, serta aturan tarif resmi.",
 [
  ("Ringkasan Pajak", "/tax",
   "Halaman utama modul Pajak, berisi angka lebih dulu daripada kalimat. Empat kartu: <b>Total terutang</b>, "
   "<b>PPh Final bulan ini</b> (perkiraan), <b>Perkiraan PPh</b> tahun berjalan, dan <b>Perlu ditinjau</b>. Di "
   "bawahnya grafik <b>PPh per bulan</b> (arahkan kursor untuk jumlah, klik untuk membuka Buku Pajak bulan "
   "itu), kartu <b>Penghasilan di Luar PPh Final</b> (hasil bersih forex, bunga, dividen, kripto sejak 1 Januari "
   "dengan perkiraan pajak 22% berlabel asumsi; ditetapkan 1 Januari tahun berikutnya, SPT Tahunan 30 April), batang "
   "<b>Terutang per jenis</b>, dan kartu <b>Tenggat terdekat</b>. Profil pajak Entity tampil sebagai label singkat "
   "di bagian atas.", "173,352"),
  ("Buku Pajak", "/tax/ledger",
   "Daftar seluruh transaksi berpajak (PPN, PPh Vendor, PPh Final), bisa disaring per jenis pajak, periode, "
   "sumber dokumen, dan status.", "91,173"),
  ("PPh Final", "/tax/pph-final",
   "Perhitungan PPh Final UMKM 0,5% dari omzet bulanan. Pilih bulan, lihat pratinjau, lalu hitung resmi. Jika "
   "dihitung ulang, sistem hanya membukukan selisihnya, tidak dobel.", "97,234"),
  ("PPh Vendor", "/tax/withholding",
   "Posisi PPh 23 (jasa dan sewa), PPh 4 ayat (2) (sewa tanah/bangunan), dan PPh 26 (ke luar negeri) atas pembelian "
   "dari vendor. PPh diambil dari bayaran vendor dan disetor PT ke negara, jadi biaya PT tetap sebesar jumlah di dokumen. "
   "Dihitung otomatis dari tagihan/beban yang relevan, tidak perlu hitung manual.", "91,93,235,256,364"),
  ("PPN", "/tax/ppn",
   "Posisi PPN keluaran (dari penjualan) dan PPN masukan (dari pembelian, yang bisa dikreditkan) untuk tiap "
   "periode pajak.", "91,92,235"),
  ("Kalender Pajak", "/tax/calendar",
   "Jadwal hitung/bayar/lapor/lampirkan bukti untuk setiap periode dan jenis pajak, dengan status: selesai, "
   "jatuh tempo, terlambat, atau belum waktunya.", "98,233"),
  ("Pelaporan & Bukti", "/tax/filing",
   "Mencatat pembayaran pajak, merekam SPT yang sudah dilaporkan (termasuk pembetulan tanpa menghapus yang lama), "
   "merekonsiliasi periode pajak, dan melampirkan bukti lapor/bayar.", "93,95,96,238"),
  ("Aturan Pajak", "/tax/rules",
   "Daftar tarif pajak resmi (PPN, PPh 23, dst.) beserta tanggal mulai berlaku dan dasar hukumnya. OWNER dapat "
   "membuat versi aturan baru. Catatan teknis: entri aturan masih berupa data JSON mentah, bukan formulir "
   "terpandu &mdash; sebaiknya ditangani oleh OWNER atau staf teknis.", "239,249"),
  ("Pengaturan Pajak", "/tax/settings",
   "Profil pajak Entity, serta “menyalakan” mesin penghitung pajak sejak tanggal tertentu. Dokumen sebelum "
   "tanggal itu tidak akan dihitung ulang pajaknya.", "90,258"),
 ]
),

("7", "Aset & Pendanaan (Assets & Financing)",
 "Aset tetap perusahaan, jadwal penyusutan, pinjaman (utang maupun piutang ke pihak lain), "
 "piutang/utang lain di luar invoice/tagihan biasa, dan modal & ekuitas.",
 [
  ("Aset Tetap", "/assets",
   "Barang bernilai besar yang dipakai dalam jangka panjang. Muncul otomatis saat tagihan/beban yang baris-nya "
   "ditandai “Aset” disetujui. Dari sini dilakukan aktivasi (tentukan tanggal mulai pakai, metode & umur "
   "penyusutan, nilai sisa), lihat riwayat, pindahkan lokasi, atau lepas aset.", "103,113,174"),
  ("Penyusutan", "/assets/depreciation",
   "Jadwal penyusutan bulanan seluruh aset beserta status posting-nya. Sistem otomatis memposting bulan yang "
   "sudah lewat saat layar ini (atau layar Aset/Dashboard) dibuka.", "104,178,269"),
  ("Pinjaman", "/assets/loans",
   "Mencatat utang ke pihak lain atau piutang pinjaman ke pihak lain: sisa pokok, jadwal cicilan, dan tunggakan. "
   "Lihat alur lengkapnya di bagian Alur Diagram.", "109,175"),
  ("Piutang Lain", "/assets/other-receivables",
   "Piutang di luar invoice biasa &mdash; misalnya pinjaman ke karyawan atau dana titipan. Bisa dicatat, "
   "dilunasi, atau dihapuskan.", "176"),
  ("Utang Lain", "/assets/other-payables",
   "Kebalikan dari Piutang Lain. Bisa dicatat, dibayar, atau dibatalkan.", "176"),
  ("Modal & Ekuitas", "/assets/equity",
   "Mencatat setoran modal, penarikan modal, dan dividen. Penarikan modal dan dividen hanya dapat disetujui "
   "oleh OWNER.", "107,112,177"),
 ]
),

("8", "Payroll",
 "Data karyawan, menjalankan proses penggajian bulanan, slip gaji, serta kewajiban pajak & BPJS "
 "yang timbul dari payroll.",
 [
  ("Karyawan", "/payroll/employees",
   "Profil karyawan: jabatan, komponen gaji, kepesertaan BPJS, dan data pajak. Informasi gaji & pajak hanya "
   "terlihat oleh pemegang peran Payroll atau OWNER.", "119,120,179"),
  ("Proses Payroll", "/payroll/runs",
   "Menjalankan penggajian bulanan melalui tahapan: Draf &rarr; Hitung &rarr; Ajukan &rarr; Setujui &rarr; "
   "Posting &rarr; Bayar &rarr; Tutup. Hanya satu proses payroll yang boleh aktif per bulan. Lihat alur lengkapnya "
   "di bagian Alur Diagram.", "122,125,180"),
  ("Slip Gaji", "/payroll/payslips",
   "Terbit otomatis saat sebuah proses payroll diposting. Slip gaji adalah “potret” angka pada saat itu dan "
   "tidak berubah lagi setelah itu, meskipun data karyawan kemudian diubah.", "129,181"),
  ("Pajak & Kewajiban Payroll", "/payroll/tax",
   "Kewajiban yang terutang dari payroll (gaji, BPJS, PPh 21), buku pajak per karyawan, dan rekonsiliasi tahunan "
   "PPh 21. Bagian buku pajak & rekonsiliasi tahunan hanya bisa diakses oleh pemegang izin pajak.", "131,182"),
 ]
),

("9", "Perencanaan (Planning)",
 "Anggaran per kategori, target pendapatan keseluruhan, perkiraan otomatis, dan transaksi "
 "berulang (recurring) untuk invoice/tagihan/beban yang rutin terjadi.",
 [
  ("Anggaran", "/planning/budgets",
   "Anggaran per kategori per bulan, dibandingkan dengan Realisasi (yang sudah benar-benar terjadi), Committed "
   "(invoice draf/tagihan yang masih menunggu), dan Perkiraan (hanya informasi, tidak pernah mengubah pembukuan).",
   "134,136,138,139,184,186"),
  ("Target Pendapatan", "/planning/targets",
   "Seperti Anggaran, tetapi untuk pendapatan keseluruhan per bulan tanpa rincian per kategori. Dibandingkan "
   "dengan invoice yang sudah terbit dan piutang (AR) yang masih outstanding.", "138,185,186"),
  ("Perkiraan", "/planning/forecasts",
   "Proyeksi otomatis per kategori per bulan, dihitung dari rata-rata realisasi 3 bulan terakhir. Bisa ditautkan "
   "ke Anggaran, dan bisa dilihat untuk 3/6/12 bulan ke depan.", "139,250"),
  ("Transaksi Berulang", "/planning/recurring",
   "Templat invoice/tagihan/beban yang berjadwal. Setiap kali jatuh waktunya, sistem membuat draf baru (tidak "
   "otomatis diterbitkan/disetujui). Bisa dijeda, dilanjutkan, diakhiri, atau dipicu secara manual.",
   "135–137,183,186"),
 ]
),

("10", "Laporan (Reports)",
 "Pusat laporan keuangan baku, beberapa ringkasan khusus (penjualan/pembelian, arus kas, pajak, payroll, "
 "aset & pinjaman), laporan kustom berbasis dataset siap pakai, dan laporan tersimpan pribadi.",
 [
  ("Laporan Keuangan", "/reports",
   "Pusat empat laporan baku: Laba Rugi, Neraca, Perubahan Ekuitas, dan Arus Kas, ditambah Buku Besar dan kolom "
   "pembanding antar periode. Semuanya dihitung dari transaksi yang sudah posting, sehingga selalu konsisten "
   "dengan Jurnal.", "148–150,189–191"),
  ("Penjualan & Pembelian", "/reports/sales-purchase",
   "Ringkasan invoice yang terbit dan tagihan yang disetujui/beban yang dikonfirmasi, dikelompokkan per "
   "pelanggan, vendor, kategori, produk, atau bulan.", ""),
  ("Arus Kas", "/reports/cashflow",
   "Pintasan langsung ke tab Laporan Arus Kas pada Laporan Keuangan.", "240"),
  ("Pajak", "/reports/tax",
   "Pintasan langsung ke Buku Pajak pada modul Pajak.", ""),
  ("Payroll", "/reports/payroll",
   "Pintasan ke tab Ringkasan Payroll dan Kontrol Payroll.", "196,240"),
  ("Aset & Pinjaman", "/reports/assets-loans",
   "Pintasan ke tab Kontrol Aset Tetap. Tab lainnya (Pinjaman Jatuh Tempo, Ringkasan Pinjaman, Jadwal Penyusutan "
   "Fiskal) berada pada kelompok Laporan Keuangan yang sama.", "195,197"),
  ("Laporan Kustom", "/reports/custom",
   "Bukan laporan bebas/custom sepenuhnya &mdash; berisi tiga dataset siap pakai: Invoice per Pelanggan, Tagihan "
   "per Vendor, dan Beban per Penerima.", "152,192"),
  ("Laporan Tersimpan", "/reports/saved",
   "Pintasan pribadi ke kombinasi laporan + filter yang sering dipakai, maksimal 100 per orang.", ""),
 ]
),

("11", "Dokumen (Documents)",
 "Pusat pencarian dokumen, lampiran bukti transaksi, dan arsip dokumen yang sudah diganti versi barunya.",
 [
  ("Pusat Dokumen", "/documents",
   "Mencari dan mendaftar seluruh dokumen, bisa disaring per jenis target, dan hanya menampilkan dokumen yang "
   "izinnya dimiliki pengguna.", "141,194"),
  ("Unggahan", "/documents/uploads",
   "Mengunggah file dilakukan langsung dari halaman detail Invoice/Tagihan/Beban, pada bagian “Lampiran” "
   "(format PDF/JPG/PNG/WebP, maksimal 4&nbsp;MB).",
   "141–142"),
  ("Bukti Terkait", "/documents/evidence",
   "<i>Belum menjadi halaman tersendiri.</i> Satu dokumen bisa menjadi bukti untuk lebih dari satu catatan "
   "transaksi. Jika diganti versi baru, versi lama tetap tersimpan sebagai riwayat.", "141–142"),
  ("Arsip", "/documents/archive",
   "Dokumen yang sudah diganti versi baru atau tidak ditautkan lagi, dipisahkan dari bukti yang masih aktif, "
   "selalu dengan alasan, pengganti, dan waktu pengarsipan.", ""),
 ]
),

("12", "Administrasi (Administration)",
 "Pengaturan tingkat Entity dan organisasi: impor data, jejak audit, pengguna & peran, pengaturan umum, "
 "keamanan, serta cadangan (backup) & pulihkan (restore).",
 [
  ("Impor Data", "/admin/imports",
   "Wizard untuk mengimpor data Kontak, Piutang Terbuka, atau Utang Terbuka secara massal. Lihat alur lengkapnya "
   "di bagian Alur Diagram.", "143–144"),
  ("Jejak Audit", "/admin/audit",
   "Riwayat seluruh perubahan data (tambah/ubah/hapus), yang terbaru di paling atas, bisa disaring per jenis "
   "operasi. Hanya menampilkan nama kolom yang berubah, bukan nilai lama/barunya.", "242"),
  ("Pengguna & Peran", "/admin/users",
   "Daftar anggota beserta peran, status, dan izin efektifnya. Mengubah peran, menonaktifkan akun, atau memberi "
   "izin khusus selalu membutuhkan alasan tertulis dan verifikasi tambahan (step-up). Menambah orang baru harus "
   "melalui Supabase Auth terlebih dahulu.", ""),
  ("Pengaturan", "/admin/settings",
   "Profil Entity, format penomoran dokumen, aturan persetujuan (approval), berbagai pengaturan tersimpan "
   "(misalnya blokir saldo negatif, toleransi tanggal rekonsiliasi, wajib MFA), zona waktu & tahun buku, serta "
   "formulir “Tambah Entity” baru (khusus OWNER).", "243,248,276"),
  ("Konfigurasi SKU", "/admin/sku",
   "Khusus OWNER. Mengatur format kode produk (urutan Brand, Jenis, Nomor, Variant, pemisah, awalan/akhiran, digit, "
   "cakupan nomor), mengelola daftar Brand, Jenis Produk, dan Variant, serta melihat riwayat perubahan SKU. Nomor "
   "dibuat atomik oleh database dan tidak pernah dipakai ulang.", "324"),
  ("Keamanan", "/admin/security",
   "Halaman baca-saja: syarat MFA Entity, kejadian keamanan, dan perangkat terpercaya tiap anggota (dengan opsi "
   "mencabut akses perangkat tersebut).", ""),
  ("Backup & Restore", "/admin/backup",
   "Mengekspor backup (Full, Data-only, atau Arsip Dokumen) dan melihat riwayatnya. Memulihkan dari berkas backup "
   "hanya bisa ke Entity yang masih kosong, membutuhkan verifikasi tambahan (step-up), dan harus mengetikkan "
   "kode Entity untuk konfirmasi.", "224,247"),
 ]
),
]

# ----------------------------------------------------------------------------
# CONTENT: Alur Diagram (flow diagrams) utama
# kind: "normal" (langkah utama), "alt" (jalur alternatif/koreksi), "end" (status akhir)
# ----------------------------------------------------------------------------

FLOWS = [
("Alur Diagram Penjualan", [
    ("Buat invoice (status: <b>Draf</b>) &mdash; pilih pelanggan, isi baris produk/jasa, jumlah, harga, diskon.", "normal"),
    ("(Opsional) Sunting draf sebelum diterbitkan.", "normal"),
    ("Terbitkan invoice &mdash; mendapat nomor resmi, jurnal piutang &amp; pendapatan tercatat, dan tautan "
     "pembayaran publik dibuat. Invoice dengan tanggal di masa depan akan tetap berstatus Draf.", "normal"),
    ("Bagikan tautan pembayaran publik ke pelanggan (tombol “Salin Tautan” &mdash; hanya tersedia setelah terbit).", "normal"),
    ("Pelanggan mengeklik “Saya Sudah Bayar” di halaman publik &rarr; tercipta <b>Klaim Pembayaran</b> berstatus "
     "menunggu. Kas dan buku besar belum berubah pada tahap ini.", "normal"),
    ("Staf meninjau klaim &rarr; <b>Konfirmasi</b> atau <b>Tolak</b> (dengan alasan).", "normal"),
    ("Pembayaran tercatat &amp; dialokasikan ke invoice; kelebihan bayar bisa disimpan sebagai saldo advance pelanggan.", "normal"),
    ("Status invoice otomatis berubah: Belum Dibayar &rarr; Dibayar Sebagian &rarr; <b>Lunas</b> (status ini "
     "dihitung otomatis, tidak pernah diisi manual).", "end"),
    ("Bila perlu, buat Pengembalian Dana dari halaman Pembayaran.", "alt"),
    ("Bila salah: invoice yang masih Draf dibatalkan tanpa efek akuntansi; invoice yang sudah terbit dibatalkan "
     "lewat jurnal pembalik (hanya jika belum ada pembayaran aktif) atau dikoreksi (void + draf pengganti).", "alt"),
], "Invoice bisa dibagikan lewat salin tautan pembayaran publik, atau (bila Resend sudah dikonfigurasi "
   "OWNER) langsung dikirim ke email pelanggan dari halaman Invoice."),

("Alur Diagram Pembelian", [
    ("Buat tagihan (status: <b>Draf</b>) dari vendor &mdash; baris barang/jasa/aset/beban dibayar di muka.", "normal"),
    ("Ajukan untuk disetujui (atau tarik kembali/Recall bila sudah diajukan).", "normal"),
    ("<b>Disetujui</b> &mdash; mendapat nomor resmi, data vendor dibekukan, jurnal tercatat (beban/aset/dibayar "
     "di muka di debit, utang usaha di kredit). Atau <b>Ditolak</b> dengan alasan, kembali ke status Draf.", "normal"),
    ("Bayar vendor dengan tombol <b>Bayar Tagihan</b> di halaman tagihan yang sudah disetujui &mdash; utang usaha dan "
     "saldo rekening berkurang, biaya tidak bertambah lagi (sudah tercatat saat disetujui). Riwayatnya ada di "
     "Pembayaran Keluar.", "normal"),
    ("Status tagihan otomatis: Menunggu Persetujuan &rarr; Terbuka &rarr; (Jatuh Tempo bila lewat tanggal) &rarr; "
     "<b>Lunas</b>.", "end"),
    ("Bila salah: tagihan Draf/Diajukan dibatalkan langsung; tagihan Disetujui yang belum ada pembayaran aktif "
     "dibatalkan lewat jurnal pembalik, atau dikoreksi.", "alt"),
    ("Jalur Beban (pembelian tunai): Draf &rarr; Ajukan &rarr; Konfirmasi &mdash; konfirmasi langsung membukukan "
     "<i>dan</i> membayar sekaligus, tanpa tahap utang terpisah.", "alt"),
]),

("Alur Diagram Rekonsiliasi Bank", [
    ("Mulai sesi rekonsiliasi untuk satu rekening + satu periode; saldo awal otomatis lanjut dari sesi terakhir "
     "yang sudah selesai (sesi harus dikerjakan berurutan).", "normal"),
    ("Tambahkan mutasi rekening koran &mdash; tempel langsung atau impor.", "normal"),
    ("<b>Cocokkan (Match)</b> setiap baris rekening koran dengan mutasi sistem yang jumlahnya sama persis; "
     "sistem menyarankan kandidat pasangannya.", "normal"),
    ("Bila tidak ada yang cocok &rarr; <b>Exclude</b> dengan alasan; atau <b>Unmatch</b> untuk mencoba pasangan lain.", "alt"),
    ("Semua baris harus berstatus Matched atau Excluded sebelum sesi bisa diselesaikan.", "normal"),
    ("<b>Selesaikan sesi (Complete)</b> &mdash; bila ada selisih dengan saldo akhir rekening koran, wajib diberi "
     "alasan tertulis (minimal 10 karakter).", "end"),
    ("Bila perlu dikoreksi lagi: <b>Reopen</b> dengan alasan, lalu <b>Discard</b> (hanya untuk sesi yang belum "
     "completed). Untuk bulan lama setelah bulan yang lebih baru sudah selesai: buka &amp; batalkan dulu sesi "
     "yang baru, baru kemudian buka sesi yang lama.", "alt"),
]),

("Alur Diagram Jurnal Manual", [
    ("Buat draf jurnal: tentukan akun debit &amp; kredit, jumlah, tanggal, dan keterangan.", "normal"),
    ("Jika menyentuh akun Dilindungi/Kontrol: wajib isi alasan override dan butuh izin khusus.", "alt"),
    ("Validasi otomatis oleh sistem: minimal 2 baris, total debit = total kredit, periode berstatus Terbuka atau "
     "Dibuka Kembali, akun aktif (bukan akun grup).", "normal"),
    ("<b>Posting</b> &mdash; mendapat nomor jurnal otomatis, status menjadi Posted, tidak bisa diubah atau "
     "dihapus lagi.", "end"),
    ("Alternatif sebelum posting: draf bisa di-<b>Discard</b> tanpa bekas.", "alt"),
    ("Jika ternyata salah <i>setelah</i> posting &rarr; buat <b>Reversal</b>: jurnal pembalik (mirror), bertanggal "
     "sama atau setelah jurnal aslinya. Hanya bisa dilakukan sekali per jurnal; jurnal asli tidak pernah diubah.", "alt"),
]),

("Alur Diagram Tutup Periode Akuntansi", [
    ("Periode akuntansi tercipta otomatis saat pertama kali dipakai, status awal: <b>Terbuka</b>.", "normal"),
    ("Mulai Tinjauan Penutupan &rarr; status menjadi <b>Dalam Tinjauan Penutupan</b>; tidak ada jurnal baru yang "
     "bisa diposting ke periode ini selama status tersebut.", "normal"),
    ("Sistem memeriksa checklist pemblokir: draf jurnal yang belum diposting, jurnal yang tidak seimbang, saldo "
     "awal migrasi yang belum selesai, selisih kas/bank vs buku besar, selisih buku pajak vs buku besar.", "normal"),
    ("Jika masih ada pemblokir &rarr; selesaikan dulu, atau <b>Batalkan Penutupan</b> untuk kembali ke status Terbuka.", "alt"),
    ("Jika semua bersih &rarr; <b>Tutup Periode (Close)</b> &mdash; periode terkunci penuh.", "end"),
    ("Jika perlu dibuka lagi: <b>Reopen</b> &mdash; wajib alasan tertulis (minimal 10 karakter) dan verifikasi "
     "tambahan (step-up); status menjadi Dibuka Kembali.", "alt"),
]),

("Alur Diagram Pelaporan & Pembayaran Pajak", [
    ("Transaksi (invoice/tagihan/beban) dibuat dengan data pajak di setiap baris.", "normal"),
    ("Dokumen diposting &rarr; mesin pajak otomatis menentukan PPN keluaran/masukan atau PPh (beban pajak PT) yang relevan.", "normal"),
    ("Jika data belum lengkap &rarr; status “Perlu Ditinjau”; belum diakui dalam posisi pajak sampai ditinjau "
     "atau di-override manual (dengan alasan &amp; bukti).", "alt"),
    ("Hasil tercatat permanen di Buku Pajak dan tidak pernah diubah langsung &mdash; koreksi hanya lewat pembatalan "
     "atau pembalikan dokumen sumbernya. (PPh Final UMKM dihitung terpisah tiap bulan lewat menu PPh Final, "
     "bukan otomatis per dokumen.)", "normal"),
    ("Di akhir periode: cek posisi terutang pada PPh Vendor / PPN / PPh Final.", "normal"),
    ("<b>Lapor</b>: rekam di Pelaporan &amp; Bukti &mdash; tanggal, nomor bukti terima, DPP, jumlah (bisa dibetulkan "
     "tanpa menghapus data lama).", "normal"),
    ("<b>Bayar</b>: rekam pembayaran dari rekening kas/bank; PPN otomatis dikompensasi dengan kredit PPN masukan.", "normal"),
    ("Lampirkan bukti lapor/bayar.", "normal"),
    ("Rekonsiliasi periode pajak: membandingkan buku besar vs pembayaran vs pelaporan; selisih wajib diberi "
     "catatan tertulis &mdash; ini juga menjadi salah satu pemblokir tutup periode akuntansi.", "end"),
]),

("Alur Diagram Aset Tetap", [
    ("Beli barang &rarr; buat Tagihan/Beban dengan baris yang ditandai “Aset”.", "normal"),
    ("Setelah disetujui &rarr; aset otomatis terdaftar sebagai draf aset.", "normal"),
    ("<b>Aktivasi</b>: tentukan tanggal mulai pakai, kelompok fiskal (disarankan otomatis oleh sistem), metode "
     "penyusutan, umur manfaat, dan nilai sisa.", "normal"),
    ("Akhir bulan: penyusutan diposting (otomatis saat layar Aset/Penyusutan/Dashboard dibuka, atau manual).", "normal"),
    ("(Opsional) kondisi/lokasi aset diperbarui, atau rencana penyusutan diubah untuk bulan-bulan mendatang.", "alt"),
    ("<b>Pelepasan</b>: dijual, rusak, hilang, atau disumbangkan &mdash; nilai buku dan akumulasi penyusutan "
     "dikeluarkan dari pembukuan, selisihnya menjadi laba/rugi pelepasan.", "end"),
    ("Pelepasan dapat dibatalkan (dibalik), yang akan mengaktifkan kembali aset tersebut.", "alt"),
]),

("Alur Diagram Pinjaman", [
    ("Pinjaman dibuat (pemberi, penerima, jumlah pokok, jadwal cicilan) &mdash; status: <b>Draf</b>.", "normal"),
    ("Diaktifkan &mdash; pokok pinjaman dicairkan.", "normal"),
    ("Cicilan dibayar &mdash; alokasi otomatis ke tunggakan tertua dulu (pokok, bunga, biaya); bunga/biaya diakui "
     "pada saat dibayar, bukan saat jatuh tempo.", "normal"),
    ("Jika perlu: <b>Restrukturisasi</b> &mdash; dibuat jadwal baru, jadwal lama tersimpan sebagai riwayat.", "alt"),
    ("<b>Pelunasan penuh</b>, atau <b>write-off</b> (perlu alasan &amp; verifikasi tambahan, dibukukan sebagai "
     "Beban/Pendapatan Non-Usaha, dan ditandai untuk ditinjau pajaknya).", "end"),
    ("Pinjaman ditutup.", "end"),
]),

("Alur Diagram Proses Payroll", [
    ("Draf dibuat untuk satu periode &amp; satu entitas.", "normal"),
    ("<b>Hitung Payroll</b> &rarr; <b>Sudah dihitung</b>: gaji, PPh 21 (metode TER bulanan, atau TER tahunan di "
     "bulan terakhir tahun), dan BPJS dihitung dari data karyawan yang tersimpan.", "normal"),
    ("Bila perlu: tambahkan penyesuaian, lalu hitung ulang &mdash; tidak bisa lanjut bila masih ada tanda "
     "“perlu ditinjau”.", "alt"),
    ("<b>Ajukan untuk Disetujui</b> &rarr; <b>Diajukan</b>.", "normal"),
    ("<b>Setujui</b> &rarr; <b>Disetujui</b> (penyetuju harus berbeda dari pengaju, kecuali untuk OWNER atau "
     "pengaturan maker-checker khusus).", "normal"),
    ("<b>Posting ke Pembukuan</b> &rarr; <b>Terposting</b>: satu aksi ini membuat jurnal, mencatat posisi PPh 21, "
     "dan menerbitkan seluruh slip gaji sekaligus.", "normal"),
    ("Bayar gaji bersih &mdash; per karyawan, bisa sebagian atau penuh, hingga status Dibayar Sebagian &rarr; "
     "<b>Dibayar Penuh</b>.", "normal"),
    ("Bayar BPJS Kesehatan secara terpisah &mdash; ke akun <b>2221</b>, tidak boleh melebihi yang terutang.", "normal"),
    ("Bayar BPJS Ketenagakerjaan (JHT/JP/JKK/JKM) secara terpisah &mdash; ke akun <b>2220</b>, tidak boleh "
     "melebihi yang terutang. (PPh 21 <i>tidak</i> dibayar dari sini, melainkan lewat menu Pajak.)", "normal"),
    ("<b>Tutup Payroll</b> &rarr; <b>Ditutup</b>, setelah semua pembayaran selesai.", "end"),
    ("Jalur Koreksi (dari Terposting/Dibayar Sebagian/Dibayar Penuh): <b>Koreksi Payroll</b> &mdash; jurnal &amp; "
     "catatan pajak dibalik, slip lama dibatalkan (tetap terlihat sebagai riwayat), revisi baru dibuka sebagai "
     "Draf baru. Semua pembayaran yang ada harus dibalik dulu, dan hanya bulan pajak terposting yang paling baru "
     "yang boleh dikoreksi.", "alt"),
    ("Jalur lain: <b>Batalkan Proses</b> (dari Draf &rarr; Dibuang), <b>Kembalikan ke Draf</b> (dari Diajukan), "
     "<b>Buka Kembali</b> (dari Ditutup &mdash; perlu otorisasi &amp; alasan).", "alt"),
], "Pemisahan BPJS Kesehatan/Ketenagakerjaan menjadi dua akun terpisah (2220 &amp; 2221) adalah hasil "
        "keputusan 277–278 dan sudah diverifikasi berjalan benar."),

("Alur Diagram Impor Data", [
    ("Administrasi &rarr; Impor Data &rarr; Impor Baru.", "normal"),
    ("Pilih jenis data: Kontak / Piutang Terbuka / Utang Terbuka.", "normal"),
    ("Tempelkan tabel dari spreadsheet, atau unggah berkas CSV.", "normal"),
    ("Periksa pemetaan kolom otomatis yang disarankan sistem.", "normal"),
    ("<b>Periksa Data</b> &mdash; sistem memvalidasi setiap baris.", "normal"),
    ("Jika ada baris bermasalah: perbaiki di sumber data, lalu <b>Periksa Ulang</b>.", "alt"),
    ("<b>Terapkan ke Pembukuan</b> &mdash; mengunci dan mencatat semua baris yang valid.", "end"),
    ("Jika perlu, impor ini bisa <b>Dibatalkan</b> sebelum diterapkan.", "alt"),
]),

("Alur Diagram Anggaran / Target Pendapatan", [
    ("Perencanaan &rarr; Anggaran (atau Target Pendapatan) &rarr; Buat Baru.", "normal"),
    ("Tentukan periode, dan untuk Anggaran: kategori yang ingin direncanakan.", "normal"),
    ("Isi nominal per bulan (dan per kategori untuk Anggaran).", "normal"),
    ("<b>Aktifkan</b> rencana (Draft &rarr; Aktif).", "normal"),
    ("Sistem otomatis membandingkan dengan Realisasi dan Committed (transaksi yang masih berjalan).", "normal"),
    ("Lihat Perkiraan sebagai pembanding tambahan, dan tautkan ke Anggaran bila diperlukan.", "alt"),
    ("Tutup rencana di akhir periode &mdash; status <b>Ditutup</b>, tidak bisa dibuka lagi.", "end"),
]),
]

# ----------------------------------------------------------------------------
# CONTENT: Peran & Izin (role templates)
# ----------------------------------------------------------------------------

ROLES = [
 ("OWNER", "Kendali penuh atas semua Entity yang berwenang. Peran awal setiap organisasi. Memegang semua izin "
           "secara otomatis dan tidak bisa ditolak; wajib MFA tanpa terkecuali; satu-satunya peran dengan akses "
           "otomatis ke Backup &amp; Restore; satu-satunya yang bisa menambah Entity baru. Setiap Entity wajib "
           "memiliki minimal satu OWNER yang aktif."),
 ("Finance Admin", "Administrasi keuangan sehari-hari, tanpa hak kepemilikan atau keamanan tingkat organisasi. "
                    "Juga memegang izin impor data (system.import)."),
 ("Finance Staff", "Transaksi rutin: penjualan, pembelian, pembayaran, dan dokumen, dalam batas kewenangan yang "
                    "diberikan."),
 ("Approver", "Meninjau dan menyetujui transaksi yang sudah dikonfigurasi perlu persetujuan, tanpa hak edit "
               "yang luas."),
 ("Accountant", "Akuntansi, rekonsiliasi, mendukung proses tutup periode, jurnal, dan laporan keuangan."),
 ("Tax", "Meninjau pajak, Buku Pajak, laporan pajak, dan bukti kepatuhan."),
 ("Payroll", "Hanya akses ke data karyawan dan modul Payroll."),
 ("Viewer / Auditor", "Akses baca-saja ke modul &amp; laporan yang diberikan."),
]

# Catatan umum / keterbatasan yang perlu diketahui pembaca
GENERAL_NOTES = [
    "Menu <b>Unggahan</b> dan <b>Bukti Terkait</b> (dalam modul Dokumen) belum menjadi halaman tersendiri; "
    "unggah lampiran dijalankan dari halaman detail transaksi (Invoice/Tagihan/Beban).",
    "Beberapa submenu pada modul <b>Laporan</b> (Arus Kas, Pajak, Payroll, Aset &amp; Pinjaman) adalah pintasan "
    "(shortcut) ke tab yang sudah ada di halaman lain, bukan halaman laporan yang berdiri sendiri.",
    "Halaman <b>Aturan Pajak</b> masih menggunakan entri data JSON mentah, bukan formulir terpandu &mdash; "
    "disarankan hanya ditangani oleh OWNER atau staf teknis.",
    "Proses Payroll belum mendukung proration otomatis untuk karyawan yang masuk/keluar di tengah bulan.",
    "Pinjaman dan aset tetap bisa dicatat dalam mata uang asing: pinjaman lewat revaluasi kurs bulanan manual "
    "(selisih kurs diposting otomatis ke laba/rugi), aset tetap lewat catatan mata uang &amp; kurs saat "
    "perolehan (tidak direvaluasi ulang). Akrual bunga pinjaman otomatis belum didukung &mdash; bunga masih "
    "dicatat saat dibayar, bukan saat terutang.",
    "Dasar fiskal penyusutan aset dan aturan pajak payroll masih menunggu verifikasi konsultan pajak OWNER "
    "sebelum benar-benar digunakan untuk pelaporan resmi (go-live).",
    "PPh 21 dari payroll secara sengaja <i>tidak</i> ditangani lewat modul Pajak, melainkan lewat menu "
    "“Pajak &amp; Kewajiban Payroll” di dalam modul Payroll.",
    "<b>Invoice yang sudah diterbitkan tetapi belum dibayar otomatis menjadi Piutang Usaha</b> (akun 1200) dan "
    "pendapatan langsung diakui saat invoice terbit. Saat pelanggan membayar, pakai <b>Catat Pembayaran</b> pada "
    "hari uang masuk ke rekening PT: piutang berkurang, kas bertambah, pendapatan tidak bertambah lagi. "
    "Penjelasan lengkap ada di Bagian VI, panduan “Memahami Piutang dan Pendapatan”.",
    "Fitur khusus untuk uang yang lebih dulu diterima di rekening pribadi atau rekening direktur belum ada "
    "(menunggu keputusan OWNER); sementara itu catat pembayaran hanya saat uang benar-benar masuk ke rekening PT.",
]

# ----------------------------------------------------------------------------
# DOCUMENT TEMPLATE with Table of Contents support
# ----------------------------------------------------------------------------

PAGE_W, PAGE_H = A4
MARGIN = 20 * mm



# ----------------------------------------------------------------------------
# Bagian VI: step-by-step guides rendered from the website's JSON content
# ----------------------------------------------------------------------------
_INLINE = re.compile(r"\*\*([^*]+)\*\*|\[([^\]]+)\]\(([a-z0-9-]+)\)")


def _plain(t):
    """Escape text for reportlab's mini-markup; Helvetica has no arrow glyph."""
    return (t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
             .replace("→", "&gt;").replace("≥", "&gt;=").replace("≤", "&lt;="))


def inline(text):
    """`**bold**` and `[teks](slug)` (internal link) to reportlab markup."""
    out, last = [], 0
    for m in _INLINE.finditer(text):
        out.append(_plain(text[last:m.start()]))
        if m.group(1) is not None:
            out.append("<b>%s</b>" % _plain(m.group(1)))
        else:
            out.append('<a href="#g-%s" color="#1a4d8f"><u>%s</u></a>' % (m.group(3), _plain(m.group(2))))
        last = m.end()
    out.append(_plain(text[last:]))
    return "".join(out)


def paras(text, style="GuideBody"):
    return [Paragraph(inline(p).replace("\n", "<br/>"), styles[style]) for p in text.split("\n\n") if p.strip()]


def callout(kind, text):
    label, bg, bar = {
        "tip": ("Tips", "#eaf3ec", "#2f5233"),
        "warning": ("Perhatian", "#fdf0e0", "#b5791a"),
    }[kind]
    cell = Paragraph('<b>%s:</b> %s' % (label, inline(text)), styles["GuideCell"])
    t = Table([[cell]], colWidths=[400])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), colors.HexColor(bg)),
        ("LINEBEFORE", (0, 0), (0, -1), 3, colors.HexColor(bar)),
        ("LEFTPADDING", (0, 0), (-1, -1), 8), ("RIGHTPADDING", (0, 0), (-1, -1), 6),
        ("TOPPADDING", (0, 0), (-1, -1), 5), ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
    ]))
    return t


def shot(image):
    path = os.path.join(GUIDE_DIR, "images", image["file"])
    if not os.path.exists(path):
        return []
    from reportlab.lib.utils import ImageReader
    w, h = ImageReader(path).getSize()
    max_w, max_h = 440.0, 290.0
    scale = min(max_w / w, max_h / h)
    img = RLImage(path, width=w * scale, height=h * scale)
    frame = Table([[img]], colWidths=[w * scale + 6])
    frame.setStyle(TableStyle([
        ("BOX", (0, 0), (-1, -1), 0.6, colors.HexColor("#c9ced6")),
        ("LEFTPADDING", (0, 0), (-1, -1), 2), ("RIGHTPADDING", (0, 0), (-1, -1), 2),
        ("TOPPADDING", (0, 0), (-1, -1), 2), ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
    ]))
    frame.hAlign = "CENTER"
    return [Spacer(1, 3), frame, Paragraph("Gambar: " + _plain(image["caption"]), styles["GuideCaption"])]


def step_block(number, step):
    num = Table([[Paragraph(str(number), styles["StepNum"])]], colWidths=[22], rowHeights=[20])
    num.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, -1), DARK), ("VALIGN", (0, 0), (-1, -1), "MIDDLE")]))
    body = [Paragraph("<b>%s</b>" % _plain(step["title"]), styles["GuideBody"])]
    body += paras(step["text"])
    if step.get("tip"):
        body += [Spacer(1, 2), callout("tip", step["tip"])]
    if step.get("warning"):
        body += [Spacer(1, 2), callout("warning", step["warning"])]
    def _row(cells):
        row = Table([cells], colWidths=[30, 410])
        row.setStyle(TableStyle([
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("LEFTPADDING", (0, 0), (-1, -1), 0), ("RIGHTPADDING", (0, 0), (-1, -1), 0),
            ("TOPPADDING", (0, 0), (-1, -1), 4), ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
        ]))
        return row

    if step.get("image"):
        picture = shot(step["image"])
        together = _row([num, body + picture])
        # A step whose text and picture together are taller than one page cannot be placed in a single table
        # row: draw the picture as its own row right under the text (same look, may break onto the next page).
        if together.wrap(440, 10000)[1] <= 640:
            return together
        return KeepTogether([_row([num, body]), _row(["", picture])])
    single = _row([num, body])
    if single.wrap(440, 10000)[1] <= 640:
        return single
    # A very long step (many paragraphs) is split into several rows so that no row is taller than a page.
    rows, chunk = [], []
    for flowable in body:
        trial = Table([[ "", chunk + [flowable] ]], colWidths=[30, 410])
        if chunk and trial.wrap(440, 10000)[1] > 600:
            rows.append(chunk)
            chunk = []
        chunk.append(flowable)
    if chunk:
        rows.append(chunk)
    return [_row([num if i == 0 else "", part]) for i, part in enumerate(rows)]


def data_table(columns, rows, widths=None):
    data = [[Paragraph("<b>%s</b>" % _plain(c), styles["GuideCell"]) for c in columns]]
    for r in rows:
        data.append([Paragraph(inline(c), styles["GuideCell"]) for c in r])
    total = 440.0
    widths = widths or [total / len(columns)] * len(columns)
    t = Table(data, colWidths=widths, repeatRows=1)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#dfe6f1")),
        ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#bbbbbb")),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("TOPPADDING", (0, 0), (-1, -1), 4), ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#f6f8fb")]),
    ]))
    return t


def bullets(items):
    return [Paragraph("&bull;&nbsp; " + inline(i), styles["GuideBody"]) for i in items]


def guide_flow(guide, titles):
    flow = [Paragraph('<a name="g-%s"/>%s' % (guide["slug"], _plain(guide["title"])), styles["GuideHeading"])]
    meta = Table([
        [Paragraph("<b>Lokasi menu</b>", styles["GuideCell"]), Paragraph(inline(guide["path"]), styles["GuideCell"])],
        [Paragraph("<b>Siapa yang bisa</b>", styles["GuideCell"]), Paragraph(inline(guide["who"]), styles["GuideCell"])],
    ], colWidths=[90, 350])
    meta.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), colors.HexColor("#f2f4f8")),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("TOPPADDING", (0, 0), (-1, -1), 3), ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
    ]))
    flow += paras(guide["summary"]) + [meta, Spacer(1, 4)]
    if guide.get("quick"):
        flow.append(callout("tip", "Ringkasnya. " + guide["quick"]))
        flow.append(Spacer(1, 4))
    if GUIDE_FLOWS.get(guide["slug"]):
        links = ", ".join('<a href="#f-%s" color="#1a4d8f"><u>%s</u></a>' % (fl["id"], _plain(fl["title"]))
                          for fl in GUIDE_FLOWS[guide["slug"]])
        flow.append(Paragraph("<b>Diagram alur:</b> " + links + " (lihat bab Alur Kerja)", styles["GuideBody"]))
        flow.append(Spacer(1, 2))
    flow.append(Paragraph("Langkah-langkah", styles["GuideH3"]))
    for i, step in enumerate(guide["steps"], 1):
        block = step_block(i, step)
        flow.extend(block if isinstance(block, list) else [block])
    for table in guide.get("tables", []):
        flow.append(Paragraph(_plain(table["title"]), styles["GuideH3"]))
        flow.append(data_table(table["columns"], table["rows"]))
    for key, title in (("result", "Hasil setelah berhasil"), ("rules", "Aturan penting"),
                       ("mistakes", "Kesalahan yang sering terjadi")):
        if guide.get(key):
            flow.append(Paragraph(title, styles["GuideH3"]))
            flow += bullets(guide[key])
    if guide.get("errors"):
        flow.append(Paragraph("Pesan kesalahan dan artinya", styles["GuideH3"]))
        flow.append(data_table(["Pesan di layar", "Artinya dan cara memperbaiki"],
                               [[e["message"], e["meaning"]] for e in guide["errors"]], [200, 240]))
    if guide.get("related"):
        links = ", ".join('<a href="#g-%s" color="#1a4d8f"><u>%s</u></a>' % (slug, _plain(titles.get(slug, slug)))
                          for slug in guide["related"])
        flow.append(Paragraph("<b>Panduan terkait:</b> " + links, styles["GuideBody"]))
    flow.append(HRFlowable(width="100%", color=colors.HexColor("#d9dde4"), spaceBefore=8, spaceAfter=4))
    return flow


FLOW_DATA = {"flows": [], "quick": []}
GUIDE_FLOWS = {}  # guide slug -> flows that explain it


def load_flows():
    data, _ = flow_diagrams.load(GUIDE_DIR)
    FLOW_DATA.update(data)
    GUIDE_FLOWS.clear()
    for fl in data["flows"]:
        for slug in fl["guides"]:
            GUIDE_FLOWS.setdefault(slug, []).append(fl)


def flow_chapter(titles):
    """Alur Kerja (Diagram): the lookup table and every flow diagram, drawn by the same code as the website."""
    data = FLOW_DATA
    story = [Paragraph("Alur Kerja (Diagram)", styles["GuideGroupHeading"])]
    story += paras(data["intro"])
    story.append(Spacer(1, 4))
    story.append(Paragraph("Daftar diagram, urut dari pertama kali memakai aplikasi", styles["GuideH3"]))
    listed_stage = None
    for number, fl in enumerate(data["flows"], start=1):
        if fl.get("stage") != listed_stage:
            listed_stage = fl.get("stage")
            story.append(Paragraph("<b>%s</b>" % _plain(listed_stage or ""), styles["GuideBody"]))
        story.append(Paragraph('&nbsp;&nbsp;&bull;&nbsp; <a href="#f-%s" color="#1a4d8f"><u>%d. %s</u></a>'
                               % (fl["id"], number, _plain(fl["title"])), styles["GuideCell"]))
    story.append(Spacer(1, 6))
    story.append(Paragraph("Saya mau ... buka menu apa?", styles["GuideH3"]))
    rows = []
    for row in data["quick"]:
        rows.append([row["want"], row["menu"], "[%s](%s)" % (titles.get(row["guide"], row["guide"]), row["guide"])])
    story.append(data_table(["Saya mau", "Buka menu", "Panduan lengkap"], rows, [150, 170, 120]))
    story.append(PageBreak())
    current_stage = None
    for number, fl in enumerate(data["flows"], start=1):
        for draw_width in (440, 400, 360, 320):  # a flow with one very tall decision is shrunk until it fits a page
            pieces = flow_diagrams.to_drawings(fl, draw_width, 600)
            if all(piece.height <= 640 for piece in pieces):
                break
        if fl.get("stage") != current_stage:
            current_stage = fl.get("stage")
            story.append(CondPageBreak(pieces[0].height + 140))
            story.append(Paragraph(_plain(current_stage or ""), styles["GuideGroupHeading"]))
        head = [Paragraph('<a name="f-%s"/>%d. %s' % (fl["id"], number, _plain(fl["title"])), styles["GuideHeading"])]
        head += paras(fl["summary"])
        head.append(Spacer(1, 4))
        story.append(CondPageBreak(pieces[0].height + 90))
        story.append(KeepTogether(head + [pieces[0]]))
        for piece in pieces[1:]:
            story.append(CondPageBreak(piece.height + 10))
            story.append(piece)
        guides = ", ".join('<a href="#g-%s" color="#1a4d8f"><u>%s</u></a>' % (slug, _plain(titles.get(slug, slug)))
                           for slug in fl["guides"])
        story.append(Paragraph("<b>Panduan langkah demi langkah:</b> " + guides, styles["GuideBody"]))
        story.append(HRFlowable(width="100%", color=colors.HexColor("#d9dde4"), spaceBefore=8, spaceAfter=8))
    story.append(PageBreak())
    return story


def load_guides():
    groups = []
    for name in GUIDE_FILES:
        with open(os.path.join(GUIDE_DIR, name), encoding="utf-8") as f:
            groups.append(json.load(f))
    return groups


def guide_section_story():
    groups = load_guides()
    load_flows()
    titles = {g["slug"]: g["title"] for grp in groups for g in grp["guides"]}
    story = [Paragraph("Bagian VI &mdash; Panduan Langkah demi Langkah", styles["ModuleHeading"])]
    story += paras(
        "Bagian ini sama persis dengan menu <b>Panduan</b> di website (isinya diambil dari sumber yang sama). "
        "Tiap panduan menjelaskan satu pekerjaan dari awal sampai selesai: di mana menunya, siapa yang boleh, "
        "langkah demi langkah dengan gambar layar asli, hasil yang benar, aturan penting, kesalahan yang sering "
        "terjadi, dan arti pesan kesalahan. Bab pertama, <b>Alur Kerja (Diagram)</b>, menggambar alur dari sebuah "
        "kejadian (misalnya ada pelanggan yang mau membayar) sampai menu yang harus dibuka. Tulisan bergaris bawah "
        "biru adalah tautan ke panduan atau diagram lain.", "Intro")
    story.append(Spacer(1, 4))
    story.append(Paragraph("<b>Daftar panduan</b>", styles["GuideBody"]))
    story.append(Paragraph('&nbsp;&nbsp;&bull;&nbsp; <a href="#f-%s" color="#1a4d8f"><u>Alur Kerja (Diagram): gambar alur '
                           'dari kejadian ke menu yang harus dibuka</u></a>' % FLOW_DATA["flows"][0]["id"],
                           styles["GuideCell"]))
    for grp in groups:
        story.append(Paragraph("<b>%s</b>" % _plain(grp["title"]), styles["GuideBody"]))
        for g in grp["guides"]:
            story.append(Paragraph('&nbsp;&nbsp;&bull;&nbsp; <a href="#g-%s" color="#1a4d8f"><u>%s</u></a>'
                                   % (g["slug"], _plain(g["title"])), styles["GuideCell"]))
    story.append(PageBreak())
    story += flow_chapter(titles)
    for grp in groups:
        story.append(Paragraph(_plain(grp["title"]), styles["GuideGroupHeading"]))
        story += paras(grp["description"])
        for g in grp["guides"]:
            story += guide_flow(g, titles)
        story.append(PageBreak())
    return story


class GuideDocTemplate(BaseDocTemplate):
    def afterFlowable(self, flowable):
        if hasattr(flowable, "style"):
            name = flowable.style.name
            text = None
            try:
                text = flowable.getPlainText()
            except Exception:
                text = None
            if text:
                if name == "ModuleHeading":
                    self.notify("TOCEntry", (0, text, self.page))
                elif name == "FlowTitle":
                    self.notify("TOCEntry", (0, text, self.page))
                elif name == "SubHeading":
                    self.notify("TOCEntry", (1, text, self.page))
                elif name == "GuideGroupHeading":
                    self.notify("TOCEntry", (1, text, self.page))
                elif name == "GuideHeading":
                    self.notify("TOCEntry", (2, text, self.page))


def header_footer(canvas, doc):
    canvas.saveState()
    canvas.setFont("Helvetica", 7.5)
    canvas.setFillColor(colors.HexColor("#999999"))
    canvas.drawString(MARGIN, 12 * mm, "Panduan Penggunaan Hikarich Finance")
    canvas.drawRightString(PAGE_W - MARGIN, 12 * mm, "Halaman %d" % doc.page)
    canvas.setStrokeColor(colors.HexColor("#cccccc"))
    canvas.line(MARGIN, 16 * mm, PAGE_W - MARGIN, 16 * mm)
    canvas.restoreState()


def cover_page(canvas, doc):
    canvas.saveState()
    canvas.setFillColor(DARK)
    canvas.rect(0, PAGE_H - 70 * mm, PAGE_W, 70 * mm, fill=1, stroke=0)
    canvas.setFillColor(colors.white)
    canvas.setFont("Helvetica-Bold", 30)
    canvas.drawCentredString(PAGE_W / 2, PAGE_H - 40 * mm, "Hikarich Finance")
    canvas.setFont("Helvetica", 14)
    canvas.drawCentredString(PAGE_W / 2, PAGE_H - 52 * mm, "Panduan Penggunaan Aplikasi")
    canvas.restoreState()


def build():
    doc = GuideDocTemplate(OUT_PATH, pagesize=A4,
                            leftMargin=MARGIN, rightMargin=MARGIN,
                            topMargin=28 * mm, bottomMargin=22 * mm,
                            title="Panduan Penggunaan Hikarich Finance")

    frame = Frame(MARGIN, 22 * mm, PAGE_W - 2 * MARGIN, PAGE_H - 28 * mm - 22 * mm, id="normal")
    cover_frame = Frame(MARGIN, 22 * mm, PAGE_W - 2 * MARGIN, PAGE_H - 28 * mm - 22 * mm, id="cover")

    doc.addPageTemplates([
        PageTemplate(id="Cover", frames=[cover_frame], onPage=cover_page),
        PageTemplate(id="Normal", frames=[frame], onPage=header_footer),
    ])

    toc = TableOfContents()
    styles.add(ParagraphStyle(
        name="TOCHeading3", fontName="Helvetica", fontSize=8.8, leading=11.5,
        leftIndent=28, textColor=colors.HexColor("#555555"),
    ))
    toc.levelStyles = [styles["TOCHeading1"], styles["TOCHeading2"], styles["TOCHeading3"]]

    story = []

    # ---- Cover ----
    story.append(Spacer(1, 90 * mm))
    story.append(Paragraph("Untuk Owner dan Setiap Pengguna yang Memiliki Akun", styles["CoverSubtitle"]))
    story.append(Spacer(1, 10))
    story.append(Paragraph(
        "Mencakup fungsi setiap menu &amp; sub-menu, serta alur diagram langkah-demi-langkah untuk "
        "proses bisnis utama di aplikasi.", styles["CoverMeta"]))
    story.append(Spacer(1, 40))
    story.append(Paragraph("PT Hikarich Kitana Digital &nbsp;&bull;&nbsp; Hikarich", styles["CoverMeta"]))
    story.append(Paragraph("Oktober 2026", styles["CoverMeta"]))
    story.append(NextPageTemplate("Normal"))
    story.append(PageBreak())

    # ---- Table of Contents ----
    story.append(Paragraph("Daftar Isi", styles["ModuleHeading"]))
    story.append(Spacer(1, 6))
    story.append(toc)
    story.append(PageBreak())

    # ---- Pendahuluan ----
    story.append(Paragraph("Pendahuluan", styles["ModuleHeading"]))
    story.append(Paragraph(
        "Dokumen ini adalah panduan penggunaan aplikasi <b>Hikarich Finance</b>, ditujukan untuk OWNER dan "
        "setiap orang yang memiliki akun pada aplikasi ini. Panduan ini terdiri dari enam bagian:",
        styles["Intro"]))
    story.append(Paragraph(
        "<b>Bagian I &mdash; Langkah Awal:</b> apa yang harus disiapkan pertama kali (rekening, kategori, pelanggan, "
        "produk &amp; jasa) supaya pembuatan invoice dan pengeluaran tinggal klik, lengkap dengan urutannya.", styles["Intro"]))
    story.append(Paragraph(
        "<b>Bagian II &mdash; Fungsi Menu &amp; Sub-Menu:</b> penjelasan singkat setiap menu dan sub-menu yang "
        "tersedia, dikelompokkan menurut 12 modul navigasi aplikasi.", styles["Intro"]))
    story.append(Paragraph(
        "<b>Bagian III &mdash; Alur Diagram Penggunaan:</b> langkah-demi-langkah untuk proses bisnis utama "
        "(misalnya: Penjualan, Pembelian, Payroll, dan lainnya), disajikan sebagai diagram alur bernomor.",
        styles["Intro"]))
    story.append(Paragraph(
        "<b>Bagian IV &mdash; Peran &amp; Izin:</b> ringkasan delapan templat peran (role) yang tersedia dan "
        "apa yang dapat dilakukan masing-masing.", styles["Intro"]))
    story.append(Paragraph(
        "<b>Bagian V &mdash; Catatan &amp; Keterbatasan:</b> hal-hal yang perlu diketahui pengguna karena "
        "masih dalam tahap penyempurnaan.", styles["Intro"]))
    story.append(Paragraph(
        "<b>Bagian VI &mdash; Panduan Langkah demi Langkah:</b> cara mengerjakan setiap pekerjaan dari awal "
        "sampai selesai (menerima pembayaran, membuat biaya, menambah rekening, dan lainnya), lengkap dengan "
        "gambar layar asli. Isinya sama dengan menu <b>Panduan</b> di website.", styles["Intro"]))
    story.append(Spacer(1, 6))
    story.append(HRFlowable(width="100%", color=colors.HexColor("#dddddd")))
    story.append(PageBreak())

    # ---- Bagian I: Langkah Awal ----
    story.append(Paragraph("Bagian I &mdash; Langkah Awal Memakai Website", styles["ModuleHeading"]))
    story.append(Paragraph(START_INTRO, styles["Intro"]))
    story.append(Spacer(1, 8))
    story.extend(flow_diagram("Urutan Persiapan Pertama Kali", START_STEPS))
    story.extend(flow_diagram("Alamat Website &amp; Pengiriman Email (Resend)", EMAIL_STEPS,
        "Jika email gagal terkirim, tautan pembayaran tetap bisa dibagikan lewat tombol Salin Tautan Publik."))
    story.append(Paragraph("Tips", styles["SubHeading"]))
    for tip in START_TIPS:
        story.append(Paragraph("&bull;&nbsp; " + tip, styles["ItemDesc"]))
        story.append(Spacer(1, 4))
    story.append(PageBreak())

    # ---- Bagian II: Modul & Sub-menu ----
    story.append(Paragraph("Bagian II &mdash; Fungsi Menu &amp; Sub-Menu", styles["ModuleHeading"]))
    story.append(Spacer(1, 4))

    for num, title, intro, items in SECTIONS:
        section_flow = []
        section_flow.append(Paragraph("%s. %s" % (num, esc(title)), styles["SubHeading"]))
        if intro:
            section_flow.append(Paragraph(intro, styles["Intro"]))
        for name, href, desc, refs in items:
            row_html = "<b>%s</b>" % esc(name)
            if href:
                row_html += '  <font face="Courier" size="8.3" color="#8a6d00">%s</font>' % esc(href)
            section_flow.append(Paragraph(row_html, styles["ItemName"]))
            desc_html = desc
            if refs:
                desc_html += ref(refs)
            section_flow.append(Paragraph(desc_html, styles["ItemDesc"]))
            section_flow.append(Spacer(1, 5))
        story.extend(section_flow)
        story.append(Spacer(1, 8))

    story.append(PageBreak())

    # ---- Bagian II: Alur Diagram ----
    story.append(Paragraph("Bagian III &mdash; Alur Diagram Penggunaan", styles["ModuleHeading"]))
    story.append(Paragraph(
        "Kotak biru bernomor menunjukkan langkah utama secara berurutan. Kotak oranye bertanda seru (!) "
        "menunjukkan jalur alternatif (koreksi, pembatalan, atau kondisi khusus). Kotak hijau menandai status "
        "akhir dari proses tersebut.", styles["Intro"]))
    story.append(Spacer(1, 10))

    for i, (title, steps) in enumerate([(f[0], f[1]) for f in FLOWS]):
        note = FLOWS[i][2] if len(FLOWS[i]) > 2 else None
        story.extend(flow_diagram(title, steps, note))
        story.append(PageBreak())

    # remove trailing page break duplication by just continuing to next section
    # ---- Bagian III: Peran & Izin ----
    story.append(Paragraph("Bagian IV &mdash; Peran &amp; Izin (Role)", styles["ModuleHeading"]))
    story.append(Paragraph(
        "Aplikasi menyediakan delapan templat peran yang dapat diberikan ke setiap anggota per Entity. "
        "Satu orang bisa memiliki peran berbeda di Entity yang berbeda.", styles["Intro"]))
    story.append(Spacer(1, 8))

    role_rows = [[Paragraph("<b>Peran</b>", styles["ItemDesc"]), Paragraph("<b>Cakupan Akses</b>", styles["ItemDesc"])]]
    for name, desc in ROLES:
        role_rows.append([Paragraph("<b>%s</b>" % esc(name), styles["ItemDesc"]), Paragraph(desc, styles["ItemDesc"])])
    role_table = Table(role_rows, colWidths=[110, 350])
    role_table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), DARK),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("GRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#cccccc")),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("TOPPADDING", (0, 0), (-1, -1), 6),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
        ("LEFTPADDING", (0, 0), (-1, -1), 8),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, LIGHTBOX]),
    ]))
    story.append(role_table)
    story.append(PageBreak())

    # ---- Bagian IV: Catatan & Keterbatasan ----
    story.append(Paragraph("Bagian V &mdash; Catatan &amp; Keterbatasan", styles["ModuleHeading"]))
    story.append(Paragraph(
        "Aplikasi ini terus disempurnakan. Berikut hal-hal yang perlu diketahui pengguna saat ini:",
        styles["Intro"]))
    story.append(Spacer(1, 6))
    for n in GENERAL_NOTES:
        story.append(Paragraph("&bull;&nbsp; " + n, styles["ItemDesc"]))
        story.append(Spacer(1, 4))

    story.append(PageBreak())
    story += guide_section_story()

    doc.multiBuild(story)
    print("PDF written to", OUT_PATH)


if __name__ == "__main__":
    build()

