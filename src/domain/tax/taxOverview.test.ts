import { describe, expect, it } from "vitest";
import { incomeTaxByMonth, totalOutstanding } from "./taxOverview";
import type { TaxLedgerRow } from "@/schemas/tax";

const row = (over: Partial<TaxLedgerRow>): TaxLedgerRow => ({
  entry_id: "00000000-0000-4000-8000-000000000001",
  entry_date: "2026-03-10",
  tax_period: "2026-03-01",
  tax_kind: "wht_pph23",
  tax_type: "wht_pph23",
  direction: "payable",
  entry_kind: "accrual",
  amount: "250000.0000",
  source_type: "expense",
  source_id: null,
  determination_status: "auto_determined",
  journal_id: null,
  description: null,
  ...over,
});

describe("incomeTaxByMonth", () => {
  it("adds accruals, subtracts reversals, skips PPN and other years", () => {
    const months = incomeTaxByMonth(
      [
        row({}),
        row({ amount: "100000.0000" }),
        row({ entry_kind: "reversal", amount: "-50000.0000" }),
        row({ tax_type: "vat", amount: "999.0000" }),
        row({ tax_period: "2025-03-01", amount: "777.0000" }),
        row({ tax_period: "2026-12-01", tax_type: "final_umkm", amount: "40000.0000" }),
      ],
      2026,
    );
    expect(Number(months[2])).toBe(300000);
    expect(Number(months[11])).toBe(40000);
    expect(months[0]).toBe("0");
  });
});

describe("totalOutstanding", () => {
  it("sums every tax type", () => {
    expect(Number(totalOutstanding({ wht_pph23: "250000.0000", vat: "100.5000" }))).toBe(250100.5);
    expect(totalOutstanding({})).toBe("0");
  });
});
