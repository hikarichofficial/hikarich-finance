import { describe, expect, it } from "vitest";
import {
  FISCAL_CLASSES,
  findFiscalClass,
  fiscalClassLabel,
  monthlyStraightLine,
  previousMonthEnd,
  suggestFiscalClass,
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

  it("suggests a group from the asset's name", () => {
    expect(suggestFiscalClass("Laptop kerja")?.key).toBe("group_1");
    expect(suggestFiscalClass("Meja kantor kayu jati")?.key).toBe("group_1");
    expect(suggestFiscalClass("Rak gudang")?.key).toBe("group_1");
    expect(suggestFiscalClass("Meja kerja")?.key).toBe("group_1");
    expect(suggestFiscalClass("Lemari besi arsip")?.key).toBe("group_2");
    expect(suggestFiscalClass("AC Daikin 1 PK")?.key).toBe("group_2");
    expect(suggestFiscalClass("Mobil operasional")?.key).toBe("group_2");
    expect(suggestFiscalClass("Sepeda motor Honda")?.key).toBe("group_1");
    expect(suggestFiscalClass("Tanah kavling")?.key).toBe("land");
    expect(suggestFiscalClass("Ruko dua lantai")?.key).toBe("building_permanent");
  });

  it("matches whole words only and gives nothing for an unknown name", () => {
    expect(suggestFiscalClass("Biaya promotor")).toBeNull();
    expect(suggestFiscalClass("Sesuatu yang lain")).toBeNull();
    expect(suggestFiscalClass("   ")).toBeNull();
  });

  it("finds the last day of the previous month", () => {
    expect(previousMonthEnd("2026-10-03")).toBe("2026-09-30");
    expect(previousMonthEnd("2026-03-01")).toBe("2026-02-28");
    expect(previousMonthEnd("2024-03-15")).toBe("2024-02-29");
    expect(previousMonthEnd("2026-01-10")).toBe("2025-12-31");
  });
});
