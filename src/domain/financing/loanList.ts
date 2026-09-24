import {
  LOAN_DIRECTION_LABELS,
  LOAN_STATUS_LABELS,
  type LoanDirection,
  type LoanStatus,
} from "@/domain/financing/financing";
import type { LoanRow, LoanScheduleRow } from "@/schemas/financing";

/**
 * Loan Register list/detail support (P13 Part 3f, second increment, Step 09 §16: "Loan dashboard shows principal
 * outstanding, next due, interest/fee split and schedule"). Mirrors the "Standard List Screen Pattern" already
 * used for the Asset Register (decision 174): `loan_list` already filters direction/status server-side, so only
 * a free-text search over loan number and counterparty is done client-side here, the same split as the Asset
 * Register's own status-server/query-client division.
 */

export type LoanListTone = "neutral" | "progress" | "attention" | "success" | "critical";
export interface LoanListBadge {
  text: string;
  tone: LoanListTone;
}

export const LOAN_STATUS_TONE: Readonly<Record<LoanStatus, LoanListTone>> = {
  draft: "neutral",
  active: "success",
  closed: "neutral",
  cancelled: "critical",
};
export function loanStatusBadge(status: LoanStatus): LoanListBadge {
  return { text: LOAN_STATUS_LABELS[status], tone: LOAN_STATUS_TONE[status] };
}

/** `loan_list` reports its own overdue installments via a plain boolean, separate from `status`. */
export function loanOverdueBadge(overdue: boolean): LoanListBadge | null {
  return overdue ? { text: "Terlambat", tone: "critical" } : null;
}

export interface LoanDirectionFilterOption {
  value: LoanDirection | null;
  label: string;
}
export const LOAN_DIRECTION_FILTER_OPTIONS: readonly LoanDirectionFilterOption[] = [
  { value: null, label: "Semua Arah" },
  ...(Object.entries(LOAN_DIRECTION_LABELS) as [LoanDirection, string][]).map(([value, label]) => ({
    value,
    label,
  })),
];
export function parseLoanDirectionFilter(value: string | undefined): LoanDirection | undefined {
  return value === "borrowed" || value === "lent" ? value : undefined;
}

export interface LoanStatusFilterOption {
  value: LoanStatus | null;
  label: string;
}
export const LOAN_STATUS_FILTER_OPTIONS: readonly LoanStatusFilterOption[] = [
  { value: null, label: "Semua Status" },
  ...(Object.entries(LOAN_STATUS_LABELS) as [LoanStatus, string][]).map(([value, label]) => ({
    value,
    label,
  })),
];
export function parseLoanStatusFilter(value: string | undefined): LoanStatus | undefined {
  const known = Object.keys(LOAN_STATUS_LABELS) as LoanStatus[];
  return value !== undefined && (known as string[]).includes(value)
    ? (value as LoanStatus)
    : undefined;
}

export function matchesLoanQuery(row: LoanRow, query: string): boolean {
  const q = query.trim().toLowerCase();
  if (!q) return true;
  return (
    row.loan_number.toLowerCase().includes(q) || row.counterparty_name.toLowerCase().includes(q)
  );
}
export function filterLoanRows(rows: readonly LoanRow[], query: string): LoanRow[] {
  return rows.filter((row) => matchesLoanQuery(row, query));
}

export type LoanScheduleState = LoanScheduleRow["state"];
export const LOAN_SCHEDULE_STATE_LABELS: Readonly<Record<LoanScheduleState, string>> = {
  paid: "Lunas",
  partially_paid: "Sebagian Lunas",
  due: "Jatuh Tempo",
  scheduled: "Terjadwal",
};
const LOAN_SCHEDULE_STATE_TONE: Readonly<Record<LoanScheduleState, LoanListTone>> = {
  paid: "success",
  partially_paid: "attention",
  due: "attention",
  scheduled: "neutral",
};
/** An overdue installment is shown critical regardless of `state` -- the same "flag wins" rule as
 * `loanOverdueBadge` above. */
export function loanScheduleStateBadge(state: LoanScheduleState, overdue: boolean): LoanListBadge {
  if (overdue) return { text: "Terlambat", tone: "critical" };
  return { text: LOAN_SCHEDULE_STATE_LABELS[state], tone: LOAN_SCHEDULE_STATE_TONE[state] };
}

export type LoanVersionStatus = "draft" | "active" | "superseded";
export const LOAN_VERSION_STATUS_LABELS: Readonly<Record<LoanVersionStatus, string>> = {
  draft: "Draf",
  active: "Berlaku",
  superseded: "Digantikan",
};
const LOAN_VERSION_STATUS_TONE: Readonly<Record<LoanVersionStatus, LoanListTone>> = {
  draft: "neutral",
  active: "success",
  superseded: "neutral",
};
export function loanVersionStatusBadge(status: LoanVersionStatus): LoanListBadge {
  return { text: LOAN_VERSION_STATUS_LABELS[status], tone: LOAN_VERSION_STATUS_TONE[status] };
}

export type LoanPaymentKind = "repayment" | "write_off";
export const LOAN_PAYMENT_KIND_LABELS: Readonly<Record<LoanPaymentKind, string>> = {
  repayment: "Pembayaran",
  write_off: "Penghapusan",
};

export type LoanPaymentStatus = "active" | "reversed";
const LOAN_PAYMENT_STATUS_TONE: Readonly<Record<LoanPaymentStatus, LoanListTone>> = {
  active: "success",
  reversed: "attention",
};
const LOAN_PAYMENT_STATUS_LABELS: Readonly<Record<LoanPaymentStatus, string>> = {
  active: "Aktif",
  reversed: "Dibalik",
};
export function loanPaymentStatusBadge(status: LoanPaymentStatus): LoanListBadge {
  return { text: LOAN_PAYMENT_STATUS_LABELS[status], tone: LOAN_PAYMENT_STATUS_TONE[status] };
}
