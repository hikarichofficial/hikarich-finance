import { describe, expect, it } from "vitest";
import { foldToAmount, hasDetailedQuantity } from "./expenseAmount";

describe("foldToAmount", () => {
  it("keeps the price when the quantity is empty or 1", () => {
    expect(foldToAmount("", "150000")).toBe("150000");
    expect(foldToAmount("1", "150000")).toBe("150000");
  });
  it("multiplies quantity by price", () => {
    expect(foldToAmount("2", "150000")).toBe("300000");
    expect(foldToAmount("1,5", "10000")).toBe("15000");
    expect(foldToAmount("3", "1250.5")).toBe("3751.5");
  });
  it("leaves an empty price or odd text alone", () => {
    expect(foldToAmount("2", "")).toBe("");
    expect(foldToAmount("abc", "100")).toBe("100");
  });
});

describe("hasDetailedQuantity", () => {
  it("is true only when a quantity other than 1 exists", () => {
    expect(hasDetailedQuantity([{ quantity: "1.0000" }, {}])).toBe(false);
    expect(hasDetailedQuantity([{ quantity: "2" }])).toBe(true);
    expect(hasDetailedQuantity([])).toBe(false);
  });
});
