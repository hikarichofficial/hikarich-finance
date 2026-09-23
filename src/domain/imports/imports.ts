import type {
  ImportBatchStatus,
  ImportDomain,
  ImportRowStatus,
  LegacyOpenItemKind,
  LegacyOpenItemStatus,
} from "@/schemas/imports";

/**
 * The import staging engine (P11, Step 15 §15, Step 08 §17/§19, Step 01 #43, DATA_CUTOVER items 7-8). The
 * database owns the whole staging -> validate -> commit/rollback lifecycle and every duplicate/reversal
 * rule; this module holds labels and presentation-only helpers so a screen can render without a round
 * trip. Nothing here is authoritative.
 */

export const IMPORT_DOMAIN_LABELS: Readonly<Record<ImportDomain, string>> = {
  contacts: "Kontak",
  legacy_open_receivables: "Piutang Terbuka (Data Awal)",
  legacy_open_payables: "Utang Terbuka (Data Awal)",
};

export const IMPORT_BATCH_STATUS_LABELS: Readonly<Record<ImportBatchStatus, string>> = {
  staging: "Persiapan",
  validated: "Sudah Divalidasi",
  committed: "Sudah Diterapkan",
  rolled_back: "Dibatalkan",
};

export const IMPORT_ROW_STATUS_LABELS: Readonly<Record<ImportRowStatus, string>> = {
  pending: "Menunggu Validasi",
  valid: "Valid",
  invalid: "Tidak Valid",
  duplicate: "Duplikat",
  committed: "Diterapkan",
  rolled_back: "Dibatalkan",
};

export const LEGACY_OPEN_ITEM_KIND_LABELS: Readonly<Record<LegacyOpenItemKind, string>> = {
  receivable: "Piutang",
  payable: "Utang",
};

export const LEGACY_OPEN_ITEM_STATUS_LABELS: Readonly<Record<LegacyOpenItemStatus, string>> = {
  open: "Terbuka",
  settled: "Lunas",
  written_off: "Dihapusbukukan",
  rolled_back: "Dibatalkan",
};

/** Whether a batch may currently be (re)validated, committed or rolled back, for disabling screen actions
 * before a command round-trip. The database re-checks every one of these itself; this is presentation only. */
export function importBatchActions(status: ImportBatchStatus): {
  canValidate: boolean;
  canCommit: boolean;
  canRollback: boolean;
} {
  return {
    canValidate: status === "staging",
    canCommit: status === "validated",
    canRollback: status === "committed",
  };
}
