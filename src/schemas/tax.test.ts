import { describe, expect, it } from "vitest";
import { createBillDraftInputSchema } from "./purchases";
import { createInvoiceDraftInputSchema } from "./sales";
import {
  computeFinalTaxInputSchema,
  confirmLineInputSchema,
  differenceSchema,
  periodPositionSchema,
  recordEntityProfileInputSchema,
  recordTaxFilingInputSchema,
  recordTaxPaymentInputSchema,
  reconcileTaxPeriodInputSchema,
  setOverrideInputSchema,
  taxCalendarSchema,
  taxLedgerSchema,
  taxPaymentListSchema,
  taxPreviewSchema,
  taxPeriodSchema,
} from "./tax";

const ID = "11111111-1111-4111-8111-111111111111";
const ID2 = "22222222-2222-4222-8222-222222222222";
const KEY = "key-tax-0001";

describe("tax input contracts", () => {
  it("a tax period is the first day of a month", () => {
    expect(taxPeriodSchema.safeParse("2026-09-01").success).toBe(true);
    expect(taxPeriodSchema.safeParse("2026-09-15").success).toBe(false);
    expect(taxPeriodSchema.safeParse("2026-02-30").success).toBe(false);
  });

  it("a payment keeps money as text and rejects numbers and floats", () => {
    const base = {
      entity_id: ID,
      idempotency_key: KEY,
      tax_type: "vat",
      period: "2026-09-01",
      payment_date: "2026-09-21",
      account_id: ID2,
      payable: "99000",
      asset_offset: "55000",
    };
    expect(recordTaxPaymentInputSchema.safeParse(base).success).toBe(true);
    expect(recordTaxPaymentInputSchema.safeParse({ ...base, payable: 99000 }).success).toBe(false);
    expect(recordTaxPaymentInputSchema.safeParse({ ...base, payable: "99,000" }).success).toBe(
      false,
    );
    expect(recordTaxPaymentInputSchema.safeParse({ ...base, tax_type: "pph21" }).success).toBe(
      false,
    );
    expect(recordTaxPaymentInputSchema.safeParse({ ...base, period: "2026-09-10" }).success).toBe(
      false,
    );
    expect(recordTaxPaymentInputSchema.safeParse({ ...base, account_id: null }).success).toBe(true);
  });

  it("a filing needs its receipt number", () => {
    const base = {
      entity_id: ID,
      idempotency_key: KEY,
      tax_type: "wht_pph23",
      period: "2026-09-01",
      filed_date: "2026-10-18",
      reference: "BPE-0001",
      reported_base: "1500000",
      reported_tax: "30000",
    };
    expect(recordTaxFilingInputSchema.safeParse(base).success).toBe(true);
    expect(recordTaxFilingInputSchema.safeParse({ ...base, reference: "B" }).success).toBe(false);
    expect(recordTaxFilingInputSchema.safeParse({ ...base, amendment: true }).success).toBe(true);
  });

  it("an override needs a reason and an evidence note", () => {
    const base = {
      source_type: "bill",
      source_id: ID,
      idempotency_key: KEY,
      kind: "wht_pph23",
      amount: "0",
      reason: "Certificate of exemption on file",
      evidence_note: "SKB 123",
    };
    expect(setOverrideInputSchema.safeParse(base).success).toBe(true);
    expect(setOverrideInputSchema.safeParse({ ...base, reason: "short" }).success).toBe(false);
    expect(setOverrideInputSchema.safeParse({ ...base, evidence_note: "x" }).success).toBe(false);
    expect(setOverrideInputSchema.safeParse({ ...base, source_type: "journal" }).success).toBe(
      false,
    );
  });

  it("confirming a line takes a known treatment", () => {
    const base = { source_type: "invoice", source_id: ID, line_no: 1, treatment: "vat_taxable" };
    expect(confirmLineInputSchema.safeParse(base).success).toBe(true);
    expect(
      confirmLineInputSchema.safeParse({ ...base, treatment: "wht_rent_movable" }).success,
    ).toBe(true);
    expect(confirmLineInputSchema.safeParse({ ...base, treatment: "whatever" }).success).toBe(
      false,
    );
    expect(confirmLineInputSchema.safeParse({ ...base, line_no: 0 }).success).toBe(false);
  });

  it("the entity profile and the reconciliation and final-tax requests validate their shape", () => {
    expect(
      recordEntityProfileInputSchema.safeParse({
        entity_id: ID,
        idempotency_key: KEY,
        effective_from: "2026-05-01",
        taxpayer_kind: "perseroan_perorangan",
        residency: "resident",
        income_regime: "final_umkm",
        umkm_exclusion: "none",
        aggregation_status: "none",
        vat_status: "non_pkp",
        withholding_agent: "no",
      }).success,
    ).toBe(true);
    expect(
      recordEntityProfileInputSchema.safeParse({
        entity_id: ID,
        idempotency_key: KEY,
        effective_from: "2026-05-01",
        taxpayer_kind: "corporation",
        residency: "resident",
        income_regime: "final_umkm",
        umkm_exclusion: "none",
        aggregation_status: "none",
        vat_status: "non_pkp",
        withholding_agent: "no",
      }).success,
    ).toBe(false);
    expect(
      reconcileTaxPeriodInputSchema.safeParse({
        entity_id: ID,
        idempotency_key: KEY,
        tax_type: "vat",
        period: "2026-09-01",
      }).success,
    ).toBe(true);
    expect(
      computeFinalTaxInputSchema.safeParse({
        entity_id: ID,
        idempotency_key: KEY,
        period: "2026-09-02",
      }).success,
    ).toBe(false);
  });
});

