import type {
  InvoiceDocument,
  InvoiceFilter,
  InvoicePosition,
} from "@/schemas/sales";
import {
  INVOICE_STATUS_LABELS,
  SETTLEMENT_LABELS,
} from "@/domain/sales/settlement";

/**
 * Pure helpers for the Invoices List and Invoice Detail screens (P13 Part 3a, Step 09 §9-§11). Nothing here
 * calls the database: everything is a display transform of rows `list_invoice_positions`/`invoice_document`
 * already returned, matching this project's "screens never invent financial truth" rule (Step 15 P13 gate).
 */

export type InvoiceListTone =
  "neutral" | "progress" | "attention" | "success" | "critical";

export interface InvoiceListStatus {
  text: string;
  tone: InvoiceListTone;
}

/**
 * The list screen's status badge (Step 09 §11: "Draft/Unpaid/Partial/Paid/Overdue/Void/Refund
 * indicators"). Overdue takes priority over the raw settlement label once an issued invoice is unpaid or
 * partially paid past its due date, mirroring `invoice_positions`' own `is_overdue` flag rather than
 * recomputing a date comparison here.
 */
export function invoicePositionStatus(row: InvoicePosition): InvoiceListStatus {
  if (row.status === "draft")
    return { text: INVOICE_STATUS_LABELS.draft, tone: "neutral" };
  if (row.status === "cancelled" || row.status === "void") {
    return { text: INVOICE_STATUS_LABELS[row.status], tone: "neutral" };
  }
  if (row.settlement_status === "paid") {
    return { text: SETTLEMENT_LABELS.paid, tone: "success" };
  }
  if (row.is_overdue) {
    return { text: `Jatuh tempo ${row.days_overdue} hari`, tone: "critical" };
  }
  if (row.settlement_status === "partial") {
    return { text: SETTLEMENT_LABELS.partial, tone: "progress" };
  }
  return {
    text: SETTLEMENT_LABELS[row.settlement_status ?? "unpaid"],
    tone: "neutral",
  };
}

/** Same badge, read off the frozen document (Invoice Detail's Header area) instead of a list row. */
export function invoiceDocumentStatus(doc: InvoiceDocument): InvoiceListStatus {
  if (doc.status === "draft")
    return { text: INVOICE_STATUS_LABELS.draft, tone: "neutral" };
  if (doc.status === "cancelled" || doc.status === "void") {
    return { text: INVOICE_STATUS_LABELS[doc.status], tone: "neutral" };
  }
  if (doc.settlement_status === "paid")
    return { text: SETTLEMENT_LABELS.paid, tone: "success" };
  if (doc.is_overdue) return { text: "Jatuh tempo", tone: "critical" };
  if (doc.settlement_status === "partial")
    return { text: SETTLEMENT_LABELS.partial, tone: "progress" };
  return {
    text: SETTLEMENT_LABELS[doc.settlement_status ?? "unpaid"],
    tone: "neutral",
  };
}

export interface InvoiceFilterOption {
  /** `null` is "every invoice" -- `list_invoice_positions` takes a null filter the same way. */
  value: InvoiceFilter | null;
  label: string;
}

/** Toolbar filter tabs (Step 09 §9), in the order the list reads best: broadest first, closed last. */
export const INVOICE_FILTER_OPTIONS: readonly InvoiceFilterOption[] = [
  { value: null, label: "Semua" },
  { value: "open", label: "Terbuka" },
  { value: "overdue", label: "Jatuh Tempo" },
  { value: "unpaid", label: "Belum Dibayar" },
  { value: "partial", label: "Dibayar Sebagian" },
  { value: "paid", label: "Lunas" },
  { value: "closed", label: "Dibatalkan" },
];

export function parseInvoiceFilter(
  value: string | undefined,
): InvoiceFilter | undefined {
  const option = INVOICE_FILTER_OPTIONS.find((o) => o.value === value);
  return option?.value ?? undefined;
}

function normalize(text: string): string {
  return text.trim().toLowerCase();
}

/**
 * Client-side substring match over the invoice number and customer name (Step 09 §9 "search"). The RPC
 * itself has no free-text search parameter yet -- a server-side index is Part 4's Global Search scope
 * (DECISIONS 145) -- so this filters what the page already fetched rather than adding a second query shape
 * ahead of that index existing.
 */
export function matchesInvoiceQuery(
  row: InvoicePosition,
  query: string,
): boolean {
  const needle = normalize(query);
  if (needle === "") return true;
  return (
    normalize(row.customer_name).includes(needle) ||
    (row.invoice_number !== null &&
      normalize(row.invoice_number).includes(needle))
  );
}

export function filterInvoicePositionsByQuery(
  rows: readonly InvoicePosition[],
  query: string,
): InvoicePosition[] {
  return rows.filter((row) => matchesInvoiceQuery(row, query));
}

export interface InvoiceActivityEntry {
  label: string;
  date: string | null;
  tone: InvoiceListTone;
}

/**
 * Invoice Detail's Activity area (Step 09 §10: "readable lifecycle timeline"), built only from facts
 * `invoice_document` actually returns -- status, issue date, and the payments received. There is no
 * per-invoice audit-log read path yet (no RPC exposes who issued/voided it, or a cancellation's own date/
 * reason beyond the reversal journal), so a fuller timeline (created-by, exact cancellation moment, refund
 * dates) is deferred rather than fabricated here (see DECISIONS, P13 Part 3a scope).
 */
export function invoiceActivityTimeline(
  doc: InvoiceDocument,
): InvoiceActivityEntry[] {
  const entries: InvoiceActivityEntry[] = [];
  if (doc.status === "draft") {
    entries.push({
      label: "Draf, belum diterbitkan",
      date: null,
      tone: "neutral",
    });
  } else {
    entries.push({
      label: "Diterbitkan",
      date: doc.issue_date,
      tone: "neutral",
    });
  }
  for (const payment of doc.payments) {
    entries.push({
      label: `Pembayaran diterima (Kwitansi ${payment.receipt_number})`,
      date: payment.payment_date,
      tone: "success",
    });
  }
  if (doc.status === "cancelled" || doc.status === "void") {
    entries.push({
      label: INVOICE_STATUS_LABELS[doc.status],
      date: null,
      tone: "neutral",
    });
  }
  return entries;
}
