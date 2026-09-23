import {
  OBLIGATION_KIND_LABELS,
  OBLIGATION_STATUS_LABELS,
  type ObligationKind,
  type ObligationStatus,
} from "@/domain/financing/financing";
import type { ObligationRow } from "@/schemas/financing";

/**
 * Other Receivables/Payables list/detail support (P13 Part 3f, third increment, Step 09 §16: "Other AR/AP uses
 * simplified obligation screens without forcing invoice/bill semantics"). `obligation_list` already filters
 * status server-side; `kind` is fixed per route (Other Receivables vs Other Payables are two separate nav items,
 * each its own screen showing one kind only, matching the spec's own "simplified" framing rather than one
 * combined screen with a kind toggle), so only the free-text search is client-side, the same split the Loan
 * Register (decision 175) and Asset Register (decision 174) already established.
 */

export type ObligationListTone = "neutral" | "progress" | "attention" | "success" | "critical";
export interface ObligationListBadge {
  text: string;
  tone: ObligationListTone;
}

/** `void` reuses the same neutral tone bills/invoices give a cancelled/void document (decision precedent in
 * `billListStatus`); `open` is shown attention normally, critical once overdue -- the same "flag wins" rule
 * `loanOverdueBadge` (decision 175) already established. */
export function obligationStatusBadge(
  status: ObligationStatus,
  overdue: boolean,
): ObligationListBadge {
  if (status === "settled") return { text: OBLIGATION_STATUS_LABELS.settled, tone: "success" };
  if (status === "void") return { text: OBLIGATION_STATUS_LABELS.void, tone: "neutral" };
  if (overdue) return { text: "Terlambat", tone: "critical" };
  return { text: OBLIGATION_STATUS_LABELS.open, tone: "attention" };
}

export interface ObligationStatusFilterOption {
  value: ObligationStatus | null;
  label: string;
}
export const OBLIGATION_STATUS_FILTER_OPTIONS: readonly ObligationStatusFilterOption[] = [
  { value: null, label: "Semua Status" },
  ...(Object.entries(OBLIGATION_STATUS_LABELS) as [ObligationStatus, string][]).map(
    ([value, label]) => ({ value, label }),
  ),
];
export function parseObligationStatusFilter(
  value: string | undefined,
): ObligationStatus | undefined {
  const known = Object.keys(OBLIGATION_STATUS_LABELS) as ObligationStatus[];
  return value !== undefined && (known as string[]).includes(value)
    ? (value as ObligationStatus)
    : undefined;
}

export function matchesObligationQuery(row: ObligationRow, query: string): boolean {
  const q = query.trim().toLowerCase();
  if (!q) return true;
  return (
    row.obligation_number.toLowerCase().includes(q) ||
    row.counterparty_name.toLowerCase().includes(q) ||
    row.purpose.toLowerCase().includes(q)
  );
}
export function filterObligationRows(
  rows: readonly ObligationRow[],
  query: string,
): ObligationRow[] {
  return rows.filter((row) => matchesObligationQuery(row, query));
}

export const OBLIGATION_SOURCE_LABELS: Readonly<Record<ObligationRow["source_type"], string>> = {
  manual: "Manual",
  asset_disposal: "Pelepasan Aset",
};

export type ObligationRecognition = "cash" | "offset" | "asset_disposal";
export const OBLIGATION_RECOGNITION_LABELS: Readonly<Record<ObligationRecognition, string>> = {
  cash: "Tunai",
  offset: "Offset Akun Lawan",
  asset_disposal: "Pelepasan Aset",
};

/** The page title/eyebrow for a fixed-kind list or detail screen. */
export function obligationKindTitle(kind: ObligationKind): string {
  return OBLIGATION_KIND_LABELS[kind];
}

export type ObligationSettlementKind = "cash" | "write_off";
export const OBLIGATION_SETTLEMENT_KIND_LABELS: Readonly<Record<ObligationSettlementKind, string>> =
  {
    cash: "Pembayaran Tunai",
    write_off: "Penghapusan",
  };

export type ObligationSettlementStatus = "active" | "reversed";
const OBLIGATION_SETTLEMENT_STATUS_TONE: Readonly<
  Record<ObligationSettlementStatus, ObligationListTone>
> = {
  active: "success",
  reversed: "attention",
};
const OBLIGATION_SETTLEMENT_STATUS_LABELS: Readonly<Record<ObligationSettlementStatus, string>> = {
  active: "Aktif",
  reversed: "Dibalik",
};
export function obligationSettlementStatusBadge(
  status: ObligationSettlementStatus,
): ObligationListBadge {
  return {
    text: OBLIGATION_SETTLEMENT_STATUS_LABELS[status],
    tone: OBLIGATION_SETTLEMENT_STATUS_TONE[status],
  };
}
