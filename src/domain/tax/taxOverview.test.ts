import { describe, expect, it } from "vitest";
import { incomeTaxByMonth, resolveTaxScope, scopeTotals, totalOutstanding } from "./taxOverview";
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

describe("resolveTaxScope (decision 409)", () => {
  const today = "2026-10-12";
  it("defaults to the whole current year", () => {
    const s = resolveTaxScope({}, today);
    expect(s).toMatchObject({ kind: "year", year: 2026, from: "2026-01-01", to: "2026-12-31" });
  });
  it("reads one month by its tax period", () => {
    const s = resolveTaxScope({ scope: "month", month: "2026-09" }, today);
    expect(s).toMatchObject({
      kind: "month",
      month: "2026-09",
      year: 2026,
      from: "2026-09-01",
      to: "2026-09-01",
    });
    expect(s.label).toBe("September 2026");
  });
  it("falls back to the running month for a bad or future month", () => {
    expect(resolveTaxScope({ scope: "month", month: "2027-01" }, today).month).toBe("2026-10");
    expect(resolveTaxScope({ scope: "month", month: "abc" }, today).month).toBe("2026-10");
  });
  it("has no limits for everything since the start", () => {
    expect(resolveTaxScope({ scope: "all" }, today)).toMatchObject({
      kind: "all",
      from: null,
      to: null,
    });
  });
  it("takes an earlier year and ignores a future one", () => {
    expect(resolveTaxScope({ scope: "year", year: "2025" }, today).year).toBe(2025);
    expect(resolveTaxScope({ scope: "year", year: "2031" }, today).year).toBe(2026);
  });
});

describe("scopeTotals", () => {
  it("adds counted and paid and subtracts them for what is left", () => {
    const rows = [
      {
        tax_type: "final_umkm",
        accrued: "116814.0000",
        paid: "16814.0000",
        outstanding: "100000.0000",
      },
      { tax_type: "wht_pph23", accrued: "50000.0000", paid: "0.0000", outstanding: "50000.0000" },
    ] as never;
    expect(scopeTotals(rows)).toEqual({
      accrued: "166814.0000",
      paid: "16814.0000",
      outstanding: "150000.0000",
    });
  });
});
