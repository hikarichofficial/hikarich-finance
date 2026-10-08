import { describe, expect, it } from "vitest";
import { compactNumber, formatPercent, percentChange, pnlBreakdown } from "./chart";
import type { ProfitAndLossRow } from "@/schemas/reports";

const row = (name: string, cls: ProfitAndLossRow["account_class"], d: string, c: string) =>
  ({
    account_id: "00000000-0000-4000-8000-000000000001",
    code: "1",
    name,
    account_class: cls,
    parent_id: null,
    debit: d,
    credit: c,
    compare_debit: null,
    compare_credit: null,
  }) as ProfitAndLossRow;

describe("compactNumber", () => {
  it("shortens to rb, jt, M", () => {
    expect(compactNumber(950)).toBe("950");
    expect(compactNumber(12_500)).toBe("12,5 rb");
    expect(compactNumber(12_500_000)).toBe("12,5 jt");
    expect(compactNumber(-3_200_000_000)).toBe("-3,2 M");
  });
});

describe("percentChange", () => {
  it("is null without a base and signed otherwise", () => {
    expect(percentChange(null, "10")).toBeNull();
    expect(percentChange("0", "10")).toBeNull();
    expect(percentChange("100", "150")).toBe(50);
    expect(formatPercent(50)).toBe("+50%");
    expect(formatPercent(-12.4)).toBe("-12%");
  });
});

describe("pnlBreakdown", () => {
  it("sorts largest first, folds the rest into Lainnya and shares sum to 100", () => {
    const rows = [
      row("A", "expense", "100.0000", "0.0000"),
      row("B", "expense", "300.0000", "0.0000"),
      row("C", "expense", "50.0000", "0.0000"),
      row("D", "other_expense", "50.0000", "0.0000"),
      row("Sales", "revenue", "0.0000", "900.0000"),
      row("Zero", "expense", "0.0000", "0.0000"),
    ];
    const items = pnlBreakdown(rows, "expense", 2);
    expect(items.map((i) => i.name)).toEqual(["B", "A", "Lainnya"]);
    expect(items[2].amount).toBe("100.0000");
    expect(items.reduce((s, i) => s + i.share, 0)).toBeCloseTo(100);
    expect(pnlBreakdown(rows, "revenue")[0].name).toBe("Sales");
    expect(pnlBreakdown([], "expense")).toEqual([]);
  });
});
