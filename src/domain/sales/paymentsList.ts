import type { PaymentListRow } from "@/schemas/sales";

/**
 * Pure helpers for the Payments Received and Refunds screens (P13 unbuilt-screens backlog, Step 09
 * §9/§11: nav lists "Payments Received; Refunds" as two separate Sales destinations). Both screens read
 * the same `list_payments` rows -- there is no separate `list_refunds` RPC, only `payment_refund_options`
 * (per-payment, used by the not-yet-built refund creation flow) and `refund_receipt_document` (per-refund
 * document, also not yet wired to any list). Refunds is therefore built as a filtered view of payments that
 * already carry refund activity (`refund_status !== "none"`), the same "shared List screen serving multiple
 * roles via a view prop" pattern decisions 198/176/225 already established, rather than guessing at an
 * unbuilt data shape. Nothing here calls the database.
 */

export type PaymentListTone = "neutral" | "progress" | "attention" | "success" | "critical";

export interface PaymentListStatus {
  text: string;
  tone: PaymentListTone;
}

/** A confirmed payment is the healthy state; a reversed one is an administrative undo, not a warning --
 * `neutral`, mirroring `invoicePositionStatus`'s own treatment of a voided invoice (decision-established
 * convention: "undone" reads as neutral, not critical, since it is a deliberate, audited correction). */
export function paymentRowStatus(row: PaymentListRow): PaymentListStatus {
  if (row.status === "reversed") return { text: "Dibalik", tone: "neutral" };
  return { text: "Dikonfirmasi", tone: "success" };
}

export interface RefundStatusDisplay {
  text: string;
  tone: PaymentListTone;
}

/** `refund_status` is `list_payments`' own computed column ('none'/'partial'/'full'), Step 09's own nav
 * item split point for Refunds. A full refund is a closed, informational state (`neutral`, matching void's
 * own convention); a partial refund still has an open remainder worth flagging (`progress`, matching a
 * partially-settled invoice's own tone). */
export function refundStatusDisplay(status: PaymentListRow["refund_status"]): RefundStatusDisplay {
  if (status === "full") return { text: "Refund Penuh", tone: "neutral" };
  if (status === "partial") return { text: "Refund Sebagian", tone: "progress" };
  return { text: "Belum Ada Refund", tone: "neutral" };
}

/** Payments Received (Step 09 primary sitemap): every payment recorded for the Entity. */
export function listReceivedPayments(rows: readonly PaymentListRow[]): PaymentListRow[] {
  return [...rows];
}

/** Refunds (Step 09 primary sitemap): payments that carry any refund activity, newest payment date first --
 * `list_payments` already orders this way, so this is a pure filter, not a re-sort. */
export function listPaymentsWithRefunds(rows: readonly PaymentListRow[]): PaymentListRow[] {
  return rows.filter((row) => row.refund_status !== "none");
}

export function matchesPaymentQuery(row: PaymentListRow, query: string): boolean {
  const q = query.trim().toLowerCase();
  if (!q) return true;
  return (
    row.payment_number.toLowerCase().includes(q) ||
    row.customer_name.toLowerCase().includes(q) ||
    (row.reference ?? "").toLowerCase().includes(q)
  );
}

export function filterPaymentRows(
  rows: readonly PaymentListRow[],
  query: string,
): PaymentListRow[] {
  if (!query.trim()) return [...rows];
  return rows.filter((row) => matchesPaymentQuery(row, query));
}
