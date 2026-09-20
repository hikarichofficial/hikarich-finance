import { describe, expect, it } from "vitest";
import { Decimal, DecimalError, allocate, sumDecimals } from "./decimal";
import { convertAmount, currencyScale, isKnownCurrency } from "./currency";

const d = (text: string) => Decimal.parse(text);

// The vectors below are the same ones asserted in supabase/tests/90_p3_posting.sql, so the application
// layer and the authoritative database engine are held to identical rounding behaviour.
describe("Decimal parsing and formatting", () => {
  it("parses plain decimals exactly", () => {
    expect(d("0").toString()).toBe("0");
    expect(d("-12.50").toString()).toBe("-12.50");
    expect(d("000123.4500").toString()).toBe("123.4500");
    expect(d("0.0001").units).toBe(BigInt(1));
    expect(d("-0.00").toString()).toBe("0.00");
  });

  it("rejects anything that is not plain decimal text", () => {
    for (const bad of [
      "",
      " 1",
      "1 ",
      "1,000",
      "1e3",
      "1.",
      ".5",
      "+1",
      "--1",
      "abc",
      "1.2.3",
      "NaN",
      "Infinity",
    ]) {
      expect(() => d(bad), bad).toThrow(DecimalError);
    }
    expect(() => Decimal.parse(12.5 as unknown as string)).toThrow(DecimalError);
    expect(Decimal.tryParse("x")).toBeNull();
    expect(Decimal.tryParse(undefined)).toBeNull();
    expect(Decimal.tryParse("1.5")?.toString()).toBe("1.5");
  });

  it("keeps 0.1 + 0.2 exact, unlike binary floating point", () => {
    expect(d("0.1").add(d("0.2")).toString()).toBe("0.3");
    expect(d("0.1").add(d("0.2")).eq(d("0.3"))).toBe(true);
    expect(0.1 + 0.2).not.toBe(0.3);
  });

  it("handles values beyond Number.MAX_SAFE_INTEGER without loss", () => {
    const big = d("99999999999999999999.9999");
    expect(big.add(d("0.0001")).toString()).toBe("100000000000000000000.0000");
  });

  it("supports add, sub, mul and comparisons across scales", () => {
    expect(d("1.5").sub(d("2.25")).toString()).toBe("-0.75");
    expect(d("1.5").mul(d("2.25")).toString()).toBe("3.375");
    expect(d("1.50").cmp(d("1.5"))).toBe(0);
    expect(d("2").cmp(d("1.999"))).toBe(1);
    expect(d("-1").cmp(d("0"))).toBe(-1);
    expect(d("0.00").isZero()).toBe(true);
    expect(sumDecimals([d("1.10"), d("2.20"), d("3.30")]).toString()).toBe("6.60");
    expect(d("-3.5").abs().toString()).toBe("3.5");
    expect(d("3.5").negate().toString()).toBe("-3.5");
  });
});

describe("rounding parity with app_private.round_amount", () => {
  const r = (v: string, scale: number, mode?: "half_up" | "half_even" | "down" | "up") =>
    d(v).round(scale, mode).toString();

  it("half_up: ties away from zero", () => {
    expect(r("2.5", 0)).toBe("3");
    expect(r("-2.5", 0)).toBe("-3");
    expect(r("0.125", 2)).toBe("0.13");
    expect(r("-0.125", 2)).toBe("-0.13");
    expect(r("1.004", 2)).toBe("1.00");
    expect(r("1.005", 2)).toBe("1.01");
  });

  it("half_even: ties to the even neighbour", () => {
    expect(r("2.5", 0, "half_even")).toBe("2");
    expect(r("3.5", 0, "half_even")).toBe("4");
    expect(r("-2.5", 0, "half_even")).toBe("-2");
    expect(r("0.125", 2, "half_even")).toBe("0.12");
    expect(r("0.135", 2, "half_even")).toBe("0.14");
    expect(r("2.6", 0, "half_even")).toBe("3");
  });

  it("directed modes", () => {
    expect(r("2.999", 2, "down")).toBe("2.99");
    expect(r("-2.999", 2, "down")).toBe("-2.99");
    expect(r("2.001", 2, "up")).toBe("2.01");
    expect(r("-2.001", 2, "up")).toBe("-2.01");
    expect(r("2.00", 2, "up")).toBe("2.00");
  });

  it("rounds up to a wider scale exactly and never loses sign of zero", () => {
    expect(r("2.5", 4)).toBe("2.5000");
    expect(r("-0.001", 2)).toBe("0.00");
  });

  it("rejects bad scales and modes", () => {
    expect(() => d("1").round(11)).toThrow(DecimalError);
    expect(() => d("1").round(-1)).toThrow(DecimalError);
    expect(() => d("1").round(2, "banana" as never)).toThrow(DecimalError);
  });

  it("fitsScale tells whether rounding would change anything", () => {
    expect(d("10.50").fitsScale(2)).toBe(true);
    expect(d("10.501").fitsScale(2)).toBe(false);
    expect(d("10.500").fitsScale(2)).toBe(true);
  });
});

