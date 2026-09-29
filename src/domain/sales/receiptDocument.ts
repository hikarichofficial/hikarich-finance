import type { ReceiptDocument } from "@/schemas/sales";
import type { InvoiceListStatus } from "./invoiceList";

/**
 * Pure helpers for the Payment Receipt document (P13 Part 5, first increment; Step 11 -- Invoice/Receipt
 * Visual Specification §10, FINAL/LOCKED). Reuses `InvoiceListStatus`/`InvoiceListTone`
 * (`src/domain/sales/invoiceList.ts`) rather than declaring its own status shape: a receipt's status badge
 * is the exact same two-tone "confirmed vs reversed" presentation concept the Invoice document's own status
 * badge already models with those types, just a different, smaller vocabulary (a receipt has no draft,
 * unpaid, partial or overdue state of its own -- it exists only once a payment is confirmed, Step 11 §10:
 * "A receipt exists only after authoritative payment confirmation").
 */
export function paymentReceiptStatus(receipt: ReceiptDocument): InvoiceListStatus {
  if (receipt.status === "reversed") return { text: "Dibatalkan", tone: "neutral" };
  return { text: "Diterima", tone: "success" };
}
