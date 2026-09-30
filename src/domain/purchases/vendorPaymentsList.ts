import type { VendorPaymentRow } from "@/schemas/purchases";

/**
 * Pure helpers for the Payments Made List/Detail screens (P13 unbuilt-screens backlog, Step 09 primary
 * sitemap: "Purchases: Bills; Expenses; Payments Made; Vendors"). No Refunds counterpart exists on the
 * Purchases side (the sitemap lists Refunds only under Sales), so this stays a plain List/Detail, unlike
 * `src/domain/sales/paymentsList.ts`'s two-view shape. Nothing here calls the database.
 */

export type VendorPaymentTone = "neutral" | "success";

export interface VendorPaymentStatus {
  text: string;
  tone: VendorPaymentTone;
}

/** Confirmed is the healthy state; reversed is a deliberate, audited undo -- `neutral`, matching this
 * codebase's own convention for void/reversed states (decision-established via `invoicePositionStatus`). */
export function vendorPaymentRowStatus(row: VendorPaymentRow): VendorPaymentStatus {
  if (row.status === "reversed") return { text: "Dibalik", tone: "neutral" };
  return { text: "Dikonfirmasi", tone: "success" };
}

export function matchesVendorPaymentQuery(row: VendorPaymentRow, query: string): boolean {
  const q = query.trim().toLowerCase();
  if (!q) return true;
  return (
    row.payment_number.toLowerCase().includes(q) ||
    row.vendor_name.toLowerCase().includes(q) ||
    (row.reference ?? "").toLowerCase().includes(q)
  );
}

export function filterVendorPaymentRows(
  rows: readonly VendorPaymentRow[],
  query: string,
): VendorPaymentRow[] {
  if (!query.trim()) return [...rows];
  return rows.filter((row) => matchesVendorPaymentQuery(row, query));
}
