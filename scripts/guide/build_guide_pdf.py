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
# The step-by-step guides (Bagian V) are read from the SAME JSON files the website's "Panduan" menu uses, so
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
    "Jika salah memasukkan data awal (misalnya rekening), perbaiki lewat halaman detailnya selama belum ada transaksi.",
    "Angka dan tanggal yang sudah diposting tidak diubah langsung. Koreksi dilakukan lewat pembatalan atau pembalikan, "
    "sehingga riwayat tetap utuh.",
    "Tautan &quot;&larr; Kembali ke ...&quot; di halaman data membawa Anda ke halaman yang dibuka sebelumnya (misalnya Aktivitas "
    "Terbaru), seperti tombol Back browser; bila halaman dibuka langsung, tautan itu menuju daftar aslinya.",
    "Warna angka: hijau = uang masuk, merah = uang keluar (mutasi rekening, Rekening Koran, Arus Kas, daftar pembayaran, "
    "Aktivitas Terbaru). Saldo, total, Laba Rugi, dan Neraca memakai warna biasa.",
    "Pinjaman bank tidak masuk kartu Utang Usaha (hanya tagihan vendor); sisa pokoknya tampil di kartu Pinjaman di Dashboard "
    "dan di Aset &amp; Pendanaan &rarr; Pinjaman. Bunga pinjaman berubah (misalnya bunga tetap lalu mengambang)? Isi "
    "tahap bunga (Bunga Berjenjang) saat membuat pinjaman, cukup tahun mulainya (misalnya mulai tahun ke-4), atau tekan "
    "Ubah Bunga pada pinjaman berjalan: cicilan berikutnya dihitung ulang dari sisa pokok dengan jangka waktu yang sama. "
    "Membayar cicilan: tekan Bayar Cicilan, pilih Cicilan sesuai jadwal lalu isi berapa cicilan yang dibayar (1, 2, dan "
    "seterusnya); pokok dan bunga terisi otomatis dan bunga tidak perlu catatan. Mau bayar sebagian pokok lebih awal? "
    "Pilih Pelunasan dipercepat, lalu pilih jangka waktu dipersingkat atau cicilan diperkecil. "
    "Restrukturisasi Jadwal untuk pinjaman "
    "yang sulit dibayar.",
]

# ----------------------------------------------------------------------------
# CONTENT: menu & sub-menu. Read from the REAL menu (src/domain/shell/navigation.ts) and from the description
# under each page title (src/content/pageHelp.ts) by scripts/guide/export_menu.mts, so this chapter follows the
# application and cannot drift from it.
# ----------------------------------------------------------------------------
GROUP_INTRO = {
    "overview": "Halaman pertama setelah masuk: ikhtisar posisi keuangan Entity yang sedang aktif, saldo kas dan bank, dan aktivitas terbaru. Hanya membaca, tidak mengubah data.",
    "sales": "Semua yang berhubungan dengan menjual ke pelanggan: invoice, pembayaran, klaim pembayaran, pendapatan tanpa invoice, marketplace, refund, serta data pelanggan dan produk.",
    "purchases": "Semua yang berhubungan dengan membeli dari vendor: tagihan, pengeluaran langsung (beban), pembayaran ke vendor, dan data vendor.",
    "money": "Rekening kas, bank, dan e-wallet milik Entity: saldo, perpindahan uang antar rekening, rekonsiliasi dengan rekening koran, dan satu daftar gabungan seluruh mutasi.",
    "accounting": "Jantung pembukuan: jurnal, rekening koran, daftar akun, kategori, status periode (tutup buku), saldo awal, dan penyesuaian saldo.",
    "tax": "Pusat kepatuhan pajak: posisi PPN, PPh vendor, PPh Final UMKM, kalender jatuh tempo, pencatatan pembayaran, pelaporan dan bukti, serta aturan tarif.",
    "assets-financing": "Aset tetap dan penyusutannya, pinjaman, piutang dan utang di luar invoice atau tagihan biasa, serta modal dan ekuitas.",
    "payroll": "Data karyawan, proses penggajian bulanan, slip gaji, serta kewajiban pajak dan BPJS yang timbul dari payroll.",
    "planning": "Anggaran, target pendapatan, perkiraan otomatis, dan transaksi berulang untuk invoice atau tagihan yang rutin terjadi.",
    "reports": "Laporan keuangan baku (Laba Rugi, Neraca, Arus Kas, Perubahan Ekuitas), ringkasan penjualan dan pembelian, laporan pajak, payroll, pinjaman, aset, laporan kustom, dan laporan tersimpan.",
    "documents": "Pencarian dokumen, lampiran bukti transaksi, dan arsip dokumen yang sudah diganti versinya.",
    "administration": "Pengaturan Entity dan organisasi: impor data, jejak audit, pengguna dan peran, pengaturan umum, tampilan invoice, SKU, keamanan, serta backup dan pemulihan.",
    "guide": "Panduan langkah demi langkah di dalam aplikasi, dan diagram alur kerja dari sebuah kejadian ke menu yang harus dibuka.",
}

