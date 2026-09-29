import { describe, expect, it } from "vitest";
import type { ReceiptDocument } from "@/schemas/sales";
import { paymentReceiptStatus } from "./receiptDocument";

function receipt(overrides: Partial<ReceiptDocument> = {}): ReceiptDocument {
  return {
    receipt_number: "RCP-0001",
    status: "confirmed",
    payment_date: "2026-09-01",
    amount: "1000000",
    currency: "IDR",
    reference: null,
    issuer: {},
    customer: {},
    method: null,
    allocations: [],
    refunded: "0",
    ...overrides,
  };
}

describe("paymentReceiptStatus", () => {
  it("marks a confirmed receipt as Diterima with a success tone", () => {
    expect(paymentReceiptStatus(receipt({ status: "confirmed" }))).toEqual({
      text: "Diterima",
      tone: "success",
    });
  });

  it("marks a reversed receipt as Dibatalkan with a neutral tone", () => {
    expect(paymentReceiptStatus(receipt({ status: "reversed" }))).toEqual({
      text: "Dibatalkan",
      tone: "neutral",
    });
  });
});
