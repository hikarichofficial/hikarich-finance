import { describe, expect, it } from "vitest";
import {
  FISCAL_CLASSES,
  findFiscalClass,
  fiscalClassLabel,
  monthlyStraightLine,
} from "./fiscalClasses";

describe("fiscal classes", () => {
  it("gives each depreciable group a life that matches its straight-line rate", () => {
    for (const item of FISCAL_CLASSES) {
      if (item.lifeMonths === null) continue;
      expect((item.lifeMonths / 12) * (item.straightLineRate ?? 0)).toBe(100);
    }
  });

  it("allows declining balance only for the non-building groups, at twice the straight-line rate", () => {
    for (const item of FISCAL_CLASSES) {
      if (item.key.startsWith("building") || item.key === "land") {
        expect(item.decliningBalanceRate).toBeNull();
      } else {
        expect(item.decliningBalanceRate).toBe((item.straightLineRate ?? 0) * 2);
      }
    }
  });

  it("labels a known key and falls back to the key itself", () => {
    expect(fiscalClassLabel("group_1")).toBe("Kelompok 1 (4 tahun)");
    expect(fiscalClassLabel("something_else")).toBe("something_else");
    expect(findFiscalClass(null)).toBeNull();
  });

  it("computes the monthly straight-line amount", () => {
    expect(monthlyStraightLine("12000000", "", "48")).toBe(250000);
    expect(monthlyStraightLine("12000000", "2400000", "48")).toBe(200000);
    expect(monthlyStraightLine("abc", "", "48")).toBeNull();
    expect(monthlyStraightLine("1000", "2000", "48")).toBeNull();
    expect(monthlyStraightLine("1000", "", "0")).toBeNull();
  });
});
