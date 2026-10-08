import { describe, expect, it } from "vitest";
import { grossFromReceived, incomeTaxNote, monthRange, summarizeIncome } from "./income";

describe("summarizeIncome", () => {
  it("adds business income and outside income apart, and skips reversed entries", () => {
    const summary = summarizeIncome([
      { status: "recorded", amount: "5000000.0000", in_turnover: true },
      { status: "recorded", amount: "1000000", in_turnover: false },
      { status: "recorded", amount: "250000.5", in_turnover: true },
      { status: "reversed", amount: "9999999", in_turnover: true },
    ]);
    expect(summary).toEqual({
      count: 3,
      total: "6250000.5",
      turnover: "5250000.5",
      outside: "1000000",
    });
  });

  it("is zero for no entries", () => {
    expect(summarizeIncome([])).toEqual({ count: 0, total: "0", turnover: "0", outside: "0" });
  });
});

describe("incomeTaxNote", () => {
  it("says whether the income is in the final-tax base", () => {
    expect(incomeTaxNote(true)).toContain("ikut dasar PPh Final");
    expect(incomeTaxNote(false)).toContain("tidak ikut dasar PPh Final");
  });
});

describe("monthRange", () => {
  it("gives the first and last day of the month", () => {
    expect(monthRange("2026-02")).toEqual({ from: "2026-02-01", to: "2026-02-28" });
    expect(monthRange("2028-02")).toEqual({ from: "2028-02-01", to: "2028-02-29" });
  });
  it("refuses anything that is not a month", () => {
    expect(monthRange("2026-13")).toBeNull();
    expect(monthRange("")).toBeNull();
  });
});

describe("incomeTaxNote for a Personal book", () => {
  it("words each tag and the untagged case", () => {
    expect(incomeTaxNote(false, "freelance")).toContain("PPh Progresif");
    expect(incomeTaxNote(false, "company_payout")).toContain("dokumen PT");
    expect(incomeTaxNote(true, "umkm_business")).toContain("PPh Final 0,5%");
    expect(incomeTaxNote(false, null)).toContain("tidak masuk hitungan Pajak Pribadi");
  });
});

describe("grossFromReceived", () => {
  it("adds the tax the client withheld to what reached the account", () => {
    expect(grossFromReceived("9500000", "500000")).toBe("10000000");
    expect(grossFromReceived("1000.5", "0.25")).toBe("1000.75");
    expect(grossFromReceived("2500000", "")).toBe("2500000");
  });
});
