import { describe, expect, it } from "vitest";
import {
  ASSET_STATUS_LABELS,
  DEPRECIATION_METHOD_LABELS,
  depreciationPlan,
  methodsFor,
  netBookValue,
  type DepreciationPlanInput,
} from "./assets";

const BASE: DepreciationPlanInput = {
  method: "straight_line",
  netBookValue: "12000000",
  residual: "1000000",
  months: 48,
  lifeMonths: 48,
  from: "2027-03-09",
};

function planOf(patch: Partial<DepreciationPlanInput> = {}) {
  const result = depreciationPlan({ ...BASE, ...patch });
  if (!result.ok) throw new Error(`unexpected problem ${result.problem}`);
  return result;
}

describe("the depreciation plan (the same figures as app_private.asset_plan)", () => {
  it("straight line: equal months, the last absorbs the rounding, the total is exactly cost less residual", () => {
    const { rows, total } = planOf();
    expect(rows).toHaveLength(48);
    expect(rows[0].periodMonth).toBe("2027-03-01");
    expect(rows[1].amount.toString()).toBe("229166.67");
    expect(rows[35].periodMonth).toBe("2030-02-01");
    expect(rows[35].amount.toString()).toBe("229166.67");
    expect(rows[47].periodMonth).toBe("2031-02-01");
    expect(rows[47].amount.toString()).toBe("229166.51");
    expect(total.toString()).toBe("11000000.00");
  });

  it("declining balance: front-loaded, never below an even spread, ends at the residual", () => {
    const { rows, total } = planOf({ method: "declining_balance" });
    expect(rows.slice(0, 4).map((row) => row.amount.toString())).toEqual([
      "500000.00",
      "479166.67",
      "459201.39",
      "440068.00",
    ]);
    expect(rows[46].amount.toString()).toBe("129628.72");
    expect(rows[47].amount.toString()).toBe("129628.71");
    expect(rows).toHaveLength(48);
    expect(total.toString()).toBe("11000000.00");
  });

  it("nothing to depreciate when the value equals the residual", () => {
    const { rows, total } = planOf({ residual: "12000000" });
    expect(rows).toEqual([]);
    expect(total.isZero()).toBe(true);
  });

  it("starts in the month of service, crossing years", () => {
    const { rows } = planOf({ months: 3, from: "2027-11-30", residual: "0", netBookValue: "3000" });
    expect(rows.map((row) => row.periodMonth)).toEqual(["2027-11-01", "2027-12-01", "2028-01-01"]);
  });

  it("reports what is wrong instead of guessing", () => {
    const problem = (patch: Partial<DepreciationPlanInput>) => {
      const result = depreciationPlan({ ...BASE, ...patch });
      return result.ok ? null : result.problem;
    };
    expect(problem({ method: "none" as "straight_line" })).toBe("method");
    expect(problem({ netBookValue: "-1" })).toBe("value");
    expect(problem({ netBookValue: "10.001" })).toBe("value");
    expect(problem({ residual: "13000000" })).toBe("residual");
    expect(problem({ months: 0 })).toBe("months");
    expect(problem({ lifeMonths: 0 })).toBe("life");
    expect(problem({ from: "March 2027" })).toBe("from");
    expect(problem({})).toBeNull();
  });
});

describe("book value and rules", () => {
  it("is cost less accumulated depreciation, never below zero", () => {
    expect(netBookValue("12000000", "2291666.70").toString()).toBe("9708333.30");
    expect(netBookValue("1000", "1500").isZero()).toBe(true);
  });

  it("a Personal asset is never depreciated", () => {
    expect(methodsFor("personal")).toEqual(["none"]);
    expect(methodsFor("company")).toEqual(["none", "straight_line", "declining_balance"]);
  });

  it("labels every status and method", () => {
    expect(Object.keys(ASSET_STATUS_LABELS)).toHaveLength(5);
    expect(Object.keys(DEPRECIATION_METHOD_LABELS)).toHaveLength(3);
  });
});
