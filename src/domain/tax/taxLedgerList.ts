import { Decimal } from "@/domain/money/decimal";
import { formatPlain } from "@/domain/money/format";
import {
  DETERMINATION_STATUS_LABELS,
  DETERMINATION_STATUS_TONE,
  TAX_KIND_LABELS,
  TAX_TYPE_LABELS,
  taxPeriodLabel,
  type DeterminationStatus,
  type DeterminationTone,
  type TaxKind,
  type TaxType,
} from "@/domain/tax/tax";
import type { TaxLedgerRow } from "@/schemas/tax";

/**
 * Pure helpers for the Tax Ledger List and Tax Determination Detail screens (P13 Part 3e, Step 09 §9-§10, §15).
 * Nothing here calls the database: `listTaxLedger`/`listTaxDeterminations` (`src/services/tax/tax.ts`) already
 * carry everything these functions need. Tax vocabulary, labels and arithmetic that do not depend on either
 * screen's own row shape stay in `@/domain/tax/tax` (Step 05, Step 15 §11, Step 16 §15); this module only adds
 * the List/Detail-specific status badge, filters and drill-back links on top of it.
 */

export interface TaxListStatus {
  text: string;
  tone: DeterminationTone;
}

const KNOWN_DETERMINATION_STATUSES = new Set(Object.keys(DETERMINATION_STATUS_LABELS));

function isKnownDeterminationStatus(status: string): status is DeterminationStatus {
  return KNOWN_DETERMINATION_STATUSES.has(status);
}

/** `tax_ledger_report`'s `determination_status` column is plain text in the database (Step 05 §12), a wider
 * vocabulary than the `DeterminationStatus` the engine's preview/read paths use -- unrecognised text still
 * renders (as itself, neutral) rather than throwing, since a ledger row must always be showable. */
export function taxLedgerStatus(determinationStatus: string): TaxListStatus {
  if (isKnownDeterminationStatus(determinationStatus)) {
    return {
      text: DETERMINATION_STATUS_LABELS[determinationStatus],
      tone: DETERMINATION_STATUS_TONE[determinationStatus],
    };
  }
  return { text: determinationStatus, tone: "neutral" };
}

// ---- filters (Step 09 §15: "filterable by tax family, period, source, status and Entity")

export interface TaxFamilyFilterOption {
  value: TaxType | null;
  label: string;
}

export const TAX_FAMILY_FILTER_OPTIONS: readonly TaxFamilyFilterOption[] = [
  { value: null, label: "Semua Jenis Pajak" },
  ...(Object.entries(TAX_TYPE_LABELS) as [TaxType, string][]).map(([value, label]) => ({
    value,
    label,
  })),
];

export function matchesTaxFamily(row: TaxLedgerRow, taxType: TaxType | null): boolean {
  return taxType === null || row.tax_type === taxType;
}

export function parseTaxFamilyFilter(value: string | undefined): TaxType | undefined {
  const option = TAX_FAMILY_FILTER_OPTIONS.find((o) => o.value === value);
  return option?.value ?? undefined;
}

/** The ledger's own source vocabulary -- `invoice`/`bill`/`expense` (a document) or `period` (PPh Final UMKM's
 * own monthly determination, no single document behind it). */
export type TaxSourceFilter = "invoice" | "bill" | "expense" | "period";

export interface TaxSourceFilterOption {
  value: TaxSourceFilter | null;
  label: string;
}

export const TAX_SOURCE_FILTER_OPTIONS: readonly TaxSourceFilterOption[] = [
  { value: null, label: "Semua Sumber" },
  { value: "invoice", label: "Faktur Penjualan" },
  { value: "bill", label: "Tagihan Pembelian" },
  { value: "expense", label: "Beban" },
  { value: "period", label: "Masa Pajak (PPh Final UMKM)" },
];

export function matchesTaxSource(row: TaxLedgerRow, sourceType: TaxSourceFilter | null): boolean {
  return sourceType === null || row.source_type === sourceType;
}

export function parseTaxSourceFilter(value: string | undefined): TaxSourceFilter | undefined {
  const option = TAX_SOURCE_FILTER_OPTIONS.find((o) => o.value === value);
  return option?.value ?? undefined;
}

export interface TaxStatusFilterOption {
  value: string | null;
  label: string;
}

/** Only the statuses a ledger entry can actually carry (an accrual is only ever recorded once its tax is
 * determined, Step 05 §14) -- `needs_review`/`not_configured`/`not_applicable` never reach the ledger. */
