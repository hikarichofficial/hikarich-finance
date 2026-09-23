import type { DocumentPurpose, DocumentTargetType } from "@/schemas/documents";

/**
 * Generalized Documents Center (P11, Step 01 #34/#35/#43/#44, Step 15 §15). The database owns the target
 * kind catalog (`app_private.document_target_kinds`), every permission check and version history; this
 * module holds labels and presentation-only helpers so a screen can render without a round trip. Nothing
 * here is authoritative.
 */

export const DOCUMENT_TARGET_TYPE_LABELS: Readonly<Record<DocumentTargetType, string>> = {
  bill: "Tagihan",
  expense: "Pengeluaran",
  invoice: "Faktur",
  fixed_asset: "Aset Tetap",
  loan: "Pinjaman",
  other_obligation: "Piutang/Utang Lain-lain",
  equity_event: "Transaksi Ekuitas",
  contact: "Kontak",
  journal_entry: "Jurnal",
  tax_filing: "Pelaporan Pajak",
  tax_payment: "Pembayaran Pajak",
  import_batch: "Batch Impor",
};

export const DOCUMENT_PURPOSE_LABELS: Readonly<Record<DocumentPurpose, string>> = {
  vendor_invoice: "Faktur vendor",
  receipt: "Kuitansi",
  contract: "Kontrak",
  other: "Lainnya",
};

/** Human-readable file size, for a screen's document list — matches `MAX_DOCUMENT_BYTES` = 25 MB scale. */
export function formatDocumentSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  const kb = bytes / 1024;
  if (kb < 1024) return `${kb.toFixed(kb < 10 ? 1 : 0)} KB`;
  const mb = kb / 1024;
  return `${mb.toFixed(mb < 10 ? 1 : 0)} MB`;
}
