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

// ================================================================ Import history screens (decision 241)

export type ImportStatusTone = "neutral" | "progress" | "attention" | "success" | "critical";

/** Badge tone per batch status. `rolled_back` is a deliberate, audited undo, so `neutral` -- this
 * codebase's own convention for reversed/void states. */
export const IMPORT_BATCH_STATUS_TONE: Readonly<Record<ImportBatchStatus, ImportStatusTone>> = {
  staging: "progress",
  validated: "attention",
  committed: "success",
  rolled_back: "neutral",
};

export const IMPORT_ROW_STATUS_TONE: Readonly<Record<ImportRowStatus, ImportStatusTone>> = {
  pending: "progress",
  valid: "success",
  invalid: "critical",
  duplicate: "attention",
  committed: "success",
  rolled_back: "neutral",
};

export const IMPORT_TARGET_TYPE_LABELS: Readonly<Record<"contact" | "legacy_open_item", string>> = {
  contact: "Kontak",
  legacy_open_item: "Item Terbuka (Data Awal)",
};

export interface ImportFilterOption<T extends string> {
  readonly value: T | undefined;
  readonly label: string;
}

/** List screen's domain filter tabs: "Semua" first (no filter), then every domain in its label order. */
export const IMPORT_DOMAIN_FILTER_OPTIONS: readonly ImportFilterOption<ImportDomain>[] = [
  { value: undefined, label: "Semua" },
  ...(Object.keys(IMPORT_DOMAIN_LABELS) as ImportDomain[]).map((value) => ({
    value,
    label: IMPORT_DOMAIN_LABELS[value],
  })),
];

/** Detail screen's row-status filter tabs, same shape. */
export const IMPORT_ROW_STATUS_FILTER_OPTIONS: readonly ImportFilterOption<ImportRowStatus>[] = [
  { value: undefined, label: "Semua" },
  ...(Object.keys(IMPORT_ROW_STATUS_LABELS) as ImportRowStatus[]).map((value) => ({
    value,
    label: IMPORT_ROW_STATUS_LABELS[value],
  })),
];

/** An unrecognized or absent `?domain=` shows everything rather than erroring -- the same "a listing's
 * natural default is unfiltered" shape `parseDocumentTargetTypeFilter` already uses. The value is passed
 * straight to `list_import_batches`' own `p_domain`, so only a known domain is ever sent. */
export function parseImportDomainFilter(value: string | undefined): ImportDomain | undefined {
  return value !== undefined && Object.hasOwn(IMPORT_DOMAIN_LABELS, value)
    ? (value as ImportDomain)
    : undefined;
}

/** Same shape for `?status=` on the batch detail, passed to `get_import_batch_rows`' own `p_status`. */
export function parseImportRowStatusFilter(value: string | undefined): ImportRowStatus | undefined {
  return value !== undefined && Object.hasOwn(IMPORT_ROW_STATUS_LABELS, value)
    ? (value as ImportRowStatus)
    : undefined;
}