export const TAX_STATUS_FILTER_OPTIONS: readonly TaxStatusFilterOption[] = [
  { value: null, label: "Semua Status" },
  { value: "auto_determined", label: DETERMINATION_STATUS_LABELS.auto_determined },
  { value: "owner_confirmed", label: DETERMINATION_STATUS_LABELS.owner_confirmed },
  { value: "overridden", label: DETERMINATION_STATUS_LABELS.overridden },
  { value: "superseded", label: DETERMINATION_STATUS_LABELS.superseded },
];

export function matchesTaxStatus(row: TaxLedgerRow, status: string | null): boolean {
  return status === null || row.determination_status === status;
}

export function parseTaxStatusFilter(value: string | undefined): string | undefined {
  const option = TAX_STATUS_FILTER_OPTIONS.find((o) => o.value === value);
  return option?.value ?? undefined;
}

export function matchesTaxPeriod(row: TaxLedgerRow, period: string | null): boolean {
  return period === null || row.tax_period === period;
}

function normalize(text: string): string {
  return text.trim().toLowerCase();
}

export function matchesTaxLedgerQuery(row: TaxLedgerRow, query: string): boolean {
  const needle = normalize(query);
  if (needle === "") return true;
  return row.description !== null && normalize(row.description).includes(needle);
}

export function filterTaxLedgerRows(
  rows: readonly TaxLedgerRow[],
  taxType: TaxType | null,
  sourceType: TaxSourceFilter | null,
  status: string | null,
  period: string | null,
  query: string,
): TaxLedgerRow[] {
  return rows.filter(
    (row) =>
      matchesTaxFamily(row, taxType) &&
      matchesTaxSource(row, sourceType) &&
      matchesTaxStatus(row, status) &&
      matchesTaxPeriod(row, period) &&
      matchesTaxLedgerQuery(row, query),
  );
}

/** Every distinct tax period present in a ledger page, newest first -- the period filter's own option list,
 * since no RPC lists an Entity's tax periods the way `listAccountingPeriods` does for accounting periods. */
export function taxLedgerPeriodOptions(
  rows: readonly TaxLedgerRow[],
): { value: string; label: string }[] {
  const periods = Array.from(new Set(rows.map((row) => row.tax_period))).sort((a, b) =>
    a < b ? 1 : a > b ? -1 : 0,
  );
  return periods.map((period) => ({ value: period, label: taxPeriodLabel(period) }));
}

// ---- drill-back to the source transaction (Step 09 §15: "... and source transaction")

/** "Source transaction" (Step 09 §15) is the Tax Determination Detail screen, not the original document
 * directly -- the same "only link what has somewhere to go" choice `journalSourceHref` made (decision 172):
 * `period` (no single document) and a missing `source_id` get no link. */
export function taxDeterminationHref(
  sourceType: string,
  sourceId: string | null,
  entity: string | undefined,
): string | null {
  if (sourceId === null) return null;
  if (sourceType !== "invoice" && sourceType !== "bill" && sourceType !== "expense") return null;
  const qs = entity ? `?entity=${encodeURIComponent(entity)}` : "";
  return `/tax/determination/${sourceType}/${sourceId}${qs}`;
}

/** From the Determination Detail screen onward to the document itself -- only `invoice`/`bill` have a Detail
 * screen to land on yet (decision 172's own precedent; `expense` has none, so it shows its label unlinked). */
export function taxSourceDocumentHref(
  sourceType: string,
  sourceId: string,
  entity: string | undefined,
): string | null {
  const qs = entity ? `?entity=${encodeURIComponent(entity)}` : "";
  switch (sourceType) {
    case "invoice":
      return `/sales/invoices/${sourceId}${qs}`;
    case "bill":
      return `/purchases/bills/${sourceId}${qs}`;
    default:
      return null;
  }
}

export function taxKindLabel(kind: TaxKind): string {
  return TAX_KIND_LABELS[kind];
}

export function taxTypeLabel(type: TaxType): string {
  return TAX_TYPE_LABELS[type];
}

/** A determination's `rate` is a 0..1 fraction (Step 05 §5-§9's rule master), shown as a percentage with no
 * trailing zeros; `null` when the tax has no single rate (a banded PPh Final UMKM calculation, an amount set
 * entirely by an OWNER override, Step 05 §9/§15). */
export function formatTaxRate(rate: string | null): string {
  if (rate === null) return "—";
  const percent = Decimal.parse(rate).mul(Decimal.parse("100"));
  return `${formatPlain(percent.toString())}%`;
}
