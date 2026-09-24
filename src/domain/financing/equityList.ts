import {
  EQUITY_KIND_LABELS,
  EQUITY_STATUS_LABELS,
  type EquityKind,
  type EquityStatus,
} from "@/domain/financing/financing";
import type { EquityRow } from "@/schemas/financing";

/**
 * Capital & Equity list/detail support (P13 Part 3f, fourth increment, Step 09 §16: "Capital & Equity screen
 * clearly separates contribution, return, dividend/distribution and history"). `equity_list` already filters
 * `kind`/`status` server-side (both sent straight through, matching the Loan Register's own direction+status
 * split, decision 175), so the "clearly separates" requirement is read as a kind filter plus each kind's own
 * label and tone -- not a route split like Other Receivables/Payables (decision 176), since Step 09 §16 names
 * this as one screen, unlike its own separate "Other AR/AP" bullet -- and only the free-text search stays
 * client-side.
 */

export type EquityListTone = "neutral" | "progress" | "attention" | "success" | "critical";
export interface EquityListBadge {
  text: string;
  tone: EquityListTone;
}

export const EQUITY_STATUS_TONE: Readonly<Record<EquityStatus, EquityListTone>> = {
  draft: "neutral",
  confirmed: "success",
  reversed: "attention",
  cancelled: "critical",
};
export function equityStatusBadge(status: EquityStatus): EquityListBadge {
  return { text: EQUITY_STATUS_LABELS[status], tone: EQUITY_STATUS_TONE[status] };
}

/** A dividend declared beyond the profit available is allowed but flagged (`exceeds_retained_earnings`), the
 * schema's own words for it -- shown as a second badge alongside the status badge, never replacing it. */
export function equityRetainedEarningsBadge(exceeds: boolean | null): EquityListBadge | null {
  return exceeds ? { text: "Melebihi Laba Ditahan", tone: "critical" } : null;
}

export interface EquityKindFilterOption {
  value: EquityKind | null;
  label: string;
}
export const EQUITY_KIND_FILTER_OPTIONS: readonly EquityKindFilterOption[] = [
  { value: null, label: "Semua Jenis" },
  ...(Object.entries(EQUITY_KIND_LABELS) as [EquityKind, string][]).map(([value, label]) => ({
    value,
    label,
  })),
];
export function parseEquityKindFilter(value: string | undefined): EquityKind | undefined {
  const known = Object.keys(EQUITY_KIND_LABELS) as EquityKind[];
  return value !== undefined && (known as string[]).includes(value)
    ? (value as EquityKind)
    : undefined;
}

export interface EquityStatusFilterOption {
  value: EquityStatus | null;
  label: string;
}
export const EQUITY_STATUS_FILTER_OPTIONS: readonly EquityStatusFilterOption[] = [
  { value: null, label: "Semua Status" },
  ...(Object.entries(EQUITY_STATUS_LABELS) as [EquityStatus, string][]).map(([value, label]) => ({
    value,
    label,
  })),
];
export function parseEquityStatusFilter(value: string | undefined): EquityStatus | undefined {
  const known = Object.keys(EQUITY_STATUS_LABELS) as EquityStatus[];
  return value !== undefined && (known as string[]).includes(value)
    ? (value as EquityStatus)
    : undefined;
}

export function matchesEquityQuery(row: EquityRow, query: string): boolean {
  const q = query.trim().toLowerCase();
  if (!q) return true;
  return (
    row.event_number.toLowerCase().includes(q) ||
    row.counterparty_name.toLowerCase().includes(q) ||
    row.purpose.toLowerCase().includes(q)
  );
}
export function filterEquityRows(rows: readonly EquityRow[], query: string): EquityRow[] {
  return rows.filter((row) => matchesEquityQuery(row, query));
}

export type EquityPaymentStatus = "active" | "reversed";
const EQUITY_PAYMENT_STATUS_TONE: Readonly<Record<EquityPaymentStatus, EquityListTone>> = {
  active: "success",
  reversed: "attention",
};
const EQUITY_PAYMENT_STATUS_LABELS: Readonly<Record<EquityPaymentStatus, string>> = {
  active: "Aktif",
  reversed: "Dibalik",
};
export function equityPaymentStatusBadge(status: EquityPaymentStatus): EquityListBadge {
  return { text: EQUITY_PAYMENT_STATUS_LABELS[status], tone: EQUITY_PAYMENT_STATUS_TONE[status] };
}
