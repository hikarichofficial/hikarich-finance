import { describe, expect, it } from "vitest";
import {
  accountDefault,
  elapsedMonths,
  guideAssetError,
  openingFormProblems,
  originProblem,
  suggestedAccumulated,
  usedAssetLifeMonths,
} from "./assetFormGuide";

describe("usedAssetLifeMonths", () => {
  it("takes the age of the asset off the life of its group", () => {
    expect(usedAssetLifeMonths(96, 2020, "2024-03-01")).toBe(48);
  });
  it("never goes below one year", () => {
    expect(usedAssetLifeMonths(48, 2000, "2024-03-01")).toBe(12);
  });
  it("a car made in the year it was put in service keeps the full life", () => {
    expect(usedAssetLifeMonths(96, 2024, "2024-03-01")).toBe(96);
  });
});

describe("elapsedMonths and suggestedAccumulated", () => {
  it("counts the in-service month and the cut-over month", () => {
    expect(elapsedMonths("2018-04-10", "2026-10-07")).toBe(103);
    expect(elapsedMonths("2026-10-01", "2026-10-31")).toBe(1);
    expect(elapsedMonths("2026-11-01", "2026-10-31")).toBeNull();
  });
  it("is the straight-line amount for the months lived", () => {
    expect(suggestedAccumulated("12000000", "0", "48", "2024-01-05", "2024-12-31")).toBe(3000000);
  });
  it("stops at cost less residual when the life is used up", () => {
    expect(suggestedAccumulated("8300000", "300000", "48", "2018-04-10", "2026-10-07")).toBe(
      8000000,
    );
  });
  it("gives nothing for unusable figures", () => {
    expect(suggestedAccumulated("abc", "0", "48", "2024-01-05", "2024-12-31")).toBeNull();
    expect(suggestedAccumulated("100", "0", "0", "2024-01-05", "2024-12-31")).toBeNull();
  });
});

describe("accountDefault", () => {
  it("suggests the group of the default accounts", () => {
    expect(accountDefault("1531")?.fiscalClass?.key).toBe("group_2");
    expect(accountDefault("1501")?.notDepreciated).toBe(true);
    expect(accountDefault("1540")?.fiscalClass).toBeNull();
    expect(accountDefault("9999")).toBeNull();
  });
});

describe("guideAssetError", () => {
  it("points at the field and says what to do", () => {
    const g = guideAssetError(
      "INVALID: the useful life of AST-1 is used up but a value above the residual remains; give more remaining months",
    );
    expect(g?.field).toBe("accumulated");
    expect(g?.fix).toContain("Isi otomatis");
  });
  it("knows the fiscal method refusal", () => {
    expect(
      guideAssetError(
        "INVALID: the fiscal class of Komputer Kantor is unknown or does not allow that method",
      )?.field,
    ).toBe("fiscal_method");
  });
  it("is null for something it does not know", () => {
    expect(guideAssetError("INVALID: something else")).toBeNull();
    expect(guideAssetError(undefined)).toBeNull();
  });
});

describe("openingFormProblems", () => {
  const ok = {
    cost: "1000",
    residual: "0",
    accumulated: "0",
    acquisitionDate: "2018-04-10",
    serviceDate: "2018-04-10",
    cutoverDate: "2026-10-07",
  };
  it("has nothing to say about a sound form", () => {
    expect(openingFormProblems(ok)).toEqual({});
  });
  it("marks dates out of order and amounts that do not fit", () => {
    expect(openingFormProblems({ ...ok, serviceDate: "2018-01-01" }).in_service_date).toBeDefined();
    expect(openingFormProblems({ ...ok, cutoverDate: "2018-01-01" }).cutover_date).toBeDefined();
    expect(openingFormProblems({ ...ok, accumulated: "1200" }).accumulated).toBeDefined();
    expect(openingFormProblems({ ...ok, residual: "2000" }).residual).toBeDefined();
  });
});

describe("originProblem", () => {
  it("asks for the year of a used asset", () => {
    expect(originProblem("used", "", "2024-01-01")).toContain("tahun pembuatannya");
    expect(originProblem("new", "", "2024-01-01")).toBeUndefined();
  });
  it("refuses a year after the year it was put in service", () => {
    expect(originProblem("used", "2025", "2024-01-01")).toContain("tidak boleh setelah");
    expect(originProblem("used", "2019", "2024-01-01")).toBeUndefined();
  });
  it("refuses a year that is not four digits", () => {
    expect(originProblem("new", "19", "2024-01-01")).toContain("4 angka");
  });
});
