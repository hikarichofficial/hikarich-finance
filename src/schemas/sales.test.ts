import { describe, expect, it } from "vitest";
import {
  createInvoiceDraftInputSchema,
  createRefundInputSchema,
  invoicePositionsSchema,
  publicClaimInputSchema,
  publicInvoiceViewSchema,
  recordPaymentInputSchema,
  updateInvoiceDraftInputSchema,
} from "./sales";

const ID = "11111111-1111-4111-8111-111111111111";
const ID2 = "22222222-2222-4222-8222-222222222222";
const TOKEN = "A".repeat(43);

describe("sales contracts", () => {
  it("an invoice draft keeps money as text and needs a due date on or after the issue date", () => {
    const base = {
      entity_id: ID,
      idempotency_key: "key-invoice-1",
      customer_id: ID2,
      issue_date: "2026-09-10",
      due_date: "2026-09-24",
      lines: [{ description: "Jasa", quantity: "2", unit_price: "150000" }],
    };
    expect(createInvoiceDraftInputSchema.safeParse(base).success).toBe(true);
    expect(
      createInvoiceDraftInputSchema.safeParse({
        ...base,
        lines: [{ description: "Jasa", unit_price: 150000 }],
      }).success,
    ).toBe(false);
    expect(
      createInvoiceDraftInputSchema.safeParse({ ...base, due_date: "2026-09-09" }).success,
    ).toBe(false);
    expect(
      createInvoiceDraftInputSchema.safeParse({ ...base, issue_date: "2026-02-30" }).success,
    ).toBe(false);
  });

  it("a draft patch must change something; lines replace all lines", () => {
    expect(updateInvoiceDraftInputSchema.safeParse({ invoice_id: ID, patch: {} }).success).toBe(
      false,
    );
    expect(
      updateInvoiceDraftInputSchema.safeParse({
        invoice_id: ID,
        expected_version: 3,
        patch: { lines: [{ description: "x", unit_price: "1" }], notes: null },
      }).success,
    ).toBe(true);
  });

  it("a payment lists its allocations as text amounts", () => {
    const input = {
      entity_id: ID,
      idempotency_key: "key-payment-01",
      customer_id: ID2,
      account_id: ID,
      payment_date: "2026-09-12",
      amount: "1000000",
      allocations: [{ invoice_id: ID2, amount: "1000000" }],
    };
    expect(recordPaymentInputSchema.safeParse(input).success).toBe(true);
    expect(
      recordPaymentInputSchema.safeParse({
        ...input,
        allocations: [{ invoice_id: ID2, amount: 1 }],
      }).success,
    ).toBe(false);
    expect(recordPaymentInputSchema.safeParse({ ...input, idempotency_key: "short" }).success).toBe(
      false,
    );
  });

  it("refund items name their source", () => {
    const base = {
      payment_id: ID,
      idempotency_key: "key-refund-01",
      account_id: ID2,
      refund_date: "2026-09-15",
    };
    expect(
      createRefundInputSchema.safeParse({
        ...base,
        items: [
          { source: "allocation", allocation_id: ID2, amount: "100000" },
          { source: "advance", amount: "50000" },
        ],
      }).success,
    ).toBe(true);
    expect(
      createRefundInputSchema.safeParse({ ...base, items: [{ source: "allocation", amount: "1" }] })
        .success,
    ).toBe(false);
    expect(createRefundInputSchema.safeParse({ ...base, items: [] }).success).toBe(false);
  });

  it("the public claim accepts only a well-formed token", () => {
    const claim = { token: TOKEN, amount: "500000", payment_date: "2026-09-18" };
    expect(publicClaimInputSchema.safeParse(claim).success).toBe(true);
    expect(publicClaimInputSchema.safeParse({ ...claim, token: "short" }).success).toBe(false);
    expect(publicClaimInputSchema.safeParse({ ...claim, token: `${TOKEN}/../x` }).success).toBe(
      false,
    );
  });

  it("the public view is either unavailable or a full document, never a partial one", () => {
    expect(publicInvoiceViewSchema.safeParse({ state: "unavailable" }).success).toBe(true);
    expect(publicInvoiceViewSchema.safeParse({ state: "ok" }).success).toBe(false);
  });

  it("invoice positions keep amounts as text", () => {
    const row = {
      invoice_id: ID,
      invoice_number: "HKD/2026/0001",
      customer_id: ID2,
      customer_name: "Alfa",
      currency: "IDR",
      status: "issued",
      issue_date: "2026-09-01",
      due_date: "2026-09-15",
      total: "1000000.0000",
      settled: "400000.0000",
      outstanding: "600000.0000",
      base_outstanding: "600000.0000",
      refunded: "0.0000",
      settlement_status: "partial",
      refund_status: "none",
      is_overdue: true,
      days_overdue: 5,
    };
    expect(invoicePositionsSchema.safeParse([row]).success).toBe(true);
    expect(invoicePositionsSchema.safeParse([{ ...row, total: 1000000 }]).success).toBe(false);
  });
});