describe("tax facts on document lines", () => {
  it("an invoice line carries the VAT treatment the drafter asserts", () => {
    const parsed = createInvoiceDraftInputSchema.parse({
      entity_id: ID,
      idempotency_key: KEY,
      customer_id: ID2,
      issue_date: "2026-09-10",
      due_date: "2026-09-24",
      lines: [{ description: "Kursus", unit_price: "1000000", vat_treatment: "vat_taxable" }],
    });
    expect(parsed.lines[0]?.vat_treatment).toBe("vat_taxable");
  });

  it("a bill line keeps the input VAT, its tax-invoice number and the withholding object", () => {
    const parsed = createBillDraftInputSchema.parse({
      entity_id: ID,
      idempotency_key: KEY,
      vendor_id: ID2,
      bill_date: "2026-09-10",
      due_date: "2026-09-24",
      lines: [
        {
          description: "Sewa",
          unit_price: "10000000",
          tax_amount: "1100000",
          vat_invoice_ref: "010.000-26.00000101",
          wht_object: "wht_rent_movable",
        },
      ],
    });
    expect(parsed.lines[0]).toMatchObject({
      tax_amount: "1100000",
      vat_invoice_ref: "010.000-26.00000101",
      wht_object: "wht_rent_movable",
    });
    expect(
      createBillDraftInputSchema.safeParse({
        entity_id: ID,
        idempotency_key: KEY,
        vendor_id: ID2,
        bill_date: "2026-09-10",
        due_date: "2026-09-24",
        lines: [{ description: "Sewa", unit_price: "1", wht_object: "made_up" }],
      }).success,
    ).toBe(false);
  });
});

describe("tax results", () => {
  it("reads a preview and keeps fields it does not list", () => {
    const parsed = taxPreviewSchema.parse({
      source_type: "invoice",
      source_id: ID,
      event_date: "2026-09-21",
      tax_period: "2026-09-01",
      status: "auto_determined",
      reasons: [],
      results: [{ kind: "vat_output", status: "auto_determined", tax: "99000", trace: [] }],
      vat_output_total: "99000",
      withheld_total: "0",
      vat_input_creditable: "0",
      vat_input_cost: "0",
      engine: "active",
    });
    expect(parsed.results[0]?.tax).toBe("99000");
    expect(parsed.engine).toBe("active");
  });

  it("reads a period position with its differences, including a negative overpayment", () => {
    const parsed = periodPositionSchema.parse({
      tax_type: "wht_pph23",
      tax_period: "2026-09-01",
      as_of: "2026-09-21",
      base: "500000.0000",
      accrued_payable: "10000.0000",
      paid_payable: "30000.0000",
      outstanding_payable: "-20000.0000",
      accrued_asset: "0.0000",
      applied_asset: "0.0000",
      asset_available: "0",
      penalty_paid: "0.0000",
      cash_paid: "30000.0000",
      filing_id: null,
      filed_reference: null,
      differences: [
        { code: "filing_missing", text: "No filing is recorded for this period", amount: null },
        { code: "overpaid", text: "20000 more was paid", amount: "-20000.0000" },
      ],
      evidence_count: 0,
    });
    expect(parsed.differences).toHaveLength(2);
    expect(differenceSchema.safeParse({ code: "other", text: "x", amount: null }).success).toBe(
      false,
    );
  });

  it("lists payments, the tax ledger and the calendar", () => {
    expect(
      taxPaymentListSchema.safeParse([
        {
          payment_id: ID,
          payment_number: "TAXPAY-000001",
          status: "confirmed",
          tax_type: "vat",
          tax_period: "2026-09-01",
          payment_date: "2026-09-21",
          payable_applied: "99000.0000",
          asset_applied: "55000.0000",
          penalty_amount: "0.0000",
          cash_amount: "44000.0000",
          financial_account_id: ID2,
          reference: "NTPN-K1",
          journal_id: ID,
          reversal_journal_id: null,
        },
      ]).success,
    ).toBe(true);
    expect(
      taxLedgerSchema.safeParse([
        {
          entry_id: ID,
          entry_date: "2026-09-21",
          tax_period: "2026-09-01",
          tax_kind: "vat_output",
          tax_type: "vat",
          direction: "payable",
          entry_kind: "accrual",
          amount: "99000.0000",
          source_type: "invoice",
          source_id: ID2,
          determination_status: "auto_determined",
          journal_id: ID,
          description: null,
        },
      ]).success,
    ).toBe(true);
    expect(
      taxCalendarSchema.safeParse([
        {
          tax_type: "final_umkm",
          tax_period: "2026-05-01",
          step: "pay",
          due_date: "2026-06-15",
          state: "done",
          outstanding: null,
          rule_code: "PPH_FINAL_UMKM",
          rule_version: 1,
          detail: null,
        },
      ]).success,
    ).toBe(true);
    // amounts are text: a JSON number would have lost its exactness on the way
    expect(
      taxPaymentListSchema.safeParse([
        {
          payment_id: ID,
          payment_number: "TAXPAY-000001",
          status: "confirmed",
          tax_type: "vat",
          tax_period: "2026-09-01",
          payment_date: "2026-09-21",
          payable_applied: 99000,
          asset_applied: "0",
          penalty_amount: "0",
          cash_amount: "0",
          financial_account_id: null,
          reference: null,
          journal_id: null,
          reversal_journal_id: null,
        },
      ]).success,
    ).toBe(false);
  });
});