GUIDE_MENU_HELP = {
    "/guide": "Daftar semua panduan langkah demi langkah, dikelompokkan menurut pekerjaan.",
    "/guide/alur-kerja": "Diagram alur dari sebuah kejadian (misalnya ada pelanggan yang mau membayar) sampai menu yang harus dibuka.",
}


def load_menu():
    """The menu tree and the page descriptions, from the application's own source files."""
    import subprocess
    repo = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    out = subprocess.run(
        ["node", "--experimental-strip-types", "--no-warnings", os.path.join("scripts", "guide", "export_menu.mts")],
        cwd=repo, capture_output=True, check=True,
    ).stdout.decode("utf-8")
    data = json.loads(out)
    return data["nav"], {**data["help"], **{k: {"summary": v} for k, v in GUIDE_MENU_HELP.items()}}


def menu_sections():
    nav, help_ = load_menu()
    sections = []
    for number, group in enumerate(nav, 1):
        items = group.get("items") or [{"label": group["label"], "href": group["href"]}]
        rows, seen = [], set()
        for item in items:
            if item["href"] in seen and item["label"] == group["label"]:
                continue
            seen.add(item["href"])
            entry = help_.get(item["href"], {})
            name = item["label"]
            alt = (item.get("labelByEntityType") or {}).get("personal")
            if alt:
                name += " (di Buku Pribadi: %s)" % alt
            desc = entry.get("summary", "")
            if entry.get("more"):
                desc += " " + entry["more"]
            rows.append((name, item["href"], desc))
        sections.append((str(number), group["label"], GROUP_INTRO.get(group["key"], ""), rows))
    return sections


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
    "<b>Invoice yang sudah diterbitkan tetapi belum dibayar otomatis menjadi Piutang Usaha</b> (akun 1200) dan "
    "pendapatan langsung diakui saat invoice terbit. Saat pelanggan membayar, pakai <b>Catat Pembayaran</b> pada "
    "hari uang masuk ke rekening PT: piutang berkurang, kas bertambah, pendapatan tidak bertambah lagi. "
    "Penjelasan lengkap ada di Bagian V, panduan &ldquo;Memahami Piutang dan Pendapatan&rdquo;.",
    "Uang dari pelanggan yang lebih dulu masuk ke rekening pribadi atau rekening direktur: catat pembayaran hanya "
    "saat uang benar-benar masuk ke rekening PT, supaya pendapatan tidak ganda. Caranya ada di panduan "
    "pembayaran lewat rekening pribadi (Bagian V, kelompok Penjualan).",
    "Pembayaran <b>PPh Final UMKM</b> dicatat sebagai pembayaran sekaligus pelaporannya: tidak ada pelaporan "
    "bulanan terpisah. Bukti bayar diunggah langsung dari halaman pembayarannya (nomor TAXPAY).",
    "Pinjaman dan aset tetap bisa dicatat dalam mata uang asing: pinjaman lewat <b>Catat Revaluasi Kurs</b> tiap "
    "akhir bulan (selisih kurs diposting ke akun Laba/Rugi Selisih Kurs), aset tetap lewat catatan mata uang "
    "asal. Akrual bunga pinjaman otomatis belum didukung &mdash; bunga dicatat saat dibayar, bukan saat terutang.",
    "Dasar fiskal penyusutan aset dan aturan pajak payroll masih menunggu verifikasi konsultan pajak OWNER "
    "sebelum benar-benar digunakan untuk pelaporan resmi (go-live).",
    "Halaman <b>Aturan Pajak</b> menampilkan aturan yang dipakai mesin pajak. Ubah hanya dengan dasar hukum "
    "tertulis dan sebaiknya setelah berkonsultasi dengan konsultan pajak; disarankan hanya ditangani OWNER.",
    "PPh 21 dari payroll ditangani lewat menu &ldquo;Pajak &amp; Kewajiban Payroll&rdquo; di dalam modul "
    "Payroll, bukan lewat modul Pajak.",
    "Peran <b>Tax</b>, <b>Accountant</b>, <b>Payroll</b>, dan <b>Viewer / Auditor</b> hanya melihat dokumen; "
    "melampirkan dokumen hanya untuk OWNER, Finance Admin, dan Finance Staff. Bukti pembayaran dan pelaporan "
    "pajak memakai izin pajak tersendiri (<font face=\"Courier\" size=\"8.5\">tax.mark_filed</font>).",
]

