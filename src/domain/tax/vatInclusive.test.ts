import { describe, expect, it } from "vitest";
import { splitVatInclusive } from "./vatInclusive";

describe("splitVatInclusive", () => {
  it("splits a receipt total into the price before VAT and the VAT", () => {
    expect(splitVatInclusive("397000")).toEqual({ net: "357658", vat: "39342" });
    expect(splitVatInclusive("111000")).toEqual({ net: "100000", vat: "11000" });
  });

  it("keeps decimals and always adds up to the total", () => {
    const split = splitVatInclusive("1500.5");
    expect(split).toEqual({ net: "1351.8", vat: "148.7" });
    expect(Number(split?.net) + Number(split?.vat)).toBeCloseTo(1500.5, 6);
  });

  it("returns null for nothing or nonsense", () => {
    expect(splitVatInclusive("")).toBeNull();
    expect(splitVatInclusive("0")).toBeNull();
    expect(splitVatInclusive("abc")).toBeNull();
  });
});
