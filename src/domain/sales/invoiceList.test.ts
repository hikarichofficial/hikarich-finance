import { describe, expect, it } from "vitest";
import type { InvoiceDocument, InvoicePosition } from "@/schemas/sales";
import {
  filterInvoicePositionsByQuery,
  invoiceActivityTimeline,
  invoiceDocumentStatus,
  invoicePositionStatus,
  matchesInvoiceQuery,
  parseInvoiceFilter,
} from "./invoiceList";

function position(overrides: Partial<InvoicePosition> = {}): InvoicePosition {
  return {
    invoice_id: "11111111-1111-1111-1111-111111111111",
    invoice_number: "INV-2026-0001",
    customer_id: "22222222-2222-2222-2222-222222222222",
    customer_name: "PT Contoh Sejahtera",
    currency: "IDR",
    status: "issued",
    issue_date: "2026-09-01",
    due_date: "2026-09-15",
    total: "1000000",
    settled: "0",
    outstanding: "1000000",
    base_outstanding: "1000000",
    refunded: "0",
    settlement_status: "unpaid",
    refund_status: null,
    is_overdue: false,
    days_overdue: 0,
    ...overrides,
  };
}

function document(overrides: Partial<InvoiceDocument> = {}): InvoiceDocument {
  return {
    invoice_number: "INV-2026-0001",
    status: "issued",
    issue_date: "2026-09-01",
    due_date: "2026-09-15",
    currency: "IDR",
    subtotal: "1000000",
    discount_total: "0",
    tax_total: "0",
    total: "1000000",
    settled: "0",
    outstanding: "1000000",
    settlement_status: "unpaid",
    is_overdue: false,
    refunded: "0",
    notes: null,
    terms: null,
    payment_note: null,
    issuer: null,
    customer: null,
    payment_instructions: null,
    lines: [],
    payments: [],
    ...overrides,
  };
}

describe("invoicePositionStatus", () => {
  it("labels a draft as neutral", () => {
    expect(invoicePositionStatus(position({ status: "draft" }))).toEqual({
      text: "Draf",
      tone: "neutral",
    });
  });

  it("labels void/cancelled as neutral regardless of settlement", () => {
    expect(invoicePositionStatus(position({ status: "void" })).tone).toBe(
      "neutral",
    );
    expect(invoicePositionStatus(position({ status: "cancelled" })).tone).toBe(
      "neutral",
    );
  });

  it("labels a paid issued invoice as success even if is_overdue was left true", () => {
    expect(
      invoicePositionStatus(
        position({ settlement_status: "paid", is_overdue: true }),
      ),
    ).toEqual({ text: "Lunas", tone: "success" });
  });

  it("labels an overdue unpaid invoice as critical, with the day count", () => {
    expect(
      invoicePositionStatus(position({ is_overdue: true, days_overdue: 12 })),
    ).toEqual({
      text: "Jatuh tempo 12 hari",
      tone: "critical",
    });
  });

  it("labels a partially paid, not-yet-due invoice as progress", () => {
    expect(
      invoicePositionStatus(position({ settlement_status: "partial" })),
    ).toEqual({
      text: "Dibayar sebagian",
      tone: "progress",
    });
  });

  it("labels an unpaid, not-yet-due invoice as neutral", () => {
    expect(invoicePositionStatus(position())).toEqual({
      text: "Belum dibayar",
      tone: "neutral",
    });
  });
});

describe("invoiceDocumentStatus", () => {
  it("mirrors invoicePositionStatus's rules off the document shape", () => {
    expect(invoiceDocumentStatus(document({ status: "draft" }))).toEqual({
      text: "Draf",
      tone: "neutral",
    });
    expect(
      invoiceDocumentStatus(document({ settlement_status: "paid" })),
    ).toEqual({
      text: "Lunas",
      tone: "success",
    });
    expect(invoiceDocumentStatus(document({ is_overdue: true })).tone).toBe(
      "critical",
    );
  });
});

describe("parseInvoiceFilter", () => {
  it("accepts a known filter value", () => {
    expect(parseInvoiceFilter("overdue")).toBe("overdue");
  });

  it("returns undefined for an absent or unknown value", () => {
    expect(parseInvoiceFilter(undefined)).toBeUndefined();
    expect(parseInvoiceFilter("bogus")).toBeUndefined();
  });
});

describe("matchesInvoiceQuery / filterInvoicePositionsByQuery", () => {
  it("matches case-insensitively on customer name or invoice number", () => {
    const row = position({
      customer_name: "PT Contoh Sejahtera",
      invoice_number: "INV-2026-0042",
    });
    expect(matchesInvoiceQuery(row, "contoh")).toBe(true);
    expect(matchesInvoiceQuery(row, "0042")).toBe(true);
    expect(matchesInvoiceQuery(row, "tidak-ada")).toBe(false);
  });

  it("treats a blank query as matching everything", () => {
    expect(matchesInvoiceQuery(position(), "   ")).toBe(true);
  });

  it("filters a list down to the matching rows only", () => {
    const rows = [
      position({ customer_name: "PT Alpha" }),
      position({ customer_name: "CV Beta" }),
    ];
    expect(filterInvoicePositionsByQuery(rows, "alpha")).toHaveLength(1);
    expect(filterInvoicePositionsByQuery(rows, "")).toHaveLength(2);
  });

  it("still matches a null invoice_number invoice by customer name", () => {
    const row = position({
      invoice_number: null,
      customer_name: "PT Draf Saja",
    });
    expect(matchesInvoiceQuery(row, "draf")).toBe(true);
  });
});

describe("invoiceActivityTimeline", () => {
  it("starts with a draft entry and no date when the invoice is still a draft", () => {
    const timeline = invoiceActivityTimeline(document({ status: "draft" }));
    expect(timeline).toEqual([
      { label: "Draf, belum diterbitkan", date: null, tone: "neutral" },
    ]);
  });

  it("starts with an issued entry dated at issue_date", () => {
    const timeline = invoiceActivityTimeline(document());
    expect(timeline[0]).toEqual({
      label: "Diterbitkan",
      date: "2026-09-01",
      tone: "neutral",
    });
  });

  it("appends one entry per payment, in the order the document lists them", () => {
    const timeline = invoiceActivityTimeline(
      document({
        payments: [
          {
            receipt_number: "RCP-0001",
            payment_date: "2026-09-05",
            amount: "500000",
            currency: "IDR",
          },
          {
            receipt_number: "RCP-0002",
            payment_date: "2026-09-10",
            amount: "500000",
            currency: "IDR",
          },
        ],
      }),
    );
    expect(timeline).toHaveLength(3);
    expect(timeline[1]).toEqual({
      label: "Pembayaran diterima (Kwitansi RCP-0001)",
      date: "2026-09-05",
      tone: "success",
    });
    expect(timeline[2].label).toContain("RCP-0002");
  });

  it("appends a closing entry when the invoice was cancelled or voided", () => {
    const voided = invoiceActivityTimeline(document({ status: "void" }));
    expect(voided.at(-1)).toEqual({
      label: "Dibatalkan (void)",
      date: null,
      tone: "neutral",
    });
  });
});
