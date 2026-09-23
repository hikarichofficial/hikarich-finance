import type { SearchTargetType } from "@/schemas/search";

/**
 * Global Search (P11, Step 01 #34, Step 13 §17, Step 06 §11, Step 08 §22). The database is the only
 * authority for what is indexed and for filtering results by permission before ranking; this module holds
 * labels so a screen can group or badge results by kind without a round trip.
 */

export const SEARCH_TARGET_TYPE_LABELS: Readonly<Record<SearchTargetType, string>> = {
  contact: "Kontak",
  invoice: "Faktur",
  bill: "Tagihan",
  expense: "Pengeluaran",
  fixed_asset: "Aset Tetap",
  loan: "Pinjaman",
  other_obligation: "Piutang/Utang Lain-lain",
  equity_event: "Transaksi Ekuitas",
  journal_entry: "Jurnal",
};
