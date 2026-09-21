import { describe, expect, it } from "vitest";
import {
  apControlSchema,
  approveBillInputSchema,
  billPositionsSchema,
  createBillDraftInputSchema,
  createExpenseDraftInputSchema,
  linkDocumentInputSchema,
  recordVendorPaymentInputSchema,
  registerDocumentInputSchema,
  updateBillDraftInputSchema,
  vendorPaymentListSchema,
} from "./purchases";

const ID = "11111111-1111-4111-8111-111111111111";
const ID2 = "22222222-2222-4222-8222-222222222222";
const HASH = "ab".repeat(32);

describe("purchase contracts", () => {
  it("a bill draft keeps money as text and needs a due date on or after the bill date", () => {
    const base = {
      entity_id: ID,
      idempotency_key: "key-bill-0001",
      vendor_id: ID2,
      bill_date: "2026-09-10",
      due_date: "2026-09-24",
      lines: [{ description: "Bahan baku", quantity: "2", unit_price: "150000" }],
    };
    expect(createBillDraftInputSchema.safeParse(base).success).toBe(true);
    expect(
      createBillDraftInputSchema.safeParse({
        ...base,
        lines: [{ description: "Bahan baku", unit_price: 150000 }],
      }).success,
    ).toBe(false);
    expect(createBillDraftInputSchema.safeParse({ ...base, due_date: "2026-09-09" }).success).toBe(
      false,
    );
    expect(
      createBillDraftInputSchema.safeParse({
        ...base,
        lines: [{ description: "x", unit_price: "1", treatment: "inventory" }],
      }).success,
    ).toBe(false);
    expect(createBillDraftInputSchema.safeParse({ ...base, notes: "n".repeat(2001) }).success).toBe(
      false,
    );
  });

  it("a draft patch must change something; lines replace all lines", () => {
    expect(updateBillDraftInputSchema.safeParse({ bill_id: ID, patch: {} }).success).toBe(false);
    expect(
      updateBillDraftInputSchema.safeParse({
        bill_id: ID,
        expected_version: 2,
        patch: { lines: [{ description: "x", unit_price: "1" }], notes: null },
      }).success,
    ).toBe(true);
  });

  it("approving a duplicate needs a written reason of at least five characters", () => {
    const base = { bill_id: ID, idempotency_key: "key-approve-1" };
    expect(approveBillInputSchema.safeParse(base).success).toBe(true);
    expect(approveBillInputSchema.safeParse({ ...base, duplicate_reason: "beda" }).success).toBe(
      false,
    );
    expect(
      approveBillInputSchema.safeParse({ ...base, duplicate_reason: "Faktur berbeda, nomor sama" })
        .success,
    ).toBe(true);
  });

  it("a vendor payment names its bills, has at least one and no more than a hundred", () => {
    const base = {
      entity_id: ID,
      idempotency_key: "key-vpay-0001",
      vendor_id: ID2,
      account_id: ID,
      payment_date: "2026-09-12",
      amount: "1000000",
      allocations: [{ bill_id: ID2, amount: "1000000" }],
    };
    expect(recordVendorPaymentInputSchema.safeParse(base).success).toBe(true);
    expect(recordVendorPaymentInputSchema.safeParse({ ...base, allocations: [] }).success).toBe(
      false,
    );
    expect(recordVendorPaymentInputSchema.safeParse({ ...base, amount: 1000000 }).success).toBe(
      false,
    );
    expect(
      recordVendorPaymentInputSchema.safeParse({ ...base, payment_date: "2026-02-30" }).success,
    ).toBe(false);
  });

  it("an expense names a vendor or a payee", () => {
    const base = {
      entity_id: ID,
      idempotency_key: "key-expense-1",
      account_id: ID2,
      expense_date: "2026-09-12",
      lines: [{ description: "Bensin", unit_price: "50000" }],
    };
    expect(createExpenseDraftInputSchema.safeParse(base).success).toBe(false);
    expect(createExpenseDraftInputSchema.safeParse({ ...base, payee_name: "SPBU" }).success).toBe(
      true,
    );
    expect(createExpenseDraftInputSchema.safeParse({ ...base, payee_id: ID }).success).toBe(true);
  });

  it("a document is a plain file name, an allowed type, up to 25 MB, and a SHA-256", () => {
    const base = {
      entity_id: ID,
      idempotency_key: "key-doc-00001",
      file_name: "faktur-001.pdf",
      mime_type: "application/pdf",
      size_bytes: 120_000,
      sha256: HASH,
    };
    expect(registerDocumentInputSchema.safeParse(base).success).toBe(true);
    expect(
      registerDocumentInputSchema.safeParse({ ...base, file_name: "../faktur.pdf" }).success,
    ).toBe(false);
    expect(registerDocumentInputSchema.safeParse({ ...base, file_name: "a\\b.pdf" }).success).toBe(
      false,
    );
    expect(registerDocumentInputSchema.safeParse({ ...base, mime_type: "text/html" }).success).toBe(
      false,
    );
    expect(
      registerDocumentInputSchema.safeParse({ ...base, size_bytes: 25 * 1024 * 1024 + 1 }).success,
    ).toBe(false);
    expect(registerDocumentInputSchema.safeParse({ ...base, size_bytes: 0 }).success).toBe(false);
    expect(registerDocumentInputSchema.safeParse({ ...base, sha256: "abc" }).success).toBe(false);
    const upper = registerDocumentInputSchema.parse({ ...base, sha256: HASH.toUpperCase() });
    expect(upper.sha256).toBe(HASH);
  });

  it("a document attaches to a bill or an expense", () => {
    expect(
      linkDocumentInputSchema.safeParse({ document_id: ID, target_type: "bill", target_id: ID2 })
        .success,
    ).toBe(true);
    expect(
      linkDocumentInputSchema.safeParse({ document_id: ID, target_type: "invoice", target_id: ID2 })
        .success,
    ).toBe(false);
    expect(
      linkDocumentInputSchema.safeParse({
        document_id: ID,
        target_type: "expense",
        target_id: ID2,
        purpose: "gossip",
      }).success,
    ).toBe(false);
  });

  it("reads amounts printed in any scale and counts that arrive as text", () => {
    const position = {
      bill_id: ID,
      bill_number: "BILL-2026-0001",
      vendor_id: ID2,
      vendor_name: "PT Vendor",
      vendor_reference: null,
      currency: "IDR",
      status: "approved",
      bill_date: "2026-09-10",
      due_date: "2026-09-24",
      total: "5000000.0000",
      settled: "0",
      outstanding: "5000000.0000",
      base_outstanding: "5000000.0000",
      settlement_status: "unpaid",
      is_overdue: false,
      days_overdue: 0,
    };
    expect(billPositionsSchema.safeParse([position]).success).toBe(true);
    expect(billPositionsSchema.safeParse([{ ...position, status: "draft" }]).success).toBe(false);
    expect(
      vendorPaymentListSchema.parse([
        {
          payment_id: ID,
          payment_number: "PAY-2026-0001",
          status: "confirmed",
          payment_date: "2026-09-12",
          vendor_id: ID2,
          vendor_name: "PT Vendor",
          currency: "IDR",
          amount: "1000000.0000",
          base_amount: "1000000.0000",
          fx_difference: "0.0000",
          reference: null,
          bill_count: "2",
        },
      ])[0].bill_count,
    ).toBe(2);
    expect(
      apControlSchema.safeParse([
        {
          sub_ledger: "0",
          ledger_purchases: "0.0000",
          ledger_total: "0",
          difference: "0",
          other_ledger: "0",
        },
      ]).success,
    ).toBe(true);
  });
});