# ----------------------------------------------------------------------------
# DOCUMENT TEMPLATE with Table of Contents support
# ----------------------------------------------------------------------------

PAGE_W, PAGE_H = A4
MARGIN = 20 * mm



# ----------------------------------------------------------------------------
# Bagian V: step-by-step guides rendered from the website's JSON content
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
    story = [Paragraph("Bagian V &mdash; Panduan Langkah demi Langkah", styles["ModuleHeading"])]
    story += paras(
        "Bagian ini sama persis dengan menu **Panduan** di website (isinya diambil dari sumber yang sama). "
        "Tiap panduan menjelaskan satu pekerjaan dari awal sampai selesai: di mana menunya, siapa yang boleh, "
        "langkah demi langkah dengan gambar layar asli, hasil yang benar, aturan penting, kesalahan yang sering "
        "terjadi, dan arti pesan kesalahan. Bab pertama, **Alur Kerja (Diagram)**, menggambar alur dari sebuah "
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


def start_steps():
    """Bagian I's numbered boxes, from the guide 'Urutan Langkah Pertama Kali' (same text as the website)."""
    for name in GUIDE_FILES:
        with open(os.path.join(GUIDE_DIR, name), encoding="utf-8") as f:
            for g in json.load(f)["guides"]:
                if g["slug"] == "urutan-langkah-awal":
                    out = []
                    for st in g["steps"]:
                        sent = re.split(r"(?<=[.!?])\s", st["text"].strip())
                        first = sent[0] if len(sent[0]) > 70 or len(sent) < 2 else sent[0] + " " + sent[1]
                        out.append(("<b>%s.</b> %s" % (_plain(st["title"]), inline(first)), "normal"))
                    out[-1] = (out[-1][0], "end")
                    return out
    raise SystemExit("guide urutan-langkah-awal not found")


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
        "Mencakup langkah awal, fungsi setiap menu &amp; sub-menu, peran, panduan langkah demi langkah, "
        "dan diagram alur kerja.", styles["CoverMeta"]))
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
        "setiap orang yang memiliki akun pada aplikasi ini. Panduan ini terdiri dari lima bagian:",
        styles["Intro"]))
    story.append(Paragraph(
        "<b>Bagian I &mdash; Langkah Awal:</b> apa yang harus disiapkan pertama kali (rekening, kategori, pelanggan, "
        "produk &amp; jasa) supaya pembuatan invoice dan pengeluaran tinggal klik, lengkap dengan urutannya.", styles["Intro"]))
    story.append(Paragraph(
        "<b>Bagian II &mdash; Fungsi Menu &amp; Sub-Menu:</b> penjelasan singkat setiap menu dan sub-menu yang "
        "tersedia, mengikuti menu di bilah samping aplikasi (dibaca langsung dari menunya, jadi selalu sama).", styles["Intro"]))
    story.append(Paragraph(
        "<b>Bagian III &mdash; Peran &amp; Izin:</b> ringkasan delapan templat peran (role) yang tersedia dan "
        "apa yang dapat dilakukan masing-masing.", styles["Intro"]))
    story.append(Paragraph(
        "<b>Bagian IV &mdash; Catatan &amp; Keterbatasan:</b> hal-hal yang perlu diketahui pengguna karena "
        "masih dalam tahap penyempurnaan.", styles["Intro"]))
    story.append(Paragraph(
        "<b>Bagian V &mdash; Panduan Langkah demi Langkah:</b> cara mengerjakan setiap pekerjaan dari awal "
        "sampai selesai, lengkap dengan gambar layar, ditambah bab <b>Alur Kerja (Diagram)</b> yang menggambar "
        "alur dari sebuah kejadian ke menu yang harus dibuka. Isinya sama dengan menu <b>Panduan</b> di website.", styles["Intro"]))
    story.append(Spacer(1, 6))
    story.append(HRFlowable(width="100%", color=colors.HexColor("#dddddd")))
    story.append(PageBreak())

    # ---- Bagian I: Langkah Awal ----
    story.append(Paragraph("Bagian I &mdash; Langkah Awal Memakai Website", styles["ModuleHeading"]))
    story.append(Paragraph(START_INTRO, styles["Intro"]))
    story.append(Spacer(1, 8))
    story.extend(flow_diagram("Urutan Persiapan Pertama Kali", start_steps()))
    story.extend(flow_diagram("Alamat Website & Pengiriman Email (Resend)", EMAIL_STEPS,
        "Jika email gagal terkirim, tautan pembayaran tetap bisa dibagikan lewat tombol Salin Tautan Publik."))
    story.append(Paragraph("Tips", styles["SubHeading"]))
    for tip in START_TIPS:
        story.append(Paragraph("&bull;&nbsp; " + tip, styles["ItemDesc"]))
        story.append(Spacer(1, 4))
    story.append(PageBreak())

    # ---- Bagian II: Modul & Sub-menu ----
    story.append(Paragraph("Bagian II &mdash; Fungsi Menu &amp; Sub-Menu", styles["ModuleHeading"]))
    story.append(Spacer(1, 4))

    for num, title, intro, items in menu_sections():
        section_flow = []
        section_flow.append(Paragraph("%s. %s" % (num, esc(title)), styles["SubHeading"]))
        if intro:
            section_flow.append(Paragraph(intro, styles["Intro"]))
        for name, href, desc in items:
            row_html = "<b>%s</b>" % esc(name)
            if href:
                row_html += '  <font face="Courier" size="8.3" color="#8a6d00">%s</font>' % esc(href)
            section_flow.append(Paragraph(row_html, styles["ItemName"]))
            desc_html = esc(desc)
            section_flow.append(Paragraph(desc_html, styles["ItemDesc"]))
            section_flow.append(Spacer(1, 5))
        story.extend(section_flow)
        story.append(Spacer(1, 8))

    story.append(PageBreak())

    # remove trailing page break duplication by just continuing to next section
    # ---- Bagian III: Peran & Izin ----
    story.append(Paragraph("Bagian III &mdash; Peran &amp; Izin (Role)", styles["ModuleHeading"]))
    story.append(Paragraph(
        "Aplikasi menyediakan delapan templat peran yang dapat diberikan ke setiap anggota per Entity. "
        "Satu orang bisa memiliki peran berbeda di Entity yang berbeda.", styles["Intro"]))
    story.append(Spacer(1, 8))

    role_rows = [[Paragraph('<font color="#ffffff"><b>Peran</b></font>', styles["ItemDesc"]), Paragraph('<font color="#ffffff"><b>Cakupan Akses</b></font>', styles["ItemDesc"])]]
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
    story.append(Paragraph("Bagian IV &mdash; Catatan &amp; Keterbatasan", styles["ModuleHeading"]))
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