describe("currency conversion", () => {
  it("knows minor units and rejects unknown currencies", () => {
    expect(currencyScale("IDR")).toBe(2);
    expect(currencyScale("JPY")).toBe(0);
    expect(isKnownCurrency("USD")).toBe(true);
    expect(isKnownCurrency("XXX")).toBe(false);
    expect(() => currencyScale("XXX")).toThrow(DecimalError);
  });

  it("rounds once with the target currency's minor unit", () => {
    expect(convertAmount(d("10"), d("16000.55"), "IDR").toString()).toBe("160005.50");
    expect(convertAmount(d("100"), d("155.555"), "JPY").toString()).toBe("15556");
    expect(() => convertAmount(d("1"), d("0"), "IDR")).toThrow(DecimalError);
  });
});

describe("allocation parity with app_private.allocate_amount", () => {
  const parts = (total: string, weights: number[], scale: number) =>
    allocate(d(total), weights, scale).map((p) => p.toString());

  it("gives the leftover units to the largest remainders, earliest first", () => {
    expect(parts("100", [1, 1, 1], 2)).toEqual(["33.34", "33.33", "33.33"]);
    expect(parts("0.05", [1, 1, 1], 2)).toEqual(["0.02", "0.02", "0.01"]);
    expect(parts("-100", [1, 1, 1], 2)).toEqual(["-33.34", "-33.33", "-33.33"]);
    expect(parts("10", [0, 1], 2)).toEqual(["0.00", "10.00"]);
    expect(parts("7", [1], 0)).toEqual(["7"]);
  });

  it("rejects impossible requests", () => {
    expect(() => allocate(d("1"), [], 2)).toThrow(DecimalError);
    expect(() => allocate(d("1"), [0, 0], 2)).toThrow(DecimalError);
    expect(() => allocate(d("1"), [-1, 2], 2)).toThrow(DecimalError);
    expect(() => allocate(d("1.001"), [1], 2)).toThrow(DecimalError);
    expect(() => allocate(d("1"), [1.5], 2)).toThrow(DecimalError);
  });

  it("always sums exactly to the total (deterministic random property)", () => {
    // Small deterministic PRNG so the test never flakes.
    let seed = 0x2f6e2b1;
    const next = () => {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      return seed / 0x100000000;
    };
    for (let n = 0; n < 500; n += 1) {
      const cents = Math.floor(next() * 2_000_000);
      const total = Decimal.fromUnits(BigInt(cents), 2);
      const weights = Array.from({ length: 1 + Math.floor(next() * 6) }, () =>
        Math.floor(next() * 40),
      );
      if (!weights.some((w) => w > 0)) weights[0] = 1;
      const result = allocate(total, weights, 2);
      expect(sumDecimals(result).eq(total)).toBe(true);
      const weightSum = weights.reduce((a, b) => a + b, 0);
      result.forEach((part, i) => {
        expect(part.isNegative()).toBe(false);
        // within one unit of the exact proportional share
        const exactTimesSum = BigInt(cents) * BigInt(weights[i]);
        const partTimesSum = part.units * BigInt(weightSum);
        const diff =
          partTimesSum > exactTimesSum
            ? partTimesSum - exactTimesSum
            : exactTimesSum - partTimesSum;
        expect(diff < BigInt(weightSum)).toBe(true);
      });
    }
  });
});
