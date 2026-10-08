import { describe, expect, it } from "vitest";
import { summaryFromDeterminations, summaryFromPreview } from "./lineTaxSummary";

describe("lineTaxSummary", () => {
  it("takes the preview totals as they are", () => {
    expect(
      summaryFromPreview("42293", {
        vat_input_creditable: "0",
        vat_input_cost: "42293",
        withheld_total: "0",
      }),
    ).toEqual({ vatCharged: "42293", vatCreditable: "0", vatCost: "42293", withheld: "0" });
  });

  it("reads the recorded determinations in force: VAT not credited stays a cost, withholding adds up", () => {
    const summary = summaryFromDeterminations("42293.0000", [
      { tax_kind: "vat_input", tax_amount: "0", superseded_at: null },
      { tax_kind: "wht_pph23", tax_amount: "7000", superseded_at: null },
      { tax_kind: "wht_pph23", tax_amount: "9999", superseded_at: "2026-10-08T00:00:00Z" },
    ]);
    expect(summary.vatCost).toBe("42293.0000");
    expect(summary.vatCreditable).toBe("0.0000");
    expect(summary.withheld).toBe("7000.0000");
  });

  it("splits VAT between credited and cost for a PKP company", () => {
    const summary = summaryFromDeterminations("1100", [
      { tax_kind: "vat_input", tax_amount: "1000", superseded_at: null },
    ]);
    expect(summary.vatCreditable).toBe("1000.0000");
    expect(summary.vatCost).toBe("100.0000");
  });
});
