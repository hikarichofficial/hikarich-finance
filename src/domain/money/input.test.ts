import { describe, expect, it } from "vitest";
import { parseMoneyInput } from "./input";

describe("typed amounts", () => {
  it("reads Indonesian thousands and decimal marks", () => {
    expect(parseMoneyInput("1.500.000")).toBe("1500000");
    expect(parseMoneyInput("1.500.000,50")).toBe("1500000.50");
    expect(parseMoneyInput("250000")).toBe("250000");
    expect(parseMoneyInput("Rp 250.000")).toBe("250000");
    expect(parseMoneyInput("rp. 1.234,5")).toBe("1234.5");
    expect(parseMoneyInput("0,5")).toBe("0.5");
  });

  it("a lone dot is thousands only before exactly three digits", () => {
    expect(parseMoneyInput("1.500")).toBe("1500");
    expect(parseMoneyInput("1.5")).toBe("1.5");
    expect(parseMoneyInput("1.25")).toBe("1.25");
    expect(parseMoneyInput("1,500.75")).toBe("1500.75");
  });

  it("refuses what it cannot read with certainty", () => {
    expect(parseMoneyInput("")).toBeNull();
    expect(parseMoneyInput("abc")).toBeNull();
    expect(parseMoneyInput("-5")).toBeNull();
    expect(parseMoneyInput("1e6")).toBeNull();
    expect(parseMoneyInput("1,500,000")).toBeNull();
    expect(parseMoneyInput("12.34.567")).toBeNull();
    expect(parseMoneyInput("1.500,")).toBeNull();
    expect(parseMoneyInput("1,2,3")).toBeNull();
  });

  it("strips leading zeros without changing the value", () => {
    expect(parseMoneyInput("0001500")).toBe("1500");
    expect(parseMoneyInput("0")).toBe("0");
  });

  it('does not guess between 0.5 and 500 for "0.500"', () => {
    expect(parseMoneyInput("0.500")).toBeNull();
    expect(parseMoneyInput("0.500.000")).toBeNull();
    expect(parseMoneyInput("0.5")).toBe("0.5");
    expect(parseMoneyInput("0,500")).toBe("0.500");
  });
});
