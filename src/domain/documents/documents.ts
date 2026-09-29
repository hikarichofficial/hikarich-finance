import {
  documentTargetTypeSchema,
  type DocumentPurpose,
  type DocumentTargetType,
} from "@/schemas/documents";

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

// ================================================================ Documents Center listing (P13 Part 4, sixth increment)

export interface DocumentTargetTypeFilterOption {
  value: DocumentTargetType | null;
  label: string;
}

/** Toolbar filter tabs for the Documents Center listing -- `null` ("Semua") is the default, matching
 * `list_documents`'s own `p_target_type` being optional (omitted = every kind, Step 01 #35). Order follows
 * `documentTargetTypeSchema`'s own declared order (DECISIONS 141/147) rather than object-key iteration, so
 * the tab order is stable and matches the catalog's own intent. */
export const DOCUMENT_TARGET_TYPE_FILTER_OPTIONS: readonly DocumentTargetTypeFilterOption[] = [
  { value: null, label: "Semua" },
  ...documentTargetTypeSchema.options.map((value) => ({
    value,
    label: DOCUMENT_TARGET_TYPE_LABELS[value],
  })),
];

/** Resolves a `?target_type=` query value to a known filter, the same "fall back to the un-filtered default
 * rather than error" shape `parseBillFilter` established: an unrecognized or absent value shows every
 * document (`undefined`, `list_documents`'s own "no filter" meaning) instead of rejecting the request. */
export function parseDocumentTargetTypeFilter(
  value: string | undefined,
): DocumentTargetType | undefined {
  const option = DOCUMENT_TARGET_TYPE_FILTER_OPTIONS.find((o) => o.value === value);
  return option?.value ?? undefined;
}

/** A document can be linked to more than one target (`target_types`, one row per distinct document) --
 * this renders that set as a single display string, falling back to the raw value for any kind the
 * catalog has not labelled (Step 01 #35's "never invent a second financial truth" also applies to labels:
 * an unrecognized kind is shown as-is, never silently dropped). */
export function documentTargetTypesLabel(targetTypes: readonly string[]): string {
  if (targetTypes.length === 0) return "—";
  return targetTypes
    .map((t) => DOCUMENT_TARGET_TYPE_LABELS[t as DocumentTargetType] ?? t)
    .join(", ");
}
