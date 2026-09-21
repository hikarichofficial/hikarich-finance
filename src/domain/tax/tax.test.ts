import { describe, expect, it } from "vitest";
import {
  CALENDAR_STATE_LABELS,
  CALENDAR_STEP_LABELS,
  DETERMINATION_STATUS_LABELS,
  DIFFERENCE_LABELS,
  EVIDENCE_PURPOSE_LABELS,
  TAX_KIND_LABELS,
  TAX_TYPE_LABELS,
  blocksRecognition,
  checkTaxPayment,
  isTaxPeriodStart,
  outstandingTax,
  taxPaymentCash,
  taxPeriodLabel,
  taxPeriodStart,
} from "./tax";

describe("tax periods", () => {
  it("a period is identified by the first day of its month", () => {
    expect(taxPeriodStart("2026-09-21")).toBe("2026-09-01");
    expect(taxPeriodStart("2026-12-31")).toBe("2026-12-01");
    expect(isTaxPeriodStart("2026-09-01")).toBe(true);
    expect(isTaxPeriodStart("2026-09-02")).toBe(false);
    expect(isTaxPeriodStart("September")).toBe(false);
  });

  it("labels a period in Indonesian", () => {
    expect(taxPeriodLabel("2026-01-01")).toBe("Januari 2026");
    expect(taxPeriodLabel("2026-12-01")).toBe("Desember 2026");
  });

  it("refuses text that is not a date", () => {
    expect(() => taxPeriodStart("2026-9-1")).toThrow(RangeError);
    expect(() => taxPeriodLabel("2026-13-01")).toThrow(RangeError);
    expect(() => taxPeriodLabel("nope")).toThrow(RangeError);
  });
});

describe("tax payment arithmetic", () => {
  it("cash is the tax paid, less the input VAT offset, plus any penalty", () => {
    expect(taxPaymentCash({ payable: "220000" }).toString()).toBe("220000");
    expect(taxPaymentCash({ payable: "220000", assetOffset: "100000" }).toString()).toBe("120000");
    expect(taxPaymentCash({ payable: "40000", assetOffset: "0", penalty: "5000" }).toString()).toBe(
      "45000",
    );
    expect(taxPaymentCash({ payable: "110000", assetOffset: "110000" }).isZero()).toBe(true);
  });

  it("stays exact with decimals", () => {
    expect(
      taxPaymentCash({ payable: "0.1", assetOffset: "0.05", penalty: "0.02" }).toString(),
    ).toBe("0.07");
  });

  it("refuses text that is not an amount", () => {
    expect(() => taxPaymentCash({ payable: "abc" })).toThrow(RangeError);
  });

  it("flags what the database would refuse", () => {
    const base = { taxType: "wht_pph23" as const, hasAccount: true, payable: "100000" };
    expect(checkTaxPayment(base)).toEqual([]);
    expect(checkTaxPayment({ ...base, payable: "0" })).toContain("payable_not_positive");
    expect(checkTaxPayment({ ...base, assetOffset: "10000" })).toContain("offset_only_vat");
    expect(checkTaxPayment({ ...base, taxType: "vat", assetOffset: "100001" })).toContain(
      "offset_exceeds_payable",
    );
    expect(checkTaxPayment({ ...base, penalty: "5000" })).toContain("penalty_needs_note");
    expect(checkTaxPayment({ ...base, penalty: "5000", note: "STP 123" })).toEqual([]);
    expect(checkTaxPayment({ ...base, hasAccount: false })).toContain("account_required");
    expect(checkTaxPayment({ ...base, taxType: "vat", assetOffset: "100000" })).toContain(
      "account_not_needed",
    );
    expect(
      checkTaxPayment({
        ...base,
        taxType: "vat",
        assetOffset: "100000",
        hasAccount: false,
      }),
    ).toEqual([]);
    expect(checkTaxPayment({ ...base, payable: "-1" })).toContain("negative_amount");
  });

  it("shows an overpayment as a negative figure, never clamped", () => {
    expect(outstandingTax("10000.0000", "30000").toString()).toBe("-20000.0000");
    expect(outstandingTax("300000", "100000").toFixed(0)).toBe("200000");
    expect(outstandingTax("0", "0").isZero()).toBe(true);
  });
});

describe("tax vocabulary", () => {
  it("only a result that needs review blocks recognition", () => {
    expect(blocksRecognition("needs_review")).toBe(true);
    expect(blocksRecognition("auto_determined")).toBe(false);
    expect(blocksRecognition("overridden")).toBe(false);
    expect(blocksRecognition("owner_confirmed")).toBe(false);
  });

  it("has a label for every code the database can return", () => {
    expect(Object.keys(TAX_TYPE_LABELS).sort()).toEqual(["final_umkm", "vat", "wht_pph23"]);
    expect(Object.keys(TAX_KIND_LABELS).sort()).toEqual([
      "final_umkm",
      "vat_input",
      "vat_output",
      "wht_pph23",
    ]);
    expect(Object.keys(CALENDAR_STEP_LABELS).sort()).toEqual([
      "calculate",
      "evidence",
      "file",
      "pay",
    ]);
    expect(Object.keys(CALENDAR_STATE_LABELS).sort()).toEqual([
      "done",
      "due",
      "no_rule",
      "not_applicable",
      "overdue",
      "upcoming",
    ]);
    expect(Object.keys(DIFFERENCE_LABELS).sort()).toEqual([
      "filed_base_differs",
      "filed_credit_differs",
      "filed_tax_differs",
      "filing_missing",
      "overpaid",
      "unpaid",
    ]);
    expect(Object.keys(EVIDENCE_PURPOSE_LABELS).sort()).toEqual([
      "filing_receipt",
      "other",
      "payment_proof",
      "tax_invoice",
      "withholding_slip",
    ]);
    expect(DETERMINATION_STATUS_LABELS.needs_review).toBe("Perlu ditinjau");
  });
});
