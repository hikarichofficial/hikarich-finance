/**
 * Indonesian text for each check of the period-close checklist (`period_close_checks`). The database returns
 * the English sentence plus a stable `code`; the screen shows the code's own Indonesian text, and the database's
 * sentence for a code this does not know, so nothing the database says is hidden (display only).
 */
const TEXT: Readonly<Record<string, string>> = {
  draft_journals: "Ada jurnal draf pada periode ini; harus diposting atau dibuang.",
  unbalanced_posted_journals: "Ditemukan jurnal terposting dengan debit tidak sama dengan kredit.",
  opening_not_completed: "Saldo awal pada periode ini belum diselesaikan dan disahkan.",
  empty_period: "Periode ini belum punya jurnal terposting.",
  money_ledger_mismatch: "Saldo kas/bank dari mutasi uang berbeda dari Buku Besar.",
  negative_cash_balance: "Ada rekening kas/bank bersaldo negatif pada akhir periode.",
  unresolved_statement_lines:
    "Baris mutasi rekening koran periode ini belum dicocokkan atau dikecualikan.",
  account_not_reconciled:
    "Rekening kas/bank aktif yang punya mutasi pada periode ini belum direkonsiliasi sampai akhir periode.",
  reconciliation_stale:
    "Rekonsiliasi yang sudah selesai tidak lagi cocok dengan pembukuan: ada mutasi ditambahkan di dalam periodenya setelah itu.",
  unmapped_cash_account:
    "Akun kas/bank di buku besar yang punya transaksi pada periode ini belum terhubung ke rekening keuangan, sehingga tidak bisa diperiksa.",
  ar_ledger_mismatch: "Piutang usaha dari invoice dan pembayaran berbeda dari Buku Besar.",
  advance_ledger_mismatch: "Uang muka pelanggan dari pembayaran berbeda dari Buku Besar.",
  draft_invoices:
    "Invoice draf bertanggal pada periode ini belum diterbitkan dan belum masuk pembukuan.",
  pending_payment_claims:
    "Klaim pembayaran pelanggan bertanggal pada periode ini masih menunggu verifikasi.",
  ap_ledger_mismatch: "Utang usaha dari tagihan dan pembayaran vendor berbeda dari Buku Besar.",
  unapproved_bills:
    "Tagihan draf atau yang diajukan pada periode ini belum disetujui dan belum masuk pembukuan.",
  unconfirmed_expenses:
    "Pengeluaran draf atau yang diajukan pada periode ini belum dikonfirmasi dan belum masuk pembukuan.",
  purchases_without_evidence:
    "Tagihan dan pengeluaran periode ini belum punya dokumen pendukung terlampir.",
  tax_ledger_mismatch: "Buku pajak berbeda dari Utang Pajak / Aset Pajak di Buku Besar.",
  tax_review_pending:
    "Dokumen draf atau yang diajukan pada periode ini perlu ditinjau pajaknya sebelum bisa diakui.",
  final_tax_not_computed:
    "PPh Final untuk bulan yang sudah selesai pada periode ini belum dihitung.",
  asset_ledger_mismatch: "Daftar aset tetap berbeda dari akun aset tetap di Buku Besar.",
  financing_ledger_mismatch:
    "Pinjaman, piutang/utang lain, atau dividen terutang berbeda dari akunnya di Buku Besar.",
  depreciation_not_posted: "Penyusutan yang jatuh tempo pada periode ini belum diposting.",
  asset_lines_pending:
    "Baris pembelian yang dicatat sebagai aset tetap pada periode ini belum didaftarkan sebagai aset.",
  loan_installments_overdue:
    "Cicilan pinjaman yang jatuh tempo sampai akhir periode belum dibayar.",
  financing_tax_review_pending:
    "Bunga pinjaman, penghapusan, dividen, atau pengembalian modal pada periode ini masih perlu ditinjau pajaknya.",
  payroll_ledger_mismatch: "Kewajiban payroll berbeda dari akunnya di Buku Besar.",
  payroll_approved_not_posted:
    "Ada payroll yang sudah disetujui pada periode ini tetapi belum diposting.",
  payroll_not_posted:
    "Payroll periode ini masih disiapkan: beban dan kewajibannya belum masuk pembukuan.",
  payroll_run_not_reconciled:
    "Ada payroll terposting yang tidak cocok dengan jurnal, buku pajak, atau slip gajinya.",
};

export function closeCheckText(code: string, fallback: string): string {
  return TEXT[code] ?? fallback;
}

export const CLOSE_CHECK_CODES: readonly string[] = Object.keys(TEXT);
