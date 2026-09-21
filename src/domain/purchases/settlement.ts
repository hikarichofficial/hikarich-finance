import { Decimal } from "@/domain/money/decimal";
import {
  AGING_BUCKET_LABELS,
  SETTLEMENT_LABELS,
  agingBucket,
  daysOverdue,
  settlementStatus,
  type AgingBucket,
  type SettlementStatus,
} from "@/domain/sales/settlement";

/**
 * Derived positions of a bill (P6, Step 07 §5, Step 12 aging). Nothing here is stored: paid, partially paid
 * and overdue are derived from the active payment allocations, so a reversal can never leave a stale "paid"
 * flag. The aging buckets, overdue days and settlement labels are the same as on the receivable side.
 */
export { AGING_BUCKET_LABELS, SETTLEMENT_LABELS, agingBucket, daysOverdue, settlementStatus };
export type { AgingBucket, SettlementStatus };

export type BillStatus = "draft" | "submitted" | "approved" | "cancelled" | "void";
export type ExpenseStatus = "draft" | "submitted" | "confirmed" | "cancelled" | "reversed";

export const BILL_STATUS_LABELS: Readonly<Record<BillStatus, string>> = {
  draft: "Draf",
  submitted: "Menunggu persetujuan",
  approved: "Disetujui",
  cancelled: "Dibatalkan",
  void: "Dibatalkan (void)",
};

export const EXPENSE_STATUS_LABELS: Readonly<Record<ExpenseStatus, string>> = {
  draft: "Draf",
  submitted: "Menunggu konfirmasi",
  confirmed: "Terkonfirmasi",
  cancelled: "Dibatalkan",
  reversed: "Dibalik",
};

/** A draft or submitted document has no accounting effect yet and can still be edited, recalled or cancelled. */
export function isPreparing(status: BillStatus | ExpenseStatus): boolean {
  return status === "draft" || status === "submitted";
}

/**
 * The outstanding amount of a bill from its total and what active allocations settled. The database RPCs
 * return `settled` as text in whatever scale Postgres produced ("0" or "5000000.0000"), so everything is
 * compared as exact decimals, never as strings.
 */
export function outstandingOf(total: string, settled: string): Decimal {
  const t = Decimal.tryParse(total);
  const s = Decimal.tryParse(settled);
  if (!t || !s) throw new RangeError("Not a decimal amount");
  return t.sub(s);
}

/** Derived status of an approved bill on a date: settlement and overdue in one place. */
export function billPosition(input: {
  total: string;
  settled: string;
  dueDate: string;
  asOf: string;
}): {
  settlement: SettlementStatus;
  outstanding: Decimal;
  daysOverdue: number;
  isOverdue: boolean;
} {
  const total = Decimal.tryParse(input.total);
  const settled = Decimal.tryParse(input.settled);
  if (!total || !settled) throw new RangeError("Not a decimal amount");
  const outstanding = total.sub(settled);
  const overdueDays = outstanding.isPositive() ? daysOverdue(input.dueDate, input.asOf) : 0;
  return {
    settlement: settlementStatus(total, settled),
    outstanding,
    daysOverdue: overdueDays,
    isOverdue: overdueDays > 0,
  };
}
