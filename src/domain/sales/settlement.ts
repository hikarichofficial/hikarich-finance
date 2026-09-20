import { Decimal } from "@/domain/money/decimal";

/**
 * Derived positions of an invoice (P5, Step 07 §9, Step 12 aging). Nothing here is stored: settlement is
 * always derived from the allocations, so a reversal or a refund can never leave a stale "paid" flag. These
 * helpers mirror the database's `app_private.invoice_positions` so the screens label figures the same way.
 */

export type SettlementStatus = "unpaid" | "partial" | "paid";

export function settlementStatus(total: Decimal, settled: Decimal): SettlementStatus {
  if (total.sub(settled).isZero()) return "paid";
  return settled.isZero() ? "unpaid" : "partial";
}

const DAY_MS = 86_400_000;

function dayNumber(isoDate: string): number {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(isoDate);
  if (!match) throw new RangeError(`Not an ISO date: ${isoDate}`);
  return Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3])) / DAY_MS;
}

/** Whole days after the due date, never negative: a due date of today is not overdue yet. */
export function daysOverdue(dueDate: string, asOf: string): number {
  return Math.max(0, dayNumber(asOf) - dayNumber(dueDate));
}

export type AgingBucket = "not_due" | "days_1_30" | "days_31_60" | "days_61_90" | "days_over_90";

export function agingBucket(days: number): AgingBucket {
  if (days <= 0) return "not_due";
  if (days <= 30) return "days_1_30";
  if (days <= 60) return "days_31_60";
  if (days <= 90) return "days_61_90";
  return "days_over_90";
}

export const AGING_BUCKET_LABELS: Readonly<Record<AgingBucket, string>> = {
  not_due: "Belum jatuh tempo",
  days_1_30: "1–30 hari",
  days_31_60: "31–60 hari",
  days_61_90: "61–90 hari",
  days_over_90: "Lebih dari 90 hari",
};

export type InvoiceStatus = "draft" | "issued" | "cancelled" | "void";

export const INVOICE_STATUS_LABELS: Readonly<Record<InvoiceStatus, string>> = {
  draft: "Draf",
  issued: "Diterbitkan",
  cancelled: "Dibatalkan",
  void: "Dibatalkan (void)",
};

export const SETTLEMENT_LABELS: Readonly<Record<SettlementStatus, string>> = {
  unpaid: "Belum dibayar",
  partial: "Dibayar sebagian",
  paid: "Lunas",
};
