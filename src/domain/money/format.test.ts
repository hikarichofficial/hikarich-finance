import { describe, expect, it } from "vitest";
import { formatDecimal, formatMoney, formatMoneyExact, formatPlain } from "./format";

describe("money formatting", () => {
  it("groups thousands with dots and uses a decimal comma", () => {
    expect(formatDecimal("1234567.5", 2)).toBe("1.234.567,50");
    expect(formatDecimal("999", 0)).toBe("999");
    expect(formatDecimal("1000", 0)).toBe("1.000");
    expect(formatDecimal("0.005", 2)).toBe("0,01");
  });

  it("keeps the sign and shows the currency", () => {
    expect(formatMoney("1500000", "IDR")).toBe("Rp 1.500.000,00");
    expect(formatMoney("-250.5", "IDR")).toBe("-Rp 250,50");
    expect(formatMoney("1234.5", "USD")).toBe("USD 1.234,50");
    expect(formatMoney("1502", "JPY")).toBe("JPY 1.502");
  });

  it("is exact for amounts a floating-point number cannot hold", () => {
    expect(formatMoney("9007199254740993.01", "IDR")).toBe("Rp 9.007.199.254.740.993,01");
  });

  it("shows quantities and prices without trailing zeros", () => {
    expect(formatPlain("2.5000")).toBe("2,5");
    expect(formatPlain("2.0000")).toBe("2");
    expect(formatPlain("1500000.0000")).toBe("1.500.000");
    expect(formatPlain("100")).toBe("100");
    expect(formatPlain("0.0500")).toBe("0,05");
  });

  it("shows a unit price with every decimal it really has, never rounded", () => {
    expect(formatMoneyExact("150000.0000", "IDR")).toBe("Rp 150.000,00");
    expect(formatMoneyExact("0.0050", "IDR")).toBe("Rp 0,005");
    expect(formatMoneyExact("12.3456", "USD")).toBe("USD 12,3456");
    expect(formatMoneyExact("1000", "JPY")).toBe("JPY 1.000");
  });
});
