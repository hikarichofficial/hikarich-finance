import { describe, expect, it } from "vitest";
import { formatRupiah, parseAmounts } from "./rupiah";

const values = (text: string) => parseAmounts(text).map((a) => a.value);

describe("parseAmounts", () => {
  it("reads units", () => {
    expect(values("kopi 85rb")).toEqual([85_000]);
    expect(values("hosting 1,2jt")).toEqual([1_200_000]);
    expect(values("sewa 2,5 juta")).toEqual([2_500_000]);
    expect(values("parkir 5k")).toEqual([5_000]);
    expect(values("150 ribu")).toEqual([150_000]);
  });
  it("reads Indonesian number formats", () => {
    expect(values("Rp 50.000")).toEqual([50_000]);
    expect(values("Rp50000")).toEqual([50_000]);
    expect(values("total 1.250.000")).toEqual([1_250_000]);
  });
  it("does not take quantities, phone numbers or years as money", () => {
    expect(values("2 x 25k")).toEqual([25_000]);
    expect(values("telp 081234567890")).toEqual([]);
    expect(values("tgl 20")).toEqual([]);
    expect(values("20 okt 2026 makan 40rb")).toEqual([40_000]);
  });
  it("finds several amounts left to right", () => {
    expect(values("kopi 25rb roti 15rb")).toEqual([25_000, 15_000]);
  });
});

describe("formatRupiah", () => {
  it("groups thousands and shows cents only when present", () => {
    expect(formatRupiah(1_250_000)).toBe("Rp 1.250.000");
    expect(formatRupiah(427.81)).toBe("Rp 427,81");
    expect(formatRupiah(-5000)).toBe("-Rp 5.000");
    expect(formatRupiah("85000")).toBe("Rp 85.000");
    expect(formatRupiah(Number.NaN)).toBe("Rp 0");
  });
});
